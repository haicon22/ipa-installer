import SwiftUI

/// Màn hình 5: Cài đặt ứng dụng (Tùy chọn ký, kiểm định chứng chỉ 6 bước & kích hoạt Engine)
struct InstallAppView: View {
    @EnvironmentObject private var appState: AppState
    let packageItem: IPAPackageItem

    @State private var options = SigningOptions()
    @State private var validationSteps: [CertificateCheckStep] = []
    @State private var isRunningAction = false
    @State private var progressFraction: Double = 0
    @State private var progressMessage: String = ""

    var body: some View {
        List {
            Section(header: Text("1. Chọn chứng chỉ ký số")) {
                if appState.certificates.isEmpty {
                    Text("Chưa có cặp chứng chỉ (.p12 + .mobileprovision) nào trong kho. Vui lòng thêm tại tab Chứng chỉ hoặc sử dụng luồng Apple Personal Team ở Giai đoạn 5–6.")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                } else {
                    Picker("Chứng chỉ sử dụng", selection: $appState.selectedCertificateId) {
                        ForEach(appState.certificates) { cert in
                            Text(cert.nickname).tag(Optional(cert.id))
                        }
                    }
                }
            }

            Section(
                header: Text("2. Tùy chỉnh gói trước khi ký"),
                footer: Text("Bật 'Gỡ bỏ PlugIns phụ' giúp tiết kiệm hạn ngạch 10 App ID mỗi 7 ngày khi dùng Apple Personal Team miễn phí.")
            ) {
                TextField("Giữ nguyên Bundle ID gốc (hoặc nhập mới)", text: $options.customBundleId)
                    .autocapitalization(.none)
                    .disableAutocorrection(true)
                    .font(.system(.subheadline, design: .monospaced))

                TextField("Giữ nguyên tên hiển thị (hoặc nhập mới)", text: $options.customDisplayName)

                Toggle("Gỡ bỏ PlugIns / App Extensions (.appex)", isOn: $options.stripAppExtensions)
                Toggle("Mở quyền chia sẻ thư mục qua Tệp (Files)", isOn: $options.enableFileSharing)
            }

            if !validationSteps.isEmpty {
                Section(header: Text("Kết quả chốt chặn kiểm tra chứng chỉ")) {
                    ForEach(validationSteps) { step in
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: step.passed ? "checkmark.circle.fill" : (step.isBlocking ? "xmark.octagon.fill" : "exclamationmark.triangle.fill"))
                                .foregroundColor(step.passed ? .green : (step.isBlocking ? .red : .orange))
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Bước \(step.id): \(step.title)")
                                    .font(.subheadline.weight(.semibold))
                                Text(step.detail)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
            }

            if isRunningAction {
                Section(header: Text("Tiến trình xử lý")) {
                    ProgressView(value: progressFraction)
                    Text(progressMessage)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            Section(
                header: Text("3. Thực thi Ký & Cài đặt"),
                footer: Text("Nguyên tắc trung thực: Nút thực thi chỉ mở khóa khi các module ZSign C++ (Giai đoạn 4) và Installation Engine (Giai đoạn 6) đã được gắn đầy đủ — không tạo tiến trình giả lập.")
            ) {
                if appState.ipaSigner == nil || appState.installationManager == nil {
                    HStack(spacing: 10) {
                        Image(systemName: "wrench.and.screwdriver.fill")
                            .foregroundColor(.orange)
                        Text("Nhân ký ZSign C++ (Giai đoạn 4) và Installation Engine (Giai đoạn 6) đang trong lộ trình tích hợp kế tiếp.")
                            .font(.footnote)
                            .foregroundColor(.secondary)
                    }
                } else {
                    Button {
                        Task {
                            await runSignAndInstallFlow()
                        }
                    } label: {
                        Label("Kiểm định chứng chỉ, Ký số & Cài đặt", systemImage: "arrow.down.app.fill")
                            .font(.subheadline.weight(.semibold))
                    }
                    .disabled(isRunningAction || appState.activeCertificate == nil)
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Cài đặt ứng dụng")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func runSignAndInstallFlow() async {
        guard let cert = appState.activeCertificate,
              let validator = appState.certValidator,
              let signer = appState.ipaSigner,
              let installer = appState.installationManager,
              let srcURL = try? appState.storage.resolveURL(for: packageItem.relativeFilePath) else {
            return
        }

        isRunningAction = true
        progressFraction = 0.1
        progressMessage = "Đang kiểm tra chứng chỉ 6 bước & OCSP..."

        let steps = await validator.validateBeforeSigning(
            certificate: cert,
            package: packageItem,
            userDeviceUDID: appState.userDeviceUDID,
            checkOnlineOCSP: appState.autoCheckOCSPBeforeInstall
        )
        validationSteps = steps

        if steps.contains(where: { !$0.passed && $0.isBlocking }) {
            isRunningAction = false
            appState.logger.error("Validator", "Chặn cài đặt \(packageItem.effectiveTitle) do không vượt qua kiểm định chứng chỉ.")
            return
        }

        do {
            let signedURL = try await signer.signPackage(
                sourceIPAURL: srcURL,
                certificate: cert,
                options: options
            ) { frac, msg in
                Task { @MainActor in
                    self.progressFraction = 0.2 + frac * 0.6
                    self.progressMessage = msg
                }
            }

            progressFraction = 0.9
            progressMessage = "Đang chuyển giao gói đã ký cho Installation Engine..."
            let method = try await installer.triggerInstallation(
                signedIPAURL: signedURL,
                package: packageItem,
                certificate: cert
            )

            progressFraction = 1.0
            progressMessage = "Đã kích hoạt cài đặt qua \(method)."
            appState.recordHistory(
                InstallHistoryEntry(
                    appName: packageItem.effectiveTitle,
                    bundleId: packageItem.effectiveBundleId,
                    version: packageItem.metadata?.version ?? "1.0",
                    methodUsed: method,
                    succeeded: true,
                    detailMessage: "Ký và gọi trình cài đặt hệ thống thành công.",
                    iosVersion: DeviceEnvironment.iosVersionString
                )
            )
            if appState.autoCleanTempAfterSign {
                appState.cleanTemporaryFiles()
            }
        } catch {
            appState.alertMessage = error.localizedDescription
            appState.recordHistory(
                InstallHistoryEntry(
                    appName: packageItem.effectiveTitle,
                    bundleId: packageItem.effectiveBundleId,
                    version: packageItem.metadata?.version ?? "1.0",
                    methodUsed: "ZSign + Engine",
                    succeeded: false,
                    detailMessage: error.localizedDescription,
                    iosVersion: DeviceEnvironment.iosVersionString
                )
            )
        }

        isRunningAction = false
    }
}

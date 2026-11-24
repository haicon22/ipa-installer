import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Màn hình 6: Quản lý chứng chỉ (.p12 + .mobileprovision & Keychain)
struct CertificateManagerView: View {
    @EnvironmentObject private var appState: AppState

    private enum ActivePicker: Identifiable {
        case p12
        case provision
        var id: Int { hashValue }
    }

    @State private var activePicker: ActivePicker?
    @State private var pickedP12URL: URL?
    @State private var pickedProvisionURL: URL?
    @State private var p12Password: String = ""
    @State private var nickname: String = ""

    var body: some View {
        AdaptiveNavigation {
            List {
                Section(
                    header: Text("Nhập cặp chứng chỉ riêng (BYOC)"),
                    footer: Text("Mật khẩu .p12 được mã hóa trực tiếp vào iOS Keychain của thiết bị. Ứng dụng không phụ thuộc hay mặc định tin cậy các dịch vụ chứng chỉ chia sẻ.")
                ) {
                    Button {
                        activePicker = .p12
                    } label: {
                        HStack {
                            Label("1. Chọn tệp chứng chỉ (.p12)", systemImage: "key.fill")
                            Spacer()
                            if let url = pickedP12URL {
                                Text(url.lastPathComponent)
                                    .font(.caption)
                                    .foregroundColor(.green)
                                    .lineLimit(1)
                            }
                        }
                    }

                    SecureField("Mật khẩu giải mã tệp .p12", text: $p12Password)

                    Button {
                        activePicker = .provision
                    } label: {
                        HStack {
                            Label("2. Chọn Provisioning (.mobileprovision)", systemImage: "doc.badge.gearshape")
                            Spacer()
                            if let url = pickedProvisionURL {
                                Text(url.lastPathComponent)
                                    .font(.caption)
                                    .foregroundColor(.green)
                                    .lineLimit(1)
                            }
                        }
                    }

                    TextField("Tên gợi nhớ (tùy chọn)", text: $nickname)

                    Button {
                        importCertificatePair()
                    } label: {
                        Label("Xác thực PKCS#12 & Lưu vào Keychain", systemImage: "lock.shield.fill")
                            .font(.subheadline.weight(.semibold))
                    }
                    .disabled(pickedP12URL == nil || pickedProvisionURL == nil)
                }

                Section(header: Text("Kho chứng chỉ đã lưu (\(appState.certificates.count))")) {
                    if appState.certificates.isEmpty {
                        Text("Chưa có chứng chỉ nào được lưu. Ở chế độ 0 đồng, bạn có thể dùng Apple Personal Team (cài qua Pairing File) hoặc phân tích IPA không cần chứng chỉ.")
                            .font(.footnote)
                            .foregroundColor(.secondary)
                    } else {
                        ForEach(appState.certificates) { cert in
                            VStack(alignment: .leading, spacing: 5) {
                                HStack {
                                    Text(cert.nickname)
                                        .font(.subheadline.weight(.semibold))
                                    Spacer()
                                    if appState.selectedCertificateId == cert.id {
                                        StatusBadge("Đang chọn", tone: .success)
                                    }
                                }
                                Text(cert.commonName)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                Text("Serial: \(cert.serialNumber) • OCSP: \(cert.lastOCSPStatus.rawValue)")
                                    .font(.system(.caption2, design: .monospaced))
                                    .foregroundColor(.secondary)

                                if appState.selectedCertificateId != cert.id {
                                    Button("Đặt làm mặc định") {
                                        appState.selectedCertificateId = cert.id
                                    }
                                    .font(.caption.weight(.semibold))
                                    .padding(.top, 2)
                                }
                            }
                            .padding(.vertical, 4)
                        }
                        .onDelete { offsets in
                            let targets = offsets.map { appState.certificates[$0] }
                            targets.forEach { appState.deleteCertificate($0) }
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Quản lý chứng chỉ")
            .sheet(item: $activePicker) { mode in
                DocumentPickerSheet(allowedTypes: allowedTypes(for: mode)) { selectedURL in
                    switch mode {
                    case .p12:
                        pickedP12URL = selectedURL
                    case .provision:
                        pickedProvisionURL = selectedURL
                    }
                }
            }
        }
    }

    private func allowedTypes(for mode: ActivePicker) -> [UTType] {
        switch mode {
        case .p12:
            var list: [UTType] = [.x509Certificate, .data]
            if let p12 = UTType(filenameExtension: "p12") { list.insert(p12, at: 0) }
            return list
        case .provision:
            var list: [UTType] = [.data]
            if let mp = UTType(filenameExtension: "mobileprovision") { list.insert(mp, at: 0) }
            return list
        }
    }

    private func importCertificatePair() {
        guard let p12URL = pickedP12URL, let provURL = pickedProvisionURL else { return }
        do {
            try appState.importBasicCertificatePair(
                p12SourceURL: p12URL,
                password: p12Password,
                provisionSourceURL: provURL,
                nickname: nickname
            )
            pickedP12URL = nil
            pickedProvisionURL = nil
            p12Password = ""
            nickname = ""
        } catch {
            appState.alertMessage = error.localizedDescription
        }
    }
}

private struct DocumentPickerSheet: UIViewControllerRepresentable {
    let allowedTypes: [UTType]
    let onPick: (URL) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onPick: onPick)
    }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        // asCopy: true sao chép an toàn tệp vào thư mục tạm để đọc ổn định trên mọi đời iOS 15+
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: allowedTypes, asCopy: true)
        picker.allowsMultipleSelection = false
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onPick: (URL) -> Void

        init(onPick: @escaping (URL) -> Void) {
            self.onPick = onPick
        }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            guard let first = urls.first else { return }
            onPick(first)
        }
    }
}

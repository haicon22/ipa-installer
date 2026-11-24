import SwiftUI
import UIKit

/// Màn hình 4: Chi tiết ứng dụng (Phong cách App Store chuyên nghiệp)
struct AppDetailView: View {
    @EnvironmentObject private var appState: AppState
    let packageItem: IPAPackageItem
    @State private var showingShareSheet = false

    private var currentPackage: IPAPackageItem {
        appState.packages.first(where: { $0.id == packageItem.id }) ?? packageItem
    }

    var body: some View {
        List {
            // Phần đầu kiểu App Store
            Section {
                HStack(spacing: 16) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .fill(Color.accentColor.opacity(0.14))
                            .frame(width: 78, height: 78)

                        if let data = currentPackage.metadata?.iconPNGData,
                           let img = UIImage(data: data) {
                            Image(uiImage: img)
                                .resizable()
                                .scaledToFill()
                                .frame(width: 78, height: 78)
                                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                        } else {
                            Image(systemName: "app.badge.checkmark")
                                .font(.system(size: 32))
                                .foregroundColor(.accentColor)
                        }
                    }

                    VStack(alignment: .leading, spacing: 5) {
                        Text(currentPackage.effectiveTitle)
                            .font(.headline)
                        Text(currentPackage.effectiveBundleId)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundColor(.secondary)
                        HStack(spacing: 6) {
                            StatusBadge(
                                currentPackage.isSignedOutput ? "Đã ký số" : "IPA gốc",
                                tone: currentPackage.isSignedOutput ? .success : .neutral
                            )
                            if let meta = currentPackage.metadata {
                                StatusBadge(
                                    meta.isFairPlayEncrypted ? "Khóa FairPlay" : "Đã giải mã",
                                    tone: meta.isFairPlayEncrypted ? .danger : .success
                                )
                            }
                        }
                    }
                }
                .padding(.vertical, 6)

                NavigationLink(destination: InstallAppView(packageItem: currentPackage)) {
                    HStack {
                        Spacer()
                        Label("Cấu hình ký & Cài đặt ứng dụng", systemImage: "signature")
                            .font(.subheadline.weight(.semibold))
                        Spacer()
                    }
                }
            }

            if let meta = currentPackage.metadata {
                Section(header: Text("Thông tin định danh & Tương thích")) {
                    InfoRow(title: "Phiên bản", value: "\(meta.version) (Build \(meta.buildNumber))")
                    InfoRow(
                        title: "iOS tối thiểu",
                        value: "iOS \(meta.minimumOSVersion ?? "Không rõ")",
                        valueColor: DeviceEnvironment.isMinimumOSMet(meta.minimumOSVersion) ? .primary : .red
                    )
                    InfoRow(title: "Kiến trúc CPU", value: meta.architectures.joined(separator: ", "), monospaced: true)
                    InfoRow(title: "Dung lượng IPA nén", value: DeviceEnvironment.formatBytes(currentPackage.fileSize))
                    InfoRow(title: "Dung lượng giải nén", value: DeviceEnvironment.formatBytes(meta.uncompressedBytes))
                    InfoRow(
                        title: "Chi phí App ID (Personal Team)",
                        value: "\(meta.personalTeamAppIDCostWithExtensions)/10 App ID (1 nếu gỡ PlugIns)"
                    )
                }

                Section(header: Text("Chữ ký & Provisioning Profile")) {
                    InfoRow(title: "Trạng thái chữ ký", value: meta.signatureSummaryVi)
                    if let prov = meta.provisioning {
                        InfoRow(title: "Tên Profile", value: prov.profileName)
                        InfoRow(title: "Loại phân phối", value: prov.distributionType)
                        InfoRow(title: "Team", value: "\(prov.teamName) (\(prov.teamIdentifier))")
                        InfoRow(title: "Số UDID đăng ký", value: prov.provisionsAllDevices ? "Mọi thiết bị" : "\(prov.provisionedUDIDs.count)")
                    }
                }

                Section(header: Text("Thành phần nhúng (\(meta.appExtensions.count) PlugIns, \(meta.frameworks.count) Frameworks)")) {
                    if meta.appExtensions.isEmpty && meta.frameworks.isEmpty {
                        Text("Không có App Extension hay Framework phụ.")
                            .font(.footnote)
                            .foregroundColor(.secondary)
                    } else {
                        ForEach(meta.appExtensions) { ext in
                            InfoRow(title: "AppEx: \(ext.displayName)", value: ext.bundleId, monospaced: true)
                        }
                        ForEach(meta.frameworks, id: \.self) { fw in
                            InfoRow(title: "Framework", value: fw, monospaced: true)
                        }
                    }
                }
            } else {
                Section(header: Text("Thông tin tệp lưu trữ")) {
                    InfoRow(title: "Tên tệp", value: currentPackage.fileName, monospaced: true)
                    InfoRow(title: "Dung lượng", value: DeviceEnvironment.formatBytes(currentPackage.fileSize))
                    Text("Bộ giải mã sâu nhị phân Native (IPA Parser: Info.plist, CgBI PNG, Mach-O & CMS) sẽ được gắn vào tự động ở Giai đoạn 4.")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
            }

            Section {
                Button {
                    showingShareSheet = true
                } label: {
                    Label("Chia sẻ / Xuất tệp .ipa", systemImage: "square.and.arrow.up")
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Chi tiết ứng dụng")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showingShareSheet) {
            if let fileURL = try? appState.storage.resolveURL(for: currentPackage.relativeFilePath) {
                ShareSheet(activityItems: [fileURL])
            }
        }
    }
}

import SwiftUI
import UniformTypeIdentifiers

/// Màn hình 1: Trang chủ
struct HomeView: View {
    @EnvironmentObject private var appState: AppState
    @Binding var selectedTab: Int
    @State private var showingFileImporter = false

    private var allowedIPATypes: [UTType] {
        var list: [UTType] = [.data, .archive, .zip]
        if let ipaType = UTType(filenameExtension: "ipa") {
            list.insert(ipaType, at: 0)
        }
        return list
    }

    var body: some View {
        AdaptiveNavigation {
            List {
                // Thao tác nhanh
                Section(header: Text("Thao tác nhanh")) {
                    Button {
                        showingFileImporter = true
                    } label: {
                        Label("Chọn tệp IPA từ ứng dụng Tệp (Files)", systemImage: "folder.badge.plus")
                            .font(.subheadline.weight(.semibold))
                    }

                    Button {
                        selectedTab = 1
                    } label: {
                        Label("Tải IPA trực tiếp từ liên kết URL", systemImage: "link.badge.plus")
                            .font(.subheadline.weight(.semibold))
                    }
                }

                // Trạng thái hệ thống & Phương thức cài đặt
                Section(header: Text("Trạng thái thiết bị & Phương thức cài đặt")) {
                    InfoRow(
                        title: "Thiết bị & Hệ điều hành",
                        value: "\(DeviceEnvironment.deviceModelIdentifier) • iOS \(DeviceEnvironment.iosVersionString)"
                    )
                    InfoRow(
                        title: "Chứng chỉ đang chọn",
                        value: appState.activeCertificate?.nickname ?? "Chưa cấu hình (Chế độ Phân tích / 0đ)",
                        valueColor: appState.activeCertificate == nil ? .secondary : .green
                    )
                    InfoRow(
                        title: "Trạng thái Engine cài đặt",
                        value: appState.installationManager?.statusSummary ?? "Đang chờ tích hợp ở Giai đoạn 6"
                    )
                    InfoRow(
                        title: "Dung lượng lưu trữ sử dụng",
                        value: DeviceEnvironment.formatBytes(appState.storageUsage.totalBytes)
                    )
                }

                // Danh sách IPA gần đây
                Section(header: Text("IPA đã nhập gần đây (\(appState.packages.count))")) {
                    if appState.packages.isEmpty {
                        Text("Chưa có tệp IPA nào. Hãy chọn tệp từ ứng dụng Tệp hoặc nhập qua URL.")
                            .font(.footnote)
                            .foregroundColor(.secondary)
                            .padding(.vertical, 4)
                    } else {
                        ForEach(appState.packages.prefix(5)) { pkg in
                            NavigationLink(destination: AppDetailView(packageItem: pkg)) {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(pkg.effectiveTitle)
                                        .font(.subheadline.weight(.semibold))
                                    Text("\(pkg.effectiveBundleId) • \(DeviceEnvironment.formatBytes(pkg.fileSize))")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                                .padding(.vertical, 2)
                            }
                        }
                    }
                }

                // Truy cập nhanh toàn bộ 10 phân hệ quản trị
                Section(header: Text("Công cụ & Nhật ký hệ thống")) {
                    NavigationLink(destination: DeviceProfileView()) {
                        Label("Quản lý định danh thiết bị & Hồ sơ", systemImage: "iphone")
                    }
                    NavigationLink(destination: InstallHistoryView()) {
                        Label("Lịch sử cài đặt (\(appState.history.count))", systemImage: "clock.arrow.circlepath")
                    }
                    NavigationLink(destination: ActivityLogView()) {
                        Label("Nhật ký hoạt động (\(appState.logger.entries.count))", systemImage: "doc.text.magnifyingglass")
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("IPA Installer")
            .fileImporter(
                isPresented: $showingFileImporter,
                allowedContentTypes: allowedIPATypes,
                allowsMultipleSelection: false
            ) { result in
                switch result {
                case .success(let urls):
                    if let first = urls.first {
                        appState.importIPAFromURL(first)
                    }
                case .failure(let err):
                    appState.alertMessage = "Không thể mở tệp: \(err.localizedDescription)"
                }
            }
        }
    }
}

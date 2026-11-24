import SwiftUI

/// Màn hình 10: Thiết lập hệ thống
struct SystemSettingsView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        AdaptiveNavigation {
            List {
                Section(header: Text("Giao diện & Hiển thị")) {
                    Picker("Chế độ màu", selection: $appState.themeRaw) {
                        ForEach(AppThemePreference.allCases) { pref in
                            Text(pref.rawValue).tag(pref.rawValue)
                        }
                    }
                }

                Section(
                    header: Text("Kiểm định chứng chỉ & Máy chủ nội bộ"),
                    footer: Text("Kiểm tra OCSP trực tuyến giúp phát hiện ngay chứng chỉ đã bị Apple thu hồi trước khi cài đặt.")
                ) {
                    Toggle("Tự động kiểm tra OCSP Apple trước khi cài", isOn: $appState.autoCheckOCSPBeforeInstall)
                    Toggle("Tự động dọn tệp giải nén tạm sau khi ký", isOn: $appState.autoCleanTempAfterSign)

                    Stepper(
                        "Cổng Local Server: \(appState.localServerPort)",
                        value: $appState.localServerPort,
                        in: 1024...65000
                    )
                }

                Section(header: Text("Quản lý dung lượng lưu trữ (Sandbox)")) {
                    InfoRow(
                        title: "Kho IPA gốc đã nhập",
                        value: DeviceEnvironment.formatBytes(appState.storageUsage.importedIPAsBytes)
                    )
                    InfoRow(
                        title: "Kho IPA đã ký số",
                        value: DeviceEnvironment.formatBytes(appState.storageUsage.signedIPAsBytes)
                    )
                    InfoRow(
                        title: "Kho chứng chỉ",
                        value: DeviceEnvironment.formatBytes(appState.storageUsage.certificatesBytes)
                    )
                    InfoRow(
                        title: "Vùng làm việc tạm (Temp)",
                        value: DeviceEnvironment.formatBytes(appState.storageUsage.tempBytes)
                    )

                    Button {
                        appState.cleanTemporaryFiles()
                    } label: {
                        Label("Dọn dẹp bộ nhớ tạm ngay", systemImage: "trash")
                    }
                }

                Section(header: Text("Truy cập quản trị nâng cao")) {
                    NavigationLink(destination: DeviceProfileView()) {
                        Label("Định danh UDID & Hồ sơ thiết bị", systemImage: "iphone")
                    }
                    NavigationLink(destination: InstallHistoryView()) {
                        Label("Lịch sử cài đặt", systemImage: "clock.arrow.circlepath")
                    }
                    NavigationLink(destination: ActivityLogView()) {
                        Label("Nhật ký hoạt động hệ thống", systemImage: "terminal")
                    }
                }

                Section(header: Text("Thông tin ứng dụng")) {
                    InfoRow(title: "Phiên bản", value: "1.0.0 (Build 100 – Giai đoạn 3)")
                    InfoRow(title: "Dải iOS hỗ trợ", value: "iOS 15.0 → iOS 26.6+")
                    InfoRow(title: "Chi phí bản quyền", value: "0 đồng (Mã nguồn mở)")
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Thiết lập hệ thống")
            .onAppear {
                appState.refreshStorageUsage()
            }
        }
    }
}

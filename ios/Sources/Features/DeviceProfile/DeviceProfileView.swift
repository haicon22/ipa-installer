import SwiftUI

/// Màn hình 7: Quản lý định danh thiết bị & Hồ sơ (UDID, Developer Mode & Hạn ngạch Personal Team)
struct DeviceProfileView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        List {
            Section(header: Text("Thông số thiết bị hiện hành")) {
                InfoRow(title: "Mã phần cứng", value: DeviceEnvironment.deviceModelIdentifier, monospaced: true)
                InfoRow(title: "Phiên bản hệ điều hành", value: "iOS \(DeviceEnvironment.iosVersionString)")
                InfoRow(
                    title: "Yêu cầu Developer Mode",
                    value: DeviceEnvironment.requiresDeveloperModeToggle
                        ? "Bắt buộc bật (iOS 16+)"
                        : "Không yêu cầu (iOS 15.x)",
                    valueColor: DeviceEnvironment.requiresDeveloperModeToggle ? .orange : .green
                )
            }

            Section(
                header: Text("Định danh UDID thiết bị của bạn"),
                footer: Text("Ứng dụng iOS trong vùng Sandbox không được Apple cho phép tự đọc UDID phần cứng bằng Public API. Nhập UDID chiếc iPhone của bạn tại đây để tự động kiểm tra khớp danh sách ProvisionedDevices trước khi cài đặt.")
            ) {
                TextField("Ví dụ: 00008130-001A2B3C4D5E6F01", text: $appState.userDeviceUDID)
                    .autocapitalization(.allCharacters)
                    .disableAutocorrection(true)
                    .font(.system(.subheadline, design: .monospaced))
            }

            if DeviceEnvironment.requiresDeveloperModeToggle {
                Section(header: Text("Hướng dẫn cho iOS \(DeviceEnvironment.majorIOSVersion)")) {
                    Text("Khi sử dụng chứng chỉ Apple Development (bao gồm tài khoản Apple ID 0 đồng), hãy mở Cài đặt > Quyền riêng tư & Bảo mật > Chế độ nhà phát triển (Developer Mode) và gạt Bật.")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
            }

            Section(header: Text("Giới hạn thực tế của Apple Personal Team (0 đồng)")) {
                InfoRow(title: "Thời hạn chứng chỉ", value: "7 ngày (cần gia hạn định kỳ)")
                InfoRow(title: "Số ứng dụng tối đa trên máy", value: "3 ứng dụng hoạt động cùng lúc")
                InfoRow(title: "Hạn ngạch đăng ký App ID", value: "10 App ID mỗi 7 ngày (tính cả .appex)")
                InfoRow(title: "Cài qua Safari itms-services", value: "Không hỗ trợ (cần Pairing File)", valueColor: .orange)
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Thiết bị & Hồ sơ")
        .navigationBarTitleDisplayMode(.inline)
    }
}

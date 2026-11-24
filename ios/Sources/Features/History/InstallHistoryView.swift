import SwiftUI

/// Màn hình 8: Lịch sử cài đặt
struct InstallHistoryView: View {
    @EnvironmentObject private var appState: AppState

    private let dateFormatter: DateFormatter = {
        let df = DateFormatter()
        df.locale = Locale(identifier: "vi_VN")
        df.dateStyle = .short
        df.timeStyle = .medium
        return df
    }()

    var body: some View {
        List {
            if appState.history.isEmpty {
                Section {
                    Text("Chưa có lịch sử ký hoặc cài đặt ứng dụng nào được ghi nhận.")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
            } else {
                Section(header: Text("Các phiên thực hiện (\(appState.history.count))")) {
                    ForEach(appState.history) { item in
                        VStack(alignment: .leading, spacing: 5) {
                            HStack {
                                Text("\(item.appName) v\(item.version)")
                                    .font(.subheadline.weight(.semibold))
                                Spacer()
                                StatusBadge(
                                    item.succeeded ? "Thành công" : "Thất bại",
                                    tone: item.succeeded ? .success : .danger
                                )
                            }
                            Text(item.bundleId)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundColor(.secondary)
                            Text(item.detailMessage)
                                .font(.caption)
                                .foregroundColor(item.succeeded ? .secondary : .red)
                            Text("\(item.methodUsed) • iOS \(item.iosVersion) • \(dateFormatter.string(from: item.timestamp))")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Lịch sử cài đặt")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button("Xóa hết") {
                    appState.clearHistory()
                }
                .foregroundColor(.red)
                .disabled(appState.history.isEmpty)
            }
        }
    }
}

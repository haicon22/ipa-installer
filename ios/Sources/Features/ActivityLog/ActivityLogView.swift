import SwiftUI

/// Màn hình 9: Nhật ký hoạt động kỹ thuật
struct ActivityLogView: View {
    @ObservedObject private var logger = AppLogger.shared
    @State private var selectedLevel: LogLevel?
    @State private var showingExportSheet = false

    private var filteredEntries: [LogEntry] {
        guard let level = selectedLevel else { return logger.entries }
        return logger.entries.filter { $0.level == level }
    }

    private let timeFormatter: DateFormatter = {
        let df = DateFormatter()
        df.dateFormat = "HH:mm:ss.SSS"
        return df
    }()

    var body: some View {
        List {
            Section {
                Picker("Lọc mức độ", selection: $selectedLevel) {
                    Text("Tất cả (\(logger.entries.count))").tag(Optional<LogLevel>.none)
                    ForEach(LogLevel.allCases) { lv in
                        Text(lv.rawValue).tag(Optional(lv))
                    }
                }
                .pickerStyle(.segmented)
            }

            Section(header: Text("Dòng sự kiện (\(filteredEntries.count))")) {
                if filteredEntries.isEmpty {
                    Text("Không có bản ghi nhật ký nào khớp bộ lọc.")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                } else {
                    ForEach(filteredEntries) { entry in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 6) {
                                StatusBadge(entry.level.rawValue, tone: tone(for: entry.level))
                                Text(entry.subsystem)
                                    .font(.caption.weight(.semibold))
                                Spacer()
                                Text(timeFormatter.string(from: entry.timestamp))
                                    .font(.system(.caption2, design: .monospaced))
                                    .foregroundColor(.secondary)
                            }
                            Text(entry.message)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundColor(.primary)
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Nhật ký hoạt động")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .navigationBarTrailing) {
                Button {
                    showingExportSheet = true
                } label: {
                    Image(systemName: "square.and.arrow.up")
                }
                .disabled(logger.entries.isEmpty)

                Button("Xóa") {
                    logger.clear()
                }
                .foregroundColor(.red)
                .disabled(logger.entries.isEmpty)
            }
        }
        .sheet(isPresented: $showingExportSheet) {
            ShareSheet(activityItems: [logger.exportPlainText()])
        }
    }

    private func tone(for level: LogLevel) -> BadgeTone {
        switch level {
        case .info: return .neutral
        case .warning: return .warning
        case .error: return .danger
        }
    }
}

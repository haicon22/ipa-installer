import Combine
import Foundation

/// Hệ thống ghi nhật ký hoạt động an toàn luồng (Thread-Safe Logger)
@MainActor
public final class AppLogger: ObservableObject {
    public static let shared = AppLogger()

    @Published public private(set) var entries: [LogEntry] = []
    private let maxEntries = 500
    private let logFileURL: URL

    private init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let dir = appSupport.appendingPathComponent("IPAInstallerLogs", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.logFileURL = dir.appendingPathComponent("activity.log")
    }

    public func log(_ level: LogLevel, subsystem: String, _ message: String) {
        let entry = LogEntry(level: level, subsystem: subsystem, message: message)
        entries.insert(entry, at: 0)
        if entries.count > maxEntries {
            entries.removeLast(entries.count - maxEntries)
        }
        appendToDisk(entry)
    }

    public func info(_ subsystem: String, _ message: String) {
        log(.info, subsystem: subsystem, message)
    }

    public func warning(_ subsystem: String, _ message: String) {
        log(.warning, subsystem: subsystem, message)
    }

    public func error(_ subsystem: String, _ message: String) {
        log(.error, subsystem: subsystem, message)
    }

    public func clear() {
        entries.removeAll()
        try? FileManager.default.removeItem(at: logFileURL)
    }

    public func exportPlainText() -> String {
        let df = ISO8601DateFormatter()
        return entries.reversed().map { item in
            "[\(df.string(from: item.timestamp))] [\(item.level.rawValue)] [\(item.subsystem)] \(item.message)"
        }.joined(separator: "\n")
    }

    private func appendToDisk(_ entry: LogEntry) {
        let df = ISO8601DateFormatter()
        let line = "[\(df.string(from: entry.timestamp))] [\(entry.level.rawValue)] [\(entry.subsystem)] \(entry.message)\n"
        guard let data = line.data(using: .utf8) else { return }
        if FileManager.default.fileExists(atPath: logFileURL.path) {
            if let handle = try? FileHandle(forWritingTo: logFileURL) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            }
        } else {
            try? data.write(to: logFileURL, options: .atomic)
        }
    }
}

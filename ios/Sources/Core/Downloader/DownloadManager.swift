import Combine
import Foundation

public struct ActiveDownloadTask: Identifiable, Hashable {
    public let id: UUID
    public let sourceURL: URL
    public var receivedBytes: Int64
    public var expectedBytes: Int64
    public var statusText: String
    public var isFinished: Bool
    public var errorMessage: String?

    public var fractionCompleted: Double {
        guard expectedBytes > 0 else { return 0 }
        return min(1.0, max(0.0, Double(receivedBytes) / Double(expectedBytes)))
    }
}

/// Trình tải xuống IPA dung lượng lớn qua URLSessionDownloadTask kèm tiến độ thời gian thực
@MainActor
public final class DownloadManager: NSObject, ObservableObject {
    @Published public private(set) var tasks: [ActiveDownloadTask] = []

    public var onDownloadCompleted: ((URL, String) -> Void)?

    private var session: URLSession!
    private var taskMap: [Int: UUID] = [:]
    private var urlTaskRefs: [UUID: URLSessionDownloadTask] = [:]

    public override init() {
        super.init()
        let config = URLSessionConfiguration.default
        config.waitsForConnectivity = true
        config.timeoutIntervalForResource = 60 * 60 * 4
        self.session = URLSession(configuration: config, delegate: self, delegateQueue: .main)
    }

    public func startDownload(from urlString: String) throws {
        guard let url = URL(string: urlString.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            throw URLError(.badURL)
        }

        let id = UUID()
        let item = ActiveDownloadTask(
            id: id,
            sourceURL: url,
            receivedBytes: 0,
            expectedBytes: -1,
            statusText: "Đang kết nối máy chủ...",
            isFinished: false,
            errorMessage: nil
        )
        tasks.insert(item, at: 0)

        let dlTask = session.downloadTask(with: url)
        taskMap[dlTask.taskIdentifier] = id
        urlTaskRefs[id] = dlTask
        dlTask.resume()
        AppLogger.shared.info("Downloader", "Bắt đầu tải IPA từ URL: \(url.absoluteString)")
    }

    public func cancelDownload(id: UUID) {
        if let dlTask = urlTaskRefs[id] {
            dlTask.cancel()
            urlTaskRefs.removeValue(forKey: id)
        }
        if let idx = tasks.firstIndex(where: { $0.id == id }) {
            tasks[idx].statusText = "Đã hủy tải xuống"
            tasks[idx].isFinished = true
        }
    }

    public func removeFinishedTasks() {
        tasks.removeAll(where: { $0.isFinished })
    }
}

extension DownloadManager: URLSessionDownloadDelegate {
    nonisolated public func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        let taskId = downloadTask.taskIdentifier
        Task { @MainActor in
            guard let id = self.taskMap[taskId],
                  let idx = self.tasks.firstIndex(where: { $0.id == id }) else { return }
            self.tasks[idx].receivedBytes = totalBytesWritten
            self.tasks[idx].expectedBytes = totalBytesExpectedToWrite
            let recvStr = DeviceEnvironment.formatBytes(totalBytesWritten)
            if totalBytesExpectedToWrite > 0 {
                let totalStr = DeviceEnvironment.formatBytes(totalBytesExpectedToWrite)
                let pct = Int(self.tasks[idx].fractionCompleted * 100)
                self.tasks[idx].statusText = "Đang tải: \(recvStr) / \(totalStr) (\(pct)%)"
            } else {
                self.tasks[idx].statusText = "Đang tải: \(recvStr)"
            }
        }
    }

    nonisolated public func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        // Phải sao chép tệp tạm ngay lập tức trước khi hàm delegate kết thúc!
        let fm = FileManager.default
        let stagingDir = StorageManager.shared.workTempDirectory
        try? fm.createDirectory(at: stagingDir, withIntermediateDirectories: true)
        let suggested = downloadTask.response?.suggestedFilename
            ?? downloadTask.originalRequest?.url?.lastPathComponent
            ?? "Downloaded.ipa"
        let finalFileName = suggested.lowercased().hasSuffix(".ipa") ? suggested : "\(suggested).ipa"
        let stagedURL = stagingDir.appendingPathComponent("\(UUID().uuidString)_\(finalFileName)")

        var copyError: Error?
        do {
            if fm.fileExists(atPath: stagedURL.path) {
                try fm.removeItem(at: stagedURL)
            }
            try fm.moveItem(at: location, to: stagedURL)
        } catch {
            copyError = error
        }

        let taskId = downloadTask.taskIdentifier
        Task { @MainActor in
            guard let id = self.taskMap[taskId],
                  let idx = self.tasks.firstIndex(where: { $0.id == id }) else {
                try? fm.removeItem(at: stagedURL)
                return
            }
            self.urlTaskRefs.removeValue(forKey: id)
            if let err = copyError {
                self.tasks[idx].errorMessage = err.localizedDescription
                self.tasks[idx].statusText = "Lỗi lưu tệp tải về"
                self.tasks[idx].isFinished = true
                AppLogger.shared.error("Downloader", "Không thể chuyển tệp tạm: \(err.localizedDescription)")
            } else {
                self.tasks[idx].statusText = "Tải hoàn tất — Đang nhập vào kho IPA..."
                self.tasks[idx].isFinished = true
                self.onDownloadCompleted?(stagedURL, finalFileName)
                try? fm.removeItem(at: stagedURL)
            }
        }
    }

    nonisolated public func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        guard let error = error else { return }
        let nsErr = error as NSError
        if nsErr.domain == NSURLErrorDomain && nsErr.code == NSURLErrorCancelled {
            return
        }
        let taskId = task.taskIdentifier
        Task { @MainActor in
            guard let id = self.taskMap[taskId],
                  let idx = self.tasks.firstIndex(where: { $0.id == id }) else { return }
            self.urlTaskRefs.removeValue(forKey: id)
            self.tasks[idx].errorMessage = error.localizedDescription
            self.tasks[idx].statusText = "Tải thất bại"
            self.tasks[idx].isFinished = true
            AppLogger.shared.error("Downloader", "Lỗi tải URL: \(error.localizedDescription)")
        }
    }
}

import Foundation
import Network
import UIKit

/// Máy chủ HTTP cục bộ (127.0.0.1) truyền phát luồng (streaming Range 206) gói .ipa & manifest.plist
/// cho tiến trình cài đặt gốc của iOS hoặc chuyển tiếp sang SideStore / LiveContainer mà không tốn RAM.
@MainActor
public final class LocalOTAServer {
    public static let shared = LocalOTAServer()

    private var listener: NWListener?
    private var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid
    private var currentIPAURL: URL?
    private var currentManifestData: Data?
    private var activePort: UInt16 = 8443
    private var autoShutdownWorkItem: DispatchWorkItem?

    private init() {}

    public func startServing(
        ipaURL: URL,
        bundleId: String,
        version: String,
        title: String,
        preferredPort: Int
    ) throws -> UInt16 {
        stop()

        guard FileManager.default.fileExists(atPath: ipaURL.path) else {
            throw NSError(
                domain: "LocalOTAServer",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Không tìm thấy gói IPA đã ký để phục vụ cài đặt."]
            )
        }

        let safePort = UInt16(clamping: max(1024, min(65000, preferredPort)))
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true

        let nwPort = NWEndpoint.Port(rawValue: safePort) ?? 8443
        let newListener = try NWListener(using: params, on: nwPort)

        self.currentIPAURL = ipaURL
        self.activePort = nwPort.rawValue
        self.currentManifestData = Self.buildManifestPlist(
            ipaDownloadURL: "http://127.0.0.1:\(nwPort.rawValue)/app.ipa",
            bundleId: bundleId,
            version: version,
            title: title
        )

        beginShortBackgroundKeepAlive()

        newListener.newConnectionHandler = { [weak self] conn in
            Task { @MainActor in
                self?.handleConnection(conn)
            }
        }

        newListener.start(queue: .global(qos: .userInitiated))
        self.listener = newListener
        AppLogger.shared.info("OTAServer", "Đã mở máy chủ nội bộ tại 127.0.0.1:\(nwPort.rawValue) cho \(ipaURL.lastPathComponent)")

        scheduleAutoShutdown(afterSeconds: 180)
        return nwPort.rawValue
    }

    public func stop() {
        autoShutdownWorkItem?.cancel()
        autoShutdownWorkItem = nil
        listener?.cancel()
        listener = nil
        endBackgroundKeepAlive()
    }

    private func beginShortBackgroundKeepAlive() {
        endBackgroundKeepAlive()
        backgroundTaskID = UIApplication.shared.beginBackgroundTask(withName: "IPAInstallerLocalDelivery") { [weak self] in
            Task { @MainActor in
                self?.stop()
            }
        }
    }

    private func endBackgroundKeepAlive() {
        if backgroundTaskID != .invalid {
            UIApplication.shared.endBackgroundTask(backgroundTaskID)
            backgroundTaskID = .invalid
        }
    }

    private func scheduleAutoShutdown(afterSeconds seconds: TimeInterval) {
        autoShutdownWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                self?.stop()
                AppLogger.shared.info("OTAServer", "Đã tự động đóng máy chủ nội bộ sau phiên cài đặt.")
            }
        }
        autoShutdownWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: item)
    }

    private func handleConnection(_ connection: NWConnection) {
        let ipaURL = self.currentIPAURL
        let manifestData = self.currentManifestData

        connection.start(queue: .global(qos: .userInitiated))
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16384) { data, _, _, error in
            guard error == nil, let reqData = data, let requestText = String(data: reqData, encoding: .utf8) else {
                connection.cancel()
                return
            }

            let lines = requestText.components(separatedBy: "\r\n")
            guard let firstLine = lines.first else {
                connection.cancel()
                return
            }
            let parts = firstLine.split(separator: " ")
            guard parts.count >= 2 else {
                connection.cancel()
                return
            }

            let method = String(parts[0]).uppercased()
            let path = String(parts[1])

            if path.hasPrefix("/manifest.plist"), let plistBytes = manifestData {
                Self.sendSimpleResponse(
                    connection: connection,
                    status: "200 OK",
                    contentType: "application/xml",
                    body: method == "HEAD" ? Data() : plistBytes,
                    declaredLength: plistBytes.count
                )
                return
            }

            if path.hasPrefix("/app.ipa"), let fileURL = ipaURL {
                let rangeHeader = lines.first { $0.lowercased().hasPrefix("range:") }
                Self.streamIPAFile(
                    connection: connection,
                    fileURL: fileURL,
                    isHeadOnly: method == "HEAD",
                    rangeHeader: rangeHeader
                )
                return
            }

            let notFound = Data("Not Found".utf8)
            Self.sendSimpleResponse(
                connection: connection,
                status: "404 Not Found",
                contentType: "text/plain",
                body: notFound,
                declaredLength: notFound.count
            )
        }
    }

    nonisolated private static func sendSimpleResponse(
        connection: NWConnection,
        status: String,
        contentType: String,
        body: Data,
        declaredLength: Int
    ) {
        let header = [
            "HTTP/1.1 \(status)",
            "Content-Type: \(contentType)",
            "Content-Length: \(declaredLength)",
            "Accept-Ranges: bytes",
            "Connection: close",
            "",
            ""
        ].joined(separator: "\r\n")

        var payload = Data(header.utf8)
        payload.append(body)
        connection.send(content: payload, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    nonisolated private static func streamIPAFile(
        connection: NWConnection,
        fileURL: URL,
        isHeadOnly: Bool,
        rangeHeader: String?
    ) {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
              let totalSizeNum = attrs[.size] as? NSNumber else {
            connection.cancel()
            return
        }
        let totalSize = totalSizeNum.int64Value
        guard totalSize > 0 else {
            connection.cancel()
            return
        }

        var startByte: Int64 = 0
        var endByte: Int64 = totalSize - 1
        var isPartial = false

        if let rawRange = rangeHeader,
           let eqIdx = rawRange.firstIndex(of: "=") {
            let spec = rawRange[rawRange.index(after: eqIdx)...].trimmingCharacters(in: .whitespaces)
            let bounds = spec.split(separator: "-", omittingEmptySubsequences: false)
            if bounds.count == 2 {
                if let s = Int64(bounds[0]) {
                    startByte = max(0, min(totalSize - 1, s))
                    isPartial = true
                }
                if let e = Int64(bounds[1]), e >= startByte {
                    endByte = min(totalSize - 1, e)
                    isPartial = true
                }
            }
        }

        let contentLen = endByte - startByte + 1
        var headers = [
            isPartial ? "HTTP/1.1 206 Partial Content" : "HTTP/1.1 200 OK",
            "Content-Type: application/octet-stream",
            "Content-Length: \(contentLen)",
            "Accept-Ranges: bytes"
        ]
        if isPartial {
            headers.append("Content-Range: bytes \(startByte)-\(endByte)/\(totalSize)")
        }
        headers.append("Connection: close")
        headers.append("")
        headers.append("")

        let headerData = Data(headers.joined(separator: "\r\n").utf8)
        if isHeadOnly {
            connection.send(content: headerData, completion: .contentProcessed { _ in
                connection.cancel()
            })
            return
        }

        guard let handle = try? FileHandle(forReadingFrom: fileURL) else {
            connection.cancel()
            return
        }
        try? handle.seek(toOffset: UInt64(startByte))

        connection.send(content: headerData, completion: .contentProcessed { err in
            if err != nil {
                try? handle.close()
                connection.cancel()
                return
            }
            Self.sendNextChunk(connection: connection, handle: handle, remaining: contentLen)
        })
    }

    nonisolated private static func sendNextChunk(
        connection: NWConnection,
        handle: FileHandle,
        remaining: Int64
    ) {
        if remaining <= 0 {
            try? handle.close()
            connection.cancel()
            return
        }
        let toRead = Int(min(65536, remaining))
        guard let chunk = try? handle.read(upToCount: toRead), !chunk.isEmpty else {
            try? handle.close()
            connection.cancel()
            return
        }
        let nextRemain = remaining - Int64(chunk.count)
        connection.send(content: chunk, completion: .contentProcessed { err in
            if err != nil {
                try? handle.close()
                connection.cancel()
                return
            }
            Self.sendNextChunk(connection: connection, handle: handle, remaining: nextRemain)
        })
    }

    private static func buildManifestPlist(
        ipaDownloadURL: String,
        bundleId: String,
        version: String,
        title: String
    ) -> Data {
        let escapedTitle = title
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")

        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>items</key>
            <array>
                <dict>
                    <key>assets</key>
                    <array>
                        <dict>
                            <key>kind</key>
                            <string>software-package</string>
                            <key>url</key>
                            <string>\(ipaDownloadURL)</string>
                        </dict>
                    </array>
                    <key>metadata</key>
                    <dict>
                        <key>bundle-identifier</key>
                        <string>\(bundleId)</string>
                        <key>bundle-version</key>
                        <string>\(version)</string>
                        <key>kind</key>
                        <string>software</string>
                        <key>title</key>
                        <string>\(escapedTitle)</string>
                    </dict>
                </dict>
            </array>
        </dict>
        </plist>
        """
        return Data(xml.utf8)
    }
}

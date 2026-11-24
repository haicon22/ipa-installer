import Foundation

public struct StorageUsageReport: Hashable {
    public let importedIPAsBytes: Int64
    public let signedIPAsBytes: Int64
    public let certificatesBytes: Int64
    public let tempBytes: Int64

    public var totalBytes: Int64 {
        importedIPAsBytes + signedIPAsBytes + certificatesBytes + tempBytes
    }
}

public enum StorageError: LocalizedError {
    case invalidArchiveMagic
    case unsafeRelativePath
    case fileNotFound

    public var errorDescription: String? {
        switch self {
        case .invalidArchiveMagic:
            return "Tệp được chọn không có chữ ký nén ZIP/IPA hợp lệ (thiếu PK header)."
        case .unsafeRelativePath:
            return "Phát hiện đường dẫn không an toàn (nguy cơ trượt thư mục Zip Slip)."
        case .fileNotFound:
            return "Không tìm thấy tệp IPA trên bộ nhớ ứng dụng."
        }
    }
}

/// Quản lý toàn bộ vùng lưu trữ riêng (Sandbox) của ứng dụng, bảo vệ chống Zip Slip
public final class StorageManager {
    public static let shared = StorageManager()

    private let fm = FileManager.default
    public let rootDirectory: URL
    public let importedIPAsDirectory: URL
    public let signedIPAsDirectory: URL
    public let certificatesDirectory: URL
    public let workTempDirectory: URL
    private let catalogFileURL: URL
    private let certCatalogFileURL: URL
    private let historyFileURL: URL

    private init() {
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fm.temporaryDirectory
        rootDirectory = base.appendingPathComponent("IPAInstallerWorkspace", isDirectory: true)
        importedIPAsDirectory = rootDirectory.appendingPathComponent("ImportedIPAs", isDirectory: true)
        signedIPAsDirectory = rootDirectory.appendingPathComponent("SignedIPAs", isDirectory: true)
        certificatesDirectory = rootDirectory.appendingPathComponent("Certificates", isDirectory: true)
        workTempDirectory = rootDirectory.appendingPathComponent("TempWork", isDirectory: true)

        catalogFileURL = rootDirectory.appendingPathComponent("ipa_catalog.json")
        certCatalogFileURL = rootDirectory.appendingPathComponent("cert_catalog.json")
        historyFileURL = rootDirectory.appendingPathComponent("install_history.json")

        ensureDirectories()
    }

    public func ensureDirectories() {
        for dir in [rootDirectory, importedIPAsDirectory, signedIPAsDirectory, certificatesDirectory, workTempDirectory] {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }

    /// Chống tấn công Zip Slip khi ghép đường dẫn giải nén
    public static func isSafeRelativeEntryPath(_ entryPath: String) -> Bool {
        if entryPath.isEmpty || entryPath.hasPrefix("/") || entryPath.hasPrefix("\\") {
            return false
        }
        let normalized = entryPath.replacingOccurrences(of: "\\", with: "/")
        let parts = normalized.split(separator: "/", omittingEmptySubsequences: false)
        return !parts.contains("..")
    }

    /// Kiểm tra nhanh 4 byte đầu có phải chữ ký ZIP (PK\x03\x04 hoặc PK\x05\x06)
    public func verifyZipSignature(at url: URL) throws {
        guard fm.fileExists(atPath: url.path) else {
            throw StorageError.fileNotFound
        }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let magic = try handle.read(upToCount: 4) ?? Data()
        guard magic.count == 4, magic[0] == 0x50, magic[1] == 0x4B else {
            throw StorageError.invalidArchiveMagic
        }
    }

    /// Sao chép tệp IPA từ Security-Scoped URL (Files / iCloud / Share Sheet) vào vùng lưu trữ riêng
    public func importExternalIPA(from sourceURL: URL) throws -> IPAPackageItem {
        ensureDirectories()
        let hasScope = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if hasScope {
                sourceURL.stopAccessingSecurityScopedResource()
            }
        }

        let rawName = sourceURL.lastPathComponent.isEmpty ? "ImportedApp.ipa" : sourceURL.lastPathComponent
        let cleanBase = rawName.replacingOccurrences(of: "[^a-zA-Z0-9._-]", with: "_", options: .regularExpression)
        let id = UUID()
        let storedFileName = "\(id.uuidString.prefix(8))_\(cleanBase)"
        let destination = importedIPAsDirectory.appendingPathComponent(storedFileName)

        if fm.fileExists(atPath: destination.path) {
            try fm.removeItem(at: destination)
        }
        try fm.copyItem(at: sourceURL, to: destination)

        do {
            try verifyZipSignature(at: destination)
        } catch {
            try? fm.removeItem(at: destination)
            throw error
        }

        let attrs = try fm.attributesOfItem(atPath: destination.path)
        let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0

        return IPAPackageItem(
            id: id,
            fileName: rawName,
            relativeFilePath: "ImportedIPAs/\(storedFileName)",
            fileSize: size,
            isSignedOutput: false
        )
    }

    public func resolveURL(for relativePath: String) throws -> URL {
        guard Self.isSafeRelativeEntryPath(relativePath) else {
            throw StorageError.unsafeRelativePath
        }
        return rootDirectory.appendingPathComponent(relativePath)
    }

    public func deletePackageFile(_ item: IPAPackageItem) {
        if let url = try? resolveURL(for: item.relativeFilePath) {
            try? fm.removeItem(at: url)
        }
    }

    public func clearTempDirectory() -> Int64 {
        let before = directorySize(at: workTempDirectory)
        try? fm.removeItem(at: workTempDirectory)
        try? fm.createDirectory(at: workTempDirectory, withIntermediateDirectories: true)
        return before
    }

    public func calculateUsage() -> StorageUsageReport {
        StorageUsageReport(
            importedIPAsBytes: directorySize(at: importedIPAsDirectory),
            signedIPAsBytes: directorySize(at: signedIPAsDirectory),
            certificatesBytes: directorySize(at: certificatesDirectory),
            tempBytes: directorySize(at: workTempDirectory)
        )
    }

    private func directorySize(at dir: URL) -> Int64 {
        guard let enumerator = fm.enumerator(
            at: dir,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return 0
        }
        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            if let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
               values.isRegularFile == true,
               let s = values.fileSize {
                total += Int64(s)
            }
        }
        return total
    }

    // MARK: - Lưu trữ bền vững danh mục JSON

    public func saveCatalog(_ items: [IPAPackageItem]) {
        saveJSON(items, to: catalogFileURL)
    }

    public func loadCatalog() -> [IPAPackageItem] {
        loadJSON([IPAPackageItem].self, from: catalogFileURL) ?? []
    }

    public func saveCertificates(_ certs: [CertificateRecord]) {
        saveJSON(certs, to: certCatalogFileURL)
    }

    public func loadCertificates() -> [CertificateRecord] {
        loadJSON([CertificateRecord].self, from: certCatalogFileURL) ?? []
    }

    public func saveHistory(_ history: [InstallHistoryEntry]) {
        saveJSON(history, to: historyFileURL)
    }

    public func loadHistory() -> [InstallHistoryEntry] {
        loadJSON([InstallHistoryEntry].self, from: historyFileURL) ?? []
    }

    private func saveJSON<T: Encodable>(_ value: T, to url: URL) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(value) {
            try? data.write(to: url, options: .atomic)
        }
    }

    private func loadJSON<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(type, from: data)
    }
}

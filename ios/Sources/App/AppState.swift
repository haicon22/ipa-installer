import Foundation
import SwiftUI

/// Quản lý trạng thái tập trung toàn ứng dụng (tương thích iOS 15.0 → iOS 26.6+)
@MainActor
public final class AppState: ObservableObject {
    @Published public var packages: [IPAPackageItem] = []
    @Published public var certificates: [CertificateRecord] = []
    @Published public var selectedCertificateId: UUID?
    @Published public var history: [InstallHistoryEntry] = []
    @Published public var storageUsage: StorageUsageReport

    // Thiết lập hệ thống lưu bền vững
    @AppStorage("ipa_theme_pref") public var themeRaw: String = AppThemePreference.system.rawValue
    @AppStorage("ipa_user_udid") public var userDeviceUDID: String = ""
    @AppStorage("ipa_local_server_port") public var localServerPort: Int = 8443
    @AppStorage("ipa_auto_ocsp_check") public var autoCheckOCSPBeforeInstall: Bool = true
    @AppStorage("ipa_auto_clean_temp") public var autoCleanTempAfterSign: Bool = true

    public let downloader = DownloadManager()
    public let storage = StorageManager.shared
    public let logger = AppLogger.shared

    // Các module lõi tách biệt (sẽ được gán ở Giai đoạn 4 & 6)
    public var ipaParser: IPAParserProtocol?
    public var certValidator: CertificateValidatorProtocol?
    public var ipaSigner: IPASignerProtocol?
    public var installationManager: InstallationManagerProtocol?

    @Published public var alertMessage: String?

    public init() {
        self.storageUsage = StorageManager.shared.calculateUsage()
        self.packages = storage.loadCatalog()
        self.certificates = storage.loadCertificates()
        self.selectedCertificateId = certificates.first?.id
        self.history = storage.loadHistory()

        // Gắn đầy đủ 4 lõi độc lập (Giai đoạn 4 & Giai đoạn 6)
        self.ipaParser = NativeIPAParser()
        self.certValidator = NativeCertificateValidator()
        self.ipaSigner = NativeIPASigner()
        let portKey = "ipa_local_server_port"
        self.installationManager = NativeInstallationManager {
            let p = UserDefaults.standard.integer(forKey: portKey)
            return p > 0 ? p : 8443
        }

        downloader.onDownloadCompleted = { [weak self] stagedURL, suggestedName in
            guard let self = self else { return }
            self.importIPAFromURL(stagedURL, overrideDisplayFileName: suggestedName)
        }

        logger.info(
            "System",
            "Khởi động IPA Installer trên \(DeviceEnvironment.deviceModelIdentifier) (iOS \(DeviceEnvironment.iosVersionString))"
        )
    }

    public var preferredColorScheme: ColorScheme? {
        switch AppThemePreference(rawValue: themeRaw) ?? .system {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }

    public var activeCertificate: CertificateRecord? {
        if let id = selectedCertificateId,
           let found = certificates.first(where: { $0.id == id }) {
            return found
        }
        return certificates.first
    }

    public func refreshStorageUsage() {
        storageUsage = storage.calculateUsage()
    }

    public func importIPAFromURL(_ url: URL, overrideDisplayFileName: String? = nil) {
        do {
            var item = try storage.importExternalIPA(from: url)
            if let overrideName = overrideDisplayFileName, !overrideName.isEmpty {
                item = IPAPackageItem(
                    id: item.id,
                    fileName: overrideName,
                    relativeFilePath: item.relativeFilePath,
                    fileSize: item.fileSize,
                    importedAt: item.importedAt,
                    isSignedOutput: false,
                    metadata: nil
                )
            }
            packages.insert(item, at: 0)
            storage.saveCatalog(packages)
            refreshStorageUsage()
            logger.info("Storage", "Đã nhập IPA: \(item.fileName) (\(DeviceEnvironment.formatBytes(item.fileSize)))")

            // Nếu bộ IPAParser của Giai đoạn 4 đã gắn vào, tự động phân tích sâu ở luồng nền
            if let parser = ipaParser,
               let storedURL = try? storage.resolveURL(for: item.relativeFilePath) {
                let targetId = item.id
                Task {
                    do {
                        let meta = try await parser.parsePackage(at: storedURL)
                        if let idx = self.packages.firstIndex(where: { $0.id == targetId }) {
                            self.packages[idx].metadata = meta
                            self.storage.saveCatalog(self.packages)
                            self.logger.info("IPAParser", "Phân tích thành công \(meta.displayName) (\(meta.bundleId))")
                        }
                    } catch {
                        self.logger.error("IPAParser", "Lỗi phân tích \(item.fileName): \(error.localizedDescription)")
                    }
                }
            }
        } catch {
            logger.error("Storage", "Nhập IPA thất bại: \(error.localizedDescription)")
            alertMessage = error.localizedDescription
        }
    }

    public func deletePackage(_ item: IPAPackageItem) {
        storage.deletePackageFile(item)
        packages.removeAll { $0.id == item.id }
        storage.saveCatalog(packages)
        refreshStorageUsage()
        logger.info("Storage", "Đã xóa gói IPA: \(item.effectiveTitle)")
    }

    public func registerSignedIPA(at signedURL: URL) async {
        let relPath = "SignedIPAs/\(signedURL.lastPathComponent)"
        let size = ((try? FileManager.default.attributesOfItem(atPath: signedURL.path))?[.size] as? NSNumber)?.int64Value ?? 0
        let meta = try? await ipaParser?.parsePackage(at: signedURL)
        let item = IPAPackageItem(
            fileName: signedURL.lastPathComponent,
            relativeFilePath: relPath,
            fileSize: size,
            isSignedOutput: true,
            metadata: meta
        )
        packages.insert(item, at: 0)
        storage.saveCatalog(packages)
        refreshStorageUsage()
        logger.info("IPASigner", "Đã lưu gói IPA đã ký vào Thư viện: \(item.effectiveTitle)")
    }

    public func importValidatedCertificatePair(
        p12SourceURL: URL,
        password: String,
        provisionSourceURL: URL,
        nickname: String
    ) async throws {
        guard let validator = certValidator else {
            try importBasicCertificatePair(
                p12SourceURL: p12SourceURL,
                password: password,
                provisionSourceURL: provisionSourceURL,
                nickname: nickname
            )
            return
        }
        let record = try await validator.importCertificatePair(
            p12URL: p12SourceURL,
            p12Password: password,
            mobileProvisionURL: provisionSourceURL,
            nickname: nickname
        )
        certificates.insert(record, at: 0)
        if selectedCertificateId == nil {
            selectedCertificateId = record.id
        }
        storage.saveCertificates(certificates)
        refreshStorageUsage()
        logger.info(
            "Certificates",
            "Đã kiểm định cặp chứng chỉ (\(record.distributionType)) & OCSP (\(record.lastOCSPStatus.rawValue)): \(record.commonName)"
        )
    }

    public func importBasicCertificatePair(
        p12SourceURL: URL,
        password: String,
        provisionSourceURL: URL,
        nickname: String
    ) throws {
        // Nếu bộ CertificateValidator chuyên sâu ở Giai đoạn 4 đã sẵn sàng thì ưu tiên dùng ở luồng async
        let p12Scoped = p12SourceURL.startAccessingSecurityScopedResource()
        let provScoped = provisionSourceURL.startAccessingSecurityScopedResource()
        defer {
            if p12Scoped { p12SourceURL.stopAccessingSecurityScopedResource() }
            if provScoped { provisionSourceURL.stopAccessingSecurityScopedResource() }
        }

        let p12Data = try Data(contentsOf: p12SourceURL)
        let provData = try Data(contentsOf: provisionSourceURL)
        let summary = try PKCS12QuickInspector.verifyPKCS12Password(data: p12Data, password: password)

        let id = UUID()
        let p12Rel = "Certificates/\(id.uuidString).p12"
        let provRel = "Certificates/\(id.uuidString).mobileprovision"
        let p12Dest = try storage.resolveURL(for: p12Rel)
        let provDest = try storage.resolveURL(for: provRel)

        try p12Data.write(to: p12Dest, options: .atomic)
        try provData.write(to: provDest, options: .atomic)

        let keychainKey = "cert_pwd_\(id.uuidString)"
        try KeychainStore.saveSecret(password, forKey: keychainKey)

        let record = CertificateRecord(
            id: id,
            nickname: nickname.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? summary.commonName : nickname,
            commonName: summary.commonName,
            teamName: "Đang chờ giải mã chi tiết CMS",
            teamId: "—",
            serialNumber: summary.serialHex,
            distributionType: "PKCS#12 + MobileProvision",
            expirationDate: nil,
            provisionsAllDevices: false,
            provisionedUDIDs: [],
            p12RelativePath: p12Rel,
            mobileProvisionRelativePath: provRel,
            keychainPasswordKey: keychainKey
        )

        certificates.insert(record, at: 0)
        if selectedCertificateId == nil {
            selectedCertificateId = record.id
        }
        storage.saveCertificates(certificates)
        refreshStorageUsage()
        logger.info("Certificates", "Đã xác thực PKCS#12 và lưu khóa vào Keychain: \(summary.commonName)")
    }

    public func deleteCertificate(_ cert: CertificateRecord) {
        KeychainStore.deleteSecret(forKey: cert.keychainPasswordKey)
        if let p12URL = try? storage.resolveURL(for: cert.p12RelativePath) {
            try? FileManager.default.removeItem(at: p12URL)
        }
        if let provURL = try? storage.resolveURL(for: cert.mobileProvisionRelativePath) {
            try? FileManager.default.removeItem(at: provURL)
        }
        certificates.removeAll { $0.id == cert.id }
        if selectedCertificateId == cert.id {
            selectedCertificateId = certificates.first?.id
        }
        storage.saveCertificates(certificates)
        refreshStorageUsage()
        logger.info("Certificates", "Đã xóa chứng chỉ & mật khẩu Keychain: \(cert.commonName)")
    }

    public func recordHistory(_ entry: InstallHistoryEntry) {
        history.insert(entry, at: 0)
        storage.saveHistory(history)
    }

    public func clearHistory() {
        history.removeAll()
        storage.saveHistory([])
        logger.info("History", "Đã xóa toàn bộ lịch sử cài đặt.")
    }

    public func cleanTemporaryFiles() {
        let freed = storage.clearTempDirectory()
        refreshStorageUsage()
        logger.info("Storage", "Đã dọn thư mục tạm, giải phóng \(DeviceEnvironment.formatBytes(freed)).")
    }
}

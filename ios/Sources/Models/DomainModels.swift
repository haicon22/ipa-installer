import Foundation

public enum LogLevel: String, Codable, CaseIterable, Identifiable {
    case info = "INFO"
    case warning = "WARN"
    case error = "ERROR"

    public var id: String { rawValue }
}

public struct LogEntry: Codable, Identifiable, Hashable {
    public let id: UUID
    public let timestamp: Date
    public let level: LogLevel
    public let subsystem: String
    public let message: String

    public init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        level: LogLevel,
        subsystem: String,
        message: String
    ) {
        self.id = id
        self.timestamp = timestamp
        self.level = level
        self.subsystem = subsystem
        self.message = message
    }
}

public struct IPAExtensionInfo: Codable, Hashable, Identifiable {
    public var id: String { folderName }
    public let folderName: String
    public let displayName: String
    public let bundleId: String
    public let extensionPoint: String?

    public init(
        folderName: String,
        displayName: String,
        bundleId: String,
        extensionPoint: String? = nil
    ) {
        self.folderName = folderName
        self.displayName = displayName
        self.bundleId = bundleId
        self.extensionPoint = extensionPoint
    }
}

public struct IPAPermissionInfo: Codable, Hashable, Identifiable {
    public var id: String { key }
    public let key: String
    public let labelVi: String
    public let usageDescription: String

    public init(key: String, labelVi: String, usageDescription: String) {
        self.key = key
        self.labelVi = labelVi
        self.usageDescription = usageDescription
    }
}

public struct ProvisioningSummary: Codable, Hashable {
    public let profileName: String
    public let teamName: String
    public let teamIdentifier: String
    public let distributionType: String
    public let creationDate: Date?
    public let expirationDate: Date?
    public let provisionsAllDevices: Bool
    public let provisionedUDIDs: [String]
    public let supportsOTA: Bool

    public init(
        profileName: String,
        teamName: String,
        teamIdentifier: String,
        distributionType: String,
        creationDate: Date?,
        expirationDate: Date?,
        provisionsAllDevices: Bool,
        provisionedUDIDs: [String],
        supportsOTA: Bool
    ) {
        self.profileName = profileName
        self.teamName = teamName
        self.teamIdentifier = teamIdentifier
        self.distributionType = distributionType
        self.creationDate = creationDate
        self.expirationDate = expirationDate
        self.provisionsAllDevices = provisionsAllDevices
        self.provisionedUDIDs = provisionedUDIDs
        self.supportsOTA = supportsOTA
    }

    public var isExpired: Bool {
        guard let exp = expirationDate else { return false }
        return exp < Date()
    }
}

public struct IPAParsedMetadata: Codable, Hashable {
    public let displayName: String
    public let bundleId: String
    public let version: String
    public let buildNumber: String
    public let executableName: String?
    public let minimumOSVersion: String?
    public let sdkVersion: String?
    public let architectures: [String]
    public let isFairPlayEncrypted: Bool
    public let totalEntries: Int
    public let uncompressedBytes: Int64
    public let frameworks: [String]
    public let appExtensions: [IPAExtensionInfo]
    public let permissions: [IPAPermissionInfo]
    public let entitlements: [String: String]
    public let provisioning: ProvisioningSummary?
    public let signatureSummaryVi: String
    public let iconPNGData: Data?

    public var personalTeamAppIDCostWithExtensions: Int {
        1 + appExtensions.count
    }

    public init(
        displayName: String,
        bundleId: String,
        version: String,
        buildNumber: String,
        executableName: String?,
        minimumOSVersion: String?,
        sdkVersion: String?,
        architectures: [String],
        isFairPlayEncrypted: Bool,
        totalEntries: Int,
        uncompressedBytes: Int64,
        frameworks: [String],
        appExtensions: [IPAExtensionInfo],
        permissions: [IPAPermissionInfo],
        entitlements: [String: String],
        provisioning: ProvisioningSummary?,
        signatureSummaryVi: String,
        iconPNGData: Data?
    ) {
        self.displayName = displayName
        self.bundleId = bundleId
        self.version = version
        self.buildNumber = buildNumber
        self.executableName = executableName
        self.minimumOSVersion = minimumOSVersion
        self.sdkVersion = sdkVersion
        self.architectures = architectures
        self.isFairPlayEncrypted = isFairPlayEncrypted
        self.totalEntries = totalEntries
        self.uncompressedBytes = uncompressedBytes
        self.frameworks = frameworks
        self.appExtensions = appExtensions
        self.permissions = permissions
        self.entitlements = entitlements
        self.provisioning = provisioning
        self.signatureSummaryVi = signatureSummaryVi
        self.iconPNGData = iconPNGData
    }
}

public struct IPAPackageItem: Codable, Identifiable, Hashable {
    public let id: UUID
    public let fileName: String
    public let relativeFilePath: String
    public let fileSize: Int64
    public let importedAt: Date
    public let isSignedOutput: Bool
    public var metadata: IPAParsedMetadata?

    public var effectiveTitle: String {
        metadata?.displayName ?? fileName
    }

    public var effectiveBundleId: String {
        metadata?.bundleId ?? "Chưa phân tích sâu"
    }

    public init(
        id: UUID = UUID(),
        fileName: String,
        relativeFilePath: String,
        fileSize: Int64,
        importedAt: Date = Date(),
        isSignedOutput: Bool = false,
        metadata: IPAParsedMetadata? = nil
    ) {
        self.id = id
        self.fileName = fileName
        self.relativeFilePath = relativeFilePath
        self.fileSize = fileSize
        self.importedAt = importedAt
        self.isSignedOutput = isSignedOutput
        self.metadata = metadata
    }
}

public enum OCSPVerificationState: String, Codable, Hashable {
    case unchecked = "Chưa kiểm tra trực tuyến"
    case good = "Hợp lệ (Good)"
    case revoked = "Đã bị Apple thu hồi (Revoked)"
    case offlineOrUnknown = "Không rõ / Mất kết nối OCSP"
}

public struct CertificateRecord: Codable, Identifiable, Hashable {
    public let id: UUID
    public var nickname: String
    public let commonName: String
    public let teamName: String
    public let teamId: String
    public let serialNumber: String
    public let distributionType: String
    public let expirationDate: Date?
    public let provisionsAllDevices: Bool
    public let provisionedUDIDs: [String]
    public let p12RelativePath: String
    public let mobileProvisionRelativePath: String
    public let keychainPasswordKey: String
    public var lastOCSPStatus: OCSPVerificationState
    public let addedAt: Date

    public var isExpired: Bool {
        guard let exp = expirationDate else { return false }
        return exp < Date()
    }

    public init(
        id: UUID = UUID(),
        nickname: String,
        commonName: String,
        teamName: String,
        teamId: String,
        serialNumber: String,
        distributionType: String,
        expirationDate: Date?,
        provisionsAllDevices: Bool,
        provisionedUDIDs: [String],
        p12RelativePath: String,
        mobileProvisionRelativePath: String,
        keychainPasswordKey: String,
        lastOCSPStatus: OCSPVerificationState = .unchecked,
        addedAt: Date = Date()
    ) {
        self.id = id
        self.nickname = nickname
        self.commonName = commonName
        self.teamName = teamName
        self.teamId = teamId
        self.serialNumber = serialNumber
        self.distributionType = distributionType
        self.expirationDate = expirationDate
        self.provisionsAllDevices = provisionsAllDevices
        self.provisionedUDIDs = provisionedUDIDs
        self.p12RelativePath = p12RelativePath
        self.mobileProvisionRelativePath = mobileProvisionRelativePath
        self.keychainPasswordKey = keychainPasswordKey
        self.lastOCSPStatus = lastOCSPStatus
        self.addedAt = addedAt
    }
}

public struct SigningOptions: Codable, Hashable {
    public var customBundleId: String = ""
    public var customDisplayName: String = ""
    public var stripAppExtensions: Bool = true
    public var enableFileSharing: Bool = true

    public init() {}
}

public struct CertificateCheckStep: Identifiable, Hashable {
    public let id: Int
    public let title: String
    public let passed: Bool
    public let isBlocking: Bool
    public let detail: String

    public init(id: Int, title: String, passed: Bool, isBlocking: Bool, detail: String) {
        self.id = id
        self.title = title
        self.passed = passed
        self.isBlocking = isBlocking
        self.detail = detail
    }
}

public struct InstallHistoryEntry: Codable, Identifiable, Hashable {
    public let id: UUID
    public let timestamp: Date
    public let appName: String
    public let bundleId: String
    public let version: String
    public let methodUsed: String
    public let succeeded: Bool
    public let detailMessage: String
    public let iosVersion: String

    public init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        appName: String,
        bundleId: String,
        version: String,
        methodUsed: String,
        succeeded: Bool,
        detailMessage: String,
        iosVersion: String
    ) {
        self.id = id
        self.timestamp = timestamp
        self.appName = appName
        self.bundleId = bundleId
        self.version = version
        self.methodUsed = methodUsed
        self.succeeded = succeeded
        self.detailMessage = detailMessage
        self.iosVersion = iosVersion
    }
}

public enum AppThemePreference: String, Codable, CaseIterable, Identifiable {
    case system = "Tự động theo iOS"
    case light = "Chế độ Sáng"
    case dark = "Chế độ Tối"

    public var id: String { rawValue }
}

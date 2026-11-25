import Foundation
import ZIPFoundation

/// Bộ phân tích gói IPA độc lập (chỉ đọc luồng nén cần thiết, không sửa dữ liệu gốc)
public final class NativeIPAParser: IPAParserProtocol {
    private static let permissionLabelsVi: [String: String] = [
        "NSCameraUsageDescription": "Máy ảnh (Camera)",
        "NSMicrophoneUsageDescription": "Micrô thu âm",
        "NSPhotoLibraryUsageDescription": "Thư viện Ảnh",
        "NSPhotoLibraryAddUsageDescription": "Lưu ảnh vào Thư viện",
        "NSLocationWhenInUseUsageDescription": "Vị trí khi dùng ứng dụng",
        "NSLocationAlwaysAndWhenInUseUsageDescription": "Vị trí luôn luôn (nền)",
        "NSFaceIDUsageDescription": "Face ID",
        "NSContactsUsageDescription": "Danh bạ",
        "NSBluetoothAlwaysUsageDescription": "Bluetooth",
        "NSLocalNetworkUsageDescription": "Mạng cục bộ (Local Network)",
        "NSUserTrackingUsageDescription": "Theo dõi quảng cáo (ATT)"
    ]

    public init() {}

    public func parsePackage(at ipaURL: URL) async throws -> IPAParsedMetadata {
        try await Task.detached(priority: .userInitiated) {
            try Self.parseSynchronously(at: ipaURL)
        }.value
    }

    private static func extractData(from archive: Archive, entry: Entry, maxBytes: Int = 0) throws -> Data {
        var out = Data()
        if maxBytes > 0 {
            out.reserveCapacity(min(maxBytes, Int(entry.uncompressedSize)))
        } else {
            out.reserveCapacity(Int(min(entry.uncompressedSize, 16 * 1024 * 1024)))
        }

        _ = try archive.extract(entry, bufferSize: 65536) { chunk in
            if maxBytes > 0 {
                let remain = maxBytes - out.count
                if remain > 0 {
                    out.append(chunk.prefix(remain))
                }
            } else {
                out.append(chunk)
            }
        }
        return out
    }

    private static func parseSynchronously(at ipaURL: URL) throws -> IPAParsedMetadata {
        guard let archive = Archive(url: ipaURL, accessMode: .read) else {
            throw NSError(
                domain: "NativeIPAParser",
                code: -10,
                userInfo: [NSLocalizedDescriptionKey: "Không thể mở kho nén ZIP của tệp IPA."]
            )
        }

        var safeEntries: [Entry] = []
        var totalUncompressed: Int64 = 0
        var appPrefix: String?

        for entry in archive {
            guard StorageManager.isSafeRelativeEntryPath(entry.path) else { continue }
            safeEntries.append(entry)
            totalUncompressed += Int64(entry.uncompressedSize)

            if appPrefix == nil, entry.path.hasPrefix("Payload/") {
                let comps = entry.path.split(separator: "/")
                if comps.count >= 2, comps[1].hasSuffix(".app") {
                    appPrefix = "Payload/\(comps[1])/"
                }
            }
        }

        guard let prefix = appPrefix else {
            throw NSError(
                domain: "NativeIPAParser",
                code: -11,
                userInfo: [NSLocalizedDescriptionKey: "Tệp IPA không chứa cấu trúc Payload/*.app hợp lệ."]
            )
        }

        let appEntries = safeEntries.filter { $0.path.hasPrefix(prefix) }
        guard let infoEntry = appEntries.first(where: { $0.path == "\(prefix)Info.plist" }) else {
            throw NSError(
                domain: "NativeIPAParser",
                code: -12,
                userInfo: [NSLocalizedDescriptionKey: "Không tìm thấy Info.plist bên trong gói ứng dụng."]
            )
        }

        let infoData = try extractData(from: archive, entry: infoEntry)
        guard let info = try PropertyListSerialization.propertyList(from: infoData, options: [], format: nil) as? [String: Any] else {
            throw NSError(
                domain: "NativeIPAParser",
                code: -13,
                userInfo: [NSLocalizedDescriptionKey: "Info.plist của ứng dụng bị hỏng."]
            )
        }

        let fallbackAppName = String(prefix.dropFirst("Payload/".count).dropLast(".app/".count))
        let displayName = (info["CFBundleDisplayName"] as? String)
            ?? (info["CFBundleName"] as? String)
            ?? (info["CFBundleExecutable"] as? String)
            ?? fallbackAppName
        let bundleId = (info["CFBundleIdentifier"] as? String) ?? "unknown.bundle.id"
        let version = (info["CFBundleShortVersionString"] as? String) ?? "1.0"
        let buildNumber = (info["CFBundleVersion"] as? String) ?? "1"
        let executableName = info["CFBundleExecutable"] as? String
        let minOSFromPlist = info["MinimumOSVersion"] as? String

        var permissions: [IPAPermissionInfo] = []
        for (key, labelVi) in permissionLabelsVi {
            if let reason = info[key] as? String {
                permissions.append(IPAPermissionInfo(key: key, labelVi: labelVi, usageDescription: reason))
            }
        }

        // Frameworks & PlugIns (.appex)
        var frameworkSet = Set<String>()
        var pluginFolders = Set<String>()
        for entry in appEntries {
            let rel = String(entry.path.dropFirst(prefix.count))
            let parts = rel.split(separator: "/")
            if parts.count >= 2, parts[0] == "Frameworks", parts[1].hasSuffix(".framework") {
                frameworkSet.insert(String(parts[1]))
            }
            if parts.count >= 2, parts[0] == "PlugIns", parts[1].hasSuffix(".appex") {
                pluginFolders.insert(String(parts[1]))
            }
        }

        var appExtensions: [IPAExtensionInfo] = []
        for folder in pluginFolders.sorted() {
            let plugPlistPath = "\(prefix)PlugIns/\(folder)/Info.plist"
            var extName = folder.replacingOccurrences(of: ".appex", with: "")
            var extBundle = "\(bundleId).\(extName)"
            var extPoint: String?
            if let pEntry = appEntries.first(where: { $0.path == plugPlistPath }),
               let pData = try? extractData(from: archive, entry: pEntry),
               let pDict = (try? PropertyListSerialization.propertyList(from: pData, options: [], format: nil)) as? [String: Any] {
                extName = (pDict["CFBundleDisplayName"] as? String) ?? (pDict["CFBundleName"] as? String) ?? extName
                extBundle = (pDict["CFBundleIdentifier"] as? String) ?? extBundle
                if let nsExt = pDict["NSExtension"] as? [String: Any] {
                    extPoint = nsExt["NSExtensionPointIdentifier"] as? String
                }
            }
            appExtensions.append(
                IPAExtensionInfo(
                    folderName: folder,
                    displayName: extName,
                    bundleId: extBundle,
                    extensionPoint: extPoint
                )
            )
        }

        // Trích xuất biểu tượng ứng dụng & khôi phục CgBI -> PNG chuẩn
        let iconPNGData = extractBestAppIcon(archive: archive, appEntries: appEntries, prefix: prefix, info: info)

        // Phân tích Mach-O & Chữ ký số
        var architectures: [String] = []
        var isEncrypted = false
        var minOSMachO: String?
        var sdkVer: String?
        var codeSigSummary: MachOInspector.CodeSignatureSummary?

        if let exec = executableName,
           let execEntry = appEntries.first(where: { $0.path == "\(prefix)\(exec)" }) {
            // Nếu tệp thực thi <= 64MB thì đọc đầy đủ để lấy cả LC_CODE_SIGNATURE ở cuối tệp; nếu lớn hơn chỉ đọc phần đầu
            let limit = execEntry.uncompressedSize <= 64 * 1024 * 1024 ? 0 : 524_288
            if let execData = try? extractData(from: archive, entry: execEntry, maxBytes: limit),
               let macho = MachOInspector.inspectHeader(execData) {
                architectures = macho.architectures
                isEncrypted = macho.isFairPlayEncrypted
                minOSMachO = macho.minOSVersion
                sdkVer = macho.sdkVersion

                if let csOff = macho.codeSignatureOffset,
                   let csLen = macho.codeSignatureSize,
                   csOff >= 0,
                   csOff + csLen <= execData.count {
                    let sigData = execData.subdata(in: (execData.startIndex + csOff)..<(execData.startIndex + csOff + csLen))
                    codeSigSummary = MachOInspector.inspectCodeSignature(sigData)
                }
            }
        }

        // Phân tích embedded.mobileprovision
        var detailedProv: MobileProvisionInspector.DetailedProvision?
        if let provEntry = appEntries.first(where: { $0.path == "\(prefix)embedded.mobileprovision" }),
           let provData = try? extractData(from: archive, entry: provEntry) {
            detailedProv = try? MobileProvisionInspector.parse(data: provData)
        }

        var mergedEntitlements = detailedProv?.entitlements ?? [:]
        if let csEnts = codeSigSummary?.entitlements {
            for (k, v) in csEnts {
                mergedEntitlements[k] = v
            }
        }

        let signatureSummaryVi: String
        if let prov = detailedProv?.summary {
            if prov.isExpired {
                signatureSummaryVi = "Đã hết hạn (\(prov.distributionType)) — Cần ký lại"
            } else {
                signatureSummaryVi = "Đã ký (\(prov.distributionType))"
            }
        } else if let cs = codeSigSummary {
            signatureSummaryVi = cs.isAdHocSigned
                ? "Chữ ký Ad-Hoc cục bộ (ldid) — Cần ký lại bằng chứng chỉ hợp lệ"
                : "Có chữ ký nhị phân (không kèm mobileprovision)"
        } else {
            signatureSummaryVi = "Chưa ký số (Unsigned IPA)"
        }

        return IPAParsedMetadata(
            displayName: displayName,
            bundleId: bundleId,
            version: version,
            buildNumber: buildNumber,
            executableName: executableName,
            minimumOSVersion: minOSFromPlist ?? minOSMachO,
            sdkVersion: sdkVer ?? (info["DTPlatformVersion"] as? String),
            architectures: architectures.isEmpty ? ["arm64"] : architectures,
            isFairPlayEncrypted: isEncrypted,
            totalEntries: safeEntries.count,
            uncompressedBytes: totalUncompressed,
            frameworks: frameworkSet.sorted(),
            appExtensions: appExtensions,
            permissions: permissions,
            entitlements: mergedEntitlements,
            provisioning: detailedProv?.summary,
            signatureSummaryVi: signatureSummaryVi,
            iconPNGData: iconPNGData
        )
    }

    private static func extractBestAppIcon(
        archive: Archive,
        appEntries: [Entry],
        prefix: String,
        info: [String: Any]
    ) -> Data? {
        var stems: [String] = []
        if let icons = info["CFBundleIcons"] as? [String: Any],
           let primary = icons["CFBundlePrimaryIcon"] as? [String: Any] {
            if let files = primary["CFBundleIconFiles"] as? [String] {
                stems.append(contentsOf: files)
            }
            if let name = primary["CFBundleIconName"] as? String {
                stems.append(name)
            }
        }
        if let legacy = info["CFBundleIconFiles"] as? [String] {
            stems.append(contentsOf: legacy)
        }

        let rootPNGs = appEntries.filter { entry in
            guard entry.type == .file else { return false }
            let rel = String(entry.path.dropFirst(prefix.count))
            return !rel.contains("/") && rel.lowercased().hasSuffix(".png")
        }

        var candidates = rootPNGs.filter { entry in
            let base = String(entry.path.dropFirst(prefix.count)).lowercased()
            return stems.contains { base.hasPrefix($0.lowercased()) }
        }
        if candidates.isEmpty {
            candidates = rootPNGs.filter { entry in
                let base = String(entry.path.dropFirst(prefix.count)).lowercased()
                return base.contains("icon")
            }
        }
        let sorted = (candidates.isEmpty ? rootPNGs : candidates)
            .sorted { $0.uncompressedSize > $1.uncompressedSize }

        if let best = sorted.first,
           let rawData = try? extractData(from: archive, entry: best),
           let norm = CgBIPNGNormalizer.normalizePNGData(rawData) {
            return norm
        }

        if let carEntry = appEntries.first(where: { $0.path == "\(prefix)Assets.car" && $0.uncompressedSize <= 24 * 1024 * 1024 }),
           let carData = try? extractData(from: archive, entry: carEntry) {
            return CgBIPNGNormalizer.extractLargestPNGFromAssetsCar(carData)
        }
        return nil
    }
}

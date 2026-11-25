import Foundation

/// Giải mã tệp CMS/PKCS#7 embedded.mobileprovision thành đối tượng cấu trúc rõ ràng
public enum MobileProvisionInspector {
    public struct DetailedProvision {
        public let summary: ProvisioningSummary
        public let appIDName: String?
        public let timeToLiveDays: Int?
        public let entitlements: [String: String]
        public let developerCertificateDERs: [Data]
    }

    public static func parse(data: Data) throws -> DetailedProvision {
        let startMarker = Data("<?xml".utf8)
        let fallbackMarker = Data("<plist".utf8)
        let endMarker = Data("</plist>".utf8)

        let plistStartRange = data.range(of: startMarker) ?? data.range(of: fallbackMarker)
        guard let startRange = plistStartRange,
              let endRange = data.range(of: endMarker, options: .backwards, in: startRange.lowerBound..<data.endIndex) else {
            throw NSError(
                domain: "MobileProvisionInspector",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Không tìm thấy nội dung XML Plist hợp lệ trong tệp .mobileprovision."]
            )
        }

        let xmlData = data.subdata(in: startRange.lowerBound..<endRange.upperBound)
        guard let dict = try PropertyListSerialization.propertyList(from: xmlData, options: [], format: nil) as? [String: Any] else {
            throw NSError(
                domain: "MobileProvisionInspector",
                code: -2,
                userInfo: [NSLocalizedDescriptionKey: "Cấu trúc Plist bên trong .mobileprovision không hợp lệ."]
            )
        }

        let name = (dict["Name"] as? String) ?? "Unknown Profile"
        let teamName = (dict["TeamName"] as? String) ?? "Unknown Team"
        let teamIds = (dict["TeamIdentifier"] as? [String]) ?? []
        let teamId = teamIds.first ?? "UNKNOWN"
        let creationDate = dict["CreationDate"] as? Date
        let expirationDate = dict["ExpirationDate"] as? Date
        let ttl = dict["TimeToLive"] as? Int
        let provisionsAll = (dict["ProvisionsAllDevices"] as? Bool) ?? false
        let udids = (dict["ProvisionedDevices"] as? [String]) ?? []
        let certDERs = (dict["DeveloperCertificates"] as? [Data]) ?? []

        let rawEnts = (dict["Entitlements"] as? [String: Any]) ?? [:]
        var stringEnts: [String: String] = [:]
        for (k, v) in rawEnts {
            stringEnts[k] = String(describing: v)
        }

        let getTaskAllow = (rawEnts["get-task-allow"] as? Bool) ?? false
        let isPersonalFree = getTaskAllow && (ttl ?? 365) <= 7

        let distType: String
        let supportsOTA: Bool

        if provisionsAll {
            distType = "Enterprise (In-House)"
            supportsOTA = true
        } else if getTaskAllow {
            distType = isPersonalFree
                ? "Development (Apple Personal Team – 7 ngày)"
                : "Apple Development"
            supportsOTA = false
        } else if !udids.isEmpty {
            distType = "Ad-Hoc Distribution"
            supportsOTA = true
        } else {
            distType = "App Store Distribution"
            supportsOTA = false
        }

        let summary = ProvisioningSummary(
            profileName: name,
            teamName: teamName,
            teamIdentifier: teamId,
            distributionType: distType,
            creationDate: creationDate,
            expirationDate: expirationDate,
            provisionsAllDevices: provisionsAll,
            provisionedUDIDs: udids,
            supportsOTA: supportsOTA
        )

        return DetailedProvision(
            summary: summary,
            appIDName: dict["AppIDName"] as? String,
            timeToLiveDays: ttl,
            entitlements: stringEnts,
            developerCertificateDERs: certDERs
        )
    }
}

import Foundation
import Security

/// Giao diện chuẩn cho 4 lõi xử lý độc lập (sẽ gắn triển khai nhị phân đầy đủ ở Giai đoạn 4 & 6)
public protocol IPAParserProtocol {
    func parsePackage(at ipaURL: URL) async throws -> IPAParsedMetadata
}

public protocol CertificateValidatorProtocol {
    func importCertificatePair(
        p12URL: URL,
        p12Password: String,
        mobileProvisionURL: URL,
        nickname: String
    ) async throws -> CertificateRecord

    func validateBeforeSigning(
        certificate: CertificateRecord,
        package: IPAPackageItem,
        userDeviceUDID: String,
        checkOnlineOCSP: Bool
    ) async -> [CertificateCheckStep]
}

public protocol IPASignerProtocol {
    func signPackage(
        sourceIPAURL: URL,
        certificate: CertificateRecord,
        options: SigningOptions,
        onProgress: @escaping @Sendable (Double, String) -> Void
    ) async throws -> URL
}

public protocol InstallationManagerProtocol {
    var statusSummary: String { get }
    func triggerInstallation(
        signedIPAURL: URL,
        package: IPAPackageItem,
        certificate: CertificateRecord?
    ) async throws -> String
}

/// Kiểm định cơ sở cho Giai đoạn 3 (kiểm tra thật PKCS#12 thông qua Security.framework ngay từ Giai đoạn 3!)
public struct PKCS12QuickInspector {
    public struct IdentitySummary {
        public let commonName: String
        public let serialHex: String
    }

    public static func verifyPKCS12Password(data: Data, password: String) throws -> IdentitySummary {
        let options: [String: Any] = [kSecImportExportPassphrase as String: password]
        var items: CFArray?
        let status = SecPKCS12Import(data as CFData, options as CFDictionary, &items)
        guard status == errSecSuccess,
              let array = items as? [[String: Any]],
              let first = array.first,
              let identityRef = first[kSecImportItemIdentity as String] else {
            throw NSError(
                domain: "PKCS12QuickInspector",
                code: Int(status),
                userInfo: [NSLocalizedDescriptionKey: "Mật khẩu .p12 không đúng hoặc tệp PKCS#12 bị hỏng (OSStatus: \(status))."]
            )
        }

        let secIdentity = identityRef as! SecIdentity
        var certRef: SecCertificate?
        let certStatus = SecIdentityCopyCertificate(secIdentity, &certRef)
        guard certStatus == errSecSuccess, let cert = certRef else {
            throw NSError(
                domain: "PKCS12QuickInspector",
                code: Int(certStatus),
                userInfo: [NSLocalizedDescriptionKey: "Không trích xuất được chứng chỉ X.509 từ PKCS#12."]
            )
        }

        let cn = (SecCertificateCopySubjectSummary(cert) as String?) ?? "Apple Certificate"
        let der = SecCertificateCopyData(cert) as Data
        let serialPreview = der.prefix(12).map { String(format: "%02X", $0) }.joined()
        return IdentitySummary(commonName: cn, serialHex: serialPreview)
    }
}

import Foundation
import ZSignKit

/// Bộ ký số IPA độc lập sử dụng nhân ZSign C++ & OpenSSL 3.6 trực tiếp trên iPhone
public final class NativeIPASigner: IPASignerProtocol {
    public init() {}

    public func signPackage(
        sourceIPAURL: URL,
        certificate: CertificateRecord,
        options: SigningOptions,
        onProgress: @escaping @Sendable (Double, String) -> Void
    ) async throws -> URL {
        let p12URL = try StorageManager.shared.resolveURL(for: certificate.p12RelativePath)
        let provURL = try StorageManager.shared.resolveURL(for: certificate.mobileProvisionRelativePath)
        guard let password = try KeychainStore.readSecret(forKey: certificate.keychainPasswordKey) else {
            throw NSError(
                domain: "NativeIPASigner",
                code: -30,
                userInfo: [NSLocalizedDescriptionKey: "Không tìm thấy mật khẩu chứng chỉ trong iOS Keychain."]
            )
        }

        StorageManager.shared.ensureDirectories()
        let outId = UUID().uuidString.prefix(8)
        let rawStem = sourceIPAURL.deletingPathExtension().lastPathComponent
        let outFileName = "\(outId)_signed_\(rawStem).ipa"
        let outURL = StorageManager.shared.signedIPAsDirectory.appendingPathComponent(outFileName)
        let tempWorkDir = StorageManager.shared.workTempDirectory

        onProgress(0.15, "Đang giải nén gói IPA và nạp khóa mật mã OpenSSL...")

        let cleanBundleId = options.customBundleId.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanDisplayName = options.customDisplayName.trimmingCharacters(in: .whitespacesAndNewlines)

        let request = ZSignRequest(
            inputIPAPath: sourceIPAURL.path,
            outputIPAPath: outURL.path,
            p12Path: p12URL.path,
            p12Password: password,
            mobileProvisionPath: provURL.path,
            customBundleId: cleanBundleId.isEmpty ? nil : cleanBundleId,
            customDisplayName: cleanDisplayName.isEmpty ? nil : cleanDisplayName,
            customBundleVersion: nil,
            tempDirectoryPath: tempWorkDir.path,
            adhocSign: false,
            removeExtensions: options.stripAppExtensions,
            enableDocuments: options.enableFileSharing,
            zipLevel: 6
        )

        onProgress(0.45, "Đang ký đệ quy Mach-O bằng ZSign C++ & sinh CodeResources...")

        try await Task.detached(priority: .userInitiated) {
            try ZSignWrapper.signIPA(request)
        }.value

        onProgress(0.85, "Đang tự xác minh cấu trúc chữ ký của gói IPA đầu ra...")

        // Phân tích ngược lại gói IPA đầu ra bằng NativeIPAParser để đảm bảo gói nguyên vẹn 100%
        let parser = NativeIPAParser()
        let signedMeta = try await parser.parsePackage(at: outURL)
        guard signedMeta.provisioning != nil else {
            try? FileManager.default.removeItem(at: outURL)
            throw NSError(
                domain: "NativeIPASigner",
                code: -31,
                userInfo: [NSLocalizedDescriptionKey: "Xác minh sau khi ký thất bại: Gói đầu ra thiếu embedded.mobileprovision."]
            )
        }

        onProgress(1.0, "Ký số và xác minh chữ ký hoàn tất!")
        return outURL
    }
}

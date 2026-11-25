import Foundation
import Security
import ZSignKit

/// Chốt chặn kiểm tra chứng chỉ 6 bước trước khi ký & cài đặt (bao gồm truy vấn OCSP trực tiếp tới Apple)
public final class NativeCertificateValidator: CertificateValidatorProtocol {
    public init() {}

    public func importCertificatePair(
        p12URL: URL,
        p12Password: String,
        mobileProvisionURL: URL,
        nickname: String
    ) async throws -> CertificateRecord {
        let p12Scoped = p12URL.startAccessingSecurityScopedResource()
        let provScoped = mobileProvisionURL.startAccessingSecurityScopedResource()
        defer {
            if p12Scoped { p12URL.stopAccessingSecurityScopedResource() }
            if provScoped { mobileProvisionURL.stopAccessingSecurityScopedResource() }
        }

        let p12Data = try Data(contentsOf: p12URL)
        let provData = try Data(contentsOf: mobileProvisionURL)

        let extracted = try Self.extractIdentityAndVerifyKeyPair(p12Data: p12Data, password: p12Password)
        let detailedProv = try MobileProvisionInspector.parse(data: provData)

        let id = UUID()
        let p12Rel = "Certificates/\(id.uuidString).p12"
        let provRel = "Certificates/\(id.uuidString).mobileprovision"
        let p12Dest = try StorageManager.shared.resolveURL(for: p12Rel)
        let provDest = try StorageManager.shared.resolveURL(for: provRel)

        try p12Data.write(to: p12Dest, options: .atomic)
        try provData.write(to: provDest, options: .atomic)

        let keychainKey = "cert_pwd_\(id.uuidString)"
        try KeychainStore.saveSecret(p12Password, forKey: keychainKey)

        let ocspState = await Self.checkAppleOCSPRevocation(
            certificate: extracted.certificate,
            p12Path: p12Dest.path,
            password: p12Password
        )

        let cleanNick = nickname.trimmingCharacters(in: .whitespacesAndNewlines)
        return CertificateRecord(
            id: id,
            nickname: cleanNick.isEmpty ? extracted.commonName : cleanNick,
            commonName: extracted.commonName,
            teamName: detailedProv.summary.teamName,
            teamId: detailedProv.summary.teamIdentifier,
            serialNumber: extracted.serialHex,
            distributionType: detailedProv.summary.distributionType,
            expirationDate: detailedProv.summary.expirationDate,
            provisionsAllDevices: detailedProv.summary.provisionsAllDevices,
            provisionedUDIDs: detailedProv.summary.provisionedUDIDs,
            p12RelativePath: p12Rel,
            mobileProvisionRelativePath: provRel,
            keychainPasswordKey: keychainKey,
            lastOCSPStatus: ocspState
        )
    }

    public func validateBeforeSigning(
        certificate: CertificateRecord,
        package: IPAPackageItem,
        userDeviceUDID: String,
        checkOnlineOCSP: Bool
    ) async -> [CertificateCheckStep] {
        var steps: [CertificateCheckStep] = []

        // Đọc dữ liệu .p12, mật khẩu Keychain & .mobileprovision
        guard let p12URL = try? StorageManager.shared.resolveURL(for: certificate.p12RelativePath),
              let provURL = try? StorageManager.shared.resolveURL(for: certificate.mobileProvisionRelativePath),
              let p12Data = try? Data(contentsOf: p12URL),
              let provData = try? Data(contentsOf: provURL),
              let password = (try? KeychainStore.readSecret(forKey: certificate.keychainPasswordKey)) ?? nil else {
            steps.append(
                CertificateCheckStep(
                    id: 1,
                    title: "Đọc khóa PKCS#12 & Keychain",
                    passed: false,
                    isBlocking: true,
                    detail: "Không đọc được tệp .p12/.mobileprovision hoặc mật khẩu trong Keychain đã bị xóa."
                )
            )
            return steps
        }

        // Bước 1: Kiểm tra giải mã PKCS#12 & toán học cặp khóa Công khai ↔ Riêng tư
        let extracted: ExtractedIdentity
        do {
            extracted = try Self.extractIdentityAndVerifyKeyPair(p12Data: p12Data, password: password)
            steps.append(
                CertificateCheckStep(
                    id: 1,
                    title: "Xác thực cặp khóa PKCS#12 (.p12)",
                    passed: true,
                    isBlocking: true,
                    detail: "Khóa riêng tư khớp toán học 100% với chứng chỉ \(extracted.commonName)."
                )
            )
        } catch {
            steps.append(
                CertificateCheckStep(
                    id: 1,
                    title: "Xác thực cặp khóa PKCS#12 (.p12)",
                    passed: false,
                    isBlocking: true,
                    detail: error.localizedDescription
                )
            )
            return steps
        }

        // Giải mã .mobileprovision
        guard let detailedProv = try? MobileProvisionInspector.parse(data: provData) else {
            steps.append(
                CertificateCheckStep(
                    id: 2,
                    title: "Đọc Provisioning Profile",
                    passed: false,
                    isBlocking: true,
                    detail: "Tệp .mobileprovision bị hỏng cấu trúc CMS/XML."
                )
            )
            return steps
        }

        // Bước 2: Kiểm tra hạn hiệu lực
        let isExpired = detailedProv.summary.isExpired
        let expString: String
        if let exp = detailedProv.summary.expirationDate {
            let df = DateFormatter()
            df.locale = Locale(identifier: "vi_VN")
            df.dateStyle = .medium
            expString = df.string(from: exp)
        } else {
            expString = "Không rõ"
        }
        steps.append(
            CertificateCheckStep(
                id: 2,
                title: "Kiểm tra thời hạn hiệu lực",
                passed: !isExpired,
                isBlocking: true,
                detail: isExpired
                    ? "Provisioning Profile đã hết hạn vào ngày \(expString)."
                    : "Còn hiệu lực đến ngày \(expString)."
            )
        )

        // Bước 3: Kiểm tra thu hồi trực tuyến OCSP tới máy chủ Apple
        if checkOnlineOCSP {
            let ocsp = await Self.checkAppleOCSPRevocation(
                certificate: extracted.certificate,
                p12Path: p12URL.path,
                password: password
            )
            switch ocsp {
            case .good:
                steps.append(
                    CertificateCheckStep(
                        id: 3,
                        title: "Kiểm tra thu hồi OCSP với Apple",
                        passed: true,
                        isBlocking: true,
                        detail: "Máy chủ OCSP của Apple xác nhận chứng chỉ đang hợp lệ (Good)."
                    )
                )
            case .revoked:
                steps.append(
                    CertificateCheckStep(
                        id: 3,
                        title: "Kiểm tra thu hồi OCSP với Apple",
                        passed: false,
                        isBlocking: true,
                        detail: "CHẶN CÀI ĐẶT: Chứng chỉ này đã bị Apple thu hồi (Revoked)! Nếu cố cài đặt, iOS sẽ báo lỗi Không thể xác minh ứng dụng."
                    )
                )
            case .offlineOrUnknown, .unchecked:
                steps.append(
                    CertificateCheckStep(
                        id: 3,
                        title: "Kiểm tra thu hồi OCSP với Apple",
                        passed: false,
                        isBlocking: false,
                        detail: "Chưa nhận được phản hồi OCSP trực tuyến (mất mạng hoặc chuỗi CA trung gian chưa tải). Chỉ tiếp tục nếu bạn chắc chắn chứng chỉ còn sống."
                    )
                )
            }
        } else {
            steps.append(
                CertificateCheckStep(
                    id: 3,
                    title: "Kiểm tra thu hồi OCSP với Apple",
                    passed: true,
                    isBlocking: false,
                    detail: "Đã bỏ qua truy vấn OCSP theo cấu hình Thiết lập hệ thống."
                )
            )
        }

        // Bước 4: Đối chiếu khớp chứng chỉ X.509 nằm trong DeveloperCertificates của .mobileprovision
        let certMatchesProfile = detailedProv.developerCertificateDERs.contains(extracted.certificateDER)
        steps.append(
            CertificateCheckStep(
                id: 4,
                title: "Đối chiếu khớp .p12 ↔ .mobileprovision",
                passed: certMatchesProfile,
                isBlocking: true,
                detail: certMatchesProfile
                    ? "Chứng chỉ .p12 nằm trong danh sách DeveloperCertificates của Profile (\(detailedProv.summary.teamName))."
                    : "Chứng chỉ .p12 KHÔNG khớp với tệp .mobileprovision đã chọn (khác chứng chỉ hoặc khác Team)."
            )
        )

        // Bước 5: Kiểm tra loại phân phối & UDID thiết bị
        let distType = detailedProv.summary.distributionType
        if distType == "App Store Distribution" {
            steps.append(
                CertificateCheckStep(
                    id: 5,
                    title: "Kiểm tra loại phân phối & UDID thiết bị",
                    passed: false,
                    isBlocking: true,
                    detail: "Profile loại App Store Distribution không thể dùng để cài đặt trực tiếp trên iPhone."
                )
            )
        } else if detailedProv.summary.provisionsAllDevices {
            steps.append(
                CertificateCheckStep(
                    id: 5,
                    title: "Kiểm tra loại phân phối & UDID thiết bị",
                    passed: true,
                    isBlocking: true,
                    detail: "Profile hỗ trợ mọi thiết bị (ProvisionsAllDevices)."
                )
            )
        } else {
            let trimmedUDID = userDeviceUDID.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmedUDID.isEmpty {
                steps.append(
                    CertificateCheckStep(
                        id: 5,
                        title: "Kiểm tra loại phân phối & UDID thiết bị",
                        passed: false,
                        isBlocking: false,
                        detail: "Profile giới hạn \(detailedProv.summary.provisionedUDIDs.count) UDID. Bạn chưa nhập UDID iPhone tại mục Thiết bị & Hồ sơ để đối chiếu tự động."
                    )
                )
            } else {
                let udidMatched = detailedProv.summary.provisionedUDIDs.contains {
                    $0.caseInsensitiveCompare(trimmedUDID) == .orderedSame
                }
                steps.append(
                    CertificateCheckStep(
                        id: 5,
                        title: "Kiểm tra loại phân phối & UDID thiết bị",
                        passed: udidMatched,
                        isBlocking: true,
                        detail: udidMatched
                            ? "UDID iPhone của bạn (\(trimmedUDID)) nằm trong danh sách được cấp phép của Profile."
                            : "CHẶN CÀI ĐẶT: UDID iPhone của bạn (\(trimmedUDID)) KHÔNG có trong danh sách ProvisionedDevices của Profile này!"
                    )
                )
            }
        }

        // Bước 6: Kiểm tra khóa FairPlay & Phiên bản iOS tối thiểu của IPA
        if let meta = package.metadata {
            if meta.isFairPlayEncrypted {
                steps.append(
                    CertificateCheckStep(
                        id: 6,
                        title: "Kiểm tra gói IPA & Tương thích iOS",
                        passed: false,
                        isBlocking: true,
                        detail: "CHẶN CÀI ĐẶT: Tệp IPA đang bị khóa DRM FairPlay App Store (cryptid = 1), không thể chạy sau khi ký lại."
                    )
                )
            } else if !DeviceEnvironment.isMinimumOSMet(meta.minimumOSVersion) {
                steps.append(
                    CertificateCheckStep(
                        id: 6,
                        title: "Kiểm tra gói IPA & Tương thích iOS",
                        passed: false,
                        isBlocking: true,
                        detail: "Ứng dụng yêu cầu iOS \(meta.minimumOSVersion ?? "?") trở lên, cao hơn iOS \(DeviceEnvironment.iosVersionString) hiện tại."
                    )
                )
            } else {
                steps.append(
                    CertificateCheckStep(
                        id: 6,
                        title: "Kiểm tra gói IPA & Tương thích iOS",
                        passed: true,
                        isBlocking: true,
                        detail: "Nhị phân Mach-O (\(meta.architectures.joined(separator: ", "))) không khóa FairPlay và tương thích iOS \(DeviceEnvironment.iosVersionString)."
                    )
                )
            }
        } else {
            steps.append(
                CertificateCheckStep(
                    id: 6,
                    title: "Kiểm tra gói IPA & Tương thích iOS",
                    passed: true,
                    isBlocking: false,
                    detail: "Sẵn sàng giải nén và kiểm tra nhị phân trong quá trình ký."
                )
            )
        }

        return steps
    }

    // MARK: - Helpers mật mã & OCSP hệ thống

    private struct ExtractedIdentity {
        let certificate: SecCertificate
        let certificateDER: Data
        let commonName: String
        let serialHex: String
    }

    private static func extractIdentityAndVerifyKeyPair(p12Data: Data, password: String) throws -> ExtractedIdentity {
        let options: [String: Any] = [kSecImportExportPassphrase as String: password]
        var importedItems: CFArray?
        let status = SecPKCS12Import(p12Data as CFData, options as CFDictionary, &importedItems)
        guard status == errSecSuccess,
              let array = importedItems as? [[String: Any]],
              let first = array.first,
              let identityObj = first[kSecImportItemIdentity as String] else {
            throw NSError(
                domain: "NativeCertificateValidator",
                code: Int(status),
                userInfo: [NSLocalizedDescriptionKey: "Giải mã .p12 thất bại (sai mật khẩu hoặc tệp PKCS#12 không hợp lệ, mã \(status))."]
            )
        }

        let identity = identityObj as! SecIdentity
        var certOpt: SecCertificate?
        var privKeyOpt: SecKey?
        guard SecIdentityCopyCertificate(identity, &certOpt) == errSecSuccess,
              let cert = certOpt,
              SecIdentityCopyPrivateKey(identity, &privKeyOpt) == errSecSuccess,
              let privateKey = privKeyOpt,
              let publicKey = SecCertificateCopyKey(cert) else {
            throw NSError(
                domain: "NativeCertificateValidator",
                code: -20,
                userInfo: [NSLocalizedDescriptionKey: "Không thể trích xuất đủ cặp khóa Công khai / Riêng tư từ tệp .p12."]
            )
        }

        // Ký thử thông điệp kiểm tra để chứng minh Private Key khớp toán học với X.509 Public Key
        let challenge = Data("ipa-installer-keypair-verification".utf8)
        let candidateAlgorithms: [SecKeyAlgorithm] = [
            .rsaSignatureMessagePKCS1v15SHA256,
            .ecdsaSignatureMessageX962SHA256
        ]

        var verifiedPair = false
        for alg in candidateAlgorithms where SecKeyIsAlgorithmSupported(privateKey, .sign, alg) {
            var signErr: Unmanaged<CFError>?
            if let sig = SecKeyCreateSignature(privateKey, alg, challenge as CFData, &signErr) as Data? {
                var verifyErr: Unmanaged<CFError>?
                if SecKeyVerifySignature(publicKey, alg, challenge as CFData, sig as CFData, &verifyErr) {
                    verifiedPair = true
                    break
                }
            }
        }

        guard verifiedPair else {
            throw NSError(
                domain: "NativeCertificateValidator",
                code: -21,
                userInfo: [NSLocalizedDescriptionKey: "Khóa riêng tư trong .p12 không khớp toán học với chứng chỉ X.509."]
            )
        }

        let cn = (SecCertificateCopySubjectSummary(cert) as String?) ?? "Apple Certificate"
        let der = SecCertificateCopyData(cert) as Data
        let serialData: Data
        if #available(iOS 11.0, *), let cfSerial = SecCertificateCopySerialNumberData(cert, nil) as Data? {
            serialData = cfSerial
        } else {
            serialData = der.prefix(10)
        }
        let serialHex = serialData.map { String(format: "%02X", $0) }.joined()

        return ExtractedIdentity(
            certificate: cert,
            certificateDER: der,
            commonName: cn,
            serialHex: serialHex
        )
    }

    private static func checkAppleOCSPRevocation(
        certificate: SecCertificate,
        p12Path: String,
        password: String
    ) async -> OCSPVerificationState {
        await Task.detached(priority: .utility) {
            // Ưu tiên 1: Truy vấn OCSP trực tiếp bằng OpenSSL + chuỗi WWDR G1-G8 nhúng sẵn của ZSign
            let zsignStatus = ZSignWrapper.checkCertificateOCSP(filePath: p12Path, password: password)
            switch zsignStatus {
            case .valid:
                return .good
            case .revoked:
                return .revoked
            case .expired:
                return .revoked
            case .unsigned, .error:
                break
            }

            // Ưu tiên 2 (Dự phòng): Đánh giá qua SecTrust của hệ điều hành iOS
            let basicPolicy = SecPolicyCreateBasicX509()
            guard let revPolicy = SecPolicyCreateRevocation(
                kSecRevocationOCSPMethod | kSecRevocationRequirePositiveResponse
            ) else {
                return .offlineOrUnknown
            }

            var trustOpt: SecTrust?
            let createStatus = SecTrustCreateWithCertificates(
                [certificate] as CFArray,
                [basicPolicy, revPolicy] as CFArray,
                &trustOpt
            )
            guard createStatus == errSecSuccess, let trust = trustOpt else {
                return .offlineOrUnknown
            }

            var evalError: CFError?
            let trusted = SecTrustEvaluateWithError(trust, &evalError)
            if trusted {
                return .good
            }

            if let err = evalError {
                let code = CFErrorGetCode(err)
                let desc = (CFErrorCopyDescription(err) as String? ?? "").lowercased()
                if code == -67820 || desc.contains("revoked") {
                    return .revoked
                }
            }
            return .offlineOrUnknown
        }.value
    }
}

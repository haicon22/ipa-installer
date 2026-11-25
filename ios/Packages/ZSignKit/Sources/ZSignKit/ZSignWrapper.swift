import CZSign
import Foundation

public enum ZSignCertStatus: Int32 {
    case valid = 0
    case revoked = 1
    case expired = 2
    case unsigned = -2
    case error = -1
}

public enum ZSignError: LocalizedError {
    case signingFailed(code: Int32, message: String)
    case verificationFailed(code: Int32, message: String)

    public var errorDescription: String? {
        switch self {
        case .signingFailed(let code, let message):
            return "Lỗi ký ZSign (\(code)): \(message)"
        case .verificationFailed(let code, let message):
            return "Xác minh chữ ký sau khi ký thất bại (\(code)): \(message)"
        }
    }
}

public struct ZSignRequest: Sendable {
    public let inputIPAPath: String
    public let outputIPAPath: String
    public let p12Path: String?
    public let p12Password: String?
    public let mobileProvisionPath: String?
    public let customBundleId: String?
    public let customDisplayName: String?
    public let customBundleVersion: String?
    public let tempDirectoryPath: String?
    public let adhocSign: Bool
    public let removeExtensions: Bool
    public let enableDocuments: Bool
    public let zipLevel: Int32

    public init(
        inputIPAPath: String,
        outputIPAPath: String,
        p12Path: String? = nil,
        p12Password: String? = nil,
        mobileProvisionPath: String? = nil,
        customBundleId: String? = nil,
        customDisplayName: String? = nil,
        customBundleVersion: String? = nil,
        tempDirectoryPath: String? = nil,
        adhocSign: Bool = false,
        removeExtensions: Bool = false,
        enableDocuments: Bool = false,
        zipLevel: Int32 = 6
    ) {
        self.inputIPAPath = inputIPAPath
        self.outputIPAPath = outputIPAPath
        self.p12Path = p12Path
        self.p12Password = p12Password
        self.mobileProvisionPath = mobileProvisionPath
        self.customBundleId = customBundleId
        self.customDisplayName = customDisplayName
        self.customBundleVersion = customBundleVersion
        self.tempDirectoryPath = tempDirectoryPath
        self.adhocSign = adhocSign
        self.removeExtensions = removeExtensions
        self.enableDocuments = enableDocuments
        self.zipLevel = zipLevel
    }
}

/// Giao diện Swift an toàn bộ nhớ gọi trực tiếp xuống nhân C++ ZSign v1.1.3 + OpenSSL 3.6
public enum ZSignWrapper {
    public static func signIPA(_ req: ZSignRequest) throws {
        var errorBuffer = [CChar](repeating: 0, count: 1024)

        let rc: Int32 = req.inputIPAPath.withCString { cInput in
            req.outputIPAPath.withCString { cOutput in
                (req.p12Path ?? "").withCString { cP12 in
                    (req.p12Password ?? "").withCString { cPass in
                        (req.mobileProvisionPath ?? "").withCString { cProv in
                            (req.customBundleId ?? "").withCString { cBid in
                                (req.customDisplayName ?? "").withCString { cName in
                                    (req.customBundleVersion ?? "").withCString { cVer in
                                        (req.tempDirectoryPath ?? "").withCString { cTmp in
                                            var opts = czsign_options_t(
                                                input_ipa_path: cInput,
                                                output_ipa_path: cOutput,
                                                p12_path: cP12,
                                                p12_password: cPass,
                                                mobileprovision_path: cProv,
                                                custom_bundle_id: cBid,
                                                custom_display_name: cName,
                                                custom_bundle_version: cVer,
                                                temp_directory_path: cTmp,
                                                adhoc_sign: req.adhocSign ? 1 : 0,
                                                remove_extensions: req.removeExtensions ? 1 : 0,
                                                enable_documents: req.enableDocuments ? 1 : 0,
                                                zip_level: req.zipLevel
                                            )
                                            return czsign_sign_ipa(&opts, &errorBuffer, UInt32(errorBuffer.count))
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }

        if rc != 0 {
            let msg = String(cString: errorBuffer)
            throw ZSignError.signingFailed(
                code: rc,
                message: msg.isEmpty ? "Không thể ký tệp IPA." : msg
            )
        }
    }

    public static func verifyMachOSignature(at machoPath: String, requireCMSBlob: Bool) throws {
        var errorBuffer = [CChar](repeating: 0, count: 1024)
        let rc = machoPath.withCString { cPath in
            czsign_verify_macho_signature(
                cPath,
                requireCMSBlob ? 1 : 0,
                &errorBuffer,
                UInt32(errorBuffer.count)
            )
        }
        if rc != 0 {
            let msg = String(cString: errorBuffer)
            throw ZSignError.verificationFailed(code: rc, message: msg)
        }
    }

    public static func checkCertificateOCSP(filePath: String, password: String = "") -> ZSignCertStatus {
        let code = filePath.withCString { cFile in
            password.withCString { cPass in
                czsign_check_certificate(cFile, cPass)
            }
        }
        return ZSignCertStatus(rawValue: code) ?? .error
    }
}

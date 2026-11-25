import Foundation
import UIKit

/// Bộ điều phối cài đặt độc lập (Giai đoạn 6):
/// - Kiểm tra nghiêm ngặt gói IPA đầu vào trước khi cài (FairPlay, chữ ký, thời hạn, OCSP, loại Profile)
/// - Tự động định tuyến trung thực theo đúng cơ chế hệ điều hành iOS 15.0 → iOS 26.6+:
///   1) Với gói Development / Apple Personal Team (0đ): ưu tiên chuyển tiếp qua SideStore / LiveContainer
///      trên thiết bị (hoặc xuất ra thư mục chia sẻ Files để cài qua Pairing File / Termux USB-OTG) —
///      tuyệt đối KHÔNG gọi mù quáng itms-services:// vốn bị installd chặn với chứng chỉ miễn phí!
///   2) Với gói Ad-Hoc / Enterprise hợp lệ: mở máy chủ Local OTA và gọi giao thức chuẩn itms-services://.
@MainActor
public final class NativeInstallationManager: InstallationManagerProtocol {
    private let portProvider: () -> Int

    public init(portProvider: @escaping () -> Int) {
        self.portProvider = portProvider
    }

    public var statusSummary: String {
        if hasSideStoreInstalled {
            return "Sẵn sàng (SideStore + Local OTA)"
        }
        if hasLiveContainerInstalled {
            return "Sẵn sàng (LiveContainer + Local OTA)"
        }
        return "Sẵn sàng (Local OTA & Chia sẻ Tệp)"
    }

    public var hasSideStoreInstalled: Bool {
        guard let url = URL(string: "sidestore://") else { return false }
        return UIApplication.shared.canOpenURL(url)
    }

    public var hasLiveContainerInstalled: Bool {
        guard let url = URL(string: "livecontainer://") else { return false }
        return UIApplication.shared.canOpenURL(url)
    }

    public func triggerInstallation(
        signedIPAURL: URL,
        package: IPAPackageItem,
        certificate: CertificateRecord?
    ) async throws -> String {
        // 1. Kiểm tra lại toàn vẹn gói IPA đã ký trước khi giao cho hệ điều hành
        let parser = NativeIPAParser()
        let verifiedMeta = try await parser.parsePackage(at: signedIPAURL)

        if verifiedMeta.isFairPlayEncrypted {
            throw NSError(
                domain: "NativeInstallationManager",
                code: -40,
                userInfo: [NSLocalizedDescriptionKey: "Chặn cài đặt: Gói IPA đang bị khóa mã hóa DRM FairPlay App Store."]
            )
        }

        if let cert = certificate, cert.lastOCSPStatus == .revoked {
            throw NSError(
                domain: "NativeInstallationManager",
                code: -41,
                userInfo: [NSLocalizedDescriptionKey: "Chặn cài đặt: Chứng chỉ ký đã bị Apple thu hồi (Revoked)."]
            )
        }

        guard let prov = verifiedMeta.provisioning else {
            throw NSError(
                domain: "NativeInstallationManager",
                code: -42,
                userInfo: [NSLocalizedDescriptionKey: "Gói IPA chưa có embedded.mobileprovision hợp lệ để cài đặt."]
            )
        }

        if prov.isExpired {
            throw NSError(
                domain: "NativeInstallationManager",
                code: -43,
                userInfo: [NSLocalizedDescriptionKey: "Provisioning Profile bên trong gói IPA đã hết hạn."]
            )
        }

        // Luôn xuất kèm bản sao sang thư mục Documents/SignedIPAs để ứng dụng Tệp (Files) & USB AFC truy cập được ngay
        exportCopyToSharedDocuments(signedIPAURL: signedIPAURL)

        let port = try LocalOTAServer.shared.startServing(
            ipaURL: signedIPAURL,
            bundleId: verifiedMeta.bundleId,
            version: verifiedMeta.version,
            title: verifiedMeta.displayName,
            preferredPort: portProvider()
        )
        let localFileURL = "http://127.0.0.1:\(port)/app.ipa"

        // 2. Định tuyến theo đúng quyền thực tế của Provisioning Profile
        if !prov.supportsOTA {
            // Profile loại Development / Apple Personal Team (0 đồng) -> installd chặn itms-services://!
            if hasSideStoreInstalled,
               let encoded = localFileURL.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
               let ssURL = URL(string: "sidestore://install?url=\(encoded)") {
                let opened = await UIApplication.shared.open(ssURL, options: [:])
                if opened {
                    AppLogger.shared.info("Installer", "Đã chuyển gói Development sang SideStore qua loopback cổng \(port).")
                    return "SideStore Loopback (0đ)"
                }
            }

            if hasLiveContainerInstalled,
               let encoded = localFileURL.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
               let lcURL = URL(string: "livecontainer://install?url=\(encoded)") {
                let opened = await UIApplication.shared.open(lcURL, options: [:])
                if opened {
                    AppLogger.shared.info("Installer", "Đã chuyển gói sang LiveContainer qua loopback cổng \(port).")
                    return "LiveContainer Loopback (0đ)"
                }
            }

            throw NSError(
                domain: "NativeInstallationManager",
                code: -44,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "Gói đã được ký hợp lệ bằng chứng chỉ '\(prov.distributionType)' và lưu vào ứng dụng Tệp (IPA Installer > SignedIPAs). Vì tiến trình installd của iOS chặn giao thức itms-services:// đối với profile Development miễn phí, hãy mở bằng SideStore/LiveContainer hoặc cài qua cáp OTG bằng công cụ termux-ipa-pusher!"
                ]
            )
        }

        // 3. Profile Ad-Hoc hoặc Enterprise -> Hỗ trợ giao thức OTA gốc itms-services://
        // Lưu ý: Trên iOS 16–26+, itms-services yêu cầu URL manifest dùng tên miền phân giải về 127.0.0.1 có HTTPS nếu hệ thống ép ATS
        let manifestURL = "https://backloop.dev:\(port)/manifest.plist"
        guard let encodedManifest = manifestURL.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let otaURL = URL(string: "itms-services://?action=download-manifest&url=\(encodedManifest)") else {
            throw NSError(
                domain: "NativeInstallationManager",
                code: -45,
                userInfo: [NSLocalizedDescriptionKey: "Không tạo được liên kết OTA itms-services hợp lệ."]
            )
        }

        let opened = await UIApplication.shared.open(otaURL, options: [:])
        if !opened {
            throw NSError(
                domain: "NativeInstallationManager",
                code: -46,
                userInfo: [NSLocalizedDescriptionKey: "Hệ điều hành từ chối mở giao thức itms-services://."]
            )
        }

        AppLogger.shared.info("Installer", "Đã kích hoạt hộp thoại cài đặt hệ thống itms-services:// (\(prov.distributionType)).")
        return "iOS Native OTA (itms-services)"
    }

    private func exportCopyToSharedDocuments(signedIPAURL: URL) {
        let fm = FileManager.default
        guard let docs = fm.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        let sharedDir = docs.appendingPathComponent("SignedIPAs", isDirectory: true)
        try? fm.createDirectory(at: sharedDir, withIntermediateDirectories: true)
        let dest = sharedDir.appendingPathComponent(signedIPAURL.lastPathComponent)
        try? fm.removeItem(at: dest)
        try? fm.copyItem(at: signedIPAURL, to: dest)
    }
}

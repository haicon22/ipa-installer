import Foundation
import XCTest
@testable import ZSignKit

#if os(macOS)
final class ZSignKitTests: XCTestCase {
    func testAdHocAndPKCS12MachOSigningVerifiedByAppleCodesign() throws {
        let fm = FileManager.default
        let workDir = fm.temporaryDirectory.appendingPathComponent("zsignkit_test_\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: workDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: workDir) }

        // 1. Biên dịch một tệp thực thi Mach-O arm64 thật bằng clang trên macOS
        let cSourceURL = workDir.appendingPathComponent("main.c")
        try "int main(void) { return 0; }\n".write(to: cSourceURL, atomically: true, encoding: .utf8)

        let appDir = workDir
            .appendingPathComponent("Payload", isDirectory: true)
            .appendingPathComponent("MiniTest.app", isDirectory: true)
        let plugDir = appDir
            .appendingPathComponent("PlugIns", isDirectory: true)
            .appendingPathComponent("DummyWidget.appex", isDirectory: true)
        try fm.createDirectory(at: plugDir, withIntermediateDirectories: true)

        let binURL = appDir.appendingPathComponent("MiniTest")
        try runProcess("/usr/bin/clang", ["-arch", "arm64", cSourceURL.path, "-o", binURL.path])

        // Gỡ bỏ chữ ký ad-hoc mặc định của linker Apple để đảm bảo đầu vào chưa ký sạch 100%
        _ = try? runProcess("/usr/bin/codesign", ["--remove-signature", binURL.path])

        let infoPlist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>CFBundleDisplayName</key><string>MiniTest</string>
            <key>CFBundleExecutable</key><string>MiniTest</string>
            <key>CFBundleIdentifier</key><string>vn.ipainstaller.minitest</string>
            <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
            <key>CFBundleName</key><string>MiniTest</string>
            <key>CFBundlePackageType</key><string>APPL</string>
            <key>CFBundleShortVersionString</key><string>1.0.0</string>
            <key>CFBundleVersion</key><string>1</string>
            <key>MinimumOSVersion</key><string>15.0</string>
        </dict>
        </plist>
        """
        try infoPlist.write(to: appDir.appendingPathComponent("Info.plist"), atomically: true, encoding: .utf8)
        try infoPlist.write(to: plugDir.appendingPathComponent("Info.plist"), atomically: true, encoding: .utf8)

        let unsignedIPA = workDir.appendingPathComponent("MiniTest-unsigned.ipa")
        try runProcess("/usr/bin/zip", ["-qry", unsignedIPA.path, "Payload"], currentDirectory: workDir)

        // 2. Tạo chuỗi chứng chỉ chuẩn 2 tầng (Root CA -> Developer Cert) + .p12 + .mobileprovision thật bằng /usr/bin/openssl
        let caKey = workDir.appendingPathComponent("ca.key")
        let caCert = workDir.appendingPathComponent("ca.crt")
        let keyPEM = workDir.appendingPathComponent("dev.key")
        let csrPEM = workDir.appendingPathComponent("dev.csr")
        let certPEM = workDir.appendingPathComponent("dev.crt")
        let certDER = workDir.appendingPathComponent("dev.der")
        let p12URL = workDir.appendingPathComponent("dev.p12")
        let provURL = workDir.appendingPathComponent("dev.mobileprovision")
        let extFile = workDir.appendingPathComponent("v3_ca.cnf")

        try """
        [v3_ca]
        basicConstraints = critical,CA:TRUE
        keyUsage = critical,keyCertSign,cRLSign
        subjectKeyIdentifier = hash
        [v3_leaf]
        basicConstraints = critical,CA:FALSE
        keyUsage = critical,digitalSignature
        extendedKeyUsage = codeSigning
        subjectKeyIdentifier = hash
        authorityKeyIdentifier = keyid,issuer
        """.write(to: extFile, atomically: true, encoding: .utf8)

        try runProcess("/usr/bin/openssl", [
            "req", "-x509", "-newkey", "rsa:2048", "-nodes",
            "-keyout", caKey.path,
            "-out", caCert.path,
            "-days", "30",
            "-subj", "/CN=CI Test Root CA/O=Test",
            "-config", extFile.path,
            "-extensions", "v3_ca"
        ])
        try runProcess("/usr/bin/openssl", [
            "req", "-newkey", "rsa:2048", "-nodes",
            "-keyout", keyPEM.path,
            "-out", csrPEM.path,
            "-subj", "/CN=Apple Development: CI Test (TEAM123456)/OU=TEAM123456/O=Test"
        ])
        try runProcess("/usr/bin/openssl", [
            "x509", "-req",
            "-in", csrPEM.path,
            "-CA", caCert.path,
            "-CAkey", caKey.path,
            "-CAcreateserial",
            "-out", certPEM.path,
            "-days", "7",
            "-extfile", extFile.path,
            "-extensions", "v3_leaf"
        ])
        try runProcess("/usr/bin/openssl", ["x509", "-in", certPEM.path, "-outform", "DER", "-out", certDER.path])
        try runProcess("/usr/bin/openssl", [
            "pkcs12", "-export",
            "-inkey", keyPEM.path,
            "-in", certPEM.path,
            "-certfile", caCert.path,
            "-out", p12URL.path,
            "-passout", "pass:testpass123"
        ])

        let derB64 = try Data(contentsOf: certDER).base64EncodedString()
        let provXML = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>AppIDName</key><string>MiniTest</string>
            <key>ApplicationIdentifierPrefix</key><array><string>TEAM123456</string></array>
            <key>CreationDate</key><date>2026-11-24T00:00:00Z</date>
            <key>ExpirationDate</key><date>2026-12-01T00:00:00Z</date>
            <key>Name</key><string>CI Test Profile</string>
            <key>TeamIdentifier</key><array><string>TEAM123456</string></array>
            <key>TeamName</key><string>CI Personal Team</string>
            <key>TimeToLive</key><integer>7</integer>
            <key>UUID</key><string>11111111-2222-3333-4444-555555555555</string>
            <key>DeveloperCertificates</key><array><data>\(derB64)</data></array>
            <key>Entitlements</key>
            <dict>
                <key>application-identifier</key><string>TEAM123456.vn.ipainstaller.signed</string>
                <key>com.apple.developer.team-identifier</key><string>TEAM123456</string>
                <key>get-task-allow</key><true/>
            </dict>
        </dict>
        </plist>
        """
        let provRawURL = workDir.appendingPathComponent("prov.plist")
        try provXML.write(to: provRawURL, atomically: true, encoding: .utf8)
        // Bọc prov.plist vào CMS SignedData chuẩn giống hệt embedded.mobileprovision thật
        try runProcess("/usr/bin/openssl", [
            "cms", "-sign", "-binary", "-nodetach",
            "-in", provRawURL.path,
            "-signer", certPEM.path,
            "-inkey", keyPEM.path,
            "-outform", "DER",
            "-out", provURL.path
        ])

        // 3A. Kiểm thử ký Ad-Hoc và xác minh toàn vẹn bảng băm SHA-256 bằng /usr/bin/codesign --verify --strict của Apple
        let adhocIPA = workDir.appendingPathComponent("MiniTest-adhoc.ipa")
        let tempZSignDir = workDir.appendingPathComponent("zsign_tmp", isDirectory: true)
        try fm.createDirectory(at: tempZSignDir, withIntermediateDirectories: true)

        try ZSignWrapper.signIPA(
            ZSignRequest(
                inputIPAPath: unsignedIPA.path,
                outputIPAPath: adhocIPA.path,
                customBundleId: "vn.ipainstaller.adhoc",
                tempDirectoryPath: tempZSignDir.path,
                adhocSign: true,
                removeExtensions: true,
                enableDocuments: true,
                zipLevel: 6
            )
        )
        let adhocExtractDir = workDir.appendingPathComponent("verify_adhoc", isDirectory: true)
        try fm.createDirectory(at: adhocExtractDir, withIntermediateDirectories: true)
        try runProcess("/usr/bin/unzip", ["-q", adhocIPA.path, "-d", adhocExtractDir.path])
        let adhocAppDir = adhocExtractDir.appendingPathComponent("Payload/MiniTest.app")
        try runProcess("/usr/bin/codesign", ["--verify", "--deep", "--strict", adhocAppDir.path])

        // 3B. Kiểm thử ký đầy đủ PKCS#12 + CMS .mobileprovision (đổi Bundle ID + gỡ PlugIns .appex!)
        let signedIPA = workDir.appendingPathComponent("MiniTest-signed.ipa")

        try ZSignWrapper.signIPA(
            ZSignRequest(
                inputIPAPath: unsignedIPA.path,
                outputIPAPath: signedIPA.path,
                p12Path: p12URL.path,
                p12Password: "testpass123",
                mobileProvisionPath: provURL.path,
                customBundleId: "vn.ipainstaller.signed",
                customDisplayName: "Đã Ký Thật",
                tempDirectoryPath: tempZSignDir.path,
                adhocSign: false,
                removeExtensions: true,
                enableDocuments: true,
                zipLevel: 6
            )
        )

        XCTAssertTrue(fm.fileExists(atPath: signedIPA.path), "Phải xuất ra tệp IPA đã ký thật")

        // 4. Giải nén ngược lại gói IPA đã ký chứng chỉ và dùng /usr/bin/codesign -d -vvv của macOS kiểm chứng!
        let verifyExtractDir = workDir.appendingPathComponent("verify_out", isDirectory: true)
        try fm.createDirectory(at: verifyExtractDir, withIntermediateDirectories: true)
        try runProcess("/usr/bin/unzip", ["-q", signedIPA.path, "-d", verifyExtractDir.path])

        let signedAppDir = verifyExtractDir.appendingPathComponent("Payload/MiniTest.app")
        let signedBin = signedAppDir.appendingPathComponent("MiniTest")

        // Kiểm chứng PlugIns/DummyWidget.appex đã được gỡ sạch
        XCTAssertFalse(
            fm.fileExists(atPath: signedAppDir.appendingPathComponent("PlugIns/DummyWidget.appex").path),
            "Thư mục PlugIns phụ phải được gỡ bỏ khi bật stripAppExtensions"
        )

        // Kiểm chứng bằng hàm tự xác minh nhị phân của ZSignWrapper (yêu cầu có cả CMS PKCS#7 blob!)
        try ZSignWrapper.verifyMachOSignature(at: signedBin.path, requireCMSBlob: true)

        // Đọc thông tin chữ ký CMS & TeamIdentifier bằng chính /usr/bin/codesign -d -vvv của Apple!
        let codesignDetails = try runProcess("/usr/bin/codesign", ["-d", "-vvv", signedAppDir.path])
        XCTAssertTrue(codesignDetails.contains("Identifier=vn.ipainstaller.signed"), "Bundle ID trong CodeDirectory phải khớp")
        XCTAssertTrue(codesignDetails.contains("TeamIdentifier=TEAM123456"), "TeamIdentifier phải được nhúng chuẩn xác")
        XCTAssertTrue(codesignDetails.contains("Authority=Apple Development: CI Test (TEAM123456)"), "Chuỗi chứng chỉ CMS phải hợp lệ")
    }

    @discardableResult
    private func runProcess(_ launchPath: String, _ args: [String], currentDirectory: URL? = nil) throws -> String {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: launchPath)
        proc.arguments = args
        if let cwd = currentDirectory {
            proc.currentDirectoryURL = cwd
        }
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe
        try proc.run()
        proc.waitUntilExit()
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        if proc.terminationStatus != 0 {
            XCTFail("Command failed (\(launchPath) \(args.joined(separator: " "))): \(out)")
            throw NSError(domain: "ZSignKitTests", code: Int(proc.terminationStatus), userInfo: [NSLocalizedDescriptionKey: out])
        }
        return out
    }
}
#endif

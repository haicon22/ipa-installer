import Foundation

/// Bộ phân tích nhị phân Mach-O & LC_CODE_SIGNATURE an toàn căn chỉnh bộ nhớ (alignment-safe) trên arm64
public enum MachOInspector {
    public struct InspectionResult {
        public let isFat: Bool
        public let architectures: [String]
        public let minOSVersion: String?
        public let sdkVersion: String?
        public let isFairPlayEncrypted: Bool
        public let linkedDylibs: [String]
        public let codeSignatureOffset: Int?
        public let codeSignatureSize: Int?
    }

    public struct CodeSignatureSummary {
        public let signingIdentifier: String?
        public let teamIdentifier: String?
        public let isAdHocSigned: Bool
        public let hasCMSBlob: Bool
        public let entitlements: [String: String]
    }

    private static func readU32BE(_ data: Data, _ offset: Int) -> UInt32 {
        guard offset >= 0, offset + 4 <= data.count else { return 0 }
        let b0 = UInt32(data[data.startIndex + offset])
        let b1 = UInt32(data[data.startIndex + offset + 1])
        let b2 = UInt32(data[data.startIndex + offset + 2])
        let b3 = UInt32(data[data.startIndex + offset + 3])
        return (b0 << 24) | (b1 << 16) | (b2 << 8) | b3
    }

    private static func readU32LE(_ data: Data, _ offset: Int) -> UInt32 {
        guard offset >= 0, offset + 4 <= data.count else { return 0 }
        let b0 = UInt32(data[data.startIndex + offset])
        let b1 = UInt32(data[data.startIndex + offset + 1])
        let b2 = UInt32(data[data.startIndex + offset + 2])
        let b3 = UInt32(data[data.startIndex + offset + 3])
        return b0 | (b1 << 8) | (b2 << 16) | (b3 << 24)
    }

    private static func readU32(_ data: Data, _ offset: Int, littleEndian: Bool) -> UInt32 {
        littleEndian ? readU32LE(data, offset) : readU32BE(data, offset)
    }

    private static func formatPackedVersion(_ raw: UInt32) -> String {
        let major = (raw >> 16) & 0xFFFF
        let minor = (raw >> 8) & 0xFF
        let patch = raw & 0xFF
        return patch > 0 ? "\(major).\(minor).\(patch)" : "\(major).\(minor)"
    }

    private static func archName(cpuType: UInt32, cpuSubtype: UInt32) -> String {
        let sub = cpuSubtype & 0x00FFFFFF
        if cpuType == 0x0100000C {
            return sub == 2 ? "arm64e" : "arm64"
        }
        if cpuType == 12 {
            if sub == 9 { return "armv7" }
            if sub == 11 { return "armv7s" }
            return "arm"
        }
        if cpuType == 0x01000007 { return "x86_64" }
        if cpuType == 7 { return "i386" }
        return String(format: "cpu_0x%X", cpuType)
    }

    private static func readCString(_ data: Data, from start: Int, limit: Int) -> String {
        let safeEnd = min(data.count, limit)
        guard start >= 0, start < safeEnd else { return "" }
        var bytes: [UInt8] = []
        var idx = start
        while idx < safeEnd {
            let b = data[data.startIndex + idx]
            if b == 0 { break }
            bytes.append(b)
            idx += 1
        }
        return String(bytes: bytes, encoding: .utf8) ?? ""
    }

    public static func inspectHeader(_ data: Data) -> InspectionResult? {
        guard data.count >= 32 else { return nil }
        let magicBE = readU32BE(data, 0)

        // FAT_MAGIC (0xcafebabe) hoặc FAT_MAGIC_64 (0xcafebabf)
        if magicBE == 0xCAFEBABE || magicBE == 0xCAFEBABF {
            let isFat64 = (magicBE == 0xCAFEBABF)
            let nfat = Int(readU32BE(data, 4))
            guard nfat >= 1, nfat <= 16 else { return nil }

            var archs: [String] = []
            var selectedSliceOffset: Int?
            var p = 8
            let stride = isFat64 ? 32 : 20

            for _ in 0..<nfat {
                guard p + stride <= data.count else { break }
                let ctype = readU32BE(data, p)
                let csub = readU32BE(data, p + 4)
                let name = archName(cpuType: ctype, cpuSubtype: csub)
                archs.append(name)

                let offset: Int
                if isFat64 {
                    let hi = UInt64(readU32BE(data, p + 8))
                    let lo = UInt64(readU32BE(data, p + 12))
                    offset = Int((hi << 32) | lo)
                } else {
                    offset = Int(readU32BE(data, p + 8))
                }

                if selectedSliceOffset == nil || name == "arm64" || name == "arm64e" {
                    selectedSliceOffset = offset
                }
                p += stride
            }

            if let sliceOff = selectedSliceOffset,
               sliceOff + 32 <= data.count,
               let parsed = parseThinSlice(data, sliceOffset: sliceOff) {
                return InspectionResult(
                    isFat: true,
                    architectures: archs,
                    minOSVersion: parsed.minOSVersion,
                    sdkVersion: parsed.sdkVersion,
                    isFairPlayEncrypted: parsed.isFairPlayEncrypted,
                    linkedDylibs: parsed.linkedDylibs,
                    codeSignatureOffset: parsed.codeSignatureOffset,
                    codeSignatureSize: parsed.codeSignatureSize
                )
            }

            return InspectionResult(
                isFat: true,
                architectures: archs,
                minOSVersion: nil,
                sdkVersion: nil,
                isFairPlayEncrypted: false,
                linkedDylibs: [],
                codeSignatureOffset: nil,
                codeSignatureSize: nil
            )
        }

        return parseThinSlice(data, sliceOffset: 0)
    }

    private static func parseThinSlice(_ data: Data, sliceOffset: Int) -> InspectionResult? {
        guard sliceOffset + 32 <= data.count else { return nil }
        let magicBE = readU32BE(data, sliceOffset)

        let is64: Bool
        let le: Bool
        switch magicBE {
        case 0xCFFAEDFE: is64 = true; le = true
        case 0xFEEDFACF: is64 = true; le = false
        case 0xCEFAEDFE: is64 = false; le = true
        case 0xFEEDFACE: is64 = false; le = false
        default: return nil
        }

        let cpuType = readU32(data, sliceOffset + 4, littleEndian: le)
        let cpuSub = readU32(data, sliceOffset + 8, littleEndian: le)
        let ncmds = Int(readU32(data, sliceOffset + 16, littleEndian: le))
        let sizeofcmds = Int(readU32(data, sliceOffset + 20, littleEndian: le))

        let arch = archName(cpuType: cpuType, cpuSubtype: cpuSub)
        let headerSize = is64 ? 32 : 28
        var cmdPos = sliceOffset + headerSize
        let cmdLimit = min(data.count, cmdPos + sizeofcmds)

        var minOS: String?
        var sdkVer: String?
        var encrypted = false
        var dylibs: [String] = []
        var csFileOffset: Int?
        var csSize: Int?

        for _ in 0..<ncmds {
            guard cmdPos + 8 <= cmdLimit else { break }
            let cmd = readU32(data, cmdPos, littleEndian: le)
            let cmdsize = Int(readU32(data, cmdPos + 4, littleEndian: le))
            guard cmdsize >= 8, cmdPos + cmdsize <= cmdLimit else { break }

            if cmd == 0x32, cmdsize >= 24 { // LC_BUILD_VERSION
                minOS = formatPackedVersion(readU32(data, cmdPos + 12, littleEndian: le))
                sdkVer = formatPackedVersion(readU32(data, cmdPos + 16, littleEndian: le))
            } else if cmd == 0x25, cmdsize >= 16 { // LC_VERSION_MIN_IPHONEOS
                if minOS == nil {
                    minOS = formatPackedVersion(readU32(data, cmdPos + 8, littleEndian: le))
                }
                if sdkVer == nil {
                    sdkVer = formatPackedVersion(readU32(data, cmdPos + 12, littleEndian: le))
                }
            } else if (cmd == 0x21 || cmd == 0x2C), cmdsize >= 20 { // LC_ENCRYPTION_INFO(_64)
                let cryptId = readU32(data, cmdPos + 16, littleEndian: le)
                if cryptId != 0 {
                    encrypted = true
                }
            } else if cmd == 0x0C || cmd == 0x80000018 { // LC_LOAD_DYLIB / WEAK
                let strOff = Int(readU32(data, cmdPos + 8, littleEndian: le))
                if strOff < cmdsize {
                    let path = readCString(data, from: cmdPos + strOff, limit: cmdPos + cmdsize)
                    if !path.isEmpty { dylibs.append(path) }
                }
            } else if cmd == 0x1D, cmdsize >= 16 { // LC_CODE_SIGNATURE
                let relOff = Int(readU32(data, cmdPos + 8, littleEndian: le))
                let size = Int(readU32(data, cmdPos + 12, littleEndian: le))
                if size > 0 {
                    csFileOffset = sliceOffset + relOff
                    csSize = size
                }
            }

            cmdPos += cmdsize
        }

        return InspectionResult(
            isFat: false,
            architectures: [arch],
            minOSVersion: minOS,
            sdkVersion: sdkVer,
            isFairPlayEncrypted: encrypted,
            linkedDylibs: dylibs,
            codeSignatureOffset: csFileOffset,
            codeSignatureSize: csSize
        )
    }

    public static func inspectCodeSignature(_ sigData: Data) -> CodeSignatureSummary? {
        guard sigData.count >= 12 else { return nil }
        guard readU32BE(sigData, 0) == 0xFADE0CC0 else { return nil } // CSMAGIC_EMBEDDED_SIGNATURE

        let count = Int(readU32BE(sigData, 8))
        var signingId: String?
        var teamId: String?
        var isAdHoc = false
        var hasCMS = false
        var entDict: [String: String] = [:]

        for i in 0..<count {
            let idxPos = 12 + i * 8
            guard idxPos + 8 <= sigData.count else { break }
            let slotType = readU32BE(sigData, idxPos)
            let blobOff = Int(readU32BE(sigData, idxPos + 4))
            guard blobOff + 8 <= sigData.count else { continue }

            let bMagic = readU32BE(sigData, blobOff)
            let bLen = Int(readU32BE(sigData, blobOff + 4))
            let bEnd = min(sigData.count, blobOff + bLen)

            if bMagic == 0xFADE0C02, blobOff + 44 <= bEnd { // CSMAGIC_CODEDIRECTORY
                let version = readU32BE(sigData, blobOff + 8)
                let flags = readU32BE(sigData, blobOff + 12)
                let identOff = Int(readU32BE(sigData, blobOff + 20))
                isAdHoc = (flags & 0x0002) != 0
                if identOff > 0, blobOff + identOff < bEnd {
                    signingId = readCString(sigData, from: blobOff + identOff, limit: bEnd)
                }
                if version >= 0x20200, blobOff + 52 <= bEnd {
                    let teamOff = Int(readU32BE(sigData, blobOff + 48))
                    if teamOff > 0, blobOff + teamOff < bEnd {
                        teamId = readCString(sigData, from: blobOff + teamOff, limit: bEnd)
                    }
                }
            } else if bMagic == 0xFADE7171, blobOff + 8 < bEnd { // CSMAGIC_ENTITLEMENTS
                let xmlSlice = sigData.subdata(in: (sigData.startIndex + blobOff + 8)..<(sigData.startIndex + bEnd))
                if let rawDict = (try? PropertyListSerialization.propertyList(from: xmlSlice, options: [], format: nil)) as? [String: Any] {
                    for (k, v) in rawDict {
                        entDict[k] = String(describing: v)
                    }
                }
            } else if bMagic == 0xFADE0B01 || slotType == 0x10000 { // CMS BlobWrapper
                if bLen > 8 {
                    hasCMS = true
                }
            }
        }

        return CodeSignatureSummary(
            signingIdentifier: signingId,
            teamIdentifier: teamId,
            isAdHocSigned: isAdHoc,
            hasCMSBlob: hasCMS,
            entitlements: entDict
        )
    }
}

/**
 * Bộ phân tích nhị phân Mach-O & Embedded Code Signature (SuperBlob)
 * Hỗ trợ:
 * - Fat/Universal Binary (FAT_MAGIC / FAT_MAGIC_64) & Thin Mach-O (32/64-bit)
 * - Nhận diện CPU (arm64, arm64e PAC, x86_64, armv7/armv7s)
 * - Phát hiện khóa DRM FairPlay App Store (LC_ENCRYPTION_INFO / LC_ENCRYPTION_INFO_64)
 * - Đọc LC_BUILD_VERSION / LC_VERSION_MIN_IPHONEOS, LC_UUID, LC_LOAD_DYLIB, LC_RPATH
 * - Giải mã LC_CODE_SIGNATURE (CodeDirectory, Ad-Hoc flag, Embedded Entitlements XML, CMS)
 */
import { parsePlist } from './plist.js';

const FAT_MAGIC = 0xcafebabe;
const FAT_MAGIC_64 = 0xcafebabf;
const MH_MAGIC_64 = 0xfeedfacf;
const MH_CIGAM_64 = 0xcffaedfe;
const MH_MAGIC = 0xfeedface;
const MH_CIGAM = 0xcefaedfe;

const LC_REQ_DYLD = 0x80000000;
const LC_LOAD_DYLIB = 0x0c;
const LC_LOAD_WEAK_DYLIB = (0x18 | LC_REQ_DYLD) >>> 0;
const LC_REEXPORT_DYLIB = (0x1f | LC_REQ_DYLD) >>> 0;
const LC_UUID = 0x1b;
const LC_RPATH = (0x1c | LC_REQ_DYLD) >>> 0;
const LC_CODE_SIGNATURE = 0x1d;
const LC_ENCRYPTION_INFO = 0x21;
const LC_VERSION_MIN_IPHONEOS = 0x25;
const LC_ENCRYPTION_INFO_64 = 0x2c;
const LC_BUILD_VERSION = 0x32;

const CSMAGIC_EMBEDDED_SIGNATURE = 0xfade0cc0;
const CSMAGIC_CODEDIRECTORY = 0xfade0c02;
const CSMAGIC_ENTITLEMENTS = 0xfade7171;
const CSMAGIC_DER_ENTITLEMENTS = 0xfade7172;
const CSMAGIC_BLOBWRAPPER = 0xfade0b01;

const utf8Decoder = new TextDecoder('utf-8', { fatal: false });

function formatPackedVersion(v) {
  const major = (v >>> 16) & 0xffff;
  const minor = (v >>> 8) & 0xff;
  const patch = v & 0xff;
  return patch > 0 ? `${major}.${minor}.${patch}` : `${major}.${minor}`;
}

function cpuArchName(cpuType, cpuSubtype) {
  const sub = cpuSubtype & 0x00ffffff;
  if (cpuType === 0x0100000c) {
    if (sub === 2) return 'arm64e';
    return 'arm64';
  }
  if (cpuType === 12) {
    if (sub === 9) return 'armv7';
    if (sub === 11) return 'armv7s';
    return `arm (${sub})`;
  }
  if (cpuType === 0x01000007) return 'x86_64';
  if (cpuType === 7) return 'i386';
  return `cpu_${cpuType.toString(16)}`;
}

function platformName(platformId) {
  switch (platformId) {
    case 1: return 'macOS';
    case 2: return 'iOS';
    case 3: return 'tvOS';
    case 4: return 'watchOS';
    case 6: return 'Mac Catalyst';
    case 7: return 'iOS Simulator';
    case 11: return 'visionOS';
    default: return `Platform(${platformId})`;
  }
}

function readCString(bytes, start, end) {
  let p = start;
  while (p < end && bytes[p] !== 0) p++;
  return utf8Decoder.decode(bytes.subarray(start, p));
}

function parseSingleSlice(bytes, sliceOffset = 0, sliceSize = bytes.length) {
  if (sliceOffset + 32 > bytes.length) {
    return null;
  }
  const dv = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  const magicBE = dv.getUint32(sliceOffset, false);

  let is64 = false;
  let littleEndian = true;
  if (magicBE === MH_CIGAM_64) {
    is64 = true;
    littleEndian = true;
  } else if (magicBE === MH_MAGIC_64) {
    is64 = true;
    littleEndian = false;
  } else if (magicBE === MH_CIGAM) {
    is64 = false;
    littleEndian = true;
  } else if (magicBE === MH_MAGIC) {
    is64 = false;
    littleEndian = false;
  } else {
    return null;
  }

  const cpuType = dv.getUint32(sliceOffset + 4, littleEndian);
  const cpuSubtype = dv.getUint32(sliceOffset + 8, littleEndian);
  const fileType = dv.getUint32(sliceOffset + 12, littleEndian);
  const ncmds = dv.getUint32(sliceOffset + 16, littleEndian);
  const sizeofcmds = dv.getUint32(sliceOffset + 20, littleEndian);
  const flags = dv.getUint32(sliceOffset + 24, littleEndian);

  const headerSize = is64 ? 32 : 28;
  const arch = cpuArchName(cpuType, cpuSubtype);

  let uuid = null;
  let minOS = null;
  let sdkVersion = null;
  let platform = 'iOS';
  let isEncrypted = false;
  let cryptId = 0;
  let codeSigOffsetInSlice = 0;
  let codeSigSize = 0;
  const dylibs = [];
  const rpaths = [];

  let cmdPos = sliceOffset + headerSize;
  const cmdLimit = Math.min(bytes.length, cmdPos + sizeofcmds);

  for (let i = 0; i < ncmds && cmdPos + 8 <= cmdLimit; i++) {
    const cmd = dv.getUint32(cmdPos, littleEndian);
    const cmdsize = dv.getUint32(cmdPos + 4, littleEndian);
    if (cmdsize < 8 || cmdPos + cmdsize > cmdLimit) break;

    if (cmd === LC_UUID && cmdsize >= 24) {
      const hex = [];
      for (let b = 0; b < 16; b++) {
        hex.push(bytes[cmdPos + 8 + b].toString(16).padStart(2, '0'));
      }
      uuid = `${hex.slice(0, 4).join('')}-${hex.slice(4, 6).join('')}-${hex.slice(6, 8).join('')}-${hex.slice(8, 10).join('')}-${hex.slice(10, 16).join('')}`.toUpperCase();
    } else if (cmd === LC_BUILD_VERSION && cmdsize >= 24) {
      const plat = dv.getUint32(cmdPos + 8, littleEndian);
      const minosRaw = dv.getUint32(cmdPos + 12, littleEndian);
      const sdkRaw = dv.getUint32(cmdPos + 16, littleEndian);
      platform = platformName(plat);
      minOS = formatPackedVersion(minosRaw);
      sdkVersion = formatPackedVersion(sdkRaw);
    } else if (cmd === LC_VERSION_MIN_IPHONEOS && cmdsize >= 16) {
      const verRaw = dv.getUint32(cmdPos + 8, littleEndian);
      const sdkRaw = dv.getUint32(cmdPos + 12, littleEndian);
      if (!minOS) minOS = formatPackedVersion(verRaw);
      if (!sdkVersion) sdkVersion = formatPackedVersion(sdkRaw);
    } else if ((cmd === LC_ENCRYPTION_INFO || cmd === LC_ENCRYPTION_INFO_64) && cmdsize >= 20) {
      cryptId = dv.getUint32(cmdPos + 16, littleEndian);
      if (cryptId !== 0) isEncrypted = true;
    } else if (
      cmd === LC_LOAD_DYLIB ||
      cmd === LC_LOAD_WEAK_DYLIB ||
      cmd === LC_REEXPORT_DYLIB
    ) {
      const strOffset = dv.getUint32(cmdPos + 8, littleEndian);
      if (strOffset < cmdsize) {
        const path = readCString(bytes, cmdPos + strOffset, cmdPos + cmdsize);
        if (path) dylibs.push({ path, weak: cmd === LC_LOAD_WEAK_DYLIB });
      }
    } else if (cmd === LC_RPATH) {
      const strOffset = dv.getUint32(cmdPos + 8, littleEndian);
      if (strOffset < cmdsize) {
        const rpath = readCString(bytes, cmdPos + strOffset, cmdPos + cmdsize);
        if (rpath) rpaths.push(rpath);
      }
    } else if (cmd === LC_CODE_SIGNATURE && cmdsize >= 16) {
      codeSigOffsetInSlice = dv.getUint32(cmdPos + 8, littleEndian);
      codeSigSize = dv.getUint32(cmdPos + 12, littleEndian);
    }

    cmdPos += cmdsize;
  }

  return {
    arch,
    is64Bit: is64,
    fileType,
    flags,
    isPIE: (flags & 0x200000) !== 0,
    uuid,
    platform,
    minOS,
    sdkVersion,
    isEncrypted,
    cryptId,
    dylibs,
    rpaths,
    sliceOffset,
    sliceSize,
    codeSignature: codeSigSize > 0
      ? {
          fileOffset: sliceOffset + codeSigOffsetInSlice,
          offsetInSlice: codeSigOffsetInSlice,
          size: codeSigSize
        }
      : null
  };
}

/**
 * Phân tích header tệp thực thi Mach-O (chỉ cần truyền 128KB đầu tiên của tệp thực thi!).
 * @param {Uint8Array} headerBytes
 * @param {number} [fullFileSize]
 */
export function parseMachOHeader(headerBytes, fullFileSize = headerBytes.length) {
  if (!headerBytes || headerBytes.length < 32) {
    throw new Error('Tệp thực thi quá nhỏ để là nhị phân Mach-O');
  }
  const dv = new DataView(headerBytes.buffer, headerBytes.byteOffset, headerBytes.byteLength);
  const magicBE = dv.getUint32(0, false);

  if (magicBE === FAT_MAGIC || magicBE === FAT_MAGIC_64) {
    const nfat = dv.getUint32(4, false);
    if (nfat < 1 || nfat > 16) {
      throw new Error(`Số lượng kiến trúc Fat Mach-O bất thường: ${nfat}`);
    }
    const archDescriptors = [];
    let p = 8;
    const isFat64 = magicBE === FAT_MAGIC_64;
    for (let i = 0; i < nfat; i++) {
      if (p + (isFat64 ? 32 : 20) > headerBytes.length) break;
      const cpuType = dv.getUint32(p, false);
      const cpuSubtype = dv.getUint32(p + 4, false);
      const offset = isFat64
        ? dv.getUint32(p + 8, false) * 4294967296 + dv.getUint32(p + 12, false)
        : dv.getUint32(p + 8, false);
      const size = isFat64
        ? dv.getUint32(p + 16, false) * 4294967296 + dv.getUint32(p + 20, false)
        : dv.getUint32(p + 12, false);
      archDescriptors.push({
        arch: cpuArchName(cpuType, cpuSubtype),
        cpuType,
        cpuSubtype,
        offset,
        size
      });
      p += isFat64 ? 32 : 20;
    }

    // Phân tích chi tiết các lát cắt nằm trong vùng đệm đã đọc
    const parsedSlices = [];
    for (const desc of archDescriptors) {
      if (desc.offset + 64 <= headerBytes.length) {
        const s = parseSingleSlice(headerBytes, desc.offset, desc.size);
        if (s) parsedSlices.push(s);
      }
    }

    return {
      isFat: true,
      architectures: archDescriptors.map((d) => d.arch),
      archDescriptors,
      slices: parsedSlices
    };
  }

  const single = parseSingleSlice(headerBytes, 0, fullFileSize);
  if (!single) {
    throw new Error('Tệp thực thi không có chữ ký Mach-O hợp lệ');
  }
  return {
    isFat: false,
    architectures: [single.arch],
    archDescriptors: [{ arch: single.arch, offset: 0, size: fullFileSize }],
    slices: [single]
  };
}

/**
 * Giải mã vùng nhị phân LC_CODE_SIGNATURE (Embedded Signature SuperBlob).
 * @param {Uint8Array} sigBytes
 */
export function parseCodeSignatureBlob(sigBytes) {
  if (!sigBytes || sigBytes.length < 12) return null;
  const dv = new DataView(sigBytes.buffer, sigBytes.byteOffset, sigBytes.byteLength);
  const magic = dv.getUint32(0, false);
  if (magic !== CSMAGIC_EMBEDDED_SIGNATURE) {
    return null;
  }

  const totalLen = dv.getUint32(4, false);
  const blobCount = dv.getUint32(8, false);
  const result = {
    totalLength: totalLen,
    blobCount,
    signingIdentifier: null,
    teamIdentifier: null,
    flags: 0,
    isAdHocSigned: false,
    hashType: null,
    codeDirectoryVersion: null,
    hasCMSBlob: false,
    cmsSize: 0,
    hasDEREntitlements: false,
    entitlements: null
  };

  for (let i = 0; i < blobCount; i++) {
    const idxPos = 12 + i * 8;
    if (idxPos + 8 > sigBytes.length) break;
    const slotType = dv.getUint32(idxPos, false);
    const blobOffset = dv.getUint32(idxPos + 4, false);
    if (blobOffset + 8 > sigBytes.length) continue;

    const blobMagic = dv.getUint32(blobOffset, false);
    const blobLen = dv.getUint32(blobOffset + 4, false);
    const blobEnd = Math.min(sigBytes.length, blobOffset + blobLen);

    if (blobMagic === CSMAGIC_CODEDIRECTORY && blobOffset + 44 <= blobEnd) {
      const version = dv.getUint32(blobOffset + 8, false);
      const cdFlags = dv.getUint32(blobOffset + 12, false);
      const identOffset = dv.getUint32(blobOffset + 20, false);
      const hashTypeByte = sigBytes[blobOffset + 36];

      result.codeDirectoryVersion = `0x${version.toString(16)}`;
      result.flags = cdFlags;
      result.isAdHocSigned = (cdFlags & 0x0002) !== 0;
      result.hashType = hashTypeByte === 2
        ? 'SHA-256'
        : hashTypeByte === 1
          ? 'SHA-1'
          : `Hash(${hashTypeByte})`;

      if (identOffset > 0 && blobOffset + identOffset < blobEnd) {
        result.signingIdentifier = readCString(sigBytes, blobOffset + identOffset, blobEnd);
      }
      if (version >= 0x20200 && blobOffset + 52 <= blobEnd) {
        const teamOffset = dv.getUint32(blobOffset + 48, false);
        if (teamOffset > 0 && blobOffset + teamOffset < blobEnd) {
          result.teamIdentifier = readCString(sigBytes, blobOffset + teamOffset, blobEnd);
        }
      }
    } else if (blobMagic === CSMAGIC_ENTITLEMENTS && blobOffset + 8 < blobEnd) {
      try {
        const xmlBytes = sigBytes.subarray(blobOffset + 8, blobEnd);
        const parsed = parsePlist(xmlBytes);
        result.entitlements = parsed.data;
      } catch {
        // Bỏ qua nếu khối entitlements trống/hỏng
      }
    } else if (blobMagic === CSMAGIC_DER_ENTITLEMENTS) {
      result.hasDEREntitlements = true;
    } else if (blobMagic === CSMAGIC_BLOBWRAPPER || slotType === 0x10000) {
      const cmsPayloadLen = Math.max(0, blobLen - 8);
      result.cmsSize = cmsPayloadLen;
      result.hasCMSBlob = cmsPayloadLen > 0;
    }
  }

  return result;
}

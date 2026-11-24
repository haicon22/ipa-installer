/**
 * Bộ đọc ngẫu nhiên ZIP & ZIP64 theo lát cắt (Blob.slice Random-Access Reader)
 * Không bao giờ nạp toàn bộ file .ipa vào RAM — phân tích IPA nhiều GB chỉ tốn vài MB RAM.
 */
import { inflateRaw, crc32 } from './deflate.js';

const EOCD_SIG = 0x06054b50;
const ZIP64_EOCD_LOCATOR_SIG = 0x07064b50;
const ZIP64_EOCD_SIG = 0x06064b50;
const CEN_SIG = 0x02014b50;
const LOC_SIG = 0x04034b50;

const utf8Decoder = new TextDecoder('utf-8', { fatal: false });

async function readSlice(blob, start, end) {
  const safeStart = Math.max(0, start);
  const safeEnd = Math.min(blob.size, end);
  if (safeEnd <= safeStart) return new Uint8Array(0);
  const ab = await blob.slice(safeStart, safeEnd).arrayBuffer();
  return new Uint8Array(ab);
}

function readU64LE(dv, offset) {
  const lo = dv.getUint32(offset, true);
  const hi = dv.getUint32(offset + 4, true);
  return hi * 4294967296 + lo;
}

/**
 * Kiểm tra đường dẫn chống tấn công Zip Slip.
 */
export function isUnsafeZipPath(name) {
  if (!name) return true;
  if (name.startsWith('/') || name.startsWith('\\')) return true;
  const parts = name.replace(/\\/g, '/').split('/');
  return parts.some((p) => p === '..');
}

/**
 * Đọc bảng mục lục Central Directory của file .ipa/.zip thông qua Blob.slice.
 * @param {Blob|File} blob
 */
export async function indexZipArchive(blob) {
  const fileSize = blob.size;
  if (fileSize < 22) {
    throw new Error('Tệp không phải định dạng IPA/ZIP hợp lệ (dung lượng quá nhỏ)');
  }

  // Quét tối đa 65557 byte cuối file để tìm End of Central Directory (EOCD)
  const tailSize = Math.min(fileSize, 65557);
  const tailStart = fileSize - tailSize;
  const tail = await readSlice(blob, tailStart, fileSize);
  const tailDv = new DataView(tail.buffer, tail.byteOffset, tail.byteLength);

  let eocdPos = -1;
  for (let i = tail.length - 22; i >= 0; i--) {
    if (tailDv.getUint32(i, true) === EOCD_SIG) {
      const commentLen = tailDv.getUint16(i + 20, true);
      if (i + 22 + commentLen <= tail.length) {
        eocdPos = i;
        break;
      }
    }
  }

  if (eocdPos < 0) {
    throw new Error('Không tìm thấy mục lục ZIP (EOCD). Tệp IPA có thể bị hỏng hoặc tải chưa hoàn tất.');
  }

  let totalEntries = tailDv.getUint16(eocdPos + 10, true);
  let cdSize = tailDv.getUint32(eocdPos + 12, true);
  let cdOffset = tailDv.getUint32(eocdPos + 16, true);
  let isZip64 = false;

  // Hỗ trợ ZIP64 cho các IPA dung lượng > 4GB
  if (
    eocdPos >= 20 &&
    tailDv.getUint32(eocdPos - 20, true) === ZIP64_EOCD_LOCATOR_SIG
  ) {
    const zip64EocdOffset = readU64LE(tailDv, eocdPos - 12);
    const z64Buf = await readSlice(blob, zip64EocdOffset, zip64EocdOffset + 56);
    if (z64Buf.length >= 56) {
      const z64Dv = new DataView(z64Buf.buffer, z64Buf.byteOffset, z64Buf.byteLength);
      if (z64Dv.getUint32(0, true) === ZIP64_EOCD_SIG) {
        isZip64 = true;
        totalEntries = readU64LE(z64Dv, 32);
        cdSize = readU64LE(z64Dv, 40);
        cdOffset = readU64LE(z64Dv, 48);
      }
    }
  }

  if (cdOffset + cdSize > fileSize) {
    throw new Error('Mục lục Central Directory của IPA bị lệch hoặc tệp tải xuống bị thiếu byte.');
  }

  const cdBytes = await readSlice(blob, cdOffset, cdOffset + cdSize);
  const cdDv = new DataView(cdBytes.buffer, cdBytes.byteOffset, cdBytes.byteLength);

  const entries = [];
  let p = 0;
  let unsafePathsSkipped = 0;

  while (p + 46 <= cdBytes.length) {
    const sig = cdDv.getUint32(p, true);
    if (sig !== CEN_SIG) break;

    const flags = cdDv.getUint16(p + 8, true);
    const method = cdDv.getUint16(p + 10, true);
    const crc = cdDv.getUint32(p + 16, true);
    let compSize = cdDv.getUint32(p + 20, true);
    let uncompSize = cdDv.getUint32(p + 24, true);
    const nameLen = cdDv.getUint16(p + 28, true);
    const extraLen = cdDv.getUint16(p + 30, true);
    const commentLen = cdDv.getUint16(p + 32, true);
    const externalAttr = cdDv.getUint32(p + 38, true);
    let localHeaderOffset = cdDv.getUint32(p + 42, true);

    const nameStart = p + 46;
    const extraStart = nameStart + nameLen;
    const nextEntry = extraStart + extraLen + commentLen;
    if (nextEntry > cdBytes.length) break;

    const name = utf8Decoder.decode(cdBytes.subarray(nameStart, extraStart));

    // Giải mã trường mở rộng ZIP64 (Extra ID 0x0001) nếu kích thước vượt 0xffffffff
    if (
      compSize === 0xffffffff ||
      uncompSize === 0xffffffff ||
      localHeaderOffset === 0xffffffff
    ) {
      let ep = extraStart;
      const extraEnd = extraStart + extraLen;
      while (ep + 4 <= extraEnd) {
        const headerId = cdDv.getUint16(ep, true);
        const dataSize = cdDv.getUint16(ep + 2, true);
        ep += 4;
        if (headerId === 0x0001 && ep + dataSize <= extraEnd) {
          let zp = ep;
          if (uncompSize === 0xffffffff && zp + 8 <= ep + dataSize) {
            uncompSize = readU64LE(cdDv, zp);
            zp += 8;
          }
          if (compSize === 0xffffffff && zp + 8 <= ep + dataSize) {
            compSize = readU64LE(cdDv, zp);
            zp += 8;
          }
          if (localHeaderOffset === 0xffffffff && zp + 8 <= ep + dataSize) {
            localHeaderOffset = readU64LE(cdDv, zp);
            zp += 8;
          }
          break;
        }
        ep += dataSize;
      }
    }

    const unixMode = (externalAttr >>> 16) & 0xffff;
    const isSymlink = (unixMode & 0xf000) === 0xa000;
    const isDirectory = name.endsWith('/');

    if (isUnsafeZipPath(name)) {
      unsafePathsSkipped++;
    } else {
      entries.push({
        name,
        flags,
        method,
        crc,
        compressedSize: compSize,
        uncompressedSize: uncompSize,
        localHeaderOffset,
        isDirectory,
        isSymlink
      });
    }

    p = nextEntry;
  }

  return {
    fileSize,
    totalEntriesDeclared: totalEntries,
    entries,
    isZip64,
    unsafePathsSkipped
  };
}

/**
 * Đọc và giải nén một entry cụ thể từ kho ZIP mà không đụng tới phần còn lại của file.
 * @param {Blob|File} blob
 * @param {object} entry Một mục từ indexZipArchive().entries
 * @param {object} [options]
 * @param {number} [options.maxOutputBytes] Giới hạn số byte đầu ra (dùng khi chỉ đọc phần đầu Mach-O)
 * @param {boolean} [options.verifyCrc] Kiểm tra CRC32 khi đọc toàn bộ entry
 */
export async function extractZipEntry(blob, entry, options = {}) {
  const { maxOutputBytes = 0, verifyCrc = false } = options;
  if (entry.isDirectory) return new Uint8Array(0);
  if ((entry.flags & 0x01) !== 0) {
    throw new Error(`Tệp "${entry.name}" trong IPA bị mã hóa mật khẩu ZIP`);
  }

  // Đọc Local File Header (30 bytes + nameLen + extraLen) để tìm vị trí chính xác của payload
  const lhProbe = await readSlice(blob, entry.localHeaderOffset, entry.localHeaderOffset + 30);
  if (lhProbe.length < 30) {
    throw new Error(`Không thể đọc Local Header của "${entry.name}"`);
  }
  const lhDv = new DataView(lhProbe.buffer, lhProbe.byteOffset, lhProbe.byteLength);
  if (lhDv.getUint32(0, true) !== LOC_SIG) {
    throw new Error(`Chữ ký Local Header của "${entry.name}" không hợp lệ`);
  }
  const nameLen = lhDv.getUint16(26, true);
  const extraLen = lhDv.getUint16(28, true);
  const dataOffset = entry.localHeaderOffset + 30 + nameLen + extraLen;

  if (entry.method === 0) {
    // Stored (không nén) — có thể cắt thẳng đúng số byte cần đọc!
    const readLen = maxOutputBytes > 0
      ? Math.min(entry.compressedSize, maxOutputBytes)
      : entry.compressedSize;
    const raw = await readSlice(blob, dataOffset, dataOffset + readLen);
    if (verifyCrc && maxOutputBytes === 0 && entry.crc !== 0) {
      const actualCrc = crc32(raw);
      if (actualCrc !== entry.crc) {
        throw new Error(`Lỗi kiểm tra toàn vẹn CRC32 tại "${entry.name}"`);
      }
    }
    return raw;
  }

  if (entry.method === 8) {
    // Deflate — nếu chỉ cần đọc phần đầu (ví dụ header Mach-O của binary 200MB),
    // chỉ cần cắt một cửa sổ dữ liệu nén đủ lớn thay vì đọc hết 200MB!
    const sliceCompLen = maxOutputBytes > 0
      ? Math.min(entry.compressedSize, Math.max(131072, maxOutputBytes * 2))
      : entry.compressedSize;

    const compBytes = await readSlice(blob, dataOffset, dataOffset + sliceCompLen);
    const out = inflateRaw(compBytes, entry.uncompressedSize, maxOutputBytes);
    if (verifyCrc && maxOutputBytes === 0 && entry.crc !== 0) {
      const actualCrc = crc32(out);
      if (actualCrc !== entry.crc) {
        throw new Error(`Lỗi kiểm tra toàn vẹn CRC32 sau giải nén tại "${entry.name}"`);
      }
    }
    return out;
  }

  throw new Error(`Phương thức nén ZIP (${entry.method}) của "${entry.name}" không được iOS hỗ trợ`);
}

/**
 * Chỉ dùng khi cần đọc một vùng offset cụ thể bên trong một entry đã biết
 * (ví dụ đọc vùng LC_CODE_SIGNATURE nằm ở cuối tệp thực thi Mach-O).
 */
export async function extractEntryRange(blob, entry, rangeOffset, rangeLength) {
  if (rangeLength <= 0) return new Uint8Array(0);
  const lhProbe = await readSlice(blob, entry.localHeaderOffset, entry.localHeaderOffset + 30);
  const lhDv = new DataView(lhProbe.buffer, lhProbe.byteOffset, lhProbe.byteLength);
  const nameLen = lhDv.getUint16(26, true);
  const extraLen = lhDv.getUint16(28, true);
  const dataOffset = entry.localHeaderOffset + 30 + nameLen + extraLen;

  if (entry.method === 0) {
    const start = dataOffset + rangeOffset;
    const end = Math.min(dataOffset + entry.compressedSize, start + rangeLength);
    return readSlice(blob, start, end);
  }

  // Với entry nén Deflate: chỉ giải nén trọn vẹn nếu kích thước hợp lý (<= 120MB) để tránh OOM trên iOS Safari
  const SAFE_DEFLATE_FULL_LIMIT = 120 * 1024 * 1024;
  if (entry.uncompressedSize > SAFE_DEFLATE_FULL_LIMIT) {
    return null;
  }
  const full = await extractZipEntry(blob, entry);
  if (rangeOffset >= full.length) return new Uint8Array(0);
  return full.subarray(rangeOffset, Math.min(full.length, rangeOffset + rangeLength));
}

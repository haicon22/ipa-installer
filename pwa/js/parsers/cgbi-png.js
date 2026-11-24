/**
 * Bộ khôi phục ảnh PNG chuẩn Apple "CgBI" -> PNG chuẩn quốc tế (RFC 2083)
 * Xcode mặc định nén tất cả PNG trong IPA sang dạng CgBI:
 * - Chèn chunk "CgBI" trước "IHDR"
 * - Nén IDAT bằng Raw Deflate (không có 2-byte zlib header và 4-byte Adler32)
 * - Đảo kênh pixel từ RGBA sang BGRA (premultiplied alpha)
 */
import { inflateRaw, packZlibStored, crc32 } from './deflate.js';

const PNG_SIG = new Uint8Array([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]);

function hasPngSignature(bytes, offset = 0) {
  if (bytes.length < offset + 8) return false;
  for (let i = 0; i < 8; i++) {
    if (bytes[offset + i] !== PNG_SIG[i]) return false;
  }
  return true;
}

function makePngChunk(typeAscii, dataBytes) {
  const chunk = new Uint8Array(12 + dataBytes.length);
  const dv = new DataView(chunk.buffer);
  dv.setUint32(0, dataBytes.length, false);
  for (let i = 0; i < 4; i++) {
    chunk[4 + i] = typeAscii.charCodeAt(i);
  }
  chunk.set(dataBytes, 8);
  const crcVal = crc32(chunk.subarray(4, 8 + dataBytes.length));
  dv.setUint32(8 + dataBytes.length, crcVal, false);
  return chunk;
}

function paethPredictor(a, b, c) {
  const p = a + b - c;
  const pa = Math.abs(p - a);
  const pb = Math.abs(p - b);
  const pc = Math.abs(p - c);
  if (pa <= pb && pa <= pc) return a;
  if (pb <= pc) return b;
  return c;
}

/**
 * Kiểm tra và chuyển đổi ảnh PNG (hỗ trợ cả CgBI và PNG chuẩn).
 * @param {Uint8Array} pngBytes
 * @returns {{ pngBytes: Uint8Array, width: number, height: number, wasCgBI: boolean }}
 */
export function normalizeApplePng(pngBytes) {
  if (!hasPngSignature(pngBytes)) {
    throw new Error('Không phải tệp ảnh PNG hợp lệ');
  }

  const dv = new DataView(pngBytes.buffer, pngBytes.byteOffset, pngBytes.byteLength);
  let pos = 8;
  let isCgBI = false;
  let ihdrData = null;
  let width = 0;
  let height = 0;
  let bitDepth = 8;
  let colorType = 6;
  let interlace = 0;
  const idatParts = [];
  let totalIdatLen = 0;

  while (pos + 12 <= pngBytes.length) {
    const len = dv.getUint32(pos, false);
    const type = String.fromCharCode(
      pngBytes[pos + 4],
      pngBytes[pos + 5],
      pngBytes[pos + 6],
      pngBytes[pos + 7]
    );
    const dataStart = pos + 8;
    const dataEnd = dataStart + len;
    if (dataEnd + 4 > pngBytes.length) break;

    if (type === 'CgBI') {
      isCgBI = true;
    } else if (type === 'IHDR' && len >= 13) {
      ihdrData = pngBytes.slice(dataStart, dataStart + 13);
      width = dv.getUint32(dataStart, false);
      height = dv.getUint32(dataStart + 4, false);
      bitDepth = pngBytes[dataStart + 8];
      colorType = pngBytes[dataStart + 9];
      interlace = pngBytes[dataStart + 12];
    } else if (type === 'IDAT') {
      const part = pngBytes.subarray(dataStart, dataEnd);
      idatParts.push(part);
      totalIdatLen += part.length;
    } else if (type === 'IEND') {
      break;
    }

    pos = dataEnd + 4;
  }

  if (!ihdrData || width === 0 || height === 0) {
    throw new Error('Ảnh PNG thiếu thông tin kích thước IHDR');
  }

  // Nếu đã là PNG chuẩn quốc tế thì giữ nguyên để không tốn CPU
  if (!isCgBI) {
    return { pngBytes, width, height, wasCgBI: false };
  }

  // Nếu là CgBI với cấu hình thông dụng nhất của icon iOS (8-bit RGB hoặc RGBA, không interlace)
  if (bitDepth !== 8 || (colorType !== 6 && colorType !== 2) || interlace !== 0) {
    // Trả nguyên bản nếu rơi vào biến thể hiếm (Safari trên iOS vẫn tự vẽ được CgBI trong thẻ <img>)
    return { pngBytes, width, height, wasCgBI: true };
  }

  const combinedIdat = new Uint8Array(totalIdatLen);
  let offset = 0;
  for (const part of idatParts) {
    combinedIdat.set(part, offset);
    offset += part.length;
  }

  const bpp = colorType === 6 ? 4 : 3;
  const rowBytes = width * bpp;
  const expectedRawLen = height * (1 + rowBytes);
  const rawScanlines = inflateRaw(combinedIdat, expectedRawLen);

  if (rawScanlines.length < expectedRawLen) {
    throw new Error('Dữ liệu pixel sau giải nén CgBI ngắn hơn kích thước ảnh');
  }

  // Khôi phục bộ lọc PNG (Unfilter) theo từng dòng quét, đảo BGRA -> RGBA và gỡ premultiplied alpha
  const recon = new Uint8Array(expectedRawLen);
  const prevRow = new Uint8Array(rowBytes);
  const currRow = new Uint8Array(rowBytes);

  for (let y = 0; y < height; y++) {
    const srcRowStart = y * (1 + rowBytes);
    const filterType = rawScanlines[srcRowStart];
    const srcPixels = rawScanlines.subarray(srcRowStart + 1, srcRowStart + 1 + rowBytes);

    for (let x = 0; x < rowBytes; x++) {
      const rawByte = srcPixels[x];
      const left = x >= bpp ? currRow[x - bpp] : 0;
      const up = prevRow[x];
      const upLeft = x >= bpp ? prevRow[x - bpp] : 0;
      let val = rawByte;
      if (filterType === 1) val = (rawByte + left) & 0xff;
      else if (filterType === 2) val = (rawByte + up) & 0xff;
      else if (filterType === 3) val = (rawByte + ((left + up) >>> 1)) & 0xff;
      else if (filterType === 4) val = (rawByte + paethPredictor(left, up, upLeft)) & 0xff;
      currRow[x] = val;
    }

    const outRowStart = y * (1 + rowBytes);
    recon[outRowStart] = 0; // Filter type 0 (None) cho ảnh đầu ra sạch

    for (let px = 0; px < width; px++) {
      const i = px * bpp;
      if (bpp === 4) {
        let b = currRow[i];
        let g = currRow[i + 1];
        let r = currRow[i + 2];
        const a = currRow[i + 3];
        if (a > 0 && a < 255) {
          r = Math.min(255, Math.round((r * 255) / a));
          g = Math.min(255, Math.round((g * 255) / a));
          b = Math.min(255, Math.round((b * 255) / a));
        }
        recon[outRowStart + 1 + i] = r;
        recon[outRowStart + 1 + i + 1] = g;
        recon[outRowStart + 1 + i + 2] = b;
        recon[outRowStart + 1 + i + 3] = a;
      } else {
        // BGR -> RGB
        recon[outRowStart + 1 + i] = currRow[i + 2];
        recon[outRowStart + 1 + i + 1] = currRow[i + 1];
        recon[outRowStart + 1 + i + 2] = currRow[i];
      }
    }

    prevRow.set(currRow);
  }

  const zlibIdat = packZlibStored(recon);
  const ihdrChunk = makePngChunk('IHDR', ihdrData);
  const idatChunk = makePngChunk('IDAT', zlibIdat);
  const iendChunk = makePngChunk('IEND', new Uint8Array(0));

  const finalPng = new Uint8Array(8 + ihdrChunk.length + idatChunk.length + iendChunk.length);
  finalPng.set(PNG_SIG, 0);
  finalPng.set(ihdrChunk, 8);
  finalPng.set(idatChunk, 8 + ihdrChunk.length);
  finalPng.set(iendChunk, 8 + ihdrChunk.length + idatChunk.length);

  return { pngBytes: finalPng, width, height, wasCgBI: true };
}

/**
 * Quét tìm luồng PNG nhúng bên trong tệp Assets.car (trường hợp ứng dụng không để file PNG rời).
 * Trả về ảnh PNG có kích thước lớn nhất tìm được.
 */
export function extractEmbeddedPngFromCar(carBytes) {
  let best = null;
  for (let i = 0; i <= carBytes.length - 32; i++) {
    if (hasPngSignature(carBytes, i)) {
      // Tìm tới cuối IEND chunk của ảnh PNG này
      const dv = new DataView(carBytes.buffer, carBytes.byteOffset, carBytes.byteLength);
      let p = i + 8;
      let valid = false;
      while (p + 12 <= carBytes.length) {
        const len = dv.getUint32(p, false);
        if (len > 16 * 1024 * 1024 || p + 12 + len > carBytes.length) break;
        const type = String.fromCharCode(
          carBytes[p + 4],
          carBytes[p + 5],
          carBytes[p + 6],
          carBytes[p + 7]
        );
        p += 12 + len;
        if (type === 'IEND') {
          valid = true;
          break;
        }
      }
      if (valid) {
        try {
          const candidate = normalizeApplePng(carBytes.subarray(i, p));
          if (!best || candidate.width * candidate.height > best.width * best.height) {
            best = candidate;
          }
          i = p - 1;
        } catch {
          // Bỏ qua nếu không phải icon hợp lệ
        }
      }
    }
  }
  return best;
}

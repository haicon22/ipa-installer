/**
 * Pure-JS RFC 1951 Raw Inflate + Zlib Uncompressed Pack + CRC32 / Adler32
 * Tương thích 100% từ iOS 15.0 đến iOS 26.6+ (Web Worker & Main Thread) và Node.js,
 * không phụ thuộc DecompressionStream hay thư viện CDN bên ngoài.
 */

const CRC32_TABLE = (() => {
  const table = new Uint32Array(256);
  for (let i = 0; i < 256; i++) {
    let c = i;
    for (let k = 0; k < 8; k++) {
      c = (c & 1) ? (0xedb88320 ^ (c >>> 1)) : (c >>> 1);
    }
    table[i] = c >>> 0;
  }
  return table;
})();

export function crc32(bytes, seed = 0) {
  let crc = (seed ^ 0xffffffff) >>> 0;
  for (let i = 0; i < bytes.length; i++) {
    crc = CRC32_TABLE[(crc ^ bytes[i]) & 0xff] ^ (crc >>> 8);
  }
  return (crc ^ 0xffffffff) >>> 0;
}

export function adler32(bytes) {
  let a = 1;
  let b = 0;
  const MOD = 65521;
  let i = 0;
  let len = bytes.length;
  while (len > 0) {
    let tlen = len > 5552 ? 5552 : len;
    len -= tlen;
    do {
      a += bytes[i++];
      b += a;
    } while (--tlen);
    a %= MOD;
    b %= MOD;
  }
  return ((b << 16) | a) >>> 0;
}

const FIXED_LIT_LENGTHS = (() => {
  const lens = new Uint8Array(288);
  for (let i = 0; i <= 143; i++) lens[i] = 8;
  for (let i = 144; i <= 255; i++) lens[i] = 9;
  for (let i = 256; i <= 279; i++) lens[i] = 7;
  for (let i = 280; i <= 287; i++) lens[i] = 8;
  return lens;
})();

const FIXED_DIST_LENGTHS = (() => {
  const lens = new Uint8Array(32);
  lens.fill(5);
  return lens;
})();

const LEN_BASE = [
  3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31,
  35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258
];
const LEN_EXTRA = [
  0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2,
  3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0
];
const DIST_BASE = [
  1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193,
  257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577
];
const DIST_EXTRA = [
  0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6,
  7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13
];
const CL_ORDER = [16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15];

function buildHuffman(lengths) {
  let maxBits = 0;
  for (let i = 0; i < lengths.length; i++) {
    if (lengths[i] > maxBits) maxBits = lengths[i];
  }
  if (maxBits === 0) {
    return { table: new Int32Array(2), maxBits: 1 };
  }
  const count = new Int32Array(maxBits + 1);
  for (let i = 0; i < lengths.length; i++) {
    if (lengths[i] > 0) count[lengths[i]]++;
  }
  const nextCode = new Int32Array(maxBits + 1);
  let code = 0;
  for (let bits = 1; bits <= maxBits; bits++) {
    code = (code + count[bits - 1]) << 1;
    nextCode[bits] = code;
  }
  const size = 1 << maxBits;
  const table = new Int32Array(size);
  table.fill(-1);

  for (let sym = 0; sym < lengths.length; sym++) {
    const len = lengths[sym];
    if (len === 0) continue;
    const c = nextCode[len]++;
    // Đảo bit cho thứ tự đọc LSB-first của Deflate
    let rev = 0;
    for (let b = 0; b < len; b++) {
      rev = (rev << 1) | ((c >>> b) & 1);
    }
    const packed = (sym << 8) | len;
    const step = 1 << len;
    for (let idx = rev; idx < size; idx += step) {
      table[idx] = packed;
    }
  }
  return { table, maxBits };
}

const FIXED_LIT_TREE = buildHuffman(FIXED_LIT_LENGTHS);
const FIXED_DIST_TREE = buildHuffman(FIXED_DIST_LENGTHS);

/**
 * Giải nén luồng Deflate thô (RFC 1951 - dùng trong ZIP method 8 và PNG CgBI IDAT).
 * @param {Uint8Array} src
 * @param {number} [expectedSize]
 * @param {number} [maxOutputBytes] Nếu chỉ cần đọc phần đầu (ví dụ 128KB đầu của Mach-O)
 * @returns {Uint8Array}
 */
export function inflateRaw(src, expectedSize = 0, maxOutputBytes = 0) {
  let pos = 0;
  let bitBuf = 0;
  let bitCnt = 0;

  const initialCap = maxOutputBytes > 0
    ? Math.min(maxOutputBytes + 32768, Math.max(65536, maxOutputBytes))
    : (expectedSize > 0 ? expectedSize : Math.max(65536, src.length * 3));

  let out = new Uint8Array(initialCap);
  let outPos = 0;

  function ensureOut(need) {
    if (outPos + need <= out.length) return;
    let nextLen = out.length * 2;
    while (nextLen < outPos + need) nextLen *= 2;
    const next = new Uint8Array(nextLen);
    next.set(out.subarray(0, outPos));
    out = next;
  }

  function fillBits(n) {
    while (bitCnt < n) {
      if (pos >= src.length) {
        throw new Error('Luồng nén Deflate bị cắt cụt bất thường');
      }
      bitBuf |= src[pos++] << bitCnt;
      bitCnt += 8;
    }
  }

  function readBits(n) {
    if (n === 0) return 0;
    fillBits(n);
    const val = bitBuf & ((1 << n) - 1);
    bitBuf >>>= n;
    bitCnt -= n;
    return val;
  }

  function decodeSymbol(tree) {
    const { table, maxBits } = tree;
    while (bitCnt < maxBits && pos < src.length) {
      bitBuf |= src[pos++] << bitCnt;
      bitCnt += 8;
    }
    const mask = (1 << maxBits) - 1;
    const entry = table[bitBuf & mask];
    if (entry < 0) {
      throw new Error('Mã Huffman không hợp lệ trong dữ liệu nén');
    }
    const len = entry & 0xff;
    if (len > bitCnt) {
      throw new Error('Thiếu dữ liệu bit khi giải mã Huffman');
    }
    bitBuf >>>= len;
    bitCnt -= len;
    return entry >>> 8;
  }

  let isFinal = 0;
  while (!isFinal) {
    isFinal = readBits(1);
    const btype = readBits(2);

    if (btype === 0) {
      // Stored block
      bitBuf = 0;
      bitCnt = 0;
      if (pos + 4 > src.length) {
        throw new Error('Khối Stored Deflate thiếu header độ dài');
      }
      const len = src[pos] | (src[pos + 1] << 8);
      const nlen = src[pos + 2] | (src[pos + 3] << 8);
      pos += 4;
      if ((len ^ 0xffff) !== nlen) {
        throw new Error('Khối Stored Deflate sai kiểm tra độ dài NLEN');
      }
      if (pos + len > src.length) {
        throw new Error('Khối Stored Deflate vượt quá kích thước nguồn');
      }
      ensureOut(len);
      out.set(src.subarray(pos, pos + len), outPos);
      pos += len;
      outPos += len;
      if (maxOutputBytes > 0 && outPos >= maxOutputBytes) {
        return out.subarray(0, maxOutputBytes);
      }
    } else if (btype === 1 || btype === 2) {
      let litTree = FIXED_LIT_TREE;
      let distTree = FIXED_DIST_TREE;

      if (btype === 2) {
        const hlit = readBits(5) + 257;
        const hdist = readBits(5) + 1;
        const hclen = readBits(4) + 4;

        const clLengths = new Uint8Array(19);
        for (let i = 0; i < hclen; i++) {
          clLengths[CL_ORDER[i]] = readBits(3);
        }
        const clTree = buildHuffman(clLengths);

        const totalCodes = hlit + hdist;
        const codeLengths = new Uint8Array(totalCodes);
        let idx = 0;
        while (idx < totalCodes) {
          const sym = decodeSymbol(clTree);
          if (sym <= 15) {
            codeLengths[idx++] = sym;
          } else if (sym === 16) {
            if (idx === 0) throw new Error('Lặp độ dài Huffman ở vị trí đầu tiên');
            const prev = codeLengths[idx - 1];
            const repeat = readBits(2) + 3;
            for (let r = 0; r < repeat; r++) codeLengths[idx++] = prev;
          } else if (sym === 17) {
            const repeat = readBits(3) + 3;
            for (let r = 0; r < repeat; r++) codeLengths[idx++] = 0;
          } else if (sym === 18) {
            const repeat = readBits(7) + 11;
            for (let r = 0; r < repeat; r++) codeLengths[idx++] = 0;
          } else {
            throw new Error('Ký hiệu bảng mã Huffman không hợp lệ');
          }
        }
        litTree = buildHuffman(codeLengths.subarray(0, hlit));
        distTree = buildHuffman(codeLengths.subarray(hlit, totalCodes));
      }

      while (true) {
        const sym = decodeSymbol(litTree);
        if (sym < 256) {
          ensureOut(1);
          out[outPos++] = sym;
          if (maxOutputBytes > 0 && outPos >= maxOutputBytes) {
            return out.subarray(0, maxOutputBytes);
          }
        } else if (sym === 256) {
          break;
        } else {
          const lenIdx = sym - 257;
          if (lenIdx < 0 || lenIdx >= LEN_BASE.length) {
            throw new Error('Mã độ dài LZ77 vượt phạm vi');
          }
          const matchLen = LEN_BASE[lenIdx] + readBits(LEN_EXTRA[lenIdx]);
          const distSym = decodeSymbol(distTree);
          if (distSym < 0 || distSym >= DIST_BASE.length) {
            throw new Error('Mã khoảng cách LZ77 vượt phạm vi');
          }
          const matchDist = DIST_BASE[distSym] + readBits(DIST_EXTRA[distSym]);
          if (matchDist > outPos) {
            throw new Error('Khoảng cách tham chiếu lùi LZ77 vượt đầu đệm');
          }
          ensureOut(matchLen);
          let copySrc = outPos - matchDist;
          for (let m = 0; m < matchLen; m++) {
            out[outPos++] = out[copySrc++];
          }
          if (maxOutputBytes > 0 && outPos >= maxOutputBytes) {
            return out.subarray(0, maxOutputBytes);
          }
        }
      }
    } else {
      throw new Error('Loại khối Deflate BTYPE=3 không hợp lệ');
    }
  }

  return out.subarray(0, outPos);
}

/**
 * Giải nén luồng Zlib chuẩn (RFC 1950 - có 2 byte header 0x78..).
 */
export function inflateZlib(src, expectedSize = 0) {
  if (src.length < 6) throw new Error('Luồng Zlib quá ngắn');
  const cmf = src[0];
  const flg = src[1];
  if ((cmf & 0x0f) !== 8 || ((cmf << 8) + flg) % 31 !== 0) {
    throw new Error('Header Zlib không hợp lệ');
  }
  const fdict = (flg & 0x20) !== 0;
  const offset = fdict ? 6 : 2;
  return inflateRaw(src.subarray(offset, src.length - 4), expectedSize);
}

/**
 * Đóng gói dữ liệu thô thành luồng Zlib hợp lệ (RFC 1950 stored blocks + Adler32)
 * dùng khi tái tạo chunk IDAT của ảnh PNG chuẩn từ dữ liệu CgBI đã khôi phục.
 */
export function packZlibStored(rawBytes) {
  const BLOCK_MAX = 65535;
  const numBlocks = Math.max(1, Math.ceil(rawBytes.length / BLOCK_MAX));
  const totalSize = 2 + numBlocks * 5 + rawBytes.length + 4;
  const out = new Uint8Array(totalSize);
  // Zlib header: CM=8 (deflate), CINFO=7 (32K window) => 0x78, FLG=0x01 (no dict, fastest)
  out[0] = 0x78;
  out[1] = 0x01;

  let p = 2;
  let offset = 0;
  for (let b = 0; b < numBlocks; b++) {
    const remain = rawBytes.length - offset;
    const chunkLen = Math.min(BLOCK_MAX, remain);
    const isLast = b === numBlocks - 1 ? 1 : 0;
    out[p++] = isLast;
    out[p++] = chunkLen & 0xff;
    out[p++] = (chunkLen >>> 8) & 0xff;
    const nlen = (~chunkLen) & 0xffff;
    out[p++] = nlen & 0xff;
    out[p++] = (nlen >>> 8) & 0xff;
    if (chunkLen > 0) {
      out.set(rawBytes.subarray(offset, offset + chunkLen), p);
      p += chunkLen;
      offset += chunkLen;
    }
  }

  const adler = adler32(rawBytes);
  out[p++] = (adler >>> 24) & 0xff;
  out[p++] = (adler >>> 16) & 0xff;
  out[p++] = (adler >>> 8) & 0xff;
  out[p++] = adler & 0xff;
  return out;
}

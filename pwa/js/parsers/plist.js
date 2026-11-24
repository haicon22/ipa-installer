/**
 * Bộ giải mã Apple Property List hoàn chỉnh:
 * 1. Binary Plist ("bplist00") — định dạng thực tế của 99% file Info.plist trong IPA biên dịch từ Xcode
 * 2. XML Plist ("<?xml ... <plist>") — hoạt động thuần JS trong cả Web Worker (không phụ thuộc DOMParser)
 */

const APPLE_EPOCH_OFFSET_MS = 978307200 * 1000; // 2001-01-01T00:00:00Z
const utf8Decoder = new TextDecoder('utf-8', { fatal: false });
const utf16beDecoder = new TextDecoder('utf-16be', { fatal: false });

function readUIntBE(bytes, offset, byteCount) {
  let val = 0;
  for (let i = 0; i < byteCount; i++) {
    val = val * 256 + bytes[offset + i];
  }
  return val;
}

function readSignedIntBE(bytes, offset, byteCount) {
  if (byteCount === 1) return (bytes[offset] << 24) >> 24;
  if (byteCount === 2) {
    const v = (bytes[offset] << 8) | bytes[offset + 1];
    return (v << 16) >> 16;
  }
  if (byteCount === 4) {
    const dv = new DataView(bytes.buffer, bytes.byteOffset + offset, 4);
    return dv.getInt32(0, false);
  }
  if (byteCount === 8) {
    const dv = new DataView(bytes.buffer, bytes.byteOffset + offset, 8);
    const hi = dv.getInt32(0, false);
    const lo = dv.getUint32(4, false);
    return hi * 4294967296 + lo;
  }
  return readUIntBE(bytes, offset, byteCount);
}

/**
 * Giải mã Apple Binary Plist (bplist00).
 * @param {Uint8Array} bytes
 */
export function parseBinaryPlist(bytes) {
  if (bytes.length < 40) {
    throw new Error('Binary Plist không hợp lệ (kích thước < 40 bytes)');
  }
  const magic = utf8Decoder.decode(bytes.subarray(0, 8));
  if (!magic.startsWith('bplist0')) {
    throw new Error(`Chữ ký Binary Plist không được hỗ trợ: ${magic}`);
  }

  // Trailer 32 bytes ở cuối tệp
  const trailerStart = bytes.length - 32;
  const offsetIntSize = bytes[trailerStart + 6];
  const objectRefSize = bytes[trailerStart + 7];
  const numObjects = readUIntBE(bytes, trailerStart + 8, 8);
  const topObject = readUIntBE(bytes, trailerStart + 16, 8);
  const offsetTableOffset = readUIntBE(bytes, trailerStart + 24, 8);

  if (
    offsetIntSize < 1 ||
    offsetIntSize > 8 ||
    objectRefSize < 1 ||
    objectRefSize > 8 ||
    offsetTableOffset + numObjects * offsetIntSize > trailerStart
  ) {
    throw new Error('Bảng offset của Binary Plist bị hỏng');
  }

  const offsets = new Array(numObjects);
  for (let i = 0; i < numObjects; i++) {
    offsets[i] = readUIntBE(bytes, offsetTableOffset + i * offsetIntSize, offsetIntSize);
  }

  const memo = new Map();
  const visiting = new Set();

  function readLength(pos, infoNibble) {
    if (infoNibble !== 0x0f) {
      return { length: infoNibble, nextPos: pos };
    }
    const intMarker = bytes[pos];
    if ((intMarker & 0xf0) !== 0x10) {
      throw new Error('Định dạng độ dài mở rộng trong bplist00 không hợp lệ');
    }
    const byteCount = 1 << (intMarker & 0x0f);
    const length = readUIntBE(bytes, pos + 1, byteCount);
    return { length, nextPos: pos + 1 + byteCount };
  }

  function decodeObject(objIdx) {
    if (objIdx < 0 || objIdx >= numObjects) {
      throw new Error(`Tham chiếu đối tượng bplist00 vượt giới hạn: ${objIdx}`);
    }
    if (memo.has(objIdx)) return memo.get(objIdx);
    if (visiting.has(objIdx)) {
      throw new Error('Phát hiện vòng lặp tham chiếu trong Binary Plist');
    }
    visiting.add(objIdx);

    const pos = offsets[objIdx];
    const marker = bytes[pos];
    const objType = (marker & 0xf0) >>> 4;
    const objInfo = marker & 0x0f;
    let result = null;

    switch (objType) {
      case 0x0: {
        if (objInfo === 0x00) result = null;
        else if (objInfo === 0x08) result = false;
        else if (objInfo === 0x09) result = true;
        else result = null;
        break;
      }
      case 0x1: {
        // Integer
        const byteCount = 1 << objInfo;
        result = byteCount >= 8
          ? readSignedIntBE(bytes, pos + 1, byteCount)
          : readUIntBE(bytes, pos + 1, byteCount);
        break;
      }
      case 0x2: {
        // Real (float32 / float64)
        const byteCount = 1 << objInfo;
        const dv = new DataView(bytes.buffer, bytes.byteOffset + pos + 1, byteCount);
        result = byteCount === 4 ? dv.getFloat32(0, false) : dv.getFloat64(0, false);
        break;
      }
      case 0x3: {
        // Date (float64 seconds từ 2001-01-01)
        const dv = new DataView(bytes.buffer, bytes.byteOffset + pos + 1, 8);
        const secs = dv.getFloat64(0, false);
        result = new Date(APPLE_EPOCH_OFFSET_MS + secs * 1000).toISOString();
        break;
      }
      case 0x4: {
        // Raw Data
        const { length, nextPos } = readLength(pos + 1, objInfo);
        result = bytes.slice(nextPos, nextPos + length);
        break;
      }
      case 0x5: {
        // ASCII String
        const { length, nextPos } = readLength(pos + 1, objInfo);
        let s = '';
        for (let i = 0; i < length; i++) {
          s += String.fromCharCode(bytes[nextPos + i]);
        }
        result = s;
        break;
      }
      case 0x6: {
        // UTF-16BE String
        const { length, nextPos } = readLength(pos + 1, objInfo);
        result = utf16beDecoder.decode(bytes.subarray(nextPos, nextPos + length * 2));
        break;
      }
      case 0x8: {
        // UID
        const byteCount = objInfo + 1;
        result = { UID: readUIntBE(bytes, pos + 1, byteCount) };
        break;
      }
      case 0xa:
      case 0xc: {
        // Array / Set
        const { length, nextPos } = readLength(pos + 1, objInfo);
        const arr = new Array(length);
        for (let i = 0; i < length; i++) {
          const ref = readUIntBE(bytes, nextPos + i * objectRefSize, objectRefSize);
          arr[i] = decodeObject(ref);
        }
        result = arr;
        break;
      }
      case 0xd: {
        // Dictionary
        const { length, nextPos } = readLength(pos + 1, objInfo);
        const dict = {};
        const valOffsetBase = nextPos + length * objectRefSize;
        for (let i = 0; i < length; i++) {
          const keyRef = readUIntBE(bytes, nextPos + i * objectRefSize, objectRefSize);
          const valRef = readUIntBE(bytes, valOffsetBase + i * objectRefSize, objectRefSize);
          const k = String(decodeObject(keyRef));
          dict[k] = decodeObject(valRef);
        }
        result = dict;
        break;
      }
      default:
        result = null;
    }

    visiting.delete(objIdx);
    memo.set(objIdx, result);
    return result;
  }

  return decodeObject(topObject);
}

function unescapeXml(str) {
  return str
    .replace(/&lt;/g, '<')
    .replace(/&gt;/g, '>')
    .replace(/&quot;/g, '"')
    .replace(/&apos;/g, "'")
    .replace(/&#x([0-9a-fA-F]+);/g, (_, hex) => String.fromCodePoint(parseInt(hex, 16)))
    .replace(/&#([0-9]+);/g, (_, dec) => String.fromCodePoint(parseInt(dec, 10)))
    .replace(/&amp;/g, '&');
}

function decodeBase64(b64) {
  const clean = b64.replace(/[^A-Za-z0-9+/=]/g, '');
  if (typeof atob === 'function') {
    const bin = atob(clean);
    const out = new Uint8Array(bin.length);
    for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
    return out;
  }
  return new Uint8Array(Buffer.from(clean, 'base64'));
}

/**
 * Giải mã XML Plist thuần JS (chạy an toàn trong Web Worker của Safari nơi không có DOMParser).
 * @param {string} xmlText
 */
export function parseXmlPlist(xmlText) {
  // Loại bỏ XML comments, DOCTYPE và processing instructions
  const cleaned = xmlText
    .replace(/<!--[\s\S]*?-->/g, '')
    .replace(/<\?[\s\S]*?\?>/g, '')
    .replace(/<!DOCTYPE[\s\S]*?>/gi, '');

  const tokenRegex = /<\/?([a-zA-Z0-9_:-]+)(?:\s+[^>]*?)?\s*\/?>|([^<]+)/g;
  const tokens = [];
  let match;
  while ((match = tokenRegex.exec(cleaned)) !== null) {
    if (match[1]) {
      const full = match[0];
      const isClose = full.startsWith('</');
      const isSelfClose = !isClose && full.endsWith('/>');
      tokens.push({
        kind: isSelfClose ? 'self' : isClose ? 'close' : 'open',
        tag: match[1]
      });
    } else if (match[2] !== undefined) {
      tokens.push({ kind: 'text', value: match[2] });
    }
  }

  let idx = 0;

  function readTextUntilClose(expectedTag) {
    let text = '';
    while (idx < tokens.length) {
      const tk = tokens[idx++];
      if (tk.kind === 'close' && tk.tag === expectedTag) break;
      if (tk.kind === 'text') text += tk.value;
    }
    return unescapeXml(text);
  }

  function parseValue() {
    while (idx < tokens.length && tokens[idx].kind === 'text') {
      if (tokens[idx].value.trim() === '') idx++;
      else break;
    }
    if (idx >= tokens.length) return null;
    const tk = tokens[idx++];

    if (tk.kind === 'self') {
      if (tk.tag === 'true') return true;
      if (tk.tag === 'false') return false;
      if (tk.tag === 'string') return '';
      if (tk.tag === 'data') return new Uint8Array(0);
      if (tk.tag === 'array') return [];
      if (tk.tag === 'dict') return {};
      return null;
    }

    if (tk.kind !== 'open') return null;

    switch (tk.tag) {
      case 'plist': {
        const inner = parseValue();
        while (idx < tokens.length) {
          const t = tokens[idx++];
          if (t.kind === 'close' && t.tag === 'plist') break;
        }
        return inner;
      }
      case 'true':
        readTextUntilClose('true');
        return true;
      case 'false':
        readTextUntilClose('false');
        return false;
      case 'string':
        return readTextUntilClose('string');
      case 'date':
        return readTextUntilClose('date').trim();
      case 'integer': {
        const raw = readTextUntilClose('integer').trim();
        return raw.startsWith('0x') || raw.startsWith('0X')
          ? parseInt(raw, 16)
          : parseInt(raw, 10);
      }
      case 'real':
        return parseFloat(readTextUntilClose('real').trim());
      case 'data':
        return decodeBase64(readTextUntilClose('data'));
      case 'array': {
        const arr = [];
        while (idx < tokens.length) {
          while (idx < tokens.length && tokens[idx].kind === 'text' && tokens[idx].value.trim() === '') {
            idx++;
          }
          if (idx < tokens.length && tokens[idx].kind === 'close' && tokens[idx].tag === 'array') {
            idx++;
            break;
          }
          arr.push(parseValue());
        }
        return arr;
      }
      case 'dict': {
        const obj = {};
        while (idx < tokens.length) {
          while (idx < tokens.length && tokens[idx].kind === 'text' && tokens[idx].value.trim() === '') {
            idx++;
          }
          if (idx < tokens.length && tokens[idx].kind === 'close' && tokens[idx].tag === 'dict') {
            idx++;
            break;
          }
          const keyToken = tokens[idx++];
          if (!keyToken || keyToken.kind !== 'open' || keyToken.tag !== 'key') {
            continue;
          }
          const key = readTextUntilClose('key');
          obj[key] = parseValue();
        }
        return obj;
      }
      default: {
        readTextUntilClose(tk.tag);
        return null;
      }
    }
  }

  // Sửa trường hợp <string></string> rỗng trả đúng chuỗi rỗng
  return parseValue();
}

/**
 * Tự động nhận diện và giải mã Plist (cả bplist00 nhị phân và XML).
 * @param {Uint8Array} bytes
 */
export function parsePlist(bytes) {
  if (!bytes || bytes.length === 0) {
    throw new Error('Dữ liệu Plist rỗng');
  }
  if (
    bytes.length >= 8 &&
    bytes[0] === 0x62 && // 'b'
    bytes[1] === 0x70 && // 'p'
    bytes[2] === 0x6c && // 'l'
    bytes[3] === 0x69 && // 'i'
    bytes[4] === 0x73 && // 's'
    bytes[5] === 0x74    // 't'
  ) {
    return { format: 'binary (bplist00)', data: parseBinaryPlist(bytes) };
  }

  const text = utf8Decoder.decode(bytes);
  const plistStart = text.indexOf('<plist');
  if (plistStart >= 0) {
    return { format: 'xml', data: parseXmlPlist(text) };
  }
  throw new Error('Định dạng Plist không nhận diện được (không phải bplist00 hay XML Plist)');
}

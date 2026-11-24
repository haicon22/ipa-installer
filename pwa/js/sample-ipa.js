/**
 * Bộ tạo gói .ipa nhị phân chuẩn thực tế 100% ngay trong bộ nhớ:
 * - Cấu trúc ZIP thật (Local File Headers + Central Directory + EOCD + CRC32)
 * - Info.plist ở định dạng Apple Binary Plist ("bplist00") thật
 * - Biểu tượng ứng dụng ở định dạng Apple Crushed PNG ("CgBI" + raw deflate BGRA) thật
 * - Tệp thực thi Fat Mach-O 64-bit thật (chứa 2 lát cắt arm64 + arm64e, LC_BUILD_VERSION,
 *   LC_ENCRYPTION_INFO_64 cryptid=0, LC_UUID, LC_LOAD_DYLIB, LC_CODE_SIGNATURE SuperBlob)
 * - embedded.mobileprovision chứa chứng chỉ X.509 ASN.1 DER thật + XML Plist
 * - PlugIns/QuickWidget.appex/Info.plist thật để kiểm chứng bộ đếm hạn ngạch 10 App ID
 *
 * Dùng cho:
 * 1) Bộ kiểm thử tự động (Automated Integration Tests) trên Node.js / CI
 * 2) Nút "Nạp IPA nhị phân mẫu để kiểm thử" ngay trên Safari iPhone khi người dùng chưa tải sẵn IPA ngoài
 */
import { crc32 } from './parsers/deflate.js';

const utf8Encoder = new TextEncoder();

/**
 * Tạo Binary Plist ("bplist00") hợp lệ từ một từ điển phẳng gồm chuỗi, số nguyên, boolean và mảng chuỗi.
 */
function encodeSimpleBinaryPlist(dictObj) {
  const objects = [];
  const addObj = (o) => {
    const idx = objects.length;
    objects.push(o);
    return idx;
  };

  // Object 0 là root dictionary placeholder
  addObj({ type: 'dict', entries: [] });
  const rootEntries = [];

  function registerValue(val) {
    if (typeof val === 'boolean') {
      return addObj({ type: 'bool', value: val });
    }
    if (typeof val === 'number') {
      return addObj({ type: 'int', value: val });
    }
    if (typeof val === 'string') {
      const isAscii = /^[\x20-\x7e]*$/.test(val);
      return addObj({ type: isAscii ? 'ascii' : 'utf16', value: val });
    }
    if (Array.isArray(val)) {
      const refs = val.map((item) => registerValue(item));
      return addObj({ type: 'array', refs });
    }
    if (val && typeof val === 'object') {
      const idx = addObj({ type: 'dict', entries: [] });
      const subEntries = [];
      for (const [k, v] of Object.entries(val)) {
        const kRef = registerValue(k);
        const vRef = registerValue(v);
        subEntries.push([kRef, vRef]);
      }
      objects[idx].entries = subEntries;
      return idx;
    }
    return addObj({ type: 'null' });
  }

  for (const [k, v] of Object.entries(dictObj)) {
    const kRef = registerValue(k);
    const vRef = registerValue(v);
    rootEntries.push([kRef, vRef]);
  }
  objects[0].entries = rootEntries;

  // objectRefSize = 1 byte (đủ cho < 256 objects)
  const chunks = [utf8Encoder.encode('bplist00')];
  let currentOffset = 8;
  const offsets = [];

  function encodeHeaderWithLen(typeHighNibble, len) {
    if (len < 15) {
      return new Uint8Array([(typeHighNibble << 4) | len]);
    }
    if (len < 256) {
      return new Uint8Array([(typeHighNibble << 4) | 0x0f, 0x10, len]);
    }
    return new Uint8Array([
      (typeHighNibble << 4) | 0x0f,
      0x11,
      (len >>> 8) & 0xff,
      len & 0xff
    ]);
  }

  for (const obj of objects) {
    offsets.push(currentOffset);
    let encoded;
    if (obj.type === 'bool') {
      encoded = new Uint8Array([obj.value ? 0x09 : 0x08]);
    } else if (obj.type === 'int') {
      encoded = new Uint8Array([0x11, (obj.value >>> 8) & 0xff, obj.value & 0xff]);
    } else if (obj.type === 'ascii') {
      const hdr = encodeHeaderWithLen(0x5, obj.value.length);
      const body = utf8Encoder.encode(obj.value);
      encoded = new Uint8Array(hdr.length + body.length);
      encoded.set(hdr, 0);
      encoded.set(body, hdr.length);
    } else if (obj.type === 'utf16') {
      const hdr = encodeHeaderWithLen(0x6, obj.value.length);
      const body = new Uint8Array(obj.value.length * 2);
      for (let i = 0; i < obj.value.length; i++) {
        const code = obj.value.charCodeAt(i);
        body[i * 2] = (code >>> 8) & 0xff;
        body[i * 2 + 1] = code & 0xff;
      }
      encoded = new Uint8Array(hdr.length + body.length);
      encoded.set(hdr, 0);
      encoded.set(body, hdr.length);
    } else if (obj.type === 'array') {
      const hdr = encodeHeaderWithLen(0xa, obj.refs.length);
      encoded = new Uint8Array(hdr.length + obj.refs.length);
      encoded.set(hdr, 0);
      obj.refs.forEach((r, i) => {
        encoded[hdr.length + i] = r;
      });
    } else if (obj.type === 'dict') {
      const n = obj.entries.length;
      const hdr = encodeHeaderWithLen(0xd, n);
      encoded = new Uint8Array(hdr.length + n * 2);
      encoded.set(hdr, 0);
      obj.entries.forEach(([kr, vr], i) => {
        encoded[hdr.length + i] = kr;
        encoded[hdr.length + n + i] = vr;
      });
    } else {
      encoded = new Uint8Array([0x00]);
    }
    chunks.push(encoded);
    currentOffset += encoded.length;
  }

  const offsetTableOffset = currentOffset;
  const offsetTable = new Uint8Array(offsets.length * 2);
  offsets.forEach((off, i) => {
    offsetTable[i * 2] = (off >>> 8) & 0xff;
    offsetTable[i * 2 + 1] = off & 0xff;
  });
  chunks.push(offsetTable);

  const trailer = new Uint8Array(32);
  trailer[6] = 2; // offsetIntSize = 2 bytes
  trailer[7] = 1; // objectRefSize = 1 byte
  const trDv = new DataView(trailer.buffer);
  trDv.setUint32(12, objects.length, false);
  trDv.setUint32(20, 0, false); // topObject = 0
  trDv.setUint32(28, offsetTableOffset, false);
  chunks.push(trailer);

  const total = chunks.reduce((s, c) => s + c.length, 0);
  const out = new Uint8Array(total);
  let p = 0;
  for (const c of chunks) {
    out.set(c, p);
    p += c.length;
  }
  return out;
}

/**
 * Tạo ảnh icon PNG chuẩn Apple CgBI (64x64 RGBA, raw deflate không header zlib, kênh màu BGRA).
 */
function createSampleCgBIPng(width = 64, height = 64) {
  const sig = new Uint8Array([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]);
  const makeChunk = (type, data) => {
    const buf = new Uint8Array(12 + data.length);
    const dv = new DataView(buf.buffer);
    dv.setUint32(0, data.length, false);
    for (let i = 0; i < 4; i++) buf[4 + i] = type.charCodeAt(i);
    buf.set(data, 8);
    dv.setUint32(8 + data.length, crc32(buf.subarray(4, 8 + data.length)), false);
    return buf;
  };

  const cgbiChunk = makeChunk('CgBI', new Uint8Array([0x50, 0x00, 0x20, 0x06]));
  const ihdr = new Uint8Array(13);
  const ihdrDv = new DataView(ihdr.buffer);
  ihdrDv.setUint32(0, width, false);
  ihdrDv.setUint32(4, height, false);
  ihdr[8] = 8; // 8-bit
  ihdr[9] = 6; // RGBA (ở CgBI là BGRA)
  const ihdrChunk = makeChunk('IHDR', ihdr);

  // Vẽ gradient xanh iOS (BGRA!)
  const rawLen = height * (1 + width * 4);
  const scanlines = new Uint8Array(rawLen);
  for (let y = 0; y < height; y++) {
    const row = y * (1 + width * 4);
    scanlines[row] = 0; // Filter None
    for (let x = 0; x < width; x++) {
      const px = row + 1 + x * 4;
      const r = Math.round(15 + (x / width) * 40);
      const g = Math.round(110 + (y / height) * 110);
      const b = 245;
      const a = 255;
      // Ghi theo thứ tự BGRA của CgBI!
      scanlines[px] = b;
      scanlines[px + 1] = g;
      scanlines[px + 2] = r;
      scanlines[px + 3] = a;
    }
  }

  // Raw Deflate stored block (KHÔNG có 2-byte zlib header, đúng chuẩn CgBI!)
  const rawDeflate = new Uint8Array(5 + scanlines.length);
  rawDeflate[0] = 0x01; // BFINAL=1, BTYPE=00
  rawDeflate[1] = scanlines.length & 0xff;
  rawDeflate[2] = (scanlines.length >>> 8) & 0xff;
  const nlen = (~scanlines.length) & 0xffff;
  rawDeflate[3] = nlen & 0xff;
  rawDeflate[4] = (nlen >>> 8) & 0xff;
  rawDeflate.set(scanlines, 5);

  const idatChunk = makeChunk('IDAT', rawDeflate);
  const iendChunk = makeChunk('IEND', new Uint8Array(0));

  const parts = [sig, cgbiChunk, ihdrChunk, idatChunk, iendChunk];
  const total = parts.reduce((s, c) => s + c.length, 0);
  const out = new Uint8Array(total);
  let p = 0;
  for (const c of parts) {
    out.set(c, p);
    p += c.length;
  }
  return out;
}

/**
 * Tạo nhị phân Fat Mach-O 64-bit hợp lệ chứa 2 kiến trúc (arm64 + arm64e) và LC_CODE_SIGNATURE SuperBlob.
 */
function createSampleFatMachO() {
  const entXml = utf8Encoder.encode(
    `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>application-identifier</key>
  <string>TEAM99DEMO.vn.ipainstaller.sampleapp</string>
  <key>com.apple.developer.team-identifier</key>
  <string>TEAM99DEMO</string>
  <key>get-task-allow</key>
  <true/>
  <key>aps-environment</key>
  <string>development</string>
</dict>
</plist>`
  );

  // Tạo CodeSignature SuperBlob
  const identBytes = utf8Encoder.encode('vn.ipainstaller.sampleapp\0');
  const teamBytes = utf8Encoder.encode('TEAM99DEMO\0');
  const cdHeaderLen = 52;
  const cdLen = cdHeaderLen + identBytes.length + teamBytes.length;
  const cdBlob = new Uint8Array(cdLen);
  const cdDv = new DataView(cdBlob.buffer);
  cdDv.setUint32(0, 0xfade0c02, false); // CSMAGIC_CODEDIRECTORY
  cdDv.setUint32(4, cdLen, false);
  cdDv.setUint32(8, 0x20400, false); // version
  cdDv.setUint32(12, 0x0000, false); // flags (not adhoc)
  cdDv.setUint32(20, cdHeaderLen, false); // identOffset
  cdBlob[36] = 2; // SHA-256
  cdDv.setUint32(48, cdHeaderLen + identBytes.length, false); // teamOffset
  cdBlob.set(identBytes, cdHeaderLen);
  cdBlob.set(teamBytes, cdHeaderLen + identBytes.length);

  const entBlob = new Uint8Array(8 + entXml.length);
  const entDv = new DataView(entBlob.buffer);
  entDv.setUint32(0, 0xfade7171, false); // CSMAGIC_ENTITLEMENTS
  entDv.setUint32(4, entBlob.length, false);
  entBlob.set(entXml, 8);

  const cmsBlob = new Uint8Array(24);
  const cmsDv = new DataView(cmsBlob.buffer);
  cmsDv.setUint32(0, 0xfade0b01, false); // CSMAGIC_BLOBWRAPPER
  cmsDv.setUint32(4, 24, false);

  const superHeaderLen = 12 + 3 * 8;
  const superLen = superHeaderLen + cdBlob.length + entBlob.length + cmsBlob.length;
  const superBlob = new Uint8Array(superLen);
  const sbDv = new DataView(superBlob.buffer);
  sbDv.setUint32(0, 0xfade0cc0, false);
  sbDv.setUint32(4, superLen, false);
  sbDv.setUint32(8, 3, false); // 3 blobs
  // Index 0: CodeDirectory
  sbDv.setUint32(12, 0, false);
  sbDv.setUint32(16, superHeaderLen, false);
  // Index 1: Entitlements
  sbDv.setUint32(20, 5, false);
  sbDv.setUint32(24, superHeaderLen + cdBlob.length, false);
  // Index 2: CMS Signature
  sbDv.setUint32(28, 0x10000, false);
  sbDv.setUint32(32, superHeaderLen + cdBlob.length + entBlob.length, false);

  superBlob.set(cdBlob, superHeaderLen);
  superBlob.set(entBlob, superHeaderLen + cdBlob.length);
  superBlob.set(cmsBlob, superHeaderLen + cdBlob.length + entBlob.length);

  function buildThinMachO(cpuSubtype) {
    const dylibPath = utf8Encoder.encode('/usr/lib/libSystem.B.dylib\0');
    const dylibCmdSize = Math.ceil((24 + dylibPath.length) / 8) * 8;
    const uuidCmdSize = 24;
    const buildVerCmdSize = 24;
    const encCmdSize = 24;
    const csCmdSize = 16;
    const sizeofcmds = uuidCmdSize + buildVerCmdSize + encCmdSize + dylibCmdSize + csCmdSize;
    const codeSigOffset = 512;
    const sliceLen = codeSigOffset + superBlob.length;

    const buf = new Uint8Array(sliceLen);
    const dv = new DataView(buf.buffer);
    // mach_header_64 (little-endian)
    dv.setUint32(0, 0xfeedfacf, true);
    dv.setUint32(4, 0x0100000c, true); // CPU_TYPE_ARM64
    dv.setUint32(8, cpuSubtype, true);
    dv.setUint32(12, 2, true); // MH_EXECUTE
    dv.setUint32(16, 5, true); // ncmds = 5
    dv.setUint32(20, sizeofcmds, true);
    dv.setUint32(24, 0x00200085, true); // MH_PIE | MH_DYLDLINK | MH_TWOLEVEL

    let p = 32;
    // 1. LC_UUID
    dv.setUint32(p, 0x1b, true);
    dv.setUint32(p + 4, uuidCmdSize, true);
    for (let i = 0; i < 16; i++) buf[p + 8 + i] = (0xa0 + i + cpuSubtype) & 0xff;
    p += uuidCmdSize;

    // 2. LC_BUILD_VERSION (Platform 2 = iOS, minos = 15.0, sdk = 26.6)
    dv.setUint32(p, 0x32, true);
    dv.setUint32(p + 4, buildVerCmdSize, true);
    dv.setUint32(p + 8, 2, true); // PLATFORM_IOS
    dv.setUint32(p + 12, (15 << 16) | (0 << 8), true); // 15.0
    dv.setUint32(p + 16, (26 << 16) | (6 << 8), true); // 26.6 SDK
    p += buildVerCmdSize;

    // 3. LC_ENCRYPTION_INFO_64 (cryptid = 0 -> Đã giải mã!)
    dv.setUint32(p, 0x2c, true);
    dv.setUint32(p + 4, encCmdSize, true);
    dv.setUint32(p + 8, 256, true);
    dv.setUint32(p + 12, 128, true);
    dv.setUint32(p + 16, 0, true); // cryptid = 0
    p += encCmdSize;

    // 4. LC_LOAD_DYLIB
    dv.setUint32(p, 0x0c, true);
    dv.setUint32(p + 4, dylibCmdSize, true);
    dv.setUint32(p + 8, 24, true); // name offset
    buf.set(dylibPath, p + 24);
    p += dylibCmdSize;

    // 5. LC_CODE_SIGNATURE
    dv.setUint32(p, 0x1d, true);
    dv.setUint32(p + 4, csCmdSize, true);
    dv.setUint32(p + 8, codeSigOffset, true);
    dv.setUint32(p + 12, superBlob.length, true);

    buf.set(superBlob, codeSigOffset);
    return buf;
  }

  const sliceArm64 = buildThinMachO(0);
  const sliceArm64e = buildThinMachO(2);
  const off1 = 4096;
  const off2 = 4096 + Math.ceil(sliceArm64.length / 4096) * 4096;
  const out = new Uint8Array(off2 + sliceArm64e.length);
  const dv = new DataView(out.buffer);
  // FAT_MAGIC (Big-Endian)
  dv.setUint32(0, 0xcafebabe, false);
  dv.setUint32(4, 2, false); // 2 architectures
  // Arch 0: arm64 (struct fat_arch = 20 bytes)
  dv.setUint32(8, 0x0100000c, false);
  dv.setUint32(12, 0, false);
  dv.setUint32(16, off1, false);
  dv.setUint32(20, sliceArm64.length, false);
  dv.setUint32(24, 14, false); // align 2^14
  // Arch 1: arm64e
  dv.setUint32(28, 0x0100000c, false);
  dv.setUint32(32, 2, false);
  dv.setUint32(36, off2, false);
  dv.setUint32(40, sliceArm64e.length, false);
  dv.setUint32(44, 14, false); // align 2^14

  out.set(sliceArm64, off1);
  out.set(sliceArm64e, off2);
  return out;
}

/**
 * Tạo chứng chỉ X.509 DER tối giản hợp lệ để nhúng vào DeveloperCertificates của embedded.mobileprovision.
 */
function createSampleX509Der() {
  const tlv = (tag, body) => {
    const len = body.length;
    if (len < 128) {
      const r = new Uint8Array(2 + len);
      r[0] = tag;
      r[1] = len;
      r.set(body, 2);
      return r;
    }
    if (len < 256) {
      const r = new Uint8Array(3 + len);
      r[0] = tag;
      r[1] = 0x81;
      r[2] = len;
      r.set(body, 3);
      return r;
    }
    const r = new Uint8Array(4 + len);
    r[0] = tag;
    r[1] = 0x82;
    r[2] = (len >>> 8) & 0xff;
    r[3] = len & 0xff;
    r.set(body, 4);
    return r;
  };
  const concat = (...arrs) => {
    const n = arrs.reduce((s, a) => s + a.length, 0);
    const out = new Uint8Array(n);
    let p = 0;
    for (const a of arrs) {
      out.set(a, p);
      p += a.length;
    }
    return out;
  };
  const rdnAttr = (oidBytes, text) =>
    tlv(0x31, tlv(0x30, concat(tlv(0x06, new Uint8Array(oidBytes)), tlv(0x0c, utf8Encoder.encode(text)))));

  const version = tlv(0xa0, tlv(0x02, new Uint8Array([0x02])));
  const serial = tlv(0x02, new Uint8Array([0x4a, 0x89, 0x10, 0x26, 0xef, 0x01]));
  const sigAlg = tlv(0x30, tlv(0x06, new Uint8Array([0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x01, 0x0b])));
  const issuer = tlv(0x30, concat(
    rdnAttr([0x55, 0x04, 0x03], 'Apple Worldwide Developer Relations Certification Authority'),
    rdnAttr([0x55, 0x04, 0x0a], 'Apple Inc.')
  ));
  const validity = tlv(0x30, concat(
    tlv(0x17, utf8Encoder.encode('261124000000Z')),
    tlv(0x17, utf8Encoder.encode('261201000000Z'))
  ));
  const subject = tlv(0x30, concat(
    rdnAttr([0x55, 0x04, 0x03], 'Apple Development: demo@ipainstaller.local (TEAM99DEMO)'),
    rdnAttr([0x55, 0x04, 0x0b], 'TEAM99DEMO')
  ));
  const spki = tlv(0x30, tlv(0x03, new Uint8Array([0x00, 0x01, 0x02, 0x03])));

  // Extension AuthorityInfoAccess chứa URL OCSP của Apple
  const ocspAccess = tlv(0x30, concat(
    tlv(0x06, new Uint8Array([0x2b, 0x06, 0x01, 0x05, 0x05, 0x07, 0x30, 0x01])),
    tlv(0x86, utf8Encoder.encode('http://ocsp.apple.com/ocsp03-wwdrg3'))
  ));
  const extSeq = tlv(0x30, tlv(0x30, concat(
    tlv(0x06, new Uint8Array([0x2b, 0x06, 0x01, 0x05, 0x05, 0x07, 0x01, 0x01])),
    tlv(0x04, tlv(0x30, ocspAccess))
  )));
  const extensions = tlv(0xa3, extSeq);

  const tbs = tlv(0x30, concat(version, serial, sigAlg, issuer, validity, subject, spki, extensions));
  const sigVal = tlv(0x03, new Uint8Array([0x00, 0xde, 0xad, 0xbe, 0xef]));
  return tlv(0x30, concat(tbs, sigAlg, sigVal));
}

function createSampleMobileProvision() {
  const certDer = createSampleX509Der();
  let b64 = '';
  if (typeof btoa === 'function') {
    b64 = btoa(String.fromCharCode(...certDer));
  } else {
    b64 = Buffer.from(certDer).toString('base64');
  }

  const now = new Date();
  const exp = new Date(now.getTime() + 7 * 24 * 3600 * 1000);

  const xml = `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>AppIDName</key>
  <string>IPA Sample Utility</string>
  <key>ApplicationIdentifierPrefix</key>
  <array><string>TEAM99DEMO</string></array>
  <key>CreationDate</key>
  <date>${now.toISOString()}</date>
  <key>ExpirationDate</key>
  <date>${exp.toISOString()}</date>
  <key>Name</key>
  <string>iOS Team Provisioning Profile: vn.ipainstaller.sampleapp</string>
  <key>ProvisionedDevices</key>
  <array>
    <string>00008130-001A2B3C4D5E6F01</string>
  </array>
  <key>TeamIdentifier</key>
  <array><string>TEAM99DEMO</string></array>
  <key>TeamName</key>
  <string>Personal Team (Mẫu kiểm thử)</string>
  <key>TimeToLive</key>
  <integer>7</integer>
  <key>UUID</key>
  <string>8B1F9200-4412-4A9E-9F10-123456789ABC</string>
  <key>DeveloperCertificates</key>
  <array>
    <data>${b64}</data>
  </array>
  <key>Entitlements</key>
  <dict>
    <key>application-identifier</key>
    <string>TEAM99DEMO.vn.ipainstaller.sampleapp</string>
    <key>com.apple.developer.team-identifier</key>
    <string>TEAM99DEMO</string>
    <key>get-task-allow</key>
    <true/>
    <key>aps-environment</key>
    <string>development</string>
  </dict>
</dict>
</plist>`;

  const cmsPrefix = new Uint8Array([0x30, 0x80, 0x06, 0x09, 0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x07, 0x02]);
  const xmlBytes = utf8Encoder.encode(xml);
  const cmsSuffix = new Uint8Array([0x00, 0x00, 0x00, 0x00]);
  const out = new Uint8Array(cmsPrefix.length + xmlBytes.length + cmsSuffix.length);
  out.set(cmsPrefix, 0);
  out.set(xmlBytes, cmsPrefix.length);
  out.set(cmsSuffix, cmsPrefix.length + xmlBytes.length);
  return out;
}

function packZipStored(files) {
  const localParts = [];
  const centralParts = [];
  let offset = 0;

  for (const f of files) {
    const nameBytes = utf8Encoder.encode(f.name);
    const data = f.data;
    const crcVal = crc32(data);

    const lh = new Uint8Array(30 + nameBytes.length);
    const lhDv = new DataView(lh.buffer);
    lhDv.setUint32(0, 0x04034b50, true);
    lhDv.setUint16(4, 20, true);
    lhDv.setUint16(6, 0x0800, true); // UTF-8 flag
    lhDv.setUint16(8, 0, true); // Stored
    lhDv.setUint32(14, crcVal, true);
    lhDv.setUint32(18, data.length, true);
    lhDv.setUint32(22, data.length, true);
    lhDv.setUint16(26, nameBytes.length, true);
    lh.set(nameBytes, 30);

    const ch = new Uint8Array(46 + nameBytes.length);
    const chDv = new DataView(ch.buffer);
    chDv.setUint32(0, 0x02014b50, true);
    chDv.setUint16(4, 0x031e, true);
    chDv.setUint16(6, 20, true);
    chDv.setUint16(8, 0x0800, true);
    chDv.setUint16(10, 0, true);
    chDv.setUint32(16, crcVal, true);
    chDv.setUint32(20, data.length, true);
    chDv.setUint32(24, data.length, true);
    chDv.setUint16(28, nameBytes.length, true);
    chDv.setUint32(42, offset, true);
    ch.set(nameBytes, 46);

    localParts.push(lh, data);
    centralParts.push(ch);
    offset += lh.length + data.length;
  }

  const cdOffset = offset;
  const cdSize = centralParts.reduce((s, c) => s + c.length, 0);
  const eocd = new Uint8Array(22);
  const eocdDv = new DataView(eocd.buffer);
  eocdDv.setUint32(0, 0x06054b50, true);
  eocdDv.setUint16(8, files.length, true);
  eocdDv.setUint16(10, files.length, true);
  eocdDv.setUint32(12, cdSize, true);
  eocdDv.setUint32(16, cdOffset, true);

  const all = [...localParts, ...centralParts, eocd];
  const total = all.reduce((s, c) => s + c.length, 0);
  const out = new Uint8Array(total);
  let p = 0;
  for (const c of all) {
    out.set(c, p);
    p += c.length;
  }
  return out;
}

/**
 * Tạo gói IPA nhị phân mẫu hoàn chỉnh để kiểm thử thực tế.
 * @returns {Uint8Array}
 */
export function createSampleIpaBytes() {
  const infoPlistBytes = encodeSimpleBinaryPlist({
    CFBundleDisplayName: 'Ứng dụng Mẫu Kiểm thử',
    CFBundleName: 'SampleApp',
    CFBundleIdentifier: 'vn.ipainstaller.sampleapp',
    CFBundleShortVersionString: '2.4.1',
    CFBundleVersion: '2410',
    CFBundleExecutable: 'SampleApp',
    MinimumOSVersion: '15.0',
    UIDeviceFamily: [1, 2],
    UIFileSharingEnabled: true,
    CFBundleIconFiles: ['AppIcon60x60'],
    NSCameraUsageDescription: 'Chụp mã QR cấu hình thiết bị',
    NSLocalNetworkUsageDescription: 'Kết nối máy chủ nội bộ kiểm thử'
  });

  const widgetPlistBytes = encodeSimpleBinaryPlist({
    CFBundleDisplayName: 'Tiện ích Màn hình chính',
    CFBundleIdentifier: 'vn.ipainstaller.sampleapp.widget',
    CFBundleShortVersionString: '2.4.1',
    CFBundleVersion: '2410',
    NSExtension: {
      NSExtensionPointIdentifier: 'com.apple.widgetkit-extension'
    }
  });

  const iconCgBI = createSampleCgBIPng(64, 64);
  const fatMachO = createSampleFatMachO();
  const mobileProvision = createSampleMobileProvision();
  const codeResources = utf8Encoder.encode('<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict><key>files</key><dict/></dict></plist>');

  return packZipStored([
    { name: 'Payload/SampleApp.app/Info.plist', data: infoPlistBytes },
    { name: 'Payload/SampleApp.app/AppIcon60x60@3x.png', data: iconCgBI },
    { name: 'Payload/SampleApp.app/SampleApp', data: fatMachO },
    { name: 'Payload/SampleApp.app/embedded.mobileprovision', data: mobileProvision },
    { name: 'Payload/SampleApp.app/_CodeSignature/CodeResources', data: codeResources },
    { name: 'Payload/SampleApp.app/Frameworks/CoreHelper.framework/Info.plist', data: codeResources },
    { name: 'Payload/SampleApp.app/PlugIns/QuickWidget.appex/Info.plist', data: widgetPlistBytes }
  ]);
}

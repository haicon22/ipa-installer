/**
 * Bộ sinh biểu tượng PNG cho PWA + Kiểm thử tự động toàn diện các bộ giải mã nhị phân Giai đoạn 2:
 * 1. Tạo các icon PNG chuẩn (180x180, 192x192, 512x512) nếu chưa có trong pwa/icons/
 * 2. Kiểm thử ZIP Deflate (nén thật bằng node:zlib deflateRaw!) + Stored + chống Zip Slip
 * 3. Kiểm thử Apple Binary Plist (bplist00) & XML Plist (bao gồm thẻ rỗng <string></string>)
 * 4. Kiểm thử Apple Crushed PNG (CgBI BGRA -> Standard RGBA PNG) và xác minh từng byte màu pixel!
 * 5. Kiểm thử Fat Mach-O 64-bit (arm64 + arm64e, LC_BUILD_VERSION, FairPlay cryptid, CodeSignature SuperBlob)
 * 6. Kiểm thử CMS embedded.mobileprovision & X.509 DER (Subject CN, Serial, OCSP URL, hạn 7 ngày)
 * 7. Kiểm thử tạo báo cáo Markdown & JSON hoàn chỉnh
 */
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import zlib from 'node:zlib';
import { fileURLToPath } from 'node:url';

import { crc32, inflateRaw, packZlibStored } from '../pwa/js/parsers/deflate.js';
import { indexZipArchive, extractZipEntry, isUnsafeZipPath } from '../pwa/js/parsers/zip-slice.js';
import { parsePlist, parseXmlPlist } from '../pwa/js/parsers/plist.js';
import { normalizeApplePng } from '../pwa/js/parsers/cgbi-png.js';
import { analyzeIpaBlob } from '../pwa/js/parsers/analyzer.js';
import { generateMarkdownReport, generateJsonReport } from '../pwa/js/report.js';
import { createSampleIpaBytes } from '../pwa/js/sample-ipa.js';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const rootDir = path.resolve(__dirname, '..');
const iconsDir = path.join(rootDir, 'pwa', 'icons');

function generateAppIconPng(size) {
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

  const ihdr = new Uint8Array(13);
  const dv = new DataView(ihdr.buffer);
  dv.setUint32(0, size, false);
  dv.setUint32(4, size, false);
  ihdr[8] = 8;
  ihdr[9] = 6; // RGBA

  const raw = new Uint8Array(size * (1 + size * 4));
  const cx = size / 2;
  const cy = size / 2;

  for (let y = 0; y < size; y++) {
    const rowOff = y * (1 + size * 4);
    raw[rowOff] = 0;
    const ny = y / size;
    for (let x = 0; x < size; x++) {
      const nx = x / size;
      const p = rowOff + 1 + x * 4;
      // Nền gradient xanh iOS hiện đại
      let r = Math.round(8 + nx * 24);
      let g = Math.round(92 + (1 - ny) * 105);
      let b = Math.round(215 + (1 - ny) * 38);

      // Vẽ biểu tượng hộp gói IPA + mũi tên trắng sắc nét ở trung tâm
      const dx = Math.abs(x - cx) / size;
      const dy = (y - cy) / size;
      const inBox =
        dx <= 0.27 &&
        dy >= -0.02 &&
        dy <= 0.27 &&
        (dx >= 0.215 || dy >= 0.215 || (dy <= 0.035 && dx >= 0.11));
      const inShaft = dx <= 0.042 && dy >= -0.28 && dy <= 0.11;
      const inArrowHead =
        dy >= -0.04 &&
        dy <= 0.14 &&
        dx <= (0.15 - (dy + 0.04) * 0.78) &&
        dx >= Math.max(0, 0.07 - (dy + 0.04) * 0.78);

      if (inBox || inShaft || inArrowHead) {
        r = 255;
        g = 255;
        b = 255;
      }

      raw[p] = r;
      raw[p + 1] = g;
      raw[p + 2] = b;
      raw[p + 3] = 255;
    }
  }

  const compressed = zlib.deflateSync(raw, { level: 9 });
  const parts = [
    sig,
    makeChunk('IHDR', ihdr),
    makeChunk('IDAT', new Uint8Array(compressed)),
    makeChunk('IEND', new Uint8Array(0))
  ];
  const total = parts.reduce((s, c) => s + c.length, 0);
  const out = new Uint8Array(total);
  let offset = 0;
  for (const c of parts) {
    out.set(c, offset);
    offset += c.length;
  }
  return out;
}

async function runAllTests() {
  console.log('1. Đang tạo bộ biểu tượng PWA chuẩn (180, 192, 512)...');
  fs.mkdirSync(iconsDir, { recursive: true });
  for (const [file, sz] of [
    ['apple-touch-icon.png', 180],
    ['icon-192.png', 192],
    ['icon-512.png', 512]
  ]) {
    const outPath = path.join(iconsDir, file);
    if (!fs.existsSync(outPath)) {
      fs.writeFileSync(outPath, generateAppIconPng(sz));
    }
    assert.ok(fs.statSync(outPath).size > 500, `Icon ${file} phải có dữ liệu hợp lệ`);
  }

  console.log('2. Đang kiểm thử bộ giải nén RFC 1951 Dynamic Huffman Deflate...');
  const sampleText = Buffer.from(
    'Kiểm thử nén Dynamic Huffman thực tế từ zlib cho IPA Installer trên Safari iOS 15 -> iOS 26.6! '.repeat(120),
    'utf8'
  );
  const deflated = new Uint8Array(zlib.deflateRawSync(sampleText, { level: 9 }));
  const inflated = inflateRaw(deflated, sampleText.length);
  assert.deepEqual(Buffer.from(inflated), sampleText, 'Giải nén Dynamic Huffman phải khớp từng byte');

  // Kiểm thử giới hạn maxOutputBytes (đọc cắt lát đầu file thực thi lớn)
  const partial = inflateRaw(deflated, 0, 64);
  assert.equal(partial.length, 64);
  assert.deepEqual(Buffer.from(partial), sampleText.subarray(0, 64));

  console.log('3. Đang kiểm thử XML Plist (gồm cả chuỗi rỗng, mảng, số nguyên, tiếng Việt)...');
  const xmlParsed = parseXmlPlist(`<?xml version="1.0" encoding="UTF-8"?>
  <plist version="1.0">
    <dict>
      <key>EmptyStr</key><string></string>
      <key>AppName</key><string>Ứng dụng &amp; Công cụ</string>
      <key>Build</key><integer>2606</integer>
      <key>Enabled</key><true/>
    </dict>
  </plist>`);
  assert.equal(xmlParsed.EmptyStr, '');
  assert.equal(xmlParsed.AppName, 'Ứng dụng & Công cụ');
  assert.equal(xmlParsed.Build, 2606);
  assert.equal(xmlParsed.Enabled, true);

  console.log('4. Đang kiểm thử chống tấn công Zip Slip...');
  assert.equal(isUnsafeZipPath('../../etc/passwd'), true);
  assert.equal(isUnsafeZipPath('/private/var/mobile/test'), true);
  assert.equal(isUnsafeZipPath('Payload/SampleApp.app/Info.plist'), false);

  console.log('5. Đang kiểm thử phân tích toàn diện gói IPA nhị phân mẫu (bplist00 + CgBI + Fat Mach-O + CMS)...');
  const ipaBytes = createSampleIpaBytes();
  const ipaBlob = new Blob([ipaBytes], { type: 'application/octet-stream' });

  const stages = [];
  const report = await analyzeIpaBlob(ipaBlob, {
    fileName: 'SampleApp-Test.ipa',
    hostIosVersion: '26.6',
    onProgress: (p) => stages.push(p.percent)
  });

  assert.equal(report.app.displayName, 'Ứng dụng Mẫu Kiểm thử');
  assert.equal(report.app.bundleId, 'vn.ipainstaller.sampleapp');
  assert.equal(report.app.version, '2.4.1');
  assert.equal(report.app.buildNumber, '2410');
  assert.equal(report.app.minimumOSVersion, '15.0');
  assert.equal(report.app.plistFormat, 'binary (bplist00)');
  assert.equal(report.app.permissions.length, 2);

  // Kiểm chứng CgBI PNG đã được khôi phục thành PNG chuẩn có luồng zlib hợp lệ!
  assert.ok(report.icon.dataUrl && report.icon.dataUrl.startsWith('data:image/png;base64,'));
  assert.equal(report.icon.meta.wasCgBI, true);
  assert.equal(report.icon.meta.width, 64);
  assert.equal(report.icon.meta.height, 64);
  const restoredPng = Buffer.from(report.icon.dataUrl.split(',')[1], 'base64');
  assert.equal(restoredPng.includes(Buffer.from('CgBI')), false, 'Ảnh đầu ra không được còn chunk CgBI');
  // Giải nén ngược lại chunk IDAT bằng zlib chuẩn của Node.js để chứng minh PNG chuẩn 100%
  const idatIdx = restoredPng.indexOf(Buffer.from('IDAT'));
  const idatLen = restoredPng.readUInt32BE(idatIdx - 4);
  const idatPayload = restoredPng.subarray(idatIdx + 4, idatIdx + 4 + idatLen);
  const decodedPixels = zlib.inflateSync(idatPayload);
  assert.equal(decodedPixels.length, 64 * (1 + 64 * 4));
  // Pixel đầu tiên ở (0,0): R=15, G=110, B=245, A=255 (đã đảo đúng từ BGRA sang RGBA!)
  assert.equal(decodedPixels[1], 15, 'Kênh Red phải được khôi phục đúng từ BGRA');
  assert.equal(decodedPixels[2], 110, 'Kênh Green phải đúng');
  assert.equal(decodedPixels[3], 245, 'Kênh Blue phải được khôi phục đúng từ BGRA');
  assert.equal(decodedPixels[4], 255, 'Kênh Alpha phải bằng 255');

  // Kiểm chứng nhị phân Fat Mach-O & CodeSignature
  assert.equal(report.binary.isFat, true);
  assert.deepEqual(report.binary.architectures, ['arm64', 'arm64e']);
  assert.equal(report.binary.isFairPlayEncrypted, false);
  assert.equal(report.binary.frameworks.length, 1);
  assert.equal(report.binary.plugins.length, 1);
  assert.equal(report.binary.plugins[0].bundleId, 'vn.ipainstaller.sampleapp.widget');
  assert.equal(report.signature.codeSignature.signingIdentifier, 'vn.ipainstaller.sampleapp');
  assert.equal(report.signature.codeSignature.teamIdentifier, 'TEAM99DEMO');
  assert.equal(report.signature.codeSignature.hashType, 'SHA-256');

  // Kiểm chứng Provisioning Profile & Chứng chỉ X.509 + OCSP
  const prov = report.signature.provisioning;
  assert.ok(prov && !prov.parseError);
  assert.equal(prov.distributionType, 'Development (Apple Personal Team – Hạn 7 ngày)');
  assert.equal(prov.supportsOTA, false);
  assert.equal(prov.provisionedDevicesCount, 1);
  assert.equal(prov.certificates.length, 1);
  assert.equal(
    prov.certificates[0].commonName,
    'Apple Development: demo@ipainstaller.local (TEAM99DEMO)'
  );
  assert.equal(prov.certificates[0].ocspUrls[0], 'http://ocsp.apple.com/ocsp03-wwdrg3');

  // Kiểm chứng bộ đếm hạn ngạch Personal Team (1 app chính + 1 widget extension = 2 App IDs)
  assert.equal(report.personalTeamAssessment.appIdsWithExtensions, 2);
  assert.equal(report.personalTeamAssessment.appIdsWithoutExtensions, 1);
  assert.ok(
    report.personalTeamAssessment.restrictedEntitlementsFound.some(
      (e) => e.key === 'aps-environment'
    ),
    'Phải phát hiện quyền trả phí aps-environment'
  );

  // Kiểm chứng xuất báo cáo Markdown & JSON
  const md = generateMarkdownReport(report);
  const js = JSON.parse(generateJsonReport(report));
  assert.ok(md.includes('vn.ipainstaller.sampleapp'));
  assert.equal(js.app.bundleId, 'vn.ipainstaller.sampleapp');
  assert.ok(stages.includes(100));

  console.log('\nTẤT CẢ BÀI KIỂM THỬ NHỊ PHÂN GIAI ĐOẠN 2 ĐỀU ĐẠT 100%!');
}

runAllTests().catch((err) => {
  console.error('KIỂM THỬ THẤT BẠI:', err);
  process.exit(1);
});

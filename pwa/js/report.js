/**
 * Bộ xuất báo cáo kỹ thuật chi tiết (.md / .json) cho từng gói IPA đã phân tích.
 */

export function formatBytes(bytes) {
  if (typeof bytes !== 'number' || Number.isNaN(bytes) || bytes < 0) return '0 B';
  if (bytes < 1024) return `${bytes} B`;
  const units = ['KB', 'MB', 'GB', 'TB'];
  let val = bytes / 1024;
  let u = 0;
  while (val >= 1024 && u < units.length - 1) {
    val /= 1024;
    u++;
  }
  return `${val.toFixed(val >= 100 ? 0 : val >= 10 ? 1 : 2)} ${units[u]}`;
}

export function generateMarkdownReport(r) {
  const lines = [];
  lines.push(`# BÁO CÁO PHÂN TÍCH GÓI ỨNG DỤNG IPA: ${r.app.displayName}`);
  lines.push('');
  lines.push(`- **Thời điểm phân tích**: ${r.analyzedAt}`);
  lines.push(`- **Tệp nguồn**: \`${r.file.name}\` (${formatBytes(r.file.compressedSize)} nén / ${formatBytes(r.file.uncompressedSize)} giải nén)`);
  lines.push(`- **Thời gian xử lý**: ${r.durationMs} ms`);
  lines.push('');

  lines.push('## 1. Thông tin định danh ứng dụng (`Info.plist`)');
  lines.push(`- **Tên hiển thị**: ${r.app.displayName}`);
  lines.push(`- **Bundle Identifier**: \`${r.app.bundleId}\``);
  lines.push(`- **Phiên bản**: \`${r.app.version}\` (Build \`${r.app.buildNumber}\`)`);
  lines.push(`- **iOS tối thiểu (\`MinimumOSVersion\`)**: iOS ${r.app.minimumOSVersion || 'Không rõ'}`);
  lines.push(`- **SDK biên dịch**: ${r.app.sdkVersion || 'Không rõ'} (${r.app.platform})`);
  lines.push(`- **Định dạng Plist gốc**: ${r.app.plistFormat}`);
  lines.push(`- **Thiết bị hỗ trợ**: ${r.app.supportedDevices.join(', ') || 'Mặc định'}`);
  lines.push(`- **Chia sẻ tệp qua ứng dụng Tệp/iTunes**: ${r.app.uiFileSharingEnabled ? 'Có' : 'Không'}`);
  if (r.icon?.meta) {
    lines.push(`- **Biểu tượng**: \`${r.icon.meta.sourcePath}\` (${r.icon.meta.width}x${r.icon.meta.height}, nén Apple CgBI: ${r.icon.meta.wasCgBI ? 'Có — đã khôi phục RGBA' : 'Không'})`);
  }
  lines.push('');

  lines.push('## 2. Phân tích nhị phân `Mach-O` & Cấu trúc gói');
  if (r.binary) {
    lines.push(`- **Kiến trúc CPU**: \`${r.binary.architectures.join(', ')}\` (${r.binary.isFat ? 'Fat/Universal Binary' : 'Thin Binary'})`);
    lines.push(`- **UUID thực thi**: \`${r.binary.uuid || 'Không có'}\``);
    lines.push(`- **Mã hóa DRM FairPlay App Store**: ${r.binary.isFairPlayEncrypted ? '**CÓ (cryptid = 1 — BỊ KHÓA DRM)**' : 'Không (cryptid = 0 — Đã giải mã / Sẵn sàng ký)'}`);
    lines.push(`- **Frameworks đi kèm (${r.binary.frameworks.length})**: ${r.binary.frameworks.join(', ') || 'Không có'}`);
    lines.push(`- **App Extensions / PlugIns (${r.binary.plugins.length})**: ${r.binary.plugins.map((p) => `${p.name} (\`${p.bundleId || p.folder}\`)`).join(', ') || 'Không có'}`);
    lines.push(`- **Thư viện động tùy chỉnh tiêm vào (${r.binary.injectedDylibs.length})**: ${r.binary.injectedDylibs.join(', ') || 'Không có'}`);
  } else {
    lines.push('- Không tìm thấy nhị phân Mach-O hợp lệ.');
  }
  lines.push('');

  lines.push('## 3. Chữ ký số & `embedded.mobileprovision`');
  lines.push(`- **Trạng thái chữ ký**: ${r.signature.summaryVi}`);
  if (r.signature.codeSignature) {
    const cs = r.signature.codeSignature;
    lines.push(`- **CodeDirectory**: Hash \`${cs.hashType}\`, Signing ID \`${cs.signingIdentifier || 'N/A'}\`, Team ID \`${cs.teamIdentifier || 'N/A'}\`, Ad-Hoc flag: \`${cs.isAdHocSigned}\``);
  }
  const prov = r.signature.provisioning;
  if (prov && !prov.parseError) {
    lines.push(`- **Tên Profile**: ${prov.name} (\`${prov.distributionType}\`)`);
    lines.push(`- **Nhà phát triển / Team**: ${prov.teamName || 'N/A'} (\`${prov.teamIdentifiers.join(', ')}\`)`);
    lines.push(`- **Hạn sử dụng Profile**: ${prov.expirationDate || 'N/A'} (${prov.isExpired ? 'ĐÃ HẾT HẠN' : `còn ${prov.daysRemaining} ngày`})`);
    lines.push(`- **Số lượng UDID đăng ký**: ${prov.provisionsAllDevices ? 'Tất cả thiết bị (Enterprise)' : prov.provisionedDevicesCount}`);
    if (prov.certificates && prov.certificates.length > 0) {
      for (const cert of prov.certificates) {
        lines.push(`- **Chứng chỉ X.509**: \`${cert.commonName}\` | Serial \`${cert.serialNumber}\` | Cấp bởi \`${cert.issuerCommonName}\` | OCSP: ${cert.ocspUrls.join(', ') || 'Mặc định'}`);
      }
    }
  }
  lines.push('');

  lines.push('## 4. Đánh giá hạn ngạch Apple Personal Team (0 đồng)');
  const pt = r.personalTeamAssessment;
  lines.push(`- **Khả năng ký bằng tài khoản miễn phí**: ${pt.canSignWithFreeAccount ? 'Khả thi' : 'Bị chặn (xem mục lỗi bên dưới)'}`);
  lines.push(`- **Tiêu tốn App ID (nếu giữ nguyên PlugIns)**: **${pt.appIdsWithExtensions}/${pt.weeklyQuotaLimit}** App ID trong 7 ngày`);
  lines.push(`- **Tiêu tốn App ID (nếu gỡ PlugIns phụ)**: **${pt.appIdsWithoutExtensions}/${pt.weeklyQuotaLimit}** App ID`);
  if (pt.restrictedEntitlementsFound.length > 0) {
    lines.push(`- **Quyền trả phí sẽ bị lược bỏ khi ký miễn phí**: ${pt.restrictedEntitlementsFound.map((e) => `${e.label} (\`${e.key}\`)`).join(', ')}`);
  }
  lines.push('');

  lines.push('## 5. Cảnh báo & Chẩn đoán tương thích');
  if (r.compatibility.blockers.length === 0 && r.compatibility.warnings.length === 0) {
    lines.push('- Không phát hiện xung đột kỹ thuật.');
  } else {
    for (const b of r.compatibility.blockers) lines.push(`- **[CHẶN]** ${b}`);
    for (const w of r.compatibility.warnings) lines.push(`- **[LƯU Ý]** ${w}`);
  }
  lines.push('');

  lines.push('## 6. Danh sách Entitlements trích xuất');
  lines.push('```json');
  lines.push(JSON.stringify(r.signature.entitlements || {}, null, 2));
  lines.push('```');
  return lines.join('\n');
}

export function generateJsonReport(record) {
  // Lược bỏ chuỗi base64 ảnh quá dài nếu người dùng xuất JSON kỹ thuật gọn sạch
  const clone = structuredClone(record);
  if (clone.icon && clone.icon.dataUrl) {
    clone.icon.dataUrlPreviewLength = clone.icon.dataUrl.length;
    delete clone.icon.dataUrl;
  }
  return JSON.stringify(clone, null, 2);
}

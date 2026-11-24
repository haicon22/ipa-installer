/**
 * Bộ điều phối phân tích toàn diện gói .ipa (chạy trong Web Worker hoặc Node.js)
 * Phân tách rõ ràng: Phân tích thực tế cấu trúc nhị phân — không giả lập cài đặt.
 */
import { indexZipArchive, extractZipEntry, extractEntryRange } from './zip-slice.js';
import { parsePlist } from './plist.js';
import { normalizeApplePng, extractEmbeddedPngFromCar } from './cgbi-png.js';
import { parseMachOHeader, parseCodeSignatureBlob } from './macho.js';
import { parseMobileProvision } from './provision.js';

const FREE_PERSONAL_RESTRICTED_ENTITLEMENTS = [
  { key: 'aps-environment', label: 'Thông báo đẩy (Push Notifications)' },
  { key: 'com.apple.developer.applesignin', label: 'Đăng nhập bằng Apple (Sign in with Apple)' },
  { key: 'com.apple.developer.icloud-services', label: 'Dịch vụ iCloud nâng cao' },
  { key: 'com.apple.developer.ubiquity-kvstore-identifier', label: 'iCloud Key-Value Store' },
  { key: 'com.apple.developer.associated-domains', label: 'Associated Domains (Universal Links)' },
  { key: 'com.apple.developer.networking.networkextension', label: 'Network Extension (VPN / Filter)' },
  { key: 'com.apple.developer.networking.vpn.api', label: 'Personal VPN API' },
  { key: 'com.apple.developer.in-app-payments', label: 'Apple Pay' },
  { key: 'com.apple.developer.siri', label: 'Tích hợp SiriKit' },
  { key: 'com.apple.developer.healthkit', label: 'HealthKit' },
  { key: 'com.apple.external-accessory.wireless-configuration', label: 'Cấu hình phụ kiện không dây' }
];

const PERMISSION_LABELS_VI = {
  NSCameraUsageDescription: 'Máy ảnh (Camera)',
  NSMicrophoneUsageDescription: 'Micrô thu âm',
  NSPhotoLibraryUsageDescription: 'Thư viện Ảnh',
  NSPhotoLibraryAddUsageDescription: 'Lưu ảnh vào Thư viện',
  NSLocationWhenInUseUsageDescription: 'Vị trí khi đang dùng ứng dụng',
  NSLocationAlwaysAndWhenInUseUsageDescription: 'Vị trí luôn luôn ( chạy nền )',
  NSFaceIDUsageDescription: 'Nhận diện khuôn mặt (Face ID)',
  NSContactsUsageDescription: 'Danh bạ',
  NSCalendarsUsageDescription: 'Lịch',
  NSBluetoothAlwaysUsageDescription: 'Bluetooth',
  NSLocalNetworkUsageDescription: 'Mạng cục bộ (Local Network)',
  NSUserTrackingUsageDescription: 'Theo dõi quảng cáo (ATT)',
  NSAppleMusicUsageDescription: 'Thư viện Nhạc / Media'
};

function bytesToBase64(bytes) {
  if (typeof btoa === 'function') {
    let binary = '';
    const chunkSize = 0x8000;
    for (let i = 0; i < bytes.length; i += chunkSize) {
      const sub = bytes.subarray(i, i + chunkSize);
      binary += String.fromCharCode.apply(null, sub);
    }
    return btoa(binary);
  }
  return Buffer.from(bytes).toString('base64');
}

function compareVersions(vA, vB) {
  if (!vA || !vB) return 0;
  const a = String(vA).split('.').map((n) => parseInt(n, 10) || 0);
  const b = String(vB).split('.').map((n) => parseInt(n, 10) || 0);
  const len = Math.max(a.length, b.length);
  for (let i = 0; i < len; i++) {
    const da = a[i] || 0;
    const db = b[i] || 0;
    if (da > db) return 1;
    if (da < db) return -1;
  }
  return 0;
}

function collectIconCandidatesFromPlist(info) {
  const names = [];
  const pushList = (arr) => {
    if (Array.isArray(arr)) {
      for (const item of arr) {
        if (typeof item === 'string' && item.trim()) names.push(item.trim());
      }
    }
  };
  if (info.CFBundleIcons && info.CFBundleIcons.CFBundlePrimaryIcon) {
    const prim = info.CFBundleIcons.CFBundlePrimaryIcon;
    pushList(prim.CFBundleIconFiles);
    if (typeof prim.CFBundleIconName === 'string') names.push(prim.CFBundleIconName);
  }
  if (info['CFBundleIcons~ipad'] && info['CFBundleIcons~ipad'].CFBundlePrimaryIcon) {
    pushList(info['CFBundleIcons~ipad'].CFBundlePrimaryIcon.CFBundleIconFiles);
  }
  pushList(info.CFBundleIconFiles);
  if (typeof info.CFBundleIconFile === 'string') names.push(info.CFBundleIconFile);
  return [...new Set(names)];
}

function selectBestIconEntry(appEntries, appPrefix, candidateStems) {
  const pngEntries = appEntries.filter((e) => {
    if (e.isDirectory) return false;
    const rel = e.name.slice(appPrefix.length);
    if (rel.includes('/')) return false; // Chỉ lấy icon ở thư mục gốc của .app
    return rel.toLowerCase().endsWith('.png');
  });

  if (pngEntries.length === 0) return null;

  let matched = [];
  for (const stem of candidateStems) {
    const lowerStem = stem.toLowerCase();
    for (const e of pngEntries) {
      const base = e.name.slice(appPrefix.length).toLowerCase();
      if (base.startsWith(lowerStem)) matched.push(e);
    }
  }
  if (matched.length === 0) {
    matched = pngEntries.filter((e) =>
      /icon|appicon/i.test(e.name.slice(appPrefix.length))
    );
  }
  const pool = matched.length > 0 ? matched : pngEntries;
  // Ưu tiên file có dung lượng không nén lớn nhất (thường là @3x / 180x180 hoặc 1024x1024)
  pool.sort((a, b) => b.uncompressedSize - a.uncompressedSize);
  return pool[0];
}

/**
 * Phân tích toàn bộ một gói Blob/File .ipa.
 * @param {Blob|File} blob
 * @param {object} [options]
 * @param {string} [options.fileName]
 * @param {string} [options.hostIosVersion] Phiên bản iOS của máy đang mở (nếu phát hiện được)
 * @param {(progress: { percent: number, stage: string }) => void} [options.onProgress]
 */
export async function analyzeIpaBlob(blob, options = {}) {
  const startTime = Date.now();
  const fileName = options.fileName || blob.name || 'unknown.ipa';
  const hostIosVersion = options.hostIosVersion || null;
  const reportProgress = (percent, stage) => {
    if (typeof options.onProgress === 'function') {
      options.onProgress({ percent, stage });
    }
  };

  reportProgress(10, 'Đang đọc mục lục ZIP (Central Directory)...');
  const zipMeta = await indexZipArchive(blob);

  // Tìm thư mục ứng dụng chính Payload/<AppName>.app/
  let appPrefix = null;
  for (const e of zipMeta.entries) {
    const m = /^Payload\/([^/]+\.app)\//.exec(e.name);
    if (m) {
      appPrefix = `Payload/${m[1]}/`;
      break;
    }
  }

  if (!appPrefix) {
    throw new Error('Không tìm thấy cấu trúc "Payload/*.app/" hợp lệ bên trong tệp IPA.');
  }

  const appEntries = zipMeta.entries.filter((e) => e.name.startsWith(appPrefix));
  let totalUncompressedBytes = 0;
  for (const e of zipMeta.entries) {
    totalUncompressedBytes += e.uncompressedSize || 0;
  }

  // Thống kê Frameworks, PlugIns (.appex), dylibs và dấu vết FairPlay (SC_Info/*.sinf)
  const frameworkSet = new Set();
  const pluginPrefixes = new Set();
  const bundledDylibs = [];
  let hasSinfMetadata = false;
  let hasCodeResources = false;

  for (const e of appEntries) {
    const rel = e.name.slice(appPrefix.length);
    if (rel === '_CodeSignature/CodeResources') hasCodeResources = true;
    if (/^SC_Info\/.+\.sinf$/i.test(rel)) hasSinfMetadata = true;

    const fwMatch = /^Frameworks\/([^/]+\.framework)\//.exec(rel);
    if (fwMatch) frameworkSet.add(fwMatch[1]);

    const dylibMatch = /^Frameworks\/([^/]+\.dylib)$/i.exec(rel);
    if (dylibMatch) bundledDylibs.push(`Frameworks/${dylibMatch[1]}`);
    else if (!rel.includes('/') && rel.toLowerCase().endsWith('.dylib')) {
      bundledDylibs.push(rel);
    }

    const plugMatch = /^PlugIns\/([^/]+\.appex)\//.exec(rel);
    if (plugMatch) pluginPrefixes.add(`${appPrefix}PlugIns/${plugMatch[1]}/`);
  }

  // Bước 2: Đọc và giải mã Info.plist
  reportProgress(30, 'Đang giải mã Info.plist (Binary/XML)...');
  const infoEntry = appEntries.find((e) => e.name === `${appPrefix}Info.plist`);
  if (!infoEntry) {
    throw new Error(`Thiếu tệp "${appPrefix}Info.plist" bên trong gói ứng dụng.`);
  }

  const infoBytes = await extractZipEntry(blob, infoEntry, { verifyCrc: true });
  const parsedInfo = parsePlist(infoBytes);
  const info = parsedInfo.data || {};

  const displayName =
    info.CFBundleDisplayName ||
    info.CFBundleName ||
    info.CFBundleExecutable ||
    appPrefix.slice('Payload/'.length, -5);
  const bundleId = info.CFBundleIdentifier || '(Không có Bundle ID)';
  const version = info.CFBundleShortVersionString || info.CFBundleVersion || '0.0';
  const buildNumber = info.CFBundleVersion || '0';
  const executableName = info.CFBundleExecutable || null;
  const minimumOSVersion = info.MinimumOSVersion || null;
  const deviceFamiliesRaw = Array.isArray(info.UIDeviceFamily) ? info.UIDeviceFamily : [];
  const supportedDevices = deviceFamiliesRaw.map((f) => {
    if (f === 1) return 'iPhone / iPod touch';
    if (f === 2) return 'iPad';
    if (f === 3) return 'Apple TV';
    if (f === 4) return 'Apple Watch';
    if (f === 6) return 'Mac (Designed for iPad)';
    if (f === 7) return 'Apple Vision';
    return `Thiết bị (${f})`;
  });

  const permissions = [];
  for (const [key, label] of Object.entries(PERMISSION_LABELS_VI)) {
    if (typeof info[key] === 'string') {
      permissions.push({ key, label, reason: info[key] });
    }
  }

  const urlSchemes = [];
  if (Array.isArray(info.CFBundleURLTypes)) {
    for (const item of info.CFBundleURLTypes) {
      if (item && Array.isArray(item.CFBundleURLSchemes)) {
        for (const s of item.CFBundleURLSchemes) {
          if (typeof s === 'string' && s) urlSchemes.push(s);
        }
      }
    }
  }

  // Phân tích chi tiết từng App Extension (.appex) trong PlugIns/
  const plugins = [];
  for (const plugPrefix of pluginPrefixes) {
    const plugFolder = plugPrefix.slice(`${appPrefix}PlugIns/`.length, -1);
    const plugInfoEntry = appEntries.find((e) => e.name === `${plugPrefix}Info.plist`);
    let plugBundleId = null;
    let plugName = plugFolder.replace(/\.appex$/i, '');
    let extensionPoint = null;
    if (plugInfoEntry) {
      try {
        const pBytes = await extractZipEntry(blob, plugInfoEntry);
        const pData = parsePlist(pBytes).data || {};
        plugBundleId = pData.CFBundleIdentifier || null;
        plugName = pData.CFBundleDisplayName || pData.CFBundleName || plugName;
        if (pData.NSExtension && pData.NSExtension.NSExtensionPointIdentifier) {
          extensionPoint = pData.NSExtension.NSExtensionPointIdentifier;
        }
      } catch {
        // Bỏ qua nếu Info.plist phụ lỗi
      }
    }
    plugins.push({
      folder: plugFolder,
      name: plugName,
      bundleId: plugBundleId,
      extensionPoint
    });
  }

  // Bước 3: Trích xuất & khôi phục biểu tượng ứng dụng (CgBI -> Standard PNG)
  reportProgress(52, 'Đang trích xuất và khôi phục biểu tượng ứng dụng (CgBI)...');
  let iconDataUrl = null;
  let iconMeta = null;
  const iconStems = collectIconCandidatesFromPlist(info);
  const bestIconEntry = selectBestIconEntry(appEntries, appPrefix, iconStems);

  if (bestIconEntry) {
    try {
      const rawPng = await extractZipEntry(blob, bestIconEntry);
      const norm = normalizeApplePng(rawPng);
      iconDataUrl = `data:image/png;base64,${bytesToBase64(norm.pngBytes)}`;
      iconMeta = {
        sourcePath: bestIconEntry.name.slice(appPrefix.length),
        width: norm.width,
        height: norm.height,
        wasCgBI: norm.wasCgBI
      };
    } catch {
      // Nếu lỗi, thử quét Assets.car bên dưới
    }
  }

  if (!iconDataUrl) {
    const carEntry = appEntries.find(
      (e) => e.name === `${appPrefix}Assets.car` && e.uncompressedSize <= 25 * 1024 * 1024
    );
    if (carEntry) {
      try {
        const carBytes = await extractZipEntry(blob, carEntry);
        const extracted = extractEmbeddedPngFromCar(carBytes);
        if (extracted) {
          iconDataUrl = `data:image/png;base64,${bytesToBase64(extracted.pngBytes)}`;
          iconMeta = {
            sourcePath: 'Assets.car (nhúng bên trong)',
            width: extracted.width,
            height: extracted.height,
            wasCgBI: extracted.wasCgBI
          };
        }
      } catch {
        // Không có PNG nhúng trực tiếp trong Assets.car
      }
    }
  }

  // Bước 4: Phân tích tệp thực thi Mach-O & Chữ ký số
  reportProgress(74, 'Đang phân tích tệp thực thi nhị phân Mach-O & chữ ký số...');
  let machoInfo = null;
  let codeSignatureInfo = null;

  if (executableName) {
    const execEntry = appEntries.find((e) => e.name === `${appPrefix}${executableName}`);
    if (execEntry) {
      // Chỉ đọc tối đa 256 KB đầu của binary để phân tích header & Load Commands
      const headerProbe = await extractZipEntry(blob, execEntry, { maxOutputBytes: 262144 });
      machoInfo = parseMachOHeader(headerProbe, execEntry.uncompressedSize);
      machoInfo.executablePath = `${appPrefix}${executableName}`;
      machoInfo.executableSize = execEntry.uncompressedSize;

      // Tìm lát cắt arm64/arm64e (hoặc lát cắt đầu tiên) để đọc LC_CODE_SIGNATURE
      const primarySlice =
        machoInfo.slices.find((s) => s.arch === 'arm64' || s.arch === 'arm64e') ||
        machoInfo.slices[0];

      if (primarySlice && primarySlice.codeSignature) {
        const cs = primarySlice.codeSignature;
        if (cs.size > 0 && cs.size <= 4 * 1024 * 1024) {
          const sigBytes = await extractEntryRange(blob, execEntry, cs.fileOffset, cs.size);
          if (sigBytes && sigBytes.length >= 12) {
            codeSignatureInfo = parseCodeSignatureBlob(sigBytes);
          }
        }
      }
    }
  }

  // Bước 5: Phân tích embedded.mobileprovision
  reportProgress(90, 'Đang kiểm tra Provisioning Profile & tính tương thích...');
  let provisioning = null;
  const provEntry = appEntries.find((e) => e.name === `${appPrefix}embedded.mobileprovision`);
  if (provEntry) {
    try {
      const provBytes = await extractZipEntry(blob, provEntry);
      provisioning = parseMobileProvision(provBytes);
    } catch (err) {
      provisioning = { parseError: err.message };
    }
  }

  // Bước 6: Tổng hợp đánh giá chữ ký, mã hóa FairPlay và hạn ngạch 0 đồng (Personal Team)
  const primarySlice = machoInfo && machoInfo.slices && machoInfo.slices.length > 0
    ? (machoInfo.slices.find((s) => s.arch === 'arm64' || s.arch === 'arm64e') || machoInfo.slices[0])
    : null;

  const effectiveMinIOS = minimumOSVersion || (primarySlice ? primarySlice.minOS : null);
  const isFairPlayEncrypted = Boolean(primarySlice && primarySlice.isEncrypted);
  const architectures = machoInfo ? machoInfo.architectures : [];
  const hasArm64 = architectures.includes('arm64') || architectures.includes('arm64e');
  const isSimulatorOnly =
    primarySlice?.platform === 'iOS Simulator' ||
    (!hasArm64 && architectures.includes('x86_64'));

  // Tổng hợp danh sách Entitlements từ CodeSignature hoặc Provisioning Profile
  const mergedEntitlements = {
    ...(provisioning && provisioning.entitlements ? provisioning.entitlements : {}),
    ...(codeSignatureInfo && codeSignatureInfo.entitlements ? codeSignatureInfo.entitlements : {})
  };

  const restrictedEntitlementsFound = FREE_PERSONAL_RESTRICTED_ENTITLEMENTS.filter(
    (item) => mergedEntitlements[item.key] !== undefined
  );

  // Phát hiện thư viện tweak được tiêm vào (Mod / Tweaked IPA)
  const injectedDylibs = [];
  if (primarySlice && Array.isArray(primarySlice.dylibs)) {
    for (const d of primarySlice.dylibs) {
      if (
        d.path.startsWith('@executable_path/') ||
        d.path.startsWith('@loader_path/') ||
        /substrate|ellekit|substitute|orion|frida|cycript/i.test(d.path) ||
        (d.path.startsWith('@rpath/') && /\.dylib$/i.test(d.path) && !d.path.includes('libswift'))
      ) {
        injectedDylibs.push(d.path);
      }
    }
  }

  // Đánh giá trạng thái chữ ký hiện tại
  let signatureStatus = 'unsigned';
  let signatureSummaryVi = 'Chưa được ký số (Unsigned IPA) — Cần ký trước khi cài đặt.';

  if (codeSignatureInfo) {
    if (codeSignatureInfo.isAdHocSigned && !codeSignatureInfo.hasCMSBlob) {
      signatureStatus = 'adhoc_ldid';
      signatureSummaryVi = 'Chữ ký giả lập ldid / Ad-Hoc cục bộ (chỉ chạy trên máy Jailbreak/TrollStore, cần ký lại trên iOS chuẩn).';
    } else if (provisioning && !provisioning.parseError) {
      if (provisioning.isExpired) {
        signatureStatus = 'expired';
        signatureSummaryVi = `Chứng chỉ/Profile đính kèm đã hết hạn (${provisioning.distributionType}) — Cần ký lại.`;
      } else {
        signatureStatus = 'signed_valid_time';
        signatureSummaryVi = `Đã ký (${provisioning.distributionType}) — Còn hạn ${provisioning.daysRemaining ?? '?'} ngày.`;
      }
    } else if (codeSignatureInfo.hasCMSBlob) {
      signatureStatus = hasSinfMetadata ? 'appstore_encrypted_or_signed' : 'cms_without_provision';
      signatureSummaryVi = hasSinfMetadata
        ? 'Chữ ký gốc App Store (kèm siêu dữ liệu SC_Info)'
        : 'Có chữ ký CMS nhưng không kèm embedded.mobileprovision';
    }
  }

  // Đánh giá tính tương thích cài đặt tổng thể
  const warnings = [];
  const blockers = [];

  if (isFairPlayEncrypted) {
    blockers.push(
      'Tệp thực thi đang bị khóa mã hóa DRM FairPlay của App Store (cryptid = 1). Nếu ký lại và cài sang iPhone khác ứng dụng sẽ văng ngay khi mở — bắt buộc dùng bản IPA đã giải mã (decrypted).'
    );
  }
  if (!executableName || !machoInfo) {
    blockers.push('Không tìm thấy hoặc không đọc được tệp thực thi Mach-O chính của ứng dụng.');
  } else if (isSimulatorOnly) {
    blockers.push('Gói IPA này được biên dịch cho máy ảo iOS Simulator, không thể cài trên iPhone thật.');
  } else if (!hasArm64) {
    blockers.push(
      `Ứng dụng chỉ chứa kiến trúc cũ (${architectures.join(', ')}), không hỗ trợ iOS 15 – iOS 26 (yêu cầu arm64/arm64e).`
    );
  }

  if (hostIosVersion && effectiveMinIOS && compareVersions(effectiveMinIOS, hostIosVersion) > 0) {
    blockers.push(
      `Ứng dụng yêu cầu tối thiểu iOS ${effectiveMinIOS}, cao hơn phiên bản iOS hiện tại của thiết bị (${hostIosVersion}).`
    );
  }

  if (plugins.length > 0) {
    warnings.push(
      `Gói chứa ${plugins.length} App Extension (.appex). Nếu ký giữ nguyên bằng Apple ID miễn phí (0 đồng), ứng dụng sẽ ngốn ${1 + plugins.length}/10 App ID trong tuần. Khuyến nghị bật "Gỡ PlugIns phụ" khi ký để chỉ tốn 1 App ID.`
    );
  }

  if (restrictedEntitlementsFound.length > 0) {
    warnings.push(
      `Ứng dụng khai báo ${restrictedEntitlementsFound.length} quyền đặc biệt (${restrictedEntitlementsFound.map((e) => e.label).join(', ')}) không được cấp trên tài khoản Apple miễn phí 0 đồng — các quyền này sẽ bị lược bỏ khi ký miễn phí.`
    );
  }

  if (injectedDylibs.length > 0) {
    warnings.push(
      `Phát hiện ${injectedDylibs.length} thư viện động tùy chỉnh được tiêm vào (${injectedDylibs.join(', ')}). Đây có thể là bản IPA đã chỉnh sửa (Mod/Tweak).`
    );
  }

  if (zipMeta.unsafePathsSkipped > 0) {
    warnings.push(
      `Đã tự động chặn ${zipMeta.unsafePathsSkipped} đường dẫn bất thường (nguy cơ Zip Slip) bên trong kho nén.`
    );
  }

  const compatibilityVerdict = blockers.length > 0
    ? 'incompatible'
    : warnings.length > 0
      ? 'compatible_with_notes'
      : 'fully_compatible';

  reportProgress(100, 'Hoàn tất phân tích!');

  return {
    id: `${bundleId}@${version}+${buildNumber}_${blob.size}`,
    analyzedAt: new Date().toISOString(),
    durationMs: Date.now() - startTime,
    file: {
      name: fileName,
      compressedSize: blob.size,
      uncompressedSize: totalUncompressedBytes,
      totalEntries: zipMeta.entries.length,
      isZip64: zipMeta.isZip64,
      appFolderPath: appPrefix
    },
    app: {
      displayName,
      bundleId,
      version,
      buildNumber,
      executableName,
      minimumOSVersion: effectiveMinIOS,
      sdkVersion: primarySlice?.sdkVersion || info.DTPlatformVersion || null,
      platform: primarySlice?.platform || info.DTPlatformName || 'iOS',
      plistFormat: parsedInfo.format,
      supportedDevices,
      urlSchemes,
      permissions,
      uiFileSharingEnabled: Boolean(info.UIFileSharingEnabled || info.LSSupportsOpeningDocumentsInPlace)
    },
    icon: {
      dataUrl: iconDataUrl,
      meta: iconMeta
    },
    binary: machoInfo
      ? {
          isFat: machoInfo.isFat,
          architectures,
          executableSize: machoInfo.executableSize,
          uuid: primarySlice?.uuid || null,
          isPIE: Boolean(primarySlice?.isPIE),
          isFairPlayEncrypted,
          cryptId: primarySlice?.cryptId ?? 0,
          hasSinfMetadata,
          hasCodeResources,
          linkedDylibs: primarySlice?.dylibs?.map((d) => d.path) || [],
          injectedDylibs,
          rpaths: primarySlice?.rpaths || [],
          frameworks: [...frameworkSet].sort(),
          bundledDylibs: bundledDylibs.sort(),
          plugins
        }
      : null,
    signature: {
      status: signatureStatus,
      summaryVi: signatureSummaryVi,
      codeSignature: codeSignatureInfo,
      provisioning,
      entitlements: mergedEntitlements
    },
    personalTeamAssessment: {
      canSignWithFreeAccount: blockers.length === 0,
      appIdsWithExtensions: 1 + plugins.length,
      appIdsWithoutExtensions: 1,
      weeklyQuotaLimit: 10,
      validityDays: 7,
      maxActiveAppsLimit: 3,
      restrictedEntitlementsFound
    },
    compatibility: {
      verdict: compatibilityVerdict,
      hostIosVersion,
      blockers,
      warnings
    }
  };
}

/**
 * Điều phối giao diện chính của IPA Installer Web (PWA) trên Safari iPhone.
 */
import { analyzeIpaBlob } from './parsers/analyzer.js';
import {
  saveAnalyzedIpa,
  listAnalyzedIpas,
  deleteAnalyzedIpa,
  clearAllAnalyzedIpas
} from './storage.js';
import {
  formatBytes,
  generateMarkdownReport,
  generateJsonReport
} from './report.js';
import { createSampleIpaBytes } from './sample-ipa.js';

const SETTINGS_KEY = 'ipa_installer_pwa_settings_v1';

const state = {
  currentResult: null,
  library: [],
  settings: loadSettings(),
  worker: null,
  requestSeq: 0
};

function detectIosVersionFromUA() {
  const ua = navigator.userAgent || '';
  const m = /OS (\d+)_(\d+)(?:_(\d+))? like Mac OS X/.exec(ua);
  if (!m) return null;
  return m[3] ? `${m[1]}.${m[2]}.${m[3]}` : `${m[1]}.${m[2]}`;
}

function loadSettings() {
  try {
    const raw = localStorage.getItem(SETTINGS_KEY);
    const parsed = raw ? JSON.parse(raw) : {};
    return {
      iosVersion: parsed.iosVersion || detectIosVersionFromUA() || '',
      deviceUdid: parsed.deviceUdid || '',
      theme: parsed.theme || 'auto',
      bannerDismissed: Boolean(parsed.bannerDismissed)
    };
  } catch {
    return {
      iosVersion: detectIosVersionFromUA() || '',
      deviceUdid: '',
      theme: 'auto',
      bannerDismissed: false
    };
  }
}

function persistSettings() {
  try {
    localStorage.setItem(SETTINGS_KEY, JSON.stringify(state.settings));
  } catch {
    // Bỏ qua nếu Safari Private Mode chặn ghi
  }
}

function applyTheme() {
  const root = document.documentElement;
  if (state.settings.theme === 'dark' || state.settings.theme === 'light') {
    root.setAttribute('data-theme', state.settings.theme);
  } else {
    root.removeAttribute('data-theme');
  }
}

function escapeHtml(str) {
  return String(str ?? '')
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;');
}

function updateNetworkBadges() {
  const online = navigator.onLine;
  const dot = document.getElementById('networkDot');
  const badge = document.getElementById('offlineBadge');
  const iosBadge = document.getElementById('iosBadge');

  if (online) {
    dot.classList.remove('offline');
    badge.textContent = 'Sẵn sàng Offline';
  } else {
    dot.classList.add('offline');
    badge.textContent = 'Đang chạy Offline';
  }

  iosBadge.textContent = state.settings.iosVersion
    ? `iOS ${state.settings.iosVersion}`
    : 'Safari PWA';
}

function switchTab(tabName) {
  document.querySelectorAll('.tab-btn').forEach((btn) => {
    const active = btn.dataset.tab === tabName;
    btn.classList.toggle('active', active);
    if (active) {
      document.getElementById('navTitle').textContent = btn.dataset.title;
    }
  });

  document.querySelectorAll('.tab-view').forEach((sec) => {
    sec.classList.toggle('active', sec.id === `tab-${tabName}`);
  });

  if (tabName === 'library') {
    refreshLibraryView();
  }
}

function runAnalysisViaWorkerOrFallback(file) {
  const hostIosVersion = state.settings.iosVersion || null;
  const progressCard = document.getElementById('progressCard');
  const progressStage = document.getElementById('progressStage');
  const progressPercent = document.getElementById('progressPercent');
  const progressBar = document.getElementById('progressBar');
  const errorCard = document.getElementById('errorCard');

  errorCard.classList.add('hidden');
  progressCard.classList.remove('hidden');

  const updateProg = (percent, stage) => {
    progressPercent.textContent = `${percent}%`;
    progressStage.textContent = stage;
    progressBar.style.width = `${percent}%`;
  };
  updateProg(5, 'Đang khởi tạo luồng đọc nhị phân...');

  return new Promise((resolve, reject) => {
    try {
      if (!state.worker && typeof Worker !== 'undefined') {
        state.worker = new Worker(new URL('./analyzer.worker.js', import.meta.url), {
          type: 'module'
        });
      }
    } catch {
      state.worker = null;
    }

    if (!state.worker) {
      analyzeIpaBlob(file, {
        fileName: file.name,
        hostIosVersion,
        onProgress: ({ percent, stage }) => updateProg(percent, stage)
      })
        .then(resolve)
        .catch(reject);
      return;
    }

    const reqId = ++state.requestSeq;
    const handler = (ev) => {
      const msg = ev.data || {};
      if (msg.requestId !== reqId) return;
      if (msg.type === 'progress') {
        updateProg(msg.percent, msg.stage);
      } else if (msg.type === 'done') {
        state.worker.removeEventListener('message', handler);
        resolve(msg.result);
      } else if (msg.type === 'error') {
        state.worker.removeEventListener('message', handler);
        reject(new Error(msg.error || 'Lỗi không xác định trong Web Worker'));
      }
    };

    state.worker.addEventListener('message', handler);
    state.worker.onerror = (errEv) => {
      state.worker.removeEventListener('message', handler);
      state.worker = null;
      // Tự động lùi về luồng chính nếu trình duyệt chặn module worker
      analyzeIpaBlob(file, {
        fileName: file.name,
        hostIosVersion,
        onProgress: ({ percent, stage }) => updateProg(percent, stage)
      })
        .then(resolve)
        .catch(() => reject(new Error(errEv.message || 'Lỗi thực thi Worker')));
    };

    state.worker.postMessage({
      requestId: reqId,
      file,
      fileName: file.name,
      hostIosVersion
    });
  });
}

async function handleSelectedIpaFile(file) {
  if (!file) return;
  const progressCard = document.getElementById('progressCard');
  const errorCard = document.getElementById('errorCard');
  const errorMessage = document.getElementById('errorMessage');

  try {
    const result = await runAnalysisViaWorkerOrFallback(file);
    state.currentResult = result;
    progressCard.classList.add('hidden');
    renderAnalysisResult(result);
    try {
      await saveAnalyzedIpa(result);
    } catch {
      // Vẫn hiển thị kết quả bình thường nếu chế độ ẩn danh khóa IndexedDB
    }
  } catch (err) {
    progressCard.classList.add('hidden');
    errorMessage.textContent = err && err.message ? err.message : String(err);
    errorCard.classList.remove('hidden');
  }
}

function triggerDownloadBlob(blob, filename) {
  const url = URL.createObjectURL(blob);
  const a = document.createElement('a');
  a.href = url;
  a.download = filename;
  document.body.appendChild(a);
  a.click();
  a.remove();
  setTimeout(() => URL.revokeObjectURL(url), 5000);
}

function renderUdidCheckHtml(prov) {
  const userUdid = (state.settings.deviceUdid || '').trim();
  if (!prov || prov.parseError) return '';
  if (prov.provisionsAllDevices) {
    return `<div class="diag-box diag-ok">Profile loại <b>Enterprise (In-House)</b> cho phép mọi thiết bị (không giới hạn UDID).</div>`;
  }
  if (!Array.isArray(prov.provisionedDevices) || prov.provisionedDevices.length === 0) {
    return '';
  }
  if (!userUdid) {
    return `<div class="diag-box diag-warn">Gói IPA này giới hạn cho <b>${prov.provisionedDevicesCount} UDID</b> cụ thể. Bạn có thể nhập UDID máy mình tại mục <b>Thiết lập</b> để tự động đối chiếu.</div>`;
  }
  const matched = prov.provisionedDevices.some(
    (u) => u.toLowerCase() === userUdid.toLowerCase()
  );
  if (matched) {
    return `<div class="diag-box diag-ok"><b>Khớp UDID thiết bị!</b> UDID iPhone của bạn (<code>${escapeHtml(userUdid)}</code>) nằm trong danh sách được cấp phép của Profile này.</div>`;
  }
  return `<div class="diag-box diag-danger"><b>Không khớp UDID!</b> UDID iPhone của bạn (<code>${escapeHtml(userUdid)}</code>) KHÔNG nằm trong ${prov.provisionedDevicesCount} thiết bị của Profile này — bắt buộc ký lại bằng chứng chỉ của máy bạn trước khi cài.</div>`;
}

function renderAnalysisResult(r) {
  const container = document.getElementById('resultContainer');
  container.classList.remove('hidden');

  const initialLetter = escapeHtml((r.app.displayName || 'A').trim().charAt(0).toUpperCase());
  const iconHtml = r.icon && r.icon.dataUrl
    ? `<img src="${r.icon.dataUrl}" alt="Biểu tượng ${escapeHtml(r.app.displayName)}" />`
    : `<span>${initialLetter}</span>`;

  const verdictBadge = r.compatibility.verdict === 'incompatible'
    ? `<span class="badge badge-danger">Có xung đột chặn cài đặt</span>`
    : r.compatibility.verdict === 'compatible_with_notes'
      ? `<span class="badge badge-warn">Tương thích (Cần lưu ý khi ký)</span>`
      : `<span class="badge badge-ok">Tương thích tốt</span>`;

  const fairPlayText = r.binary?.isFairPlayEncrypted
    ? `<span class="badge badge-danger">Khóa FairPlay (cryptid=1)</span>`
    : `<span class="badge badge-ok">Đã giải mã (cryptid=0)</span>`;

  const blockersHtml = r.compatibility.blockers
    .map((b) => `<div class="diag-box diag-danger"><strong>Chặn:</strong> ${escapeHtml(b)}</div>`)
    .join('');

  const warningsHtml = r.compatibility.warnings
    .map((w) => `<div class="diag-box diag-warn"><strong>Lưu ý:</strong> ${escapeHtml(w)}</div>`)
    .join('');

  const prov = r.signature.provisioning;
  const certsHtml = prov && Array.isArray(prov.certificates) && prov.certificates.length > 0
    ? prov.certificates.map((c) => `
      <div class="diag-box ${c.isExpired ? 'diag-danger' : 'diag-ok'}">
        <div><strong>${escapeHtml(c.commonName)}</strong></div>
        <div class="mono" style="font-size:12px;margin-top:4px">
          Serial: ${escapeHtml(c.serialNumber)} | Thuật toán: ${escapeHtml(c.signatureAlgorithm)}<br/>
          Cấp bởi: ${escapeHtml(c.issuerCommonName)}<br/>
          Hết hạn: ${escapeHtml(c.notAfter || 'N/A')} ${c.ocspUrls.length ? `| OCSP: ${escapeHtml(c.ocspUrls[0])}` : ''}
        </div>
      </div>
    `).join('')
    : '';

  const udidListHtml = prov && Array.isArray(prov.provisionedDevices) && prov.provisionedDevices.length > 0
    ? `<details class="ios-details">
        <summary>Xem danh sách ${prov.provisionedDevicesCount} UDID trong Profile</summary>
        <pre class="code-block">${escapeHtml(prov.provisionedDevices.join('\n'))}</pre>
      </details>`
    : '';

  const pluginsHtml = r.binary && r.binary.plugins.length > 0
    ? r.binary.plugins.map((p) =>
        `<span class="tag-chip">${escapeHtml(p.name)} (<code>${escapeHtml(p.bundleId || p.folder)}</code>)</span>`
      ).join('')
    : '<span class="muted-text">Không có App Extension (.appex)</span>';

  const frameworksHtml = r.binary && r.binary.frameworks.length > 0
    ? r.binary.frameworks.map((fw) => `<span class="tag-chip">${escapeHtml(fw)}</span>`).join('')
    : '<span class="muted-text">Không nhúng Framework riêng</span>';

  const permissionsHtml = r.app.permissions.length > 0
    ? `<ul class="kv-list">
        ${r.app.permissions.map((pm) => `<li><span>${escapeHtml(pm.label)}</span><strong>${escapeHtml(pm.reason)}</strong></li>`).join('')}
      </ul>`
    : '<p class="muted-text">Ứng dụng không yêu cầu quyền nhạy cảm đặc biệt trong Info.plist.</p>';

  const entitlementsJson = JSON.stringify(r.signature.entitlements || {}, null, 2);

  container.innerHTML = `
    <!-- Thẻ tổng quan kiểu App Store -->
    <div class="card">
      <div class="appstore-hero">
        <div class="app-icon-box">${iconHtml}</div>
        <div class="hero-meta">
          <h2>${escapeHtml(r.app.displayName)}</h2>
          <div class="hero-bundle mono">${escapeHtml(r.app.bundleId)}</div>
          <div class="hero-actions">
            ${verdictBadge}
            ${fairPlayText}
          </div>
        </div>
      </div>

      <div class="stats-strip">
        <div class="stat-cell">
          <span>Phiên bản</span>
          <strong>${escapeHtml(r.app.version)} (${escapeHtml(r.app.buildNumber)})</strong>
        </div>
        <div class="stat-cell">
          <span>iOS tối thiểu</span>
          <strong>iOS ${escapeHtml(r.app.minimumOSVersion || '?')}</strong>
        </div>
        <div class="stat-cell">
          <span>Kiến trúc</span>
          <strong>${escapeHtml(r.binary?.architectures?.join(', ') || 'N/A')}</strong>
        </div>
        <div class="stat-cell">
          <span>Dung lượng</span>
          <strong>${escapeHtml(formatBytes(r.file.compressedSize))}</strong>
        </div>
      </div>
    </div>

    <!-- Chẩn đoán tương thích & Hạn ngạch Apple ID 0 đồng -->
    <div class="card">
      <h3 class="card-title">Đánh giá tương thích &amp; Hạn ngạch ký 0 đồng (Personal Team)</h3>
      ${blockersHtml}
      ${warningsHtml}
      ${renderUdidCheckHtml(prov)}
      ${blockersHtml === '' && warningsHtml === '' ? '<div class="diag-box diag-ok">Gói IPA sạch, không khóa FairPlay và tương thích tốt để ký cài đặt.</div>' : ''}

      <ul class="kv-list" style="margin-top:10px">
        <li>
          <span>Số App ID tiêu tốn (giữ nguyên PlugIns)</span>
          <strong>${r.personalTeamAssessment.appIdsWithExtensions} / 10 App ID (chu kỳ 7 ngày)</strong>
        </li>
        <li>
          <span>Số App ID tiêu tốn (nếu gỡ PlugIns phụ)</span>
          <strong>${r.personalTeamAssessment.appIdsWithoutExtensions} / 10 App ID</strong>
        </li>
        <li>
          <span>Dung lượng sau khi giải nén</span>
          <strong>${escapeHtml(formatBytes(r.file.uncompressedSize))} (${r.file.totalEntries} tệp)</strong>
        </li>
        <li>
          <span>Thời gian phân tích trên thiết bị</span>
          <strong>${r.durationMs} ms (${escapeHtml(r.app.plistFormat)})</strong>
        </li>
      </ul>
    </div>

    <!-- Phân tích chữ ký & Provisioning Profile -->
    <div class="card">
      <h3 class="card-title">Chữ ký số &amp; Provisioning Profile</h3>
      <ul class="kv-list">
        <li><span>Trạng thái hiện tại</span><strong>${escapeHtml(r.signature.summaryVi)}</strong></li>
        <li><span>Signing Identifier</span><strong class="mono">${escapeHtml(r.signature.codeSignature?.signingIdentifier || 'Chưa có')}</strong></li>
        <li><span>Team ID</span><strong class="mono">${escapeHtml(r.signature.codeSignature?.teamIdentifier || prov?.teamIdentifiers?.join(', ') || 'Chưa có')}</strong></li>
        <li><span>Thuật toán băm CodeDirectory</span><strong>${escapeHtml(r.signature.codeSignature?.hashType || 'Chưa có')}</strong></li>
        ${prov && !prov.parseError ? `
          <li><span>Tên Provisioning Profile</span><strong>${escapeHtml(prov.name || 'N/A')}</strong></li>
          <li><span>Loại phân phối</span><strong>${escapeHtml(prov.distributionType)}</strong></li>
          <li><span>Nhà phát triển / Team</span><strong>${escapeHtml(prov.teamName || 'N/A')}</strong></li>
          <li><span>Ngày hết hạn Profile</span><strong>${escapeHtml(prov.expirationDate || 'N/A')}</strong></li>
          <li><span>Hỗ trợ cài qua Safari OTA (itms-services)</span><strong>${prov.supportsOTA ? 'Có (Ad-Hoc / Enterprise)' : 'Không (Cần ký Ad-Hoc hoặc cài qua Pairing File)'}</strong></li>
        ` : ''}
      </ul>
      ${certsHtml}
      ${udidListHtml}

      <details class="ios-details">
        <summary>Xem chi tiết Entitlements (${Object.keys(r.signature.entitlements || {}).length} khóa)</summary>
        <pre class="code-block">${escapeHtml(entitlementsJson)}</pre>
      </details>
    </div>

    <!-- Phân tích nhị phân Mach-O -->
    <div class="card">
      <h3 class="card-title">Cấu trúc nhị phân Mach-O &amp; Thành phần nhúng</h3>
      <ul class="kv-list">
        <li><span>Tệp thực thi chính</span><strong class="mono">${escapeHtml(r.app.executableName || 'N/A')} (${escapeHtml(formatBytes(r.binary?.executableSize || 0))})</strong></li>
        <li><span>Loại nhị phân</span><strong>${r.binary?.isFat ? 'Universal / Fat Mach-O' : 'Single-Arch Mach-O'} (${r.binary?.isPIE ? 'PIE ASLR' : 'No PIE'})</strong></li>
        <li><span>Mach-O UUID</span><strong class="mono">${escapeHtml(r.binary?.uuid || 'N/A')}</strong></li>
        <li><span>SDK biên dịch</span><strong>${escapeHtml(r.app.sdkVersion || 'Không rõ')} (${escapeHtml(r.app.platform)})</strong></li>
        <li><span>Thiết bị hỗ trợ</span><strong>${escapeHtml(r.app.supportedDevices.join(', ') || 'iOS chung')}</strong></li>
        <li><span>Chia sẻ tệp (Files App)</span><strong>${r.app.uiFileSharingEnabled ? 'Bật' : 'Tắt'}</strong></li>
      </ul>

      <div style="margin-top:12px">
        <strong style="font-size:13px">App Extensions / PlugIns (${r.binary?.plugins?.length || 0}):</strong>
        <div class="tag-cloud">${pluginsHtml}</div>
      </div>

      <div style="margin-top:12px">
        <strong style="font-size:13px">Frameworks nhúng kèm (${r.binary?.frameworks?.length || 0}):</strong>
        <div class="tag-cloud">${frameworksHtml}</div>
      </div>

      ${r.binary?.linkedDylibs?.length ? `
        <details class="ios-details">
          <summary>Xem ${r.binary.linkedDylibs.length} thư viện động liên kết (LC_LOAD_DYLIB)</summary>
          <pre class="code-block">${escapeHtml(r.binary.linkedDylibs.join('\n'))}</pre>
        </details>
      ` : ''}
    </div>

    <!-- Quyền truy cập riêng tư -->
    <div class="card">
      <h3 class="card-title">Quyền truy cập hệ thống khai báo (${r.app.permissions.length})</h3>
      ${permissionsHtml}
    </div>

    <!-- Xuất báo cáo & Tải biểu tượng -->
    <div class="card">
      <h3 class="card-title">Xuất báo cáo phân tích</h3>
      <div class="hero-actions">
        <button type="button" class="btn btn-primary btn-sm" id="shareReportBtn">Chia sẻ báo cáo</button>
        <button type="button" class="btn btn-secondary btn-sm" id="exportMdBtn">Tải báo cáo .md</button>
        <button type="button" class="btn btn-secondary btn-sm" id="exportJsonBtn">Tải dữ liệu .json</button>
        ${r.icon?.dataUrl ? '<button type="button" class="btn btn-secondary btn-sm" id="exportIconBtn">Lưu biểu tượng .png</button>' : ''}
      </div>
    </div>
  `;

  const safeSlug = (r.app.bundleId || 'ipa-report').replace(/[^a-zA-Z0-9._-]/g, '_');

  document.getElementById('exportMdBtn')?.addEventListener('click', () => {
    const md = generateMarkdownReport(r);
    triggerDownloadBlob(new Blob([md], { type: 'text/markdown;charset=utf-8' }), `${safeSlug}-report.md`);
  });

  document.getElementById('exportJsonBtn')?.addEventListener('click', () => {
    const js = generateJsonReport(r);
    triggerDownloadBlob(new Blob([js], { type: 'application/json;charset=utf-8' }), `${safeSlug}-report.json`);
  });

  document.getElementById('exportIconBtn')?.addEventListener('click', async () => {
    if (!r.icon?.dataUrl) return;
    const resp = await fetch(r.icon.dataUrl);
    const iconBlob = await resp.blob();
    triggerDownloadBlob(iconBlob, `${safeSlug}-icon.png`);
  });

  document.getElementById('shareReportBtn')?.addEventListener('click', async () => {
    const md = generateMarkdownReport(r);
    if (navigator.share) {
      try {
        await navigator.share({
          title: `Báo cáo IPA: ${r.app.displayName}`,
          text: md
        });
        return;
      } catch {
        // Người dùng đóng hộp thoại Share
      }
    }
    triggerDownloadBlob(new Blob([md], { type: 'text/markdown;charset=utf-8' }), `${safeSlug}-report.md`);
  });
}

async function refreshLibraryView() {
  const listEl = document.getElementById('libraryList');
  const countLabel = document.getElementById('libraryCountLabel');
  const query = (document.getElementById('librarySearchInput').value || '').trim().toLowerCase();

  try {
    state.library = await listAnalyzedIpas();
  } catch {
    state.library = [];
  }

  const filtered = query
    ? state.library.filter(
        (item) =>
          (item.app?.displayName || '').toLowerCase().includes(query) ||
          (item.app?.bundleId || '').toLowerCase().includes(query)
      )
    : state.library;

  countLabel.textContent = `${filtered.length} hồ sơ đã lưu offline`;

  if (filtered.length === 0) {
    listEl.innerHTML = `<div class="card"><p class="muted-text" style="margin:0;text-align:center">Chưa có hồ sơ IPA nào trong thư viện. Hãy phân tích một tệp IPA ở tab đầu tiên.</p></div>`;
    return;
  }

  listEl.innerHTML = filtered
    .map((item) => {
      const letter = escapeHtml((item.app?.displayName || 'A').charAt(0).toUpperCase());
      const thumb = item.icon?.dataUrl
        ? `<img src="${item.icon.dataUrl}" alt="" />`
        : `<span>${letter}</span>`;
      const dateStr = item.analyzedAt
        ? new Date(item.analyzedAt).toLocaleString('vi-VN')
        : '';
      return `
        <div class="library-item" data-id="${escapeHtml(item.id)}">
          <div class="lib-icon">${thumb}</div>
          <div class="lib-info">
            <strong>${escapeHtml(item.app?.displayName)} <span class="muted-text">v${escapeHtml(item.app?.version)}</span></strong>
            <small class="mono">${escapeHtml(item.app?.bundleId)}</small>
            <small>${escapeHtml(formatBytes(item.file?.compressedSize || 0))} • ${escapeHtml(item.binary?.architectures?.join(', ') || '?')} • ${escapeHtml(dateStr)}</small>
          </div>
          <button type="button" class="lib-delete-btn" data-del="${escapeHtml(item.id)}">Xóa</button>
        </div>
      `;
    })
    .join('');

  listEl.querySelectorAll('.library-item').forEach((row) => {
    row.addEventListener('click', (ev) => {
      const delId = ev.target?.dataset?.del;
      if (delId) return;
      const found = state.library.find((x) => x.id === row.dataset.id);
      if (found) {
        state.currentResult = found;
        renderAnalysisResult(found);
        switchTab('analyze');
        window.scrollTo({ top: 0, behavior: 'smooth' });
      }
    });
  });

  listEl.querySelectorAll('.lib-delete-btn').forEach((btn) => {
    btn.addEventListener('click', async (ev) => {
      ev.stopPropagation();
      await deleteAnalyzedIpa(btn.dataset.del);
      refreshLibraryView();
    });
  });
}

function registerServiceWorker() {
  const swText = document.getElementById('swStatusText');
  if (!('serviceWorker' in navigator)) {
    swText.textContent = 'Không hỗ trợ trên ngữ cảnh này';
    return;
  }
  navigator.serviceWorker
    .register('./sw.js')
    .then(() => {
      swText.textContent = 'Đã kích hoạt (Sẵn sàng Offline)';
    })
    .catch(() => {
      swText.textContent = 'Chạy trực tiếp không bộ đệm';
    });
}

function initApp() {
  applyTheme();
  updateNetworkBadges();
  window.addEventListener('online', updateNetworkBadges);
  window.addEventListener('offline', updateNetworkBadges);

  // Hiện gợi ý cài lên màn hình chính nếu mở trên Safari iPhone chưa ở chế độ standalone
  const isStandalone =
    window.navigator.standalone === true ||
    window.matchMedia('(display-mode: standalone)').matches;
  if (!isStandalone && !state.settings.bannerDismissed) {
    document.getElementById('pwaBanner').classList.remove('hidden');
  }

  document.getElementById('dismissBannerBtn').addEventListener('click', () => {
    state.settings.bannerDismissed = true;
    persistSettings();
    document.getElementById('pwaBanner').classList.add('hidden');
  });

  // Tab switching
  document.querySelectorAll('.tab-btn').forEach((btn) => {
    btn.addEventListener('click', () => switchTab(btn.dataset.tab));
  });

  // Chọn file IPA
  const fileInput = document.getElementById('ipaFileInput');
  document.getElementById('pickFileBtn').addEventListener('click', () => fileInput.click());
  fileInput.addEventListener('change', () => {
    if (fileInput.files && fileInput.files[0]) {
      handleSelectedIpaFile(fileInput.files[0]);
      fileInput.value = '';
    }
  });

  // Kéo thả file
  const dropZone = document.getElementById('dropZone');
  dropZone.addEventListener('dragover', (e) => {
    e.preventDefault();
    dropZone.classList.add('dragover');
  });
  dropZone.addEventListener('dragleave', () => dropZone.classList.remove('dragover'));
  dropZone.addEventListener('drop', (e) => {
    e.preventDefault();
    dropZone.classList.remove('dragover');
    if (e.dataTransfer?.files?.[0]) {
      handleSelectedIpaFile(e.dataTransfer.files[0]);
    }
  });

  // Nạp file IPA nhị phân mẫu ngay trên trình duyệt
  document.getElementById('loadSampleBtn').addEventListener('click', () => {
    const bytes = createSampleIpaBytes();
    const sampleFile = new File([bytes], 'SampleApp-v2.4.1-arm64.ipa', {
      type: 'application/octet-stream'
    });
    handleSelectedIpaFile(sampleFile);
  });

  document.getElementById('downloadSampleIpaBtn').addEventListener('click', () => {
    const bytes = createSampleIpaBytes();
    triggerDownloadBlob(
      new Blob([bytes], { type: 'application/octet-stream' }),
      'SampleApp-v2.4.1-arm64.ipa'
    );
  });

  // Tìm kiếm & xóa thư viện
  document.getElementById('librarySearchInput').addEventListener('input', refreshLibraryView);
  document.getElementById('clearLibraryBtn').addEventListener('click', async () => {
    await clearAllAnalyzedIpas();
    refreshLibraryView();
  });

  // Thiết lập hệ thống
  const iosInput = document.getElementById('settingIosVersion');
  const udidInput = document.getElementById('settingDeviceUdid');
  const themeSelect = document.getElementById('settingTheme');
  iosInput.value = state.settings.iosVersion;
  udidInput.value = state.settings.deviceUdid;
  themeSelect.value = state.settings.theme;

  document.getElementById('saveSettingsBtn').addEventListener('click', () => {
    state.settings.iosVersion = iosInput.value.trim();
    state.settings.deviceUdid = udidInput.value.trim();
    state.settings.theme = themeSelect.value;
    persistSettings();
    applyTheme();
    updateNetworkBadges();
    if (state.currentResult) {
      renderAnalysisResult(state.currentResult);
    }
    const toast = document.getElementById('saveSettingsToast');
    toast.classList.remove('hidden');
    setTimeout(() => toast.classList.add('hidden'), 2400);
  });

  registerServiceWorker();
}

initApp();

/**
 * Quản lý thư viện IPA đã phân tích cục bộ bằng IndexedDB
 * Tương thích từ Safari iOS 15.0 đến iOS 26.6+ và hoạt động 100% Offline.
 * Không lưu toàn bộ file .ipa nhiều GB vào IndexedDB để tránh lỗi tràn bộ nhớ WebKit;
 * chỉ lưu hồ sơ phân tích đầy đủ, biểu tượng đã khôi phục và siêu dữ liệu kiểm chứng.
 */

const DB_NAME = 'ipa_installer_pwa_db';
const DB_VERSION = 1;
const STORE_NAME = 'analyzed_ipas';

function openDb() {
  return new Promise((resolve, reject) => {
    if (typeof indexedDB === 'undefined') {
      reject(new Error('Trình duyệt hiện tại không hỗ trợ IndexedDB'));
      return;
    }
    const req = indexedDB.open(DB_NAME, DB_VERSION);
    req.onupgradeneeded = () => {
      const db = req.result;
      if (!db.objectStoreNames.contains(STORE_NAME)) {
        const store = db.createObjectStore(STORE_NAME, { keyPath: 'id' });
        store.createIndex('analyzedAt', 'analyzedAt', { unique: false });
      }
    };
    req.onsuccess = () => resolve(req.result);
    req.onerror = () => reject(req.error || new Error('Không thể mở cơ sở dữ liệu thư viện IPA'));
  });
}

export async function saveAnalyzedIpa(record) {
  const db = await openDb();
  return new Promise((resolve, reject) => {
    const tx = db.transaction(STORE_NAME, 'readwrite');
    const store = tx.objectStore(STORE_NAME);
    store.put(record);
    tx.oncomplete = () => {
      db.close();
      resolve(record);
    };
    tx.onerror = () => {
      db.close();
      reject(tx.error || new Error('Lỗi lưu hồ sơ IPA vào thư viện'));
    };
  });
}

export async function listAnalyzedIpas() {
  const db = await openDb();
  return new Promise((resolve, reject) => {
    const tx = db.transaction(STORE_NAME, 'readonly');
    const store = tx.objectStore(STORE_NAME);
    const req = store.getAll();
    req.onsuccess = () => {
      db.close();
      const items = Array.isArray(req.result) ? req.result : [];
      items.sort((a, b) => (b.analyzedAt || '').localeCompare(a.analyzedAt || ''));
      resolve(items);
    };
    req.onerror = () => {
      db.close();
      reject(req.error || new Error('Không thể đọc danh sách thư viện IPA'));
    };
  });
}

export async function deleteAnalyzedIpa(id) {
  const db = await openDb();
  return new Promise((resolve, reject) => {
    const tx = db.transaction(STORE_NAME, 'readwrite');
    tx.objectStore(STORE_NAME).delete(id);
    tx.oncomplete = () => {
      db.close();
      resolve();
    };
    tx.onerror = () => {
      db.close();
      reject(tx.error || new Error('Không thể xóa mục khỏi thư viện'));
    };
  });
}

export async function clearAllAnalyzedIpas() {
  const db = await openDb();
  return new Promise((resolve, reject) => {
    const tx = db.transaction(STORE_NAME, 'readwrite');
    tx.objectStore(STORE_NAME).clear();
    tx.oncomplete = () => {
      db.close();
      resolve();
    };
    tx.onerror = () => {
      db.close();
      reject(tx.error || new Error('Không thể dọn sạch thư viện IPA'));
    };
  });
}

/**
 * Web Worker xử lý phân tích nhị phân IPA ở luồng nền riêng biệt,
 * giữ giao diện Safari iOS mượt 60fps và cô lập vùng nhớ tạm.
 */
import { analyzeIpaBlob } from './parsers/analyzer.js';

self.onmessage = async (event) => {
  const { requestId, file, fileName, hostIosVersion } = event.data || {};
  if (!file) {
    self.postMessage({
      requestId,
      type: 'error',
      error: 'Không nhận được tệp IPA hợp lệ trong Web Worker.'
    });
    return;
  }

  try {
    const result = await analyzeIpaBlob(file, {
      fileName: fileName || file.name,
      hostIosVersion,
      onProgress: ({ percent, stage }) => {
        self.postMessage({
          requestId,
          type: 'progress',
          percent,
          stage
        });
      }
    });

    self.postMessage({
      requestId,
      type: 'done',
      result
    });
  } catch (err) {
    self.postMessage({
      requestId,
      type: 'error',
      error: err && err.message ? err.message : String(err)
    });
  }
};

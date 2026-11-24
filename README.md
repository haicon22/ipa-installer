# IPA Installer – Hệ sinh thái Quản lý, Phân tích, Ký & Cài đặt IPA (Chi phí 0 đồng)

Hệ sinh thái mã nguồn mở hỗ trợ quản lý, phân tích cấu trúc nhị phân, ký số và cài đặt ứng dụng `.ipa` trên iPhone (**iOS 15.0 → iOS 26.6+**) với **chi phí 0 đồng**, không yêu cầu MacBook và không cần Jailbreak.

## Liên kết sử dụng ngay trên Safari iPhone (Web PWA)

- **Trang ứng dụng Web PWA (HTTPS)**: `https://haicon22.github.io/ipa-installer/`
- Mở bằng **Safari trên iPhone** → Nhấn **Chia sẻ (Share)** → Chọn **"Thêm vào MH chính" (Add to Home Screen)** để sử dụng toàn màn hình và **100% Offline**.

---

## Ba thành phần của dự án

1. **`pwa/` – IPA Installer Web (PWA)** *(Đã hoàn thành ở Giai đoạn 2)*:
   - Chạy trực tiếp trên Safari iPhone, không cần cáp hay chứng chỉ.
   - Đọc ngẫu nhiên theo lát cắt nhị phân (`Blob.slice` + `Web Worker`), phân tích tệp `.ipa` nặng nhiều GB chỉ tốn vài MB RAM.
   - Giải mã thực tế: Apple Binary Plist (`bplist00`) & XML Plist, khôi phục biểu tượng nén `CgBI` → PNG chuẩn RGBA, phân tích `Mach-O` (`arm64`/`arm64e`, khóa DRM FairPlay `cryptid`, `LC_LOAD_DYLIB`, `LC_CODE_SIGNATURE`), giải mã `embedded.mobileprovision` & chứng chỉ X.509 DER, đánh giá hạn ngạch 10 App ID của Apple Personal Team và xuất báo cáo `.md`/`.json`.
2. **`ios/` – IPA Installer Native (SwiftUI)** *(Triển khai ở Giai đoạn 3–4–6)*:
   - Ứng dụng gốc hỗ trợ từ **iOS 15.0 đến iOS 26.6+**, biên dịch tự động trên đám mây GitHub Actions (`macos-latest`).
   - Tách riêng `IPAParser`, `CertificateValidator` (6 bước + OCSP), `IPASigner` (`ZSign` C++) và `InstallationManager`.
3. **`termux-bootstrap/` – Android Termux Bootstrap** *(Triển khai ở Giai đoạn 5)*:
   - Bộ công cụ kiểm tra cáp USB-OTG, `termux-usb`, `usbmuxd` và `libimobiledevice` ngay trên điện thoại Android không cần PC.

---

## Kiểm thử cục bộ bộ giải mã nhị phân

```bash
node tests/test-pwa-parsers.mjs
```

## Tài liệu dự án

- Đặc tả tổng thể: [ipa_install.md](./ipa_install.md)
- Báo cáo xác minh khả thi Giai đoạn 1: [docs/PHASE1_FEASIBILITY.md](./docs/PHASE1_FEASIBILITY.md)

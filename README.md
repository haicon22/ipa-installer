# IPA Installer – Hệ sinh thái Quản lý, Phân tích, Ký & Cài đặt IPA (Chi phí 0 đồng)

Hệ sinh thái mã nguồn mở hỗ trợ quản lý, phân tích cấu trúc nhị phân, ký số và cài đặt ứng dụng `.ipa` trên iPhone (**iOS 15.0 → iOS 26.6+**) với **chi phí 0 đồng**, không yêu cầu MacBook và không cần Jailbreak.

## Liên kết sử dụng ngay trên Safari iPhone (Web PWA)

- **Trang ứng dụng Web PWA (HTTPS)**: **https://haicon22.github.io/ipa-installer/**
- Mở bằng **Safari trên iPhone** → Nhấn **Chia sẻ (Share)** → Chọn **"Thêm vào MH chính" (Add to Home Screen)** để sử dụng toàn màn hình và **100% Offline**.

---

## Ba thành phần của hệ sinh thái (Đã hoàn thiện mã nguồn Giai đoạn 1 → 6)

1. **`pwa/` – IPA Installer Web (PWA)** *(Hoàn thành & đang chạy trực tuyến)*:
   - Chạy trực tiếp trên Safari iPhone với 0 đồng, không cần dây cáp hay chứng chỉ.
   - Đọc ngẫu nhiên theo lát cắt nhị phân (`Blob.slice` + `Web Worker`), phân tích tệp `.ipa` nặng nhiều GB chỉ tốn vài MB RAM.
   - Giải mã thực tế: Apple Binary Plist (`bplist00`) & XML Plist, khôi phục biểu tượng nén `CgBI` → PNG chuẩn RGBA, phân tích `Mach-O` (`arm64`/`arm64e`, khóa DRM FairPlay `cryptid`, `LC_LOAD_DYLIB`, `LC_CODE_SIGNATURE`), giải mã `embedded.mobileprovision` & chứng chỉ X.509 DER, đánh giá hạn ngạch 10 App ID của Apple Personal Team và xuất báo cáo `.md`/`.json`.
2. **`ios/` – IPA Installer Native (SwiftUI cho iOS 15.0 → 26.6+)** *(Hoàn thành Giai đoạn 3–4–6)*:
   - Giao diện 10 màn hình Tiếng Việt chuẩn iOS (tương thích xuyên suốt iOS 15.0 đến iOS 26.6+).
   - Tách riêng 4 lõi độc lập:
     - `NativeIPAParser`: Đọc chọn lọc ZIP, `Info.plist`, khôi phục `CgBI` PNG, phân tích `Mach-O` & `.mobileprovision`.
     - `NativeCertificateValidator`: Lưu mật khẩu trong **iOS Keychain**, chốt chặn 6 bước trước cài đặt kèm truy vấn thu hồi **OCSP trực tiếp tới Apple** (hỗ trợ chuỗi WWDR G1–G8).
     - `NativeIPASigner` (`ZSignKit`): Tích hợp **`ZSign v1.1.3` C++17 & `OpenSSL 3.6`**, ký đệ quy Mach-O ngay trên thiết bị, gỡ bỏ `PlugIns/*.appex` tiết kiệm hạn ngạch 10 App ID, và tự xác minh chữ ký sau khi ký.
     - `NativeInstallationManager` (`LocalOTAServer`): Máy chủ truyền phát luồng `HTTP 206 Range` cục bộ, tự động định tuyến trung thực sang `SideStore`/`LiveContainer` đối với chứng chỉ miễn phí 0 đồng hoặc `itms-services://` đối với chứng chỉ Ad-Hoc/Enterprise hợp lệ.
3. **`termux-bootstrap/` – Android Termux Bootstrap** *(Hoàn thành Giai đoạn 5 – sẵn sàng thử cáp OTG ở Giai đoạn 7)*:
   - Công cụ gốc viết bằng C (`termux_ipa_pusher.c`) biên dịch trực tiếp trên Android `aarch64` liên kết `libimobiledevice` + `libplist` + `usbmuxd` (`TERMUX_USB_FD` không cần Root).
   - Hỗ trợ kiểm tra trạng thái Trust của iPhone, xuất tệp ghép đôi (`.mobiledevicepairing`) và đẩy gói `.ipa` đã ký qua `AFC` + `mobile_installation_proxy`.

---

## Kiểm thử nhanh trên máy cục bộ / Termux

```bash
# 1. Kiểm thử bộ giải mã nhị phân PWA
node tests/test-pwa-parsers.mjs

# 2. Biên dịch & chẩn đoán môi trường USB-OTG trên Android Termux
cd termux-bootstrap
./build.sh
./check-env.sh
```

## Tài liệu dự án

- Đặc tả tổng thể: [ipa_install.md](./ipa_install.md)
- Báo cáo xác minh khả thi Giai đoạn 1: [docs/PHASE1_FEASIBILITY.md](./docs/PHASE1_FEASIBILITY.md)

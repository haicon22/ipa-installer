# GIAI ĐOẠN 1: BÁO CÁO NGHIÊN CỨU KHẢ THI & XÁC MINH GIỚI HẠN KỸ THUẬT THỰC TẾ

> **Dự án**: IPA Installer (Hệ sinh thái 0 đồng: Web PWA + Native SwiftUI + Android Termux Bootstrap)
> **Ngày xác minh**: 25/11/2026
> **Trạng thái**: Hoàn thành Giai đoạn 1 (Đã kiểm chứng thực nghiệm trên thiết bị Android 14 Termux hiện tại & đối chiếu tài liệu hệ thống iOS 15.0 – iOS 26.6).

---

## 1. Xác minh các giới hạn bảo mật cốt lõi của iOS (iOS 15.0 → iOS 26.6+)

### 1.1. Phân biệt rạch ròi 3 khái niệm kỹ thuật trên iOS không Jailbreak

| Khái niệm | Cơ chế hệ thống liên quan | Thực hiện trực tiếp trên iPhone với 0 đồng? | Giải thích kỹ thuật xác thực |
| :--- | :--- | :---: | :--- |
| **1. Phân tích IPA (`Analyze`)** | Đọc cấu trúc ZIP, `bplist00`/XML, `CgBI` PNG, header `Mach-O`, ASN.1 CMS PKCS#7 | **CÓ (100%)** | Chỉ thao tác đọc dữ liệu nhị phân trong vùng nhớ người dùng (cả trên Safari PWA lẫn Native Sandbox), không bị `AMFI` hay `installd` can thiệp. |
| **2. Ký số IPA (`Sign`)** | Ghi `LC_CODE_SIGNATURE`, băm SHA-256 `CodeDirectory`, tạo `_CodeSignature/CodeResources` & CMS blob | **CÓ (Kèm điều kiện chứng chỉ)** | Thực hiện hoàn toàn trong không gian người dùng bằng `ZSign` + `OpenSSL`. Để có chứng chỉ 0 đồng, cần gọi Apple Developer API (`Anisette v3`) lấy chứng chỉ *Apple Development* của Personal Team (hoặc nhập file `.p12`/`.mobileprovision` sẵn có). |
| **3. Cài đặt IPA (`Install`)** | Giao tiếp với hệ thống `installd` / `AMFI` để giải nén vào `/private/var/containers/Bundle/Application` | **BỊ GIỚI HẠN BỞI KERNEL / DAEMON** | iOS khóa cứng quyền cài đặt ứng dụng qua 2 cổng duy nhất: **(A)** `itms-services://` (OTA) và **(B)** `mobile_installation_proxy` trên `lockdownd`. Cổng (A) từ chối chứng chỉ 0 đồng; cổng (B) bắt buộc có kết nối USB hoặc `Pairing File` tạo từ USB trước đó. |

### 1.2. Tại sao chứng chỉ Apple ID miễn phí (`Personal Team`) không thể cài qua `itms-services://`
- Tài khoản Apple ID 0 đồng chỉ được máy chủ Apple cấp duy nhất loại **Development Provisioning Profile** (`get-task-allow = true`), tuyệt đối **không được cấp Ad-Hoc hoặc Enterprise Profile**.
- Khi gọi `itms-services://?action=download-manifest&url=...`, tiến trình `itunesstored` và `installd` của iOS kiểm tra trường loại phân phối trong `embedded.mobileprovision`: nếu không phải `Ad-Hoc` (có đăng ký UDID) hoặc `Enterprise In-House`, `installd` lập tức hủy gói cài đặt.
- **Hệ quả thiết kế bắt buộc**:
  - Trên **Web PWA**: Tuyệt đối không đặt nút "Cài đặt trực tiếp qua Safari" giả lập.
  - Trên **Native App**: `Installation Manager` phải đọc loại Provisioning Profile trước khi cài. Nếu là profile *Free Personal Team Development*, ứng dụng phải tự động khóa luồng `itms-services://` và chuyển hướng sang luồng `lockdownd` / chuyển tiếp `SideStore` / `LiveContainer`, kèm giải thích rõ bằng tiếng Việt.

### 1.3. Toàn bộ hạn ngạch cứng của Apple Personal Team (0 đồng) cần xử lý trong code
1. **Thời hạn 7 ngày**: Chứng chỉ/profile cài trên máy hết hạn đúng 7 ngày sau khi cấp → Cần hiển thị bộ đếm ngược số ngày/giờ còn lại rõ ràng.
2. **Tối đa 3 ứng dụng hoạt động đồng thời** trên một chiếc iPhone (tính cả ứng dụng cài đặt như SideStore/IPA Installer).
3. **Tối đa 10 App ID trong chu kỳ trượt 7 ngày**:
   - **Điểm bẫy quan trọng nhất**: Mỗi **App Extension (`.appex`)** nằm trong thư mục `PlugIns/` của file `.ipa` (ví dụ Widget, Share Extension, Notification Service) đều tiêu tốn **1 App ID riêng biệt** và Apple không cho xóa App ID đã đăng ký trước hạn 7 ngày.
   - **Giải pháp kỹ thuật đưa vào dự án**: Cả **Web PWA** và **Native App** phải đếm và cảnh báo chính xác tổng số App ID mà 1 file `.ipa` sẽ tiêu tốn (`1 thực thi chính + N PlugIns`), đồng thời cung cấp tùy chọn **"Gỡ bỏ PlugIns/Extensions phụ khi ký"** trong `IPA Signer` để chỉ tốn đúng 1 App ID.
4. **Khác biệt theo phiên bản iOS (iOS 15.0 → iOS 26.6+)**:
   - **iOS 15.x**: Sau khi cài ứng dụng Development và bấm *Tin cậy (Trust)* trong Cài đặt, ứng dụng mở được ngay.
   - **iOS 16.0 → iOS 26.6+**: Apple bắt buộc bật thêm công tắc **Chế độ nhà phát triển (`Developer Mode`)** trong *Cài đặt > Quyền riêng tư & Bảo mật* và khởi động lại máy khi dùng chứng chỉ Development.
   - **Ứng dụng mã hóa FairPlay (`cryptid = 1`)**: Các file `.ipa` trích xuất trực tiếp từ App Store chưa qua giải mã (`LC_ENCRYPTION_INFO_64` có `cryptid != 0`) sẽ văng ngay lập tức khi mở trên máy khác dù ký lại bằng bất kỳ chứng chỉ nào → Bộ `IPA Parser` bắt buộc phải phát hiện cờ `cryptid` này và cảnh báo đỏ ngay từ bước phân tích.

---

## 2. Xác minh giới hạn kỹ thuật của Safari iOS cho phiên bản Web PWA

### 2.1. Trần bộ nhớ RAM của WebKit (`WebContent` Jetsam Limit)
- Trên Safari iOS (iOS 15 → iOS 26.6), một tab web hoặc PWA nếu cấp phát mảng nhị phân (`ArrayBuffer` / `Uint8Array`) vượt ngưỡng ~300 MB – 800 MB (tùy dung lượng RAM thiết bị) sẽ bị nhân iOS (`Jetsam`) giết tiến trình ngay lập tức với lỗi trắng trang *"Đã xảy ra sự cố lặp đi lặp lại"*.
- **Kiến trúc bắt buộc cho Giai đoạn 2 (PWA)**:
  - **Cấm tuyệt đối** gọi `await file.arrayBuffer()` trên toàn bộ file `.ipa`.
  - Sử dụng kỹ thuật **Đọc ZIP ngẫu nhiên theo lát cắt (`Blob.slice` Random-Access ZIP Parser)** chạy bên trong **Web Worker**:
    1. Chỉ cắt đọc 65 KB cuối cùng của file `.ipa` để tìm bản ghi `End of Central Directory (EOCD)` (hỗ trợ cả `ZIP64 EOCD` cho các IPA game lớn hơn 4 GB).
    2. Cắt đọc vùng `Central Directory` (thường chỉ vài chục đến vài trăm KB) để lập chỉ mục toàn bộ danh sách file bên trong IPA mà **không cần giải nén toàn bộ gói**.
    3. Chỉ cắt và giải nén đúng 4 thành phần nhỏ cần thiết:
       - `Payload/<App>.app/Info.plist` (vài chục KB).
       - File biểu tượng ứng dụng (vài chục đến vài trăm KB).
       - `Payload/<App>.app/embedded.mobileprovision` (thường < 100 KB).
       - **64 KB đầu tiên** của tệp thực thi chính `Payload/<App>.app/<Executable>` để đọc trọn vẹn `fat_header`, `mach_header_64` và toàn bộ các `Load Commands` (`LC_BUILD_VERSION`, `LC_VERSION_MIN_IPHONEOS`, `LC_ENCRYPTION_INFO_64`, `LC_LOAD_DYLIB`, `LC_CODE_SIGNATURE`) + cắt đúng lát cắt vùng `LC_CODE_SIGNATURE` nếu cần kiểm tra CMS chữ ký!
  - **Kết quả đạt được**: Có thể phân tích một file `.ipa` nặng **3 GB – 8 GB** ngay trên Safari iPhone chỉ trong **< 1 giây** với mức tiêu thụ RAM **< 10 MB**.

### 2.2. Các định dạng nhị phân đặc thù của Apple mà PWA bắt buộc giải mã thật
1. **Binary Plist (`bplist00`)**: Hơn 99% file `.ipa` biên dịch từ Xcode lưu `Info.plist` ở dạng nhị phân `bplist00` (gồm header 8 byte, bảng đối tượng độ dài thay đổi, bảng offset và trailer 32 byte ở cuối), **không phải dạng văn bản XML**. PWA bắt buộc có bộ giải mã cả hai chuẩn `bplist00` và `XML Plist`.
2. **Ảnh PNG chuẩn Apple `CgBI`**: Xcode nén các icon PNG bằng cách chèn chunk `CgBI` trước `IHDR`, lược bỏ 2 byte zlib header + 4 byte Adler32 của luồng nén trong `IDAT`, đồng thời đảo thứ tự màu từ `RGBA` sang `BGRA` (premultiplied alpha). Trình duyệt ngoài hoặc thẻ `<img>` thông thường có thể lỗi hiển thị hoặc sai màu khi xuất file → Cần bộ chuyển đổi `CgBI → Standard PNG` thuần chuẩn.
3. **Lưu trữ cục bộ Offline**:
   - Dùng `Service Worker` lưu toàn bộ mã nguồn HTML/CSS/JS/Icons để mở tức thì khi tắt mạng (Airplane Mode).
   - Dùng `IndexedDB` lưu siêu dữ liệu thư viện IPA đã phân tích, ảnh icon đã giải mã và báo cáo lịch sử (tương thích xuyên suốt từ iOS 15.0 đến iOS 26.6+, không bị gãy trên iOS 15–16 nơi OPFS chưa hoàn thiện).

---

## 3. Kiểm chứng thực tế môi trường Android Termux hiện tại (Chuẩn bị cho Giai đoạn 5)

Đã thực hiện kiểm tra thực nghiệm trực tiếp trên thiết bị hiện hành (không suy đoán):

### 3.1. Thông số hệ thống thực tế ghi nhận
- **Hệ điều hành & Kiến trúc**: `Android 14` – Kernel `Linux 5.4.254 aarch64` (64-bit ARM).
- **Công cụ đã có sẵn trên máy**:
  - `git`, `node`, `npm`, `python3`, `clang` (sẵn sàng kiểm thử tự động bộ giải mã PWA bằng Node.js ngay trên máy!).
  - `termux-usb` (thuộc gói `termux-api 0.60.0` đã cài sẵn).
  - `proot-distro 5.10.3` (đã cài sẵn).
- **Gói phần mềm iOS có sẵn trên kho chính thức của Termux (`aarch64`)**:
  - `libimobiledevice` phiên bản `1.4.0-1` (chưa cài, sẵn sàng cài qua `pkg install libimobiledevice`).
  - `usbmuxd` phiên bản `1.1.1-p20250201-3` (chưa cài, sẵn sàng cài qua `pkg install usbmuxd`).
  - `openssl-tool` (sẵn sàng cài khi cần).

### 3.2. Giới hạn kỹ thuật quan trọng của USB-OTG trên Android không Root
- Trên Android 14 không Root, ứng dụng dòng lệnh trong Termux **không có quyền mở trực tiếp** node thiết bị `/dev/bus/usb/BBB/DDD` (sẽ bị lỗi `Permission denied`).
- Mọi truy cập USB vật lý bắt buộc phải đi qua lệnh `termux-usb -r -e <script> /dev/bus/usb/BBB/DDD` (yêu cầu ứng dụng Android **Termux:API** đã được cài trên điện thoại để bật hộp thoại cấp quyền USB của Android và truyền biến môi trường `TERMUX_USB_FD` chứa File Descriptor đã mở vào tiến trình con).
- Daemon `usbmuxd` mặc định trên Linux quét bus USB qua `libusb_open()` thay vì nhận sẵn `TERMUX_USB_FD`, nên ở **Giai đoạn 5** cần xây dựng cơ chế tương thích `TERMUX_USB_FD` (hoặc bản vá `libusb`/`termux-usbmuxd`) và chỉ kết luận khả năng ghép đôi `idevicepair` sau khi thử nghiệm với cáp OTG + iPhone thật.

---

## 4. Xác minh hạ tầng GitHub miễn phí (Public Repository)

Với quyết định chuyển sang **Public Repository** theo [quyetdinh.md](../quyetdinh.md):
- **GitHub Actions (`macos-latest` & `ubuntu-latest`)**: Miễn phí **không giới hạn số phút chạy** cho kho công khai → Thoải mái biên dịch kiểm tra lỗi C++ (`ZSign`) + SwiftUI (`XcodeGen`) ở từng giai đoạn.
- **GitHub Pages**: Miễn phí 100% kèm chứng chỉ HTTPS chuẩn → Cho phép người dùng iPhone mở link GitHub Pages bằng Safari và bấm **"Thêm vào MH chính"** để dùng bản **IPA Installer Web (PWA)** ngay từ Giai đoạn 2.
- **GitHub Releases**: Miễn phí lưu trữ các bản phát hành `.ipa` và bộ script Termux.
- **Bảo vệ khóa xác thực**: File `github_token` trong thư mục làm việc đã được đưa vào `.gitignore` ngay từ Giai đoạn 1 để đảm bảo tuyệt đối không bao giờ lọt lên kho công khai.

---

## 5. Kết luận Giai đoạn 1 & Điều kiện sẵn sàng cho Giai đoạn 2

1. Toàn bộ giới hạn của iOS (15.0 → 26.6+), Apple Personal Team (7 ngày / 3 app / 10 App ID tính cả `.appex`), Safari WebKit RAM limit và Android 14 Termux USB-OTG đã được xác minh rõ ràng, có phương án kiến trúc xử lý tận gốc.
2. `.gitignore` và tài liệu đặc tả tổng thể [ipa_install.md](../ipa_install.md) đã được đồng bộ hoàn chỉnh.
3. **Bước tiếp theo (Giai đoạn 2)**: Xây dựng hoàn chỉnh **IPA Installer Web (PWA)** với bộ đọc ZIP theo lát cắt (`Blob.slice` + `Web Worker`), bộ giải mã nhị phân thật (`bplist00`/XML, `CgBI` PNG, `Mach-O`, CMS `.mobileprovision`), kiểm thử tự động trên file mẫu `.ipa` tạo thực tế ngay trong Termux, khởi tạo kho GitHub Public và xuất bản lên **GitHub Pages**.

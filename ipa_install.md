# DỰ ÁN: IPA INSTALLER – HỆ SINH THÁI QUẢN LÝ, PHÂN TÍCH, KÝ VÀ CÀI ĐẶT IPA (CHI PHÍ 0 ĐỒNG)

> **Tài liệu đặc tả tổng thể đã đồng bộ theo [quyetdinh.md](./quyetdinh.md) và [thaydoi.md](./thaydoi.md)**
> **Kiến trúc lựa chọn**: **HƯỚNG 3 – KẾT HỢP WEB PWA + NATIVE SWIFTUI + ANDROID TERMUX BOOTSTRAP**

---

## 1. Mục tiêu và Điều kiện bắt buộc (Tuyệt đối 0 đồng)

- **Chi phí 0 đồng xuyên suốt**:
  - Không mua Apple Developer Program ($99/năm).
  - Không mua chứng chỉ Developer chia sẻ từ bên thứ ba.
  - Không dùng dịch vụ ký IPA trả phí.
  - Không thuê máy chủ VPS trả phí.
  - Không cần MacBook hoặc PC.
  - Không cần Jailbreak.
- **Thiết bị mục tiêu**:
  - **iPhone**: Hỗ trợ dải rộng từ **iOS 15.0 đến iOS 26.x (bao gồm iOS 26.6) và tương thích tiến lên iOS 27+**.
  - **Android chạy Termux**: Sử dụng làm trạm điều phối mã nguồn, chạy công cụ kiểm tra kết nối USB-OTG và nghiên cứu khởi tạo ban đầu (`Bootstrap`) cho iPhone.
- **Hạ tầng GitHub công khai miễn phí (`Public Repository`)**:
  - Mã nguồn công khai trên GitHub để sử dụng hợp lệ và miễn phí **GitHub Actions (`macos-latest` & `ubuntu-latest`)**, **GitHub Pages** (phân phối bản Web PWA qua HTTPS) và **GitHub Releases** (lưu trữ bản phát hành Native `.ipa` cùng bộ công cụ Termux).
  - **Quy tắc bảo mật tuyệt đối**: Không bao giờ đẩy `github_token`, chứng chỉ `.p12`, `.mobileprovision`, khóa riêng tư hay `Pairing File` lên repository công khai.
- **Nguyên tắc trung thực kỹ thuật**:
  - Phân biệt rạch ròi giữa **Phân tích IPA**, **Ký IPA** và **Cài đặt IPA**.
  - Không tạo bất kỳ nút chức năng giả lập nào; không khẳng định thành công cơ chế phần cứng khi chưa qua kiểm thử thực tế.

---

## 2. Kiến trúc hệ sinh thái 3 thành phần

### Thành phần A – IPA Installer Web (PWA trên Safari iPhone)
Phiên bản chạy ngay lập tức từ trình duyệt Safari trên mọi chiếc iPhone với **0 đồng, 0 dây cáp, 0 chứng chỉ**:
- Hỗ trợ **"Thêm vào MH chính" (Add to Home Screen)** với biểu tượng riêng, giao diện toàn màn hình chuẩn iOS Tiếng Việt (Dark/Light Mode) và hoạt động **100% Offline** nhờ `Service Worker`.
- **Đọc ZIP ngẫu nhiên không tràn RAM (`Random-Access Slice Reader`)**: Xử lý trong `Web Worker` bằng `Blob.slice()` chỉ đọc bảng mục lục `Central Directory` ở cuối file và giải nén đúng các entry cần thiết — cho phép phân tích tệp `.ipa` nặng hàng GB trên iPhone mà chỉ tốn vài MB bộ nhớ, không gây sập tiến trình Safari WebKit.
- **Trình phân tích nhị phân thực thụ trên trình duyệt**:
  - Giải mã cả **Apple Binary Plist (`bplist00`)** lẫn **XML Plist** để đọc `Info.plist` (Tên ứng dụng, `Bundle Identifier`, Phiên bản, `Build Number`, `MinimumOSVersion`, quyền hệ thống).
  - Trích xuất biểu tượng ứng dụng và **khôi phục ảnh PNG bị Apple nén chuẩn `CgBI`** (bỏ chunk `CgBI`, giải nén raw deflate, đảo kênh BGRA → RGBA, tính lại CRC32 chuẩn).
  - Phân tích trực tiếp header nhị phân **`Mach-O`** (hỗ trợ cả `Fat/Universal` và `Mach-O 64-bit`): xác định kiến trúc CPU (`arm64`, `arm64e`), cờ mã hóa FairPlay (`LC_ENCRYPTION_INFO_64`), danh sách `Frameworks`, `PlugIns` (`.appex` – tính toán chính xác số lượng App ID tiêu tốn khi ký bằng tài khoản miễn phí) và `dylib`.
  - Trích xuất chữ ký `LC_CODE_SIGNATURE` và giải mã cấu trúc ASN.1 / CMS PKCS#7 của `embedded.mobileprovision` để đọc thông tin chứng chỉ, Team ID, hạn dùng, danh sách UDID và Entitlements.
- **Quản lý thư viện & Báo cáo**: Lưu hồ sơ lịch sử phân tích cục bộ (`OPFS` / `IndexedDB`) và xuất báo cáo chi tiết (`.json` / `.md`).
- **Ranh giới minh bạch**: Không hiển thị nút "Cài đặt trực tiếp" giả lập trên trình duyệt; hướng dẫn rõ các phương thức cài đặt hợp lệ sang Thành phần B/C hoặc công cụ sideload miễn phí sẵn có.

### Thành phần B – IPA Installer Native (Ứng dụng gốc SwiftUI cho iOS 15.0+)
Ứng dụng gốc biên dịch bằng Xcode trên đám mây GitHub Actions (`IPHONEOS_DEPLOYMENT_TARGET = 15.0`, Base SDK mới nhất):
- **Giao diện 10 màn hình Tiếng Việt chuẩn iOS** (gồm Trang chủ, Nhập IPA, Thư viện IPA, Chi tiết ứng dụng, Cài đặt ứng dụng, Quản lý chứng chỉ, Quản lý định danh & Hồ sơ, Lịch sử cài đặt, Nhật ký hoạt động, và **10. Thiết lập hệ thống**).
- **Tách biệt rạch ròi các lõi độc lập**:
  1. `Storage & Download Manager`: Tải IPA dung lượng lớn qua `URLSession`, bảo vệ chống Zip Slip, quản lý bộ nhớ Sandbox.
  2. `IPA Parser` (Độc lập – Chỉ đọc): Giải nén chọn lọc, đọc `Info.plist`, giải mã `CgBI` PNG, phân tích `Mach-O` & CMS `.mobileprovision`.
  3. `Certificate & Provisioning Validator` (Chốt chặn trước cài đặt): Lưu trữ an toàn trong **iOS Keychain**, kiểm tra 6 bước (khớp khóa `.p12`, thời hạn, truy vấn thu hồi OCSP với Apple, khớp `.mobileprovision`, kiểm tra UDID & Developer Mode theo đời iOS, kiểm tra xung đột `MinimumOSVersion`/Entitlements).
  4. `IPA Signer` (Độc lập – Tích hợp `ZSign` C++): Ký nhị phân Mach-O thực tế trên thiết bị, hỗ trợ **gỡ bỏ các PlugIns/App Extensions phụ** để tiết kiệm hạn ngạch 10 App ID/7 ngày của Apple Personal Team, đổi Bundle ID/Tên ứng dụng, tự xác minh chữ ký sau khi ký (`Post-Sign Verification`).
  5. `Installation Manager` (Độc lập – Điều phối cài đặt minh bạch theo điều kiện thực tế):
     - Hỗ trợ chuyển tiếp hợp lệ sang hệ sinh thái sideload miễn phí sẵn có (`SideStore` / `LiveContainer`) hoặc luồng cài đặt qua `Pairing File` + Local VPN trong phạm vi kỹ thuật kiểm chứng được.
     - Hỗ trợ Local HTTPS Server `itms-services://` khi và chỉ khi phát hiện gói đã ký bằng profile hỗ trợ OTA hợp lệ (tự động khóa phương thức OTA nếu phát hiện profile *Free Personal Team Development* để không gây lỗi ngầm cho người dùng).

### Thành phần C – Android Termux Bootstrap (Bộ công cụ thiết lập từ Android)
Bộ script và công cụ chẩn đoán chạy trên môi trường **Android + Termux** (không cần root, không cần PC):
- Tự động kiểm tra điều kiện môi trường: `termux-api` / `termux-usb`, `libimobiledevice`, `usbmuxd`, quyền truy cập USB-OTG.
- Xử lý chuyển tiếp File Descriptor (`TERMUX_USB_FD`) của Android sang `usbmuxd` / `libimobiledevice` để giao tiếp với iPhone qua cáp OTG.
- Thực hiện kiểm tra nhận diện iPhone (`ideviceinfo`), ghép đôi tạo `Pairing File` (`idevicepair`) và kiểm tra khả năng đẩy gói `.ipa` đã ký bằng tài khoản miễn phí.
- Báo cáo trung thực từng bước kiểm tra phần cứng thực tế, không giả định thành công khi chưa cắm thiết bị kiểm thử.

---

## 3. Tự động hóa CI/CD trên GitHub (Public Repository)

- **`.github/workflows/deploy-pwa.yml`**: Kiểm tra cú pháp/kiểm thử bộ giải mã nhị phân của bản Web PWA và tự động xuất bản lên **GitHub Pages** (cung cấp liên kết HTTPS miễn phí để iPhone mở bằng Safari và cài PWA ngay).
- **`.github/workflows/build-ios.yml`**: Chạy trên `macos-latest`, dùng `XcodeGen` sinh project từ `project.yml`, biên dịch toàn bộ mã SwiftUI + `ZSign` C++ cho `iOS 15.0+`, kiểm tra lỗi nghiêm ngặt và đóng gói `IPAInstaller-unsigned.ipa`.
- **`.github/workflows/release.yml`**: Đóng gói bản phát hành chính thức (`IPAInstaller-unsigned.ipa`, gói offline PWA và bộ công cụ `termux-bootstrap`) đưa lên **GitHub Releases**.

---

## 4. Lộ trình triển khai 8 giai đoạn bắt buộc

> **Nguyên tắc thực thi**: Không xuất toàn bộ dự án trong một phản hồi duy nhất. Hoàn thành dứt điểm từng giai đoạn, lưu mã nguồn vào thư mục dự án, chạy kiểm chứng thực tế rồi mới chuyển sang giai đoạn tiếp theo.

- **Giai đoạn 1**: Nghiên cứu khả thi và xác minh toàn bộ giới hạn iOS, Safari PWA và môi trường Android Termux (`docs/PHASE1_FEASIBILITY.md`).
- **Giai đoạn 2**: Xây dựng hoàn chỉnh **IPA Installer Web (PWA)** (đọc ZIP theo lát cắt, giải mã `bplist00`/XML, `CgBI` PNG, `Mach-O`, CMS `.mobileprovision`, lưu trữ offline & xuất báo cáo) + triển khai GitHub repo & GitHub Pages.
- **Giai đoạn 3**: Xây dựng khung **IPA Installer Native (SwiftUI)** (kiến trúc `XcodeGen` hỗ trợ iOS 15.0+, hệ thống điều hướng thích ứng, 10 màn hình tiếng Việt, quản lý tệp/tải xuống, nhật ký lỗi) + xác nhận biên dịch xanh trên GitHub Actions `macos-latest`.
- **Giai đoạn 4**: Xây dựng lõi **`IPA Parser`**, **`Certificate Validator` (6 bước + OCSP)** và **`IPA Signer` (`ZSign` C++ bridge)** cho bản Native + kiểm chứng biên dịch C++/Swift trên GitHub Actions.
- **Giai đoạn 5**: Nghiên cứu và xây dựng bộ công cụ **Android Termux Bootstrap** (`termux-usb`, `usbmuxd`, `libimobiledevice`, chẩn đoán OTG & Pairing File) ngay trên môi trường Termux.
- **Giai đoạn 6**: Tích hợp và hoàn thiện cơ chế **Installation Manager** (phối hợp luồng Apple Personal Team, chuyển tiếp sideload miễn phí, kiểm tra điều kiện trước cài đặt).
- **Giai đoạn 7**: Kiểm thử thực tế trên iPhone (cả bản PWA trên Safari lẫn bản Native và kết nối OTG nếu có cáp) và tinh chỉnh sửa lỗi thực tế.
- **Giai đoạn 8**: Hoàn thiện tài liệu hướng dẫn toàn diện tiếng Việt, đóng gói phát hành lên **GitHub Releases** và nghiệm thu tổng thể.

---

## 5. Tiêu chí nghiệm thu sản phẩm

1. **PWA chạy thật trên Safari iPhone**: Cài được ra màn hình chính, chạy offline, phân tích chính xác file `.ipa` thực tế (cả `bplist00`, icon `CgBI`, `Mach-O`, `.mobileprovision`) không tràn bộ nhớ.
2. **Native App build xanh trên GitHub Actions**: Biên dịch ra file `.ipa` thật sự hỗ trợ iOS 15.0 → iOS 26.6+, tách bạch rõ Parser, Validator, Signer và Installation Manager.
3. **Ký số thật bằng `ZSign`**: Ký và xác minh chữ ký thật khi có chứng chỉ/profile hợp lệ; hỗ trợ tối ưu hạn ngạch App ID cho Apple Personal Team.
4. **Không nút giả, không chi phí ẩn**: Mọi giới hạn của tài khoản 0 đồng được thông báo minh bạch ngay trên giao diện; không rò rỉ token hay khóa riêng tư lên kho công khai.

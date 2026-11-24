QUYẾT ĐỊNH KIẾN TRÚC DỰ ÁN IPA INSTALLER

Tôi chọn HƯỚNG 3: KẾT HỢP NATIVE SWIFTUI + WEB PWA.

Mục tiêu: Xây dựng một hệ sinh thái quản lý, phân tích, ký và cài đặt IPA với chi phí 0 đồng.

1. Điều kiện bắt buộc

- Không mua Apple Developer Program.
- Không mua chứng chỉ.
- Không thuê VPS.
- Không cần MacBook.
- Không Jailbreak.
- Ưu tiên sử dụng iPhone và Android chạy Termux.
- Mã nguồn ưu tiên công khai trên GitHub.
- GitHub Actions sử dụng macOS runner miễn phí theo chính sách hiện hành.
- GitHub Releases lưu trữ các bản phát hành.

2. Xây dựng hai phiên bản

A. IPA Installer Web (PWA)

- Chạy trực tiếp bằng Safari.
- Cài biểu tượng lên màn hình chính.
- Hoạt động offline sau khi tải tài nguyên.
- Nhập IPA từ Files.
- Phân tích Info.plist.
- Đọc Bundle Identifier.
- Đọc phiên bản và Build Number.
- Trích xuất biểu tượng.
- Phân tích Mach-O.
- Kiểm tra chữ ký và Provisioning Profile.
- Quản lý thư viện IPA.
- Xuất báo cáo phân tích.
- Tối ưu cho iPhone.

Không giả lập khả năng cài IPA trực tiếp.

B. IPA Installer Native (SwiftUI)

- Giao diện iOS native.
- IPA Parser.
- IPA Signer.
- Certificate Manager.
- Provisioning Profile Manager.
- Installation Manager.
- Download Manager.
- Installation History.
- Nhật ký lỗi.
- Tích hợp cơ chế sideloading hợp lệ.
- Hỗ trợ Apple Personal Team trong phạm vi được phép.

C. Android Termux Bootstrap

Nghiên cứu xây dựng công cụ hỗ trợ thiết lập ban đầu bằng Android:

- Kiểm tra USB OTG.
- Kiểm tra kết nối iPhone.
- Nghiên cứu libimobiledevice.
- Nghiên cứu usbmuxd.
- Nghiên cứu tạo Pairing File.
- Kiểm tra khả năng cài IPA.
- Tự động kiểm tra các điều kiện cần thiết.

Không được khẳng định thành công trước khi thử nghiệm thực tế.

3. GitHub

Sử dụng repository công khai để tận dụng chính sách miễn phí của GitHub.

Tạo workflow tự động:

- Build PWA.
- Build Native iOS trên macOS.
- Kiểm tra lỗi biên dịch.
- Xuất IPA khi có phương thức ký hợp lệ.
- Đưa bản phát hành lên GitHub Releases.

Không nhúng chứng chỉ hoặc khóa riêng vào repository công khai.

4. Phân chia giai đoạn triển khai

Giai đoạn 1: Nghiên cứu khả thi và xác minh toàn bộ giới hạn iOS.

Giai đoạn 2: Xây dựng PWA hoàn chỉnh.

Giai đoạn 3: Xây dựng Native SwiftUI.

Giai đoạn 4: Xây dựng IPA Parser và IPA Signer.

Giai đoạn 5: Nghiên cứu Android Termux Bootstrap.

Giai đoạn 6: Tích hợp cơ chế cài đặt.

Giai đoạn 7: Kiểm thử trên iPhone thực tế.

Giai đoạn 8: Hoàn thiện tài liệu và phát hành.

Không xuất toàn bộ dự án trong một phản hồi. Hoàn thành từng giai đoạn, lưu mã nguồn và kiểm tra trước khi chuyển giai đoạn tiếp theo.

5. Tiêu chí nghiệm thu

- PWA chạy thật trên Safari.
- Phân tích IPA thật.
- Native App build thành công.
- Có khả năng ký IPA khi đáp ứng điều kiện chứng chỉ.
- Kiểm chứng được cơ chế cài đặt.
- Không có nút chức năng giả.
- Không có dịch vụ trả phí bắt buộc.
- Công khai các giới hạn thực tế.

Ưu tiên sản phẩm hoạt động thật, không ưu tiên demo giao diện.
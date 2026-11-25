#!/data/data/com.termux/files/usr/bin/bash
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PUSHER_BIN="$SCRIPT_DIR/bin/termux-ipa-pusher"

echo "========================================================"
echo " CHẨN ĐOÁN MÔI TRƯỜNG ANDROID TERMUX BOOTSTRAP (GIAI ĐOẠN 5)"
echo "========================================================"
echo "Kiến trúc máy : $(uname -m) | Kernel: $(uname -r)"
echo "Android OS    : $(getprop ro.build.version.release 2>/dev/null || echo 'Unknown')"
echo ""

PASS_COUNT=0
WARN_COUNT=0

check_cmd() {
  local label="$1"
  local cmd="$2"
  if command -v "$cmd" >/dev/null 2>&1; then
    echo "  [ĐẠT] $label: $(command -v "$cmd")"
    PASS_COUNT=$((PASS_COUNT + 1))
  else
    echo "  [THIẾU] $label ($cmd chưa được cài đặt)"
    WARN_COUNT=$((WARN_COUNT + 1))
  fi
}

echo "--- 1. Kiểm tra công cụ phần mềm ---"
check_cmd "Termux USB Bridge" "termux-usb"
check_cmd "Daemon usbmuxd" "usbmuxd"
check_cmd "Công cụ ghép đôi idevicepair" "idevicepair"
check_cmd "Đọc thông tin ideviceinfo" "ideviceinfo"

if [ -x "$PUSHER_BIN" ]; then
  echo "  [ĐẠT] Trình đẩy IPA gốc (termux-ipa-pusher): $PUSHER_BIN"
  PASS_COUNT=$((PASS_COUNT + 1))
else
  echo "  [CHƯA BUILD] Chưa có $PUSHER_BIN (hãy chạy ./build.sh)"
  WARN_COUNT=$((WARN_COUNT + 1))
fi

echo ""
echo "--- 2. Kiểm tra hỗ trợ chuyển tiếp File Descriptor (TERMUX_USB_FD) ---"
if python3 -c 'import pathlib,sys; b=pathlib.Path("/data/data/com.termux/files/usr/lib/libusb-1.0.so").read_bytes(); sys.exit(0 if b"TERMUX_USB_FD" in b else 1)' 2>/dev/null; then
  echo "  [ĐẠT] libusb-1.0.so của Termux có hỗ trợ gốc TERMUX_USB_FD (không cần Root)."
  PASS_COUNT=$((PASS_COUNT + 1))
else
  echo "  [CẢNH BÁO] Không tìm thấy cờ TERMUX_USB_FD trong libusb-1.0.so."
  WARN_COUNT=$((WARN_COUNT + 1))
fi

echo ""
echo "--- 3. Kiểm tra danh sách thiết bị USB-OTG vật lý hiện tại ---"
USB_OUT="$(timeout 4 termux-usb -l 2>&1 || echo 'TIMEOUT_NO_TERMUX_API_APP')"
if [[ "$USB_OUT" == *"TIMEOUT_NO_TERMUX_API_APP"* ]]; then
  echo "  [LƯU Ý QUAN TRỌNG] Lệnh 'termux-usb -l' bị hết thời gian chờ."
  echo "    -> Hãy đảm bảo bạn đã cài thêm ứng dụng 'Termux:API' (từ F-Droid) trên máy Android này."
  WARN_COUNT=$((WARN_COUNT + 1))
elif [[ "$USB_OUT" == "[]" ]]; then
  echo "  [CHỜ CẮM CÁP] Termux:API phản hồi tốt ([]), hiện chưa cắm cáp USB-OTG nối với iPhone."
else
  echo "  [PHÁT HIỆN USB] Danh sách node USB đang cắm: $USB_OUT"
fi

echo ""
echo "--- 4. Kiểm tra kết nối iPhone trên usbmuxd ---"
if [ -x "$PUSHER_BIN" ]; then
  "$PUSHER_BIN" status || true
fi

echo ""
echo "========================================================"
echo " KẾT LUẬN TRUNG THỰC: $PASS_COUNT hạng mục phần mềm sẵn sàng | $WARN_COUNT lưu ý."
echo " (Chưa khẳng định ghép đôi phần cứng cho tới khi cắm cáp OTG kiểm thử thực tế)"
echo "========================================================"

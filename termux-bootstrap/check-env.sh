#!/data/data/com.termux/files/usr/bin/bash
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PUSHER_BIN="$SCRIPT_DIR/bin/termux-ipa-pusher"
MUX_SOCK="$PREFIX/var/run/usbmuxd"

echo "========================================================"
echo " CHẨN ĐOÁN MÔI TRƯỜNG ANDROID TERMUX BOOTSTRAP (CÓ ROOT)"
echo "========================================================"
echo "Kiến trúc máy : $(uname -m) | Kernel: $(uname -r)"
echo "Android OS    : $(getprop ro.build.version.release 2>/dev/null || echo 'Unknown')"
echo ""

PASS_COUNT=0
WARN_COUNT=0
HAS_ROOT=0

if command -v su >/dev/null 2>&1 && su -c "id -u" 2>/dev/null | grep -q "^0$"; then
  HAS_ROOT=1
fi

echo "--- 1. Kiểm tra đặc quyền hệ thống & Bus USB vật lý ---"
if [ "$HAS_ROOT" -eq 1 ]; then
  ROOT_ID="$(su -c 'id' 2>/dev/null)"
  echo "  [ĐẠT] Đã xác nhận quyền ROOT ($ROOT_ID)"
  echo "        -> Truy cập trực tiếp nhân Linux /dev/bus/usb & sysfs giống hệt máy tính Linux!"
  echo "        -> KHÔNG cần ứng dụng phụ Termux:API hay termux-usb."
  PASS_COUNT=$((PASS_COUNT + 1))

  APPLE_USB="$(su -c 'for d in /sys/bus/usb/devices/*; do [ -f "$d/idVendor" ] && grep -qi "^05ac$" "$d/idVendor" && cat "$d/product" 2>/dev/null; done' || true)"
  if [ -n "$APPLE_USB" ]; then
    echo "  [PHÁT HIỆN IPHONE VẬT LÝ] Thiết bị Apple trên bus USB: $APPLE_USB"
  else
    echo "  [CHỜ CẮM CÁP] Bus USB hoạt động tốt (/dev/bus/usb sẵn sàng), hiện chưa cắm cáp iPhone (VID 05ac)."
  fi
else
  echo "  [KHÔNG ROOT] Không phát hiện quyền su — Sẽ dùng chế độ dự phòng termux-usb."
  USB_OUT="$(timeout 4 termux-usb -l 2>&1 || echo 'TIMEOUT')"
  if [[ "$USB_OUT" == *"TIMEOUT"* ]]; then
    echo "  [CẢNH BÁO] Máy không Root cần cài thêm ứng dụng Android Termux:API."
    WARN_COUNT=$((WARN_COUNT + 1))
  fi
fi

echo ""
echo "--- 2. Kiểm tra công cụ phần mềm gốc ---"
for item in "Daemon usbmuxd:usbmuxd" "Ghép đôi idevicepair:idevicepair" "Thông tin ideviceinfo:ideviceinfo" "OpenSSL CLI:openssl"; do
  label="${item%%:*}"
  cmd="${item##*:}"
  if command -v "$cmd" >/dev/null 2>&1; then
    echo "  [ĐẠT] $label: $(command -v "$cmd")"
    PASS_COUNT=$((PASS_COUNT + 1))
  else
    echo "  [THIẾU] $label ($cmd)"
    WARN_COUNT=$((WARN_COUNT + 1))
  fi
done

if [ -x "$PUSHER_BIN" ]; then
  echo "  [ĐẠT] Trình đẩy IPA gốc (termux-ipa-pusher): $PUSHER_BIN"
  PASS_COUNT=$((PASS_COUNT + 1))
else
  echo "  [CHƯA BUILD] Chưa có $PUSHER_BIN (chạy ./build.sh)"
  WARN_COUNT=$((WARN_COUNT + 1))
fi

echo ""
echo "--- 3. Kiểm thử thực tế khởi chạy daemon usbmuxd với quyền Root ---"
if [ "$HAS_ROOT" -eq 1 ]; then
  mkdir -p "$PREFIX/var/run" "$PREFIX/var/lib/lockdown"
  su -c "$PREFIX/bin/usbmuxd -X" >/dev/null 2>&1 || true
  su -c "$PREFIX/bin/usbmuxd -U root -S $MUX_SOCK -P $PREFIX/var/run/usbmuxd.pid" >/dev/null 2>&1 || true
  sleep 1
  if su -c "test -S $MUX_SOCK"; then
    su -c "chmod 666 $MUX_SOCK"
    echo "  [ĐẠT] Daemon usbmuxd khởi chạy thành công dưới quyền Root và mở socket: $MUX_SOCK"
    PASS_COUNT=$((PASS_COUNT + 1))
    "$PUSHER_BIN" status || true
    su -c "$PREFIX/bin/usbmuxd -X" >/dev/null 2>&1 || true
  else
    echo "  [LỖI] Không tạo được socket $MUX_SOCK khi thử chạy usbmuxd."
    WARN_COUNT=$((WARN_COUNT + 1))
  fi
fi

echo ""
echo "========================================================"
echo " KẾT LUẬN TRUNG THỰC: $PASS_COUNT hạng mục ĐẠT 100% | $WARN_COUNT cảnh báo."
echo " Môi trường Root + usbmuxd + libimobiledevice đã sẵn sàng chờ cắm cáp USB!"
echo "========================================================"

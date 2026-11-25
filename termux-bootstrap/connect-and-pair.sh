#!/data/data/com.termux/files/usr/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PUSHER_BIN="$SCRIPT_DIR/bin/termux-ipa-pusher"
PAIRING_DIR="$SCRIPT_DIR/pairing_out"
MUX_SOCK="$PREFIX/var/run/usbmuxd"
MUX_PID_FILE="$PREFIX/var/run/usbmuxd.pid"

if [ ! -x "$PUSHER_BIN" ]; then
  "$SCRIPT_DIR/build.sh"
fi

mkdir -p "$PREFIX/var/run" "$PREFIX/var/lib/lockdown"

HAS_ROOT=0
if command -v su >/dev/null 2>&1 && su -c "id -u" 2>/dev/null | grep -q "^0$"; then
  HAS_ROOT=1
fi

if [ "$HAS_ROOT" -eq 1 ]; then
  echo "=== [CHẾ ĐỘ ROOT TRỰC TIẾP] Kiểm tra iPhone trên bus USB nhân Linux ==="
  APPLE_VID_FOUND="$(su -c 'for d in /sys/bus/usb/devices/*; do [ -f "$d/idVendor" ] && grep -qi "^05ac$" "$d/idVendor" && echo "FOUND"; done' || true)"
  if [ -z "$APPLE_VID_FOUND" ]; then
    echo "[DỪNG] Chưa phát hiện thiết bị Apple (VID 0x05ac) trên cổng USB-OTG."
    echo "  -> Hãy cắm cáp nối Android với iPhone, mở khóa màn hình iPhone rồi chạy lại lệnh này."
    exit 1
  fi

  echo "=== Khởi chạy daemon usbmuxd dưới quyền Root ==="
  su -c "$PREFIX/bin/usbmuxd -X" >/dev/null 2>&1 || true
  su -c "$PREFIX/bin/usbmuxd -U root -S $MUX_SOCK -P $MUX_PID_FILE"
  trap 'su -c "$PREFIX/bin/usbmuxd -X" >/dev/null 2>&1 || true' EXIT

  for _ in 1 2 3 4 5; do
    if su -c "test -S $MUX_SOCK"; then
      su -c "chmod 666 $MUX_SOCK"
      su -c "chmod -R a+rX $PREFIX/var/lib/lockdown" 2>/dev/null || true
      break
    fi
    sleep 1
  done
else
  echo "=== [CHẾ ĐỘ DỰ PHÒNG KHÔNG ROOT] Quét cổng USB qua termux-usb ==="
  USB_JSON="$(timeout 6 termux-usb -l || echo '[]')"
  USB_DEV="$(python3 -c "import json; arr=json.loads('''$USB_JSON'''); print(arr[0] if arr else '')" 2>/dev/null || true)"
  if [ -z "$USB_DEV" ]; then
    echo "[DỪNG] Không tìm thấy thiết bị USB qua termux-usb."
    exit 1
  fi
  usbmuxd -X 2>/dev/null || true
  termux-usb -r -e "$PREFIX/bin/usbmuxd -f -n" "$USB_DEV" &
  MUX_BG=$!
  trap 'kill $MUX_BG 2>/dev/null || true; usbmuxd -X 2>/dev/null || true' EXIT
  sleep 3
fi

echo "=== Thực hiện ghép đôi mật mã (Trust Pairing) với iPhone ==="
echo "Hãy mở sáng màn hình iPhone -> Bấm 'Tin cậy' (Trust) -> Nhập mật mã khóa màn hình!"
for attempt in 1 2 3 4; do
  if [ "$HAS_ROOT" -eq 1 ]; then
    su -c "USBMUXD_SOCKET_ADDRESS=unix:$MUX_SOCK $PREFIX/bin/idevicepair pair && USBMUXD_SOCKET_ADDRESS=unix:$MUX_SOCK $PREFIX/bin/idevicepair validate" && break
  else
    idevicepair pair && idevicepair validate && break
  fi
  echo "Đang chờ xác nhận 'Tin cậy' trên màn hình iPhone (lần $attempt/4)..."
  sleep 4
done

if [ "$HAS_ROOT" -eq 1 ]; then
  su -c "chmod -R a+rX $PREFIX/var/lib/lockdown" 2>/dev/null || true
fi

export USBMUXD_SOCKET_ADDRESS="unix:$MUX_SOCK"
"$PUSHER_BIN" status
"$PUSHER_BIN" export-pairing "$PAIRING_DIR"

if [ "${1:-}" != "" ]; then
  echo "=== Đang cài đặt gói IPA đã ký ($1) lên iPhone ==="
  "$PUSHER_BIN" install "$1"
fi

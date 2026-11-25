#!/data/data/com.termux/files/usr/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PUSHER_BIN="$SCRIPT_DIR/bin/termux-ipa-pusher"
PAIRING_DIR="$SCRIPT_DIR/pairing_out"

if [ ! -x "$PUSHER_BIN" ]; then
  "$SCRIPT_DIR/build.sh"
fi

echo "=== Bước 1: Quét cổng USB-OTG tìm iPhone ==="
USB_JSON="$(timeout 6 termux-usb -l || echo '[]')"
echo "Thiết bị USB phát hiện: $USB_JSON"

USB_DEV="$(python3 -c "import json,sys; arr=json.loads('''$USB_JSON'''); print(arr[0] if arr else '')" 2>/dev/null || true)"

if [ -z "$USB_DEV" ]; then
  echo "[DỪNG] Chưa phát hiện thiết bị USB-OTG nào."
  echo "  1. Cắm đầu OTG vào máy Android, đầu Lightning/USB-C kia vào iPhone."
  echo "  2. Mở khóa màn hình iPhone và chạy lại lệnh này."
  exit 1
fi

echo "=== Bước 2: Xin quyền USB Android & khởi chạy usbmuxd qua $USB_DEV ==="
mkdir -p "$PREFIX/var/run" "$PREFIX/var/lib/lockdown"
usbmuxd -X 2>/dev/null || true

# Khởi chạy usbmuxd ở chế độ nhận TERMUX_USB_FD từ termux-usb
termux-usb -r -e "$PREFIX/bin/usbmuxd -f -n" "$USB_DEV" &
MUX_PID=$!
trap 'kill $MUX_PID 2>/dev/null || true; usbmuxd -X 2>/dev/null || true' EXIT

sleep 3

echo "=== Bước 3: Kiểm tra nhận diện & Thực hiện ghép đôi (Trust) ==="
echo "Hãy mở sáng màn hình iPhone, nếu hiện bảng 'Tin cậy máy tính này?' hãy bấm 'Tin cậy' và nhập mật mã!"
for attempt in 1 2 3; do
  if idevicepair pair && idevicepair validate; then
    echo "[GHÉP ĐÔI THÀNH CÔNG]"
    break
  fi
  echo "Đang chờ bạn bấm 'Tin cậy' trên màn hình iPhone (thử lần $attempt/3)..."
  sleep 4
done

"$PUSHER_BIN" status
"$PUSHER_BIN" export-pairing "$PAIRING_DIR"

if [ "${1:-}" != "" ]; then
  echo "=== Bước 4: Cài đặt gói IPA đã ký ($1) lên iPhone ==="
  "$PUSHER_BIN" install "$1"
fi

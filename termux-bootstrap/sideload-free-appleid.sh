#!/data/data/com.termux/files/usr/bin/bash
set -euo pipefail

# Ký & Cài đặt trực tiếp tệp .ipa (như IPAInstaller-unsigned.ipa hoặc SideStore.ipa)
# bằng tài khoản Apple ID miễn phí (0 đồng) ngay trên máy Android đã Root thông qua AltServer-Linux aarch64!

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN_DIR="$SCRIPT_DIR/bin"
ALTSERVER_BIN="$BIN_DIR/AltServer-aarch64"
MUX_SOCK="$PREFIX/var/run/usbmuxd"
ALTSERVER_URL="https://github.com/NyaMisty/AltServer-Linux/releases/download/v0.0.5/AltServer-aarch64"

if [ $# -lt 1 ]; then
  echo "Cách dùng: ./sideload-free-appleid.sh <đường_dẫn_tệp.ipa> [Apple_ID_Email]"
  echo "Ví dụ   : ./sideload-free-appleid.sh ../IPAInstaller-unsigned.ipa"
  exit 1
fi

IPA_FILE="$1"
APPLE_ID="${2:-}"

if [ ! -f "$IPA_FILE" ]; then
  echo "Lỗi: Không tìm thấy tệp IPA tại: $IPA_FILE"
  exit 1
fi

mkdir -p "$BIN_DIR"
if [ ! -x "$ALTSERVER_BIN" ]; then
  echo "=== Đang tải AltServer-Linux tĩnh (aarch64) phục vụ ký Apple ID 0 đồng ==="
  curl -fL --progress-bar "$ALTSERVER_URL" -o "$ALTSERVER_BIN"
  chmod +x "$ALTSERVER_BIN"
fi

echo "=== Kiểm tra kết nối iPhone & Khởi động usbmuxd (Root) ==="
"$SCRIPT_DIR/connect-and-pair.sh"

# Mở lại usbmuxd nền cho phiên AltServer
su -c "$PREFIX/bin/usbmuxd -X" >/dev/null 2>&1 || true
su -c "$PREFIX/bin/usbmuxd -U root -S $MUX_SOCK -P $PREFIX/var/run/usbmuxd.pid"
trap 'su -c "$PREFIX/bin/usbmuxd -X" >/dev/null 2>&1 || true' EXIT
sleep 1
su -c "chmod 666 $MUX_SOCK"

UDID="$("$BIN_DIR/termux-ipa-pusher" status | awk '/UDID/{print $3; exit}')"
if [ -z "$UDID" ]; then
  echo "Lỗi: Không đọc được UDID của iPhone đang kết nối."
  exit 1
fi

if [ -z "$APPLE_ID" ]; then
  read -r -p "Nhập địa chỉ Email Apple ID miễn phí của bạn: " APPLE_ID
fi
read -r -s -p "Nhập mật khẩu Apple ID (không hiển thị trên màn hình, không lưu đĩa): " APPLE_PASS
echo ""

export USBMUXD_SOCKET_ADDRESS="unix:$MUX_SOCK"
export ALTSERVER_ANISETTE_SERVER="${ALTSERVER_ANISETTE_SERVER:-https://ani.sidestore.io}"

echo "=== Đang ký gói IPA với Apple Personal Team (0 đồng) & cài đặt vào UDID $UDID ==="
# AltServer-aarch64 là binary Linux chuẩn; chạy qua proot để ánh xạ /var/run/usbmuxd -> $MUX_SOCK sạch sẽ
if command -v proot >/dev/null 2>&1; then
  proot -b "$MUX_SOCK:/var/run/usbmuxd" -b "$PREFIX/var/lib/lockdown:/var/lib/lockdown" \
    "$ALTSERVER_BIN" -u "$UDID" -a "$APPLE_ID" -p "$APPLE_PASS" "$IPA_FILE"
else
  "$ALTSERVER_BIN" -u "$UDID" -a "$APPLE_ID" -p "$APPLE_PASS" "$IPA_FILE"
fi

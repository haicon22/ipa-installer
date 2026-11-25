#!/data/data/com.termux/files/usr/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN_DIR="$SCRIPT_DIR/bin"
mkdir -p "$BIN_DIR"

echo "=== [1/2] Kiểm tra gói phụ thuộc trên Termux ==="
NEEDED_PKGS=()
for cmd_pkg in "clang:clang" "idevicepair:libimobiledevice" "usbmuxd:usbmuxd" "termux-usb:termux-api" "openssl:openssl-tool"; do
  cmd="${cmd_pkg%%:*}"
  pkg="${cmd_pkg##*:}"
  if ! command -v "$cmd" >/dev/null 2>&1; then
    NEEDED_PKGS+=("$pkg")
  fi
done

if [ "${#NEEDED_PKGS[@]}" -gt 0 ]; then
  echo "Đang cài đặt các gói còn thiếu: ${NEEDED_PKGS[*]} ..."
  DEBIAN_FRONTEND=noninteractive apt-get update -qq
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${NEEDED_PKGS[@]}"
fi

echo "=== [2/2] Biên dịch công cụ gốc termux-ipa-pusher (aarch64) ==="
clang -O2 -Wall -Wextra \
  "$SCRIPT_DIR/src/termux_ipa_pusher.c" \
  -I"$PREFIX/include" \
  -L"$PREFIX/lib" \
  -limobiledevice-1.0 -lplist-2.0 -lpthread \
  -o "$BIN_DIR/termux-ipa-pusher"

chmod +x "$BIN_DIR/termux-ipa-pusher"
echo "[HOÀN TẤT] Đã biên dịch thành công: $BIN_DIR/termux-ipa-pusher"
"$BIN_DIR/termux-ipa-pusher" --help 2>/dev/null || true

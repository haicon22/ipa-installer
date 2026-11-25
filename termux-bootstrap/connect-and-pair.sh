#!/data/data/com.termux/files/usr/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PUSHER_BIN="$SCRIPT_DIR/bin/termux-ipa-pusher"
PAIRING_DIR="$SCRIPT_DIR/pairing_out"

if [ ! -x "$PUSHER_BIN" ]; then
  "$SCRIPT_DIR/build.sh"
fi

mkdir -p "$PREFIX/var/run" "$PREFIX/var/lib/lockdown" "$PAIRING_DIR"

if command -v su >/dev/null 2>&1 && su -c "id -u" 2>/dev/null | grep -q "^0$"; then
  echo "=== [CHẾ ĐỘ ROOT + TERMUX_USB_FD] Đang trực chờ bắt kết nối iPhone (90 giây) ==="
  su -c "$PREFIX/bin/python3 - '$PUSHER_BIN' '$PAIRING_DIR' '${1:-}'" << 'PY'
import os, sys, glob, time, subprocess

PREFIX = "/data/data/com.termux/files/usr"
MUX_SOCK = f"{PREFIX}/var/run/usbmuxd"
PUSHER = sys.argv[1]
PAIR_OUT = sys.argv[2]
IPA_TO_INSTALL = sys.argv[3] if len(sys.argv) > 3 else ""

otg_sw = "/sys/devices/virtual/oplus_chg/usb/otg_switch"
if os.path.exists(otg_sw):
    val = open(otg_sw).read().strip()
    if val == "0":
        print("[LƯU Ý] Công tắc OTG sau khi khởi động lại máy đang TẮT (otg_switch=0).")
        print("  -> Đang bật lại otg_switch=1 (hoặc hãy bật 'Kết nối OTG' trong Cài đặt Android)...", flush=True)
        try:
            with open(otg_sw, "w") as f:
                f.write("1\n")
        except OSError:
            pass

subprocess.run([f"{PREFIX}/bin/usbmuxd", "-X"], stderr=subprocess.DEVNULL)
seen = set()
deadline = time.time() + 90.0
prompted = False

while time.time() < deadline:
    nodes = [c for c in sorted(glob.glob("/dev/bus/usb/001/*")) if not c.endswith("/001")]
    if not nodes:
        if not prompted:
            print("Đang chờ tín hiệu USB từ iPhone (hãy cắm cáp và mở khóa màn hình iPhone)...", flush=True)
            prompted = True
        time.sleep(0.1)
        continue

    dev = nodes[-1]
    if dev in seen:
        time.sleep(0.1)
        continue
    seen.add(dev)

    try:
        fd = os.open(dev, os.O_RDWR)
    except OSError:
        time.sleep(0.05)
        continue

    if os.path.exists(MUX_SOCK):
        try: os.unlink(MUX_SOCK)
        except OSError: pass

    env = os.environ.copy()
    env["TERMUX_USB_FD"] = str(fd)
    env["LD_LIBRARY_PATH"] = f"{PREFIX}/lib"
    mux = subprocess.Popen(
        [f"{PREFIX}/bin/usbmuxd", "-f", "-n", "-U", "root", "-S", MUX_SOCK, "-P", "NONE"],
        env=env,
        pass_fds=(fd,),
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL
    )
    for _ in range(35):
        if os.path.exists(MUX_SOCK):
            os.chmod(MUX_SOCK, 0o666)
            break
        time.sleep(0.03)
    time.sleep(0.15)

    cenv = os.environ.copy()
    cenv["USBMUXD_SOCKET_ADDRESS"] = f"unix:{MUX_SOCK}"
    cenv["LD_LIBRARY_PATH"] = f"{PREFIX}/lib"

    paired = False
    # Giữ phiên mở và thử ghép đôi liên tục trong khi kết nối USB đang sống
    for _ in range(20):
        if not os.path.exists(dev):
            break
        try:
            r = subprocess.run([f"{PREFIX}/bin/idevicepair", "pair"], env=cenv, capture_output=True, text=True, timeout=3.0)
            out = (r.stdout + " " + r.stderr).strip()
            print(f"[{dev}] {out}", flush=True)
            if "SUCCESS: Paired with device" in out:
                subprocess.run([f"{PREFIX}/bin/idevicepair", "validate"], env=cenv, timeout=3.0)
                os.system(f"chmod -R a+rX {PREFIX}/var/lib/lockdown 2>/dev/null || true")
                subprocess.run([PUSHER, "status"], env=cenv, timeout=4.0)
                subprocess.run([PUSHER, "reveal-devmode"], env=cenv, timeout=6.0)
                subprocess.run([PUSHER, "export-pairing", PAIR_OUT], env=cenv, timeout=4.0)
                if IPA_TO_INSTALL:
                    subprocess.run([PUSHER, "install", IPA_TO_INSTALL], env=cenv)
                paired = True
                break
        except subprocess.TimeoutExpired:
            pass
        time.sleep(1.2)

    mux.terminate()
    os.close(fd)
    if paired:
        sys.exit(0)

print("[HẾT THỜI GIAN CHỜ] Chưa hoàn tất ghép đôi trong 90 giây.", flush=True)
sys.exit(1)
PY
else
  echo "Chế độ không Root cần termux-usb."
  exit 1
fi

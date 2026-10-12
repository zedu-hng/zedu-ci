#!/usr/bin/env bash
# Starts the display stack and the emulator for one session, installs the PR's APK once Android has
# booted and opens it. Runs in the foreground until the emulator exits, then stops everything it
# started. The agent owns this process group and kills it at the TTL.
# Usage: session.sh <app dir>   (APP_BIN names the APK inside it)
set -uo pipefail
app_dir=${1:?app dir}
app_bin=${APP_BIN:-app.apk}
upstream=${UPSTREAM_PORT:-6080}

export DISPLAY=:1 HOME=${HOME:-/home/device} XDG_RUNTIME_DIR=/tmp/xdg
mkdir -p "$XDG_RUNTIME_DIR" && chmod 700 "$XDG_RUNTIME_DIR"
# The emulator's temporary files go in the session's exec tmpfs.
export TMPDIR
TMPDIR="$(dirname "$app_dir")/tmp"
mkdir -p "$TMPDIR"
export LIBGL_ALWAYS_SOFTWARE=1 LP_NUM_THREADS=3 QT_QPA_PLATFORM=xcb

# The emulator writes lock and version files next to its AVD (even read-only), and the image's root is
# read-only. So each session starts from a fresh copy of the baked AVD in the session's tmpfs.
avd_home="$(dirname "$app_dir")/avd"
mkdir -p "$avd_home"
cp -r /opt/android-avd/slot.avd "$avd_home/"
sed -e "s#^path=.*#path=$avd_home/slot.avd#" -e "s#^path.rel=.*#path.rel=avd/slot.avd#" /opt/android-avd/slot.ini > "$avd_home/slot.ini"
export ANDROID_AVD_HOME="$avd_home"

# The device's screen, and a virtual display just big enough for it (plus the emulator's side toolbar and
# the window title), so the phone is not shrunk to fit and noVNC scales the whole display to the viewer's
# height. Tune with DEVICE_WIDTH, DEVICE_HEIGHT and DEVICE_DENSITY: a bigger device costs software-rendering CPU.
width=${DEVICE_WIDTH:-720}
height=${DEVICE_HEIGHT:-1280}
density=${DEVICE_DENSITY:-320}
for v in "$width" "$height" "$density"; do
  [[ "$v" =~ ^[0-9]{3,4}$ ]] || { echo "DEVICE_WIDTH, DEVICE_HEIGHT and DEVICE_DENSITY must be 3 or 4 digit numbers, got '$v'" >&2; exit 1; }
done
sed -i -e "s#^hw.lcd.width=.*#hw.lcd.width=$width#" -e "s#^hw.lcd.height=.*#hw.lcd.height=$height#" \
  -e "s#^hw.lcd.density=.*#hw.lcd.density=$density#" "$avd_home/slot.avd/config.ini"

cleanup() { jobs -p | xargs -r kill 2>/dev/null; adb kill-server 2>/dev/null; wait 2>/dev/null; }
trap cleanup EXIT

[ -r /dev/kvm ] && [ -w /dev/kvm ] || { echo "No access to /dev/kvm (is APP_GROUPS the kvm group id?)" >&2; exit 1; }

Xtigervnc "$DISPLAY" -geometry "${SCREEN:-$((width + 90))x$((height + 50))}" -depth 24 -SecurityTypes None -localhost yes \
  -rfbport 5901 -AlwaysShared > /tmp/xvnc.log 2>&1 &
for _ in $(seq 1 40); do [ -S /tmp/.X11-unix/X1 ] && break; sleep 0.25; done
[ -S /tmp/.X11-unix/X1 ] || { echo "Xtigervnc did not start" >&2; cat /tmp/xvnc.log >&2; exit 1; }

openbox > /tmp/openbox.log 2>&1 &
websockify --web /usr/share/novnc "127.0.0.1:$upstream" localhost:5901 > /tmp/websockify.log 2>&1 &

emulator -avd slot -no-snapshot -no-audio -no-boot-anim -no-metrics \
  -gpu swiftshader_indirect -accel on -memory 3072 -cores 3 \
  > /tmp/emulator.log 2>&1 &
emulator_pid=$!

install_and_open() {
  adb start-server > /dev/null 2>&1
  adb wait-for-device
  for _ in $(seq 1 200); do
    [ "$(adb shell getprop sys.boot_completed 2> /dev/null | tr -d '\r')" = 1 ] && break
    sleep 3
  done
  [ "$(adb shell getprop sys.boot_completed 2> /dev/null | tr -d '\r')" = 1 ] || { echo "Android did not finish booting" >&2; return; }
  echo "Android booted; installing $app_bin" >&2
  if ! adb install -r -g "$app_dir/$app_bin" > /tmp/install.log 2>&1; then
    echo "adb install failed:" >&2
    cat /tmp/install.log >&2
    return  # leave the emulator up so the reviewer can see it
  fi
  pkg=$(adb shell pm list packages -3 2> /dev/null | head -1 | cut -d: -f2 | tr -d '\r')
  [ -n "$pkg" ] && adb shell monkey -p "$pkg" -c android.intent.category.LAUNCHER 1 > /dev/null 2>&1
  echo "Opened $pkg" >&2
}
install_and_open &

# The emulator picks its own window scale (about half size here) and ignores -scale. Once its window exists,
# resize it to the device's full size at the top-left of the display, so the phone fills the display.
fit_window() {
  local wid=""
  for _ in $(seq 1 180); do
    wid=$(xdotool search --onlyvisible --name '^Android Emulator' 2> /dev/null | head -1)
    [ -n "$wid" ] && break
    sleep 1
  done
  [ -n "$wid" ] || { echo "no emulator window to resize" >&2; return; }
  sleep 3
  xdotool windowsize "$wid" "$width" "$height" windowmove "$wid" 0 0 2> /dev/null || echo "could not resize the emulator window" >&2
}
fit_window &

wait "$emulator_pid"
code=$?
echo "emulator exited with $code" >&2
tail -n 20 /tmp/emulator.log >&2
exit "$code"

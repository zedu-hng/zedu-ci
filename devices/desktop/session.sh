#!/usr/bin/env bash
# Starts the display stack and the app for one session. Runs in the foreground until the app exits,
# then stops everything it started. The agent owns this process group and kills it at the TTL.
# Usage: session.sh <app dir>   (APP_BIN names the executable inside it)
set -uo pipefail
app_dir=${1:?app dir}
app_bin=${APP_BIN:-zedu}
upstream=${UPSTREAM_PORT:-6080}

export DISPLAY=:1 HOME=${HOME:-/home/device} XDG_RUNTIME_DIR=/tmp/xdg
mkdir -p "$XDG_RUNTIME_DIR" && chmod 700 "$XDG_RUNTIME_DIR"
# Software rendering: the box has no GPU.
export LIBGL_ALWAYS_SOFTWARE=1 GALLIUM_DRIVER=llvmpipe GDK_BACKEND=x11 NO_AT_BRIDGE=1

cleanup() { jobs -p | xargs -r kill 2>/dev/null; wait 2>/dev/null; }
trap cleanup EXIT

# The VNC server listens on localhost only; websockify serves noVNC and bridges to it.
Xtigervnc "$DISPLAY" -geometry "${SCREEN:-1280x800}" -depth 24 -SecurityTypes None -localhost yes \
  -rfbport 5901 -AlwaysShared >/tmp/xvnc.log 2>&1 &
for _ in $(seq 1 40); do [ -S /tmp/.X11-unix/X1 ] && break; sleep 0.25; done
[ -S /tmp/.X11-unix/X1 ] || { echo "Xtigervnc did not start" >&2; cat /tmp/xvnc.log >&2; exit 1; }

# flutter_secure_storage needs a Secret Service on the session bus.
eval "$(dbus-launch --sh-syntax)"
eval "$(echo -n '' | gnome-keyring-daemon --unlock --components=secrets 2>/dev/null)" || true

openbox >/tmp/openbox.log 2>&1 &
websockify --web /usr/share/novnc "127.0.0.1:$upstream" localhost:5901 >/tmp/websockify.log 2>&1 &

cd "$app_dir" || exit 1
"./$app_bin"
code=$?
echo "app exited with $code" >&2
exit "$code"

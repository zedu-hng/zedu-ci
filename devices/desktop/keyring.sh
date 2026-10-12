# shellcheck shell=bash
# Sourced by session.sh after dbus-launch: starts gnome-keyring on the session bus with an unlocked
# default keyring, which is the secret service flutter_secure_storage (libsecret) talks to.
#
# The app stalled on its splash screen with KeyringLocked. A fresh home has no keyring, and neither
# `--unlock` nor `--login` creates one without a login session, so the secret service had no default
# collection (`/org/freedesktop/secrets/collection/login` did not exist). A plain-text keyring file has
# no password to prompt for, so it is always unlocked. It lives in the session's tmpfs home and goes
# with the container.
dir="${XDG_DATA_HOME:-$HOME/.local/share}/keyrings"
mkdir -p "$dir"
printf 'login' > "$dir/default"
cat > "$dir/login.keyring" <<'KEYRING'
[keyring]
display-name=Login
ctime=0
mtime=0
lock-on-idle=false
lock-after=false
KEYRING
unset dir
eval "$(gnome-keyring-daemon --start --components=secrets 2>/dev/null)" || true

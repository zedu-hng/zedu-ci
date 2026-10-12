# shellcheck shell=bash
# Sourced by session.sh after dbus-launch: starts gnome-keyring on the session bus with an unlocked
# login keyring, which is the secret service flutter_secure_storage (libsecret) talks to.
#
# The app stalled on its splash screen with KeyringLocked: a fresh home has no login keyring, and
# `--unlock` only unlocks an existing one. `--login` reads the password on stdin and creates the login
# keyring when it is missing; `--start` then brings up the secret service component on the bus. The
# password only protects a keyring in the session's tmpfs home, which goes with the container.
eval "$(printf '%s' "${KEYRING_PASSWORD:-session}" | gnome-keyring-daemon --login 2>/dev/null)" || true
eval "$(gnome-keyring-daemon --start --components=secrets 2>/dev/null)" || true

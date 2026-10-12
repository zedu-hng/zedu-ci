# shellcheck shell=bash
# Sourced by session.sh after dbus-launch: starts gnome-keyring on the session bus with an unlocked
# login keyring, which is the secret service flutter_secure_storage (libsecret) talks to.
#
# `--unlock` creates the login keyring from the password on stdin. An empty password does not create
# one, so the secret service has no unlocked default collection and every read fails with
# KeyringLocked (the app then stays on its splash screen). The password only protects a keyring that
# lives in the session's tmpfs home and is discarded with the container.
eval "$(printf '%s' "${KEYRING_PASSWORD:-session}" | gnome-keyring-daemon --unlock --components=secrets 2>/dev/null)" || true

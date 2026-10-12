#!/usr/bin/env bash
# Entry point for device-session.yml. See scripts/lib/device-session.sh.
set -euo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/device-session.sh
source "$here/lib/device-session.sh"
ds_main

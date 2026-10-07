#!/usr/bin/env bash
# Tests for scripts/lib with a stubbed gh. Run by Lint; run locally with: bash scripts/test.sh
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
fails=0
check() { # name expected actual
  if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1: expected [$2], got [$3]"; fails=$((fails + 1)); fi
}

# shellcheck source=scripts/lib/backend-url.sh
source scripts/lib/backend-url.sh
check "backend: no line" "" "$(backend_from_body $'intro\nno backend here')"
check "backend: template comment" "" "$(backend_from_body $'<!-- add a line starting with "Backend URL:" -->')"
check "backend: valid, trailing slash" "api.flamingo.groups.zedu.chat" "$(backend_from_body $'x\r\nBackend URL: https://api.flamingo.groups.zedu.chat/\r\n')"
# shellcheck disable=SC2016 # literal backticks in the body
check "backend: case, backticks" "api.x-y.groups.zedu.chat" "$(backend_from_body 'backend url:  `https://api.x-y.groups.zedu.chat`')"
check "backend: http" "invalid" "$(backend_from_body 'Backend URL: http://api.x.groups.zedu.chat')"
check "backend: other host" "invalid" "$(backend_from_body 'Backend URL: https://evil.example')"
check "backend: space inside" "invalid" "$(backend_from_body 'Backend URL: https://api.al pha.groups.zedu.chat')"
check "backend: two spaces, angle brackets" "api.team.groups.zedu.chat" "$(backend_from_body 'Backend URL:  <https://api.team.groups.zedu.chat>  ')"
check "backend: no space after colon" "api.team.groups.zedu.chat" "$(backend_from_body 'Backend URL:https://api.team.groups.zedu.chat')"

# Stub gh: status reads come from $STATUSES, writes are logged to $WRITES.
WRITES=$(mktemp); READS=$(mktemp)
gh() {
  case "$*" in
    *"/commits/"*"/status"*) echo read >> "$READS"; printf '%s\n' "$STATUSES" ;;
    *"/statuses/"*) echo "$*" >> "$WRITES" ;;
    *"contents/teams.yml"*) printf 'teams:\n  Zedu-Flamingo:\n    leads:\n      - a\n      - b\n  other: {}\n' ;;
  esac
}
export -f gh
export REPO=o/r
# shellcheck source=scripts/lib/status.sh
source scripts/lib/status.sh
STATUSES=$'Lint|success|Passed'
status_set sha1 Lint success Passed
check "status: unchanged" "unchanged" "$status_outcome"
status_set sha1 Lint failure Passed
check "status: changed state" "posted" "$status_outcome"
reads=$(grep -c . "$READS")
status_set sha1 Lint failure Passed
check "status: cache sees own write" "unchanged" "$status_outcome"
check "status: one read per sha" "$reads" "$(grep -c . "$READS")"
status_set sha1 Build success Ok https://u
check "status: target url sent" "1" "$(grep -c 'target_url=https://u' "$WRITES")"
STATUSES=""
status_set sha2 Build success Ok
check "status: new sha re-reads" "posted" "$status_outcome"

# shellcheck source=scripts/lib/teams.sh
source scripts/lib/teams.sh
check "teams: found, case-insensitive" $'found=true\nteam=Zedu-Flamingo\nleads=a,b' "$(team_of zedu-flamingo)"
check "teams: not found" "found=false" "$(team_of nobody)"
check "teams: orgs" $'Zedu-Flamingo\nother' "$(team_orgs)"

rm -f "$WRITES" "$READS"
[ "$fails" -eq 0 ] || { echo "$fails test(s) failed"; exit 1; }

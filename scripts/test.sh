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

# shellcheck source=scripts/lib/docs-only.sh
source scripts/lib/docs-only.sh
dq() { if printf '%s\n' "${@:2}" | docs_only "$1"; then echo yes; else echo no; fi; }
check "docs-only: all markdown" "yes" "$(dq 2 README.md docs/a.md)"
check "docs-only: code too" "no" "$(dq 2 README.md src/a.ts)"
check "docs-only: no files" "no" "$(dq 0)"
check "docs-only: over 100" "no" "$(dq 101 a.md)"
check "docs-only: list shorter than total" "no" "$(dq 3 a.md b.md)"

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

# open_prs: a good response, a response without repository data (exit 0), and an API failure.
# shellcheck source=scripts/lib/open-prs.sh
source scripts/lib/open-prs.sh
sleep() { :; }
CALLS=$(mktemp)
gh() {
  echo call >> "$CALLS"
  case "$GH_MODE" in
    good) printf '%s\n' '{"data":{"repository":{"pullRequests":{"nodes":[{"number":1},{"number":2}]}}}}' ;;
    null) printf '%s\n' '{"data":{"repository":null},"errors":[{"message":"partial"}]}' ;;
    fail) return 1 ;;
  esac
}
GH_MODE=good; : > "$CALLS"
check "open_prs: good response" "2" "$(open_prs 2>/dev/null | jq length)"
for mode in null fail; do
  GH_MODE=$mode; : > "$CALLS"
  if open_prs >/dev/null 2>&1; then got=0; else got=1; fi
  check "open_prs: $mode response fails" "1" "$got"
  check "open_prs: $mode response retried once" "2" "$(grep -c . "$CALLS")"
done
rm -f "$CALLS"

# reviewer-claim sweep: a timestamp read from jq feeds `date -d`, so it must come out without JSON quotes.
# jq -s alone printed "2026-10-10T14:39:09Z" with the quotes, `date -d` failed, and every scheduled
# sweep died on the first ready PR.
timeline='[{"event":"labeled","label":{"name":"ready-for-review"},"created_at":"2026-10-10T14:39:09Z"}]'
check "claim sweep: jq -rs prints a bare timestamp" "2026-10-10T14:39:09Z" \
  "$(printf '%s' "$timeline" | jq -rs '[flatten[] | select(.event=="labeled")] | last | .created_at // empty')"
check "claim sweep: no timeline match is empty" "" \
  "$(printf '[]' | jq -rs '[flatten[] | select(.event=="labeled")] | last | .created_at // empty')"
check "claim sweep: every created_at read uses jq -r" "0" \
  "$(grep -E 'jq .*created_at' .github/workflows/reviewer-claim.yml | grep -c -v -E 'jq -[a-z]*r')"
check "claim sweep: created_at reads exist" "2" "$(grep -c -E 'jq .*created_at' .github/workflows/reviewer-claim.yml)"

rm -f "$WRITES" "$READS"
[ "$fails" -eq 0 ] || { echo "$fails test(s) failed"; exit 1; }

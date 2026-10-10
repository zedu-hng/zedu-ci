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

# obfuscation-scan: synthetic fixtures in a throwaway repo. Padding and obfuscator-shaped text are
# generated here; no real payload is stored.
OBF=$(mktemp -d)
obf() { # name expected-exit: scans HEAD~1..HEAD of the fixture repo
  (cd "$OBF" && bash "$OLDPWD/scripts/obfuscation-scan.sh" HEAD~1 HEAD > out.txt 2>&1); local rc=$?
  check "obfuscation: $1" "$2" "$rc"
}
obf_commit() { (cd "$OBF" && git add -A && git -c user.name=t -c user.email=t@t commit -qm "$1"); }
tabs=$(printf '\t%.0s' $(seq 1 300))
(cd "$OBF" && git init -q . && mkdir -p src .vscode \
  && printf '{\n  "scripts": {\n    "dev": "next dev"\n  }\n}\n' > package.json \
  && printf 'export default {};\n' > postcss.config.mjs && printf 'const a = 1;\n' > src/a.js)
obf_commit base

printf 'const b = 2;\nexport const c = 3;\n' >> "$OBF/src/a.js"; obf_commit clean
obf "clean change passes" 0

printf 'export default {};%sconsole.log(1);\n' "$tabs" > "$OBF/postcss.config.mjs"; obf_commit pad
obf "code hidden behind tabs" 1
check "obfuscation: reports the file" "1" "$(grep -c 'postcss.config.mjs:1' "$OBF/out.txt")"

printf 'var x = 1;\n' > "$OBF/src/a.js"; printf 'export default {};\n' > "$OBF/postcss.config.mjs"; obf_commit reset
printf 'var _0xa1b2=1,_0xc3d4=2,_0xe5f6=3;\n' > "$OBF/src/a.js"; obf_commit obf
obf "_0x identifiers" 1
printf 'x(0x2607+-0x1*parseInt(0xbfd)+-0x103d*Math.ceil(0x1));\n' > "$OBF/src/a.js"; obf_commit hexmath
obf "hex arithmetic" 1
printf 'var l = "%s";\n' "$(head -c 9000 /dev/zero | tr '\0' a)" > "$OBF/src/a.js"; obf_commit long
obf "9000-char line in JS" 1
printf 'var l = "%s";\n' "$(head -c 9000 /dev/zero | tr '\0' a)" > "$OBF/data.csv"; printf 'var s = 1;\n' > "$OBF/src/a.js"; obf_commit longcsv
obf "long line in a .csv passes" 0
printf 'fetch("https://eth.drpc.org/x");\n' > "$OBF/src/a.js"; obf_commit ioc
obf "known indicator" 1

printf 'var s = 2;\n' > "$OBF/src/a.js"; printf 'console.log(1);\n' > "$OBF/api.js"
printf '{\n  "scripts": {\n    "dev": "node api.js && next dev"\n  }\n}\n' > "$OBF/package.json"; obf_commit wiring
obf "package.json runs an added file" 1
printf '{\n  "scripts": {\n    "dev": "node api.js && next dev",\n    "lint": "node api.js"\n  }\n}\n' > "$OBF/package.json"; obf_commit existing
obf "package.json runs a file from an earlier commit passes" 0

printf 'wOF2 not really\n' > "$OBF/f.woff2"; obf_commit font
obf "plain-text font" 1
(cd "$OBF" && printf 'wOF2\000\001\002\003binary' > f.woff2); printf 'var s = 4;\n' > "$OBF/src/a.js"; obf_commit realfont
obf "binary font passes" 0

printf '{ "tasks": [{ "runOptions": { "runOn": "folderOpen" } }] }\n' > "$OBF/.vscode/tasks.json"; obf_commit task
obf "folderOpen task" 1

printf 'export default {};\n' > "$OBF/postcss.config.mjs"; printf 'var s = 5;\n' > "$OBF/src/a.js"; rm -f "$OBF/api.js" "$OBF/.vscode/tasks.json"; obf_commit reset2
printf 'const c = "%s";\n' "$(head -c 1600 /dev/zero | tr '\0' a)" > "$OBF/postcss.config.mjs"; obf_commit cfglong
obf "1600-char line in a config file" 1
printf 'export default {};\n' > "$OBF/postcss.config.mjs"; obf_commit reset3
printf 'const c = "%s";\n' "$(head -c 1600 /dev/zero | tr '\0' a)" > "$OBF/src/data.ts"; obf_commit longother
obf "1600-char line outside configs passes" 0
printf 'x();%sfetch("https://eth.drpc.org/a");\n' "$tabs" > "$OBF/src/a.js"; obf_commit hiddenioc
obf "indicator hidden behind padding" 1
printf 'var s = 6;\n' > "$OBF/src/a.js"; printf 'console.log(1);\n' > "$OBF/jest.setup.js"; obf_commit rootscript
obf "new plain root-level script passes" 0
printf 'node_modules\ntemp_auto_push.bat\n' > "$OBF/.gitignore"; obf_commit ignore
obf "gitignore hides loader artifact" 1
printf 'var s = 8;\n' > "$OBF/src/a.js"; printf '{}\n' > "$OBF/branch_structure.json"; obf_commit bsj
obf "branch_structure.json" 1

# Parser differentials: the PR controls .gitattributes, NUL bytes, file names and the whitespace it pads with.
hide="x();${tabs}fetch(\"https://eth.drpc.org/a\");"
printf '%s\n' "$hide" > "$OBF/src/attr.js"; printf 'src/attr.js -diff\n' > "$OBF/.gitattributes"; obf_commit attr
obf "gitattributes -diff does not hide a file" 1
printf '//\000\n%s\n' "$hide" > "$OBF/src/nul.js"; obf_commit nul
obf "NUL byte does not hide a file" 1
nbsp=$(printf '\302\240%.0s' $(seq 1 300))
printf 'x();%sPAYLOAD();\n' "$nbsp" > "$OBF/src/nbsp.js"; obf_commit nbsp
obf "NBSP padding" 1
printf 'x();%sPAYLOAD();\n' "$(printf '\f%.0s' $(seq 1 300))" > "$OBF/src/ff.js"; obf_commit ff
obf "form-feed padding" 1
printf '%s\n' "$hide" > "$OBF/note.txt"; obf_commit txt
obf "padded payload in a .txt" 1
printf '%s\n' "$hide" > "$OBF/src/lib.min.js"; obf_commit minjs
obf "padded payload in a .min.js" 1
printf 'var _0xa1b2c3=1,_0xd4e5f6=2,_0x112233=3;\n' > "$OBF/src/data.log"; obf_commit log
obf "_0x code in a .log" 1
printf '%s\n' "$hide" > "$OBF/:(exclude)magic.js"; obf_commit magic
obf "pathspec-magic file name" 1
printf '%s\n' "$hide" > "$OBF/$(printf 'nl\n::warning::forged.js')"; obf_commit newline
obf "newline in a file name" 1
check "obfuscation: file name cannot forge a workflow command" "0" "$(grep -c '^::warning::forged' "$OBF/out.txt")"
printf '| a%s| b |\n' "$(printf ' %.0s' $(seq 1 300))" > "$OBF/table.md"; printf 'a  b  c\n' > "$OBF/notes.md"; printf '{"a": 1}\n' > "$OBF/data.json"; obf_commit benign
obf "plain md and json pass" 0

(cd "$OBF" && SWEEP=1 bash "$OLDPWD/scripts/obfuscation-scan.sh" "$(git hash-object -t tree -w /dev/null)" HEAD > out.txt 2>&1); check "obfuscation: sweep skips the added-file wiring rule" "0" "$(grep -c 'a file this PR adds' "$OBF/out.txt")"

h=$(cd "$OBF" && printf 'known\n' > k.dat && git hash-object k.dat); printf '%s known\n' "$h" > "$OBF/blobs.txt"
(cd "$OBF" && git add -A && git -c user.name=t -c user.email=t@t commit -qm known)
(cd "$OBF" && BLOBS="$OBF/blobs.txt" bash "$OLDPWD/scripts/obfuscation-scan.sh" HEAD~1 HEAD > out.txt 2>&1); check "obfuscation: known blob" "1" "$?"
(cd "$OBF" && bash "$OLDPWD/scripts/obfuscation-scan.sh" nosuchref HEAD > out.txt 2>&1); check "obfuscation: bad base is an error" "2" "$?"
rm -rf "$OBF"
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

# reviewer-notify: the build status the queue waits for is an input, and the default keeps mobile and
# desktop (no input passed) on "Fork build".
RN=.github/workflows/reviewer-notify.yml
check "reviewer-notify: build context comes from the input" "1" "$(grep -c -E '^  BUILD_CONTEXT: \$\{\{ inputs\.build_context \}\}$' "$RN")"
check "reviewer-notify: input defaults to Fork build" "Fork build" "$(awk '/build_context:/{f=1} f&&/default:/{sub(/^ *default: */,""); print; exit}' "$RN")"

rm -f "$WRITES" "$READS"
[ "$fails" -eq 0 ] || { echo "$fails test(s) failed"; exit 1; }

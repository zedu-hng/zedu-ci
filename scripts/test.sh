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

# shellcheck source=scripts/lib/conflicts.sh
source scripts/lib/conflicts.sh
check "conflicts: clean" "success|No conflicts with dev." "$(conflict_verdict true dev true)"
check "conflicts: conflicting" "failure|Conflicts with dev. Merge or rebase dev, then push." "$(conflict_verdict false dev true)"
check "conflicts: unknown" "" "$(conflict_verdict null dev true)"
check "conflicts: off, conflicting" "success|Not enforced" "$(conflict_verdict false dev false)"
check "conflicts: off, unknown" "success|Not enforced" "$(conflict_verdict null dev false)"

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
printf '%s\n' "$hide" > "$OBF/x.pdf"; obf_commit pdfjs
obf "JS saved as .pdf" 1
printf '%s\n' "$hide" > "$OBF/.wasm"; obf_commit dotwasm
obf "JS saved as a .wasm dot-file" 1
printf '%s\n' "$hide" > "$OBF/zip"; obf_commit barezip
obf "JS in a file named zip" 1
printf '\357\273\277%s\n' "$hide" > "$OBF/bom.zip"; obf_commit bomzip
obf "BOM-prefixed JS saved as .zip" 1
printf '//\001\n%s\n' "$hide" > "$OBF/ctl.png"; obf_commit ctlpng
obf "JS behind a control byte saved as .png" 1
printf '%%PDF-1.4\nplain ascii body\n' > "$OBF/ok.pdf"; printf 'PK\003\004bin' > "$OBF/ok.zip"; obf_commit realbin
obf "real pdf and zip pass" 0
printf 'just some words\n' > "$OBF/.wasm"; obf_commit dotwasmplain
obf "plain text saved as a .wasm dot-file" 1
check "obfuscation: dot-file disguise is reported as plain text" "1" "$(grep -c 'plain text, not binary' "$OBF/out.txt" | awk '{print ($1 > 0)}')"
printf 'var l = "%s";\n' "$(head -c 9000 /dev/zero | tr '\0' a)" > "$OBF/.pnp.cjs"; obf_commit pnp
obf "long line in .pnp.cjs passes" 0
printf 'var l = "%s";%sx\n' "$(head -c 9000 /dev/zero | tr '\0' a)" "$tabs" > "$OBF/.pnp.cjs"; obf_commit pnppad
obf "padding in .pnp.cjs" 1
printf 'fetch("https://eth.drpc.org/a");\n' > "$OBF/.pnp.cjs"; obf_commit pnpioc
obf "IOC in .pnp.cjs" 1
(cd "$OBF" && printf '\000asm\001\000\000\000' > nul.wasm && git add -A && git -c user.name=t -c user.email=t@t commit -qm nul && bash "$OLDPWD/scripts/obfuscation-scan.sh" HEAD~1 HEAD 2>&1 | grep -c 'ignored null byte' > nulwarn.txt); check "obfuscation: no null-byte warnings" "0" "$(cat "$OBF/nulwarn.txt")"
lng=$(printf 'var l = "%s";\n' "$(head -c 9000 /dev/zero | tr '\0' a)")
mkdir -p "$OBF/src/ui/svgs"; printf '%s\n' "$lng" > "$OBF/src/ui/svgs/index.tsx"; obf_commit lngsvg
(cd "$OBF" && LONG_ALLOW='src/**/svgs/index.tsx' bash "$OLDPWD/scripts/obfuscation-scan.sh" HEAD~1 HEAD > out.txt 2>&1); check "obfuscation: LONG_ALLOW exempts a listed path" "0" "$?"
(cd "$OBF" && bash "$OLDPWD/scripts/obfuscation-scan.sh" HEAD~1 HEAD > out.txt 2>&1); check "obfuscation: the same file fails without LONG_ALLOW" "1" "$?"
printf '%s\n' "$lng" > "$OBF/src/ui/svgs/other.tsx"; obf_commit lngother
(cd "$OBF" && LONG_ALLOW='src/**/svgs/index.tsx' bash "$OLDPWD/scripts/obfuscation-scan.sh" HEAD~1 HEAD > out.txt 2>&1); check "obfuscation: LONG_ALLOW does not cover other paths" "1" "$?"
allow_scan() { (cd "$OBF" && LONG_ALLOW='src/**/svgs/index.tsx' bash "$OLDPWD/scripts/obfuscation-scan.sh" HEAD~1 HEAD > out.txt 2>&1); }
printf 'x();%sx\n' "$tabs" > "$OBF/src/ui/svgs/index.tsx"; obf_commit lngpad
allow_scan; check "obfuscation: LONG_ALLOW does not skip padding" "1" "$(grep -c 'code hidden after' "$OBF/out.txt" | awk '{print ($1 > 0)}')"
printf 'fetch("https://eth.drpc.org/a");\n' > "$OBF/src/ui/svgs/index.tsx"; obf_commit lngioc
allow_scan; check "obfuscation: LONG_ALLOW does not skip IOC" "1" "$(grep -c 'known malware indicator' "$OBF/out.txt" | awk '{print ($1 > 0)}')"
# The glob must not be expanded against the tree: src/ui/svgs/index.tsx exists, and the deeper file still matches.
mkdir -p "$OBF/src/a/b/svgs"; printf '%s\n' "$lng" > "$OBF/src/a/b/svgs/index.tsx"; obf_commit lngdeep
allow_scan; check "obfuscation: LONG_ALLOW glob is not expanded by the shell" "0" "$?"
printf '%%PDF-1.4\n%s\n' "$hide" > "$OBF/hdr.pdf"; obf_commit pdfhdr
obf "payload after a %PDF header" 1

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
check "reviewer-notify: the cap comes from the input" "1" "$(grep -c -E '^  CAP: \$\{\{ inputs\.cap \}\}$' "$RN")"
check "reviewer-notify: the cap defaults to 5" "5" "$(awk '/^      cap:/{f=1} f&&/default:/{gsub(/[" ]/,""); sub(/default:/,""); print; exit}' "$RN")"
check "reviewer-notify: a non-numeric cap fails the run" "1" "$(grep -c 'cap must be a whole number' "$RN")"

# status_set retries a failed write. A status that never lands (Build) leaves the PR out of the queue.
W2=$(mktemp)
gh() {
  case "$*" in
    *"/commits/"*"/status"*) printf '' ;;
    *"/statuses/"*) echo w >> "$W2"; [ "$(grep -c . "$W2")" -gt "${FAIL_FIRST:-0}" ] ;;
  esac
}
sleep() { :; }
retry_case() { # name, failing writes, expected exit, expected writes
  : > "$W2"; _status_sha=""; FAIL_FIRST=$2
  status_set sha9 Build success Passed >/dev/null 2>&1; local rc=$?
  check "status retry: $1, exit" "$3" "$rc"
  check "status retry: $1, writes" "$4" "$(grep -c . "$W2")"
}
retry_case "first write lands" 0 0 1
retry_case "recovers on the 3rd attempt" 2 0 3
retry_case "gives up after 3 attempts" 99 1 3
unset FAIL_FIRST; rm -f "$W2"
PRC=.github/workflows/pr-review-comment.yml
check "pr-review-comment: a failed status write fails the run" "1" "$(grep -c -E 'name: Fail if a status was not posted' "$PRC")"
check "pr-review-comment: no write failure is only a warning" "0" "$(grep -c -E "warning::Couldn't post" "$PRC")"
# Run the real "Post check statuses" step with a stub status_set and a results file.
step_run() { # results-json [context whose write fails]
  local d; d=$(mktemp -d)
  ruby -ryaml -e 'y = YAML.load_file(ARGV[0]); puts y["jobs"]["comment"]["steps"].find { |s| s["id"] == "statuses" }["run"]' "$PRC" > "$d/step.sh"
  mkdir -p "$d/.zedu-ci/scripts/lib"
  # shellcheck disable=SC2016 # the stub is written out literally
  printf '%s\n' 'status_set() { echo "$2" >> "$POSTED"; [ "$2" != "$FAIL_CONTEXT" ]; }' > "$d/.zedu-ci/scripts/lib/status.sh"
  printf '%s' "$1" > "$d/results.json"; : > "$d/posted"; : > "$d/out"
  (cd "$d" && POSTED="$d/posted" GITHUB_OUTPUT="$d/out" FILE="$d/results.json" HEAD_SHA=x RUN_URL=u \
    FAIL_CONTEXT="${2:-}" bash -e step.sh > /dev/null 2>&1); local rc=$?
  echo "rc=$rc $(tr '\n' ' ' < "$d/out")posted=$(grep -c . "$d/posted")"; rm -rf "$d"
}
three='{"checks":[{"context":"ESLint","state":"success"},{"context":"Build","state":"success"},{"context":"Prettier","state":"failure"}]}'
check "statuses step: all three post" "rc=0 failed=0 posted=3" "$(step_run "$three")"
check "statuses step: one write fails, the others still post" "rc=0 failed=1 posted=3" "$(step_run "$three" Build)"
check "statuses step: unreadable results fail loudly" "rc=0 failed=1 posted=0" "$(step_run '{not json')"
check "statuses step: empty results post nothing" "rc=0 posted=0" "$(step_run '')"
check "statuses step: unknown contexts are dropped" "rc=0 failed=0 posted=1" "$(step_run '{"checks":[{"context":"Evil","state":"success"},{"context":"Build","state":"success"}]}')"

rm -f "$WRITES" "$READS"

# pr-scans: Semgrep is optional. Run the real "Record results" step with each outcome.
PRS=.github/workflows/pr-scans.yml
d=$(mktemp -d)
ruby -ryaml -e 'y = YAML.load_file(ARGV[0]); puts y["jobs"]["scans"]["steps"].find { |s| s["name"] == "Record results" }["run"]' "$PRS" > "$d/rec.sh"
rec() { (cd "$d" && SEMGREP=$1 CLAMAV=success OBFUSCATION=success bash rec.sh && cut -f1 results.tsv | tr '\n' ,); }
check "pr-scans: skipped Semgrep posts no row" "ClamAV,Obfuscation scan," "$(rec skipped)"
check "pr-scans: ran Semgrep posts a row" "Semgrep,ClamAV,Obfuscation scan," "$(rec success)"
check "pr-scans: failed Semgrep still posts a row" "Semgrep,ClamAV,Obfuscation scan," "$(rec failure)"
check "pr-scans: Semgrep step is skipped when unconfigured" "1" "$(grep -c "if: inputs.semgrep_configs != '' && inputs.semgrep_paths != ''" "$PRS")"
rm -rf "$d"

# pr-checks-node: previews. Run the real "Decide" and "Record results" steps, and publish-results.sh.
PCN=.github/workflows/pr-checks-node.yml
d=$(mktemp -d)
step() { ruby -ryaml -e 'y = YAML.load_file(ARGV[0]); puts y["jobs"]["checks"]["steps"].find { |s| s["name"] == ARGV[1] }["run"]' "$PCN" "$2" > "$d/$1.sh"; }
step decide Decide; step rec "Record results"
decide() { # preview action body-from body [label]
  (cd "$d" && : > out; : > genv; PREVIEW=$1 ACTION=$2 BODY_FROM=$3 PR_BODY=$4 LABEL=${5:-preview} GITHUB_OUTPUT="$PWD/out" GITHUB_ENV="$PWD/genv" bash decide.sh >/dev/null && cat out genv | tr '\n' ' ')
}
check "pr-checks-node: a push is a full run" "mode=full " "$(decide true synchronize '' '')"
check "pr-checks-node: a preview label rebuilds only the preview" "mode=preview SKIP_PUBLISH=true " "$(decide true labeled '' '')"
check "pr-checks-node: an unrelated label does nothing" "mode=none SKIP_PUBLISH=true " "$(decide true labeled '' '' bug)"
check "pr-checks-node: a Backend URL edit rebuilds only the preview" "mode=preview SKIP_PUBLISH=true " "$(decide true edited 'Backend URL: https://api.a.groups.zedu.chat' 'Backend URL: https://api.b.groups.zedu.chat')"
check "pr-checks-node: any other body edit does nothing" "mode=none SKIP_PUBLISH=true " "$(decide true edited 'x' 'y')"
check "pr-checks-node: a repo without previews is always full" "mode=full " "$(decide false labeled '' '')"
recb() { (cd "$d" && JEST_ENABLED=false BUILD_ENABLED=$1 INSTALL=success FILE_POLICY=success GITLEAKS=success HEURISTICS=success COMMITLINT=success AUDIT=success PRETTIER=success ESLINT=success TYPES=success REVIEW=success BUILD=$2 bash rec.sh && cut -f1,2 results.tsv | tail -1 | tr '\t' ' '); }
check "pr-checks-node: no Build row without a build" "PR review success" "$(recb false skipped)"
check "pr-checks-node: a failed build posts a failed Build row" "Build failure" "$(recb true failure)"
(cd "$d" && : > env2 && printf 'x\ty\tz\n' > results.tsv && GITHUB_ENV="$PWD/env2" SKIP_PUBLISH=true bash "$OLDPWD/scripts/publish-results.sh")
check "pr-checks-node: SKIP_PUBLISH posts nothing" "fail=0 no-json" "$(tr '\n' ' ' < "$d/env2")$([ -f "$d/pr-checks-results.json" ] || echo no-json)"
rm -rf "$d"

# device-session: /test comments. Pure helpers first, then ds_main against stubbed gh and the slot.
source scripts/lib/device-session.sh
check "device-session: /test desktop starts" "start:desktop" "$(ds_command '/test desktop')"
check "device-session: trailing words are ignored" "start:desktop" "$(ds_command '/test desktop please')"
check "device-session: only the first line counts" "stop" "$(ds_command $'/test stop\nthanks')"
check "device-session: bare /test is help" "help" "$(ds_command '/test')"
check "device-session: an unknown word is help" "help" "$(ds_command '/test nonsense')"
check "device-session: extend" "extend" "$(ds_command '/test extend')"
check "device-session: a normal comment is ignored" "none" "$(ds_command 'looks good to me')"
check "device-session: /testing is not a command" "none" "$(ds_command '/testing')"
check "device-session: a leading space is not a command" "none" "$(ds_command ' /test desktop')"
statuses='[{"context":"Fork build","state":"success"},{"context":"ClamAV","state":"failure"},{"context":"Lazarus","state":"pending"},{"context":"Fork build","state":"failure"}]'
check "device-session: the newest status per context wins, the rest are listed" "ClamAV: failure|Lazarus: pending|Scan: missing|" "$(ds_missing_statuses "$statuses" 'Fork build, ClamAV,Lazarus,Scan' | tr '\n' '|')"
check "device-session: nothing is missing when all pass" "" "$(ds_missing_statuses '[{"context":"A","state":"success"}]' 'A')"
arts='{"artifacts":[{"id":1,"name":"x","expired":false,"created_at":"2026-01-01T00:00:00Z"},{"id":2,"name":"x","expired":false,"created_at":"2026-01-02T00:00:00Z"},{"id":3,"name":"x","expired":true,"created_at":"2026-01-03T00:00:00Z"},{"id":4,"name":"y","expired":false,"created_at":"2026-01-04T00:00:00Z"}]}'
check "device-session: the newest unexpired artifact of that name" "2" "$(ds_pick_artifact "$arts" x)"
check "device-session: no artifact of that name" "" "$(ds_pick_artifact "$arts" z)"

DS_DIR=$(mktemp -d)
python3 -c "import zipfile,sys; z=zipfile.ZipFile(sys.argv[1],'w'); z.writestr('zedu-linux.tar.gz','tarball'); z.close()" "$DS_DIR/a.zip"
python3 -c "import zipfile,sys; z=zipfile.ZipFile(sys.argv[1],'w'); z.writestr('app-release.apk','apk-bytes'); z.close()" "$DS_DIR/apk.zip"
DS_SHA=$(printf 'a%.0s' $(seq 1 40))
gh() { # canned GitHub answers for owner/repo#7, fork fork/r
  case "$*" in
    "api repos/o/r/collaborators/rev/permission --jq .permission") echo "${PERM:-write}" ;;
    "api repos/o/r/collaborators/"*) echo none ;;
    "api repos/o/r/pulls/7 --jq "*) printf 'open\t%s\tfork/r\n' "$DS_SHA" ;;
    "api repos/o/r/commits/$DS_SHA/statuses?per_page=100") echo "${STATUSES:-[]}" ;;
    "api repos/fork/r/actions/workflows/pr-build.yml/runs?head_sha=$DS_SHA&per_page=10 --jq "*) echo "${RUN:-}" ;;
    "api repos/fork/r/actions/runs/55/artifacts?per_page=100") echo "{\"artifacts\":[{\"id\":9,\"name\":\"${ARTIFACT_NAME:-desktop-linux}\",\"expired\":false,\"created_at\":\"2026-01-01T00:00:00Z\",\"size_in_bytes\":100}]}" ;;
    "api repos/fork/r/actions/artifacts/9/zip") cat "$DS_DIR/${ZIP_FILE:-a.zip}" ;;
    "api repos/o/r/issues/7/comments --paginate --jq "*) echo "" ;;
    "api repos/o/r/issues/7/comments -f body="*) printf '%s' "${*#*-f body=}" > "$DS_DIR/comment" ;;
    *) echo "unexpected gh: $*" >&2; return 1 ;;
  esac
}
curl() { # the slot: -X METHOD, -o FILE, URL last
  local out="" method=GET url=""
  while [ $# -gt 0 ]; do
    case "$1" in -o) out=$2; shift ;; -X) method=$2; shift ;; --data-binary) cp "${2#@}" "$DS_DIR/uploaded"; shift ;; -w | -H | -m) shift ;; -sS) ;; *) url=$1 ;; esac
    shift
  done
  case "$method $url" in
    "PUT "*) printf '%s' "$SLOT_BODY" > "$out"; printf '%s' "$SLOT_CODE" ;;
    "DELETE "*) printf '{}' > "$out"; printf '200' ;;
    *) printf '{}' > "$out"; printf '404' ;;
  esac
}
dsrun() { # comment body, then optional env assignments: prints the comment the workflow posted
  rm -f "$DS_DIR/comment"
  (
    REPO=o/r PR=7 WHO=rev PLATFORM=desktop SLOT_URL=https://slot.test ARTIFACT=desktop-linux
    TARBALL=zedu-linux.tar.gz REQUIRED="Fork build,ClamAV" DEVICE_TOKEN=t BODY=$1
    shift
    for kv in "$@"; do export "${kv?}"; done
    ds_main > /dev/null 2>&1
  )
  if [ -f "$DS_DIR/comment" ]; then cat "$DS_DIR/comment"; else echo "(no comment)"; fi
}
ok_statuses='[{"context":"Fork build","state":"success"},{"context":"ClamAV","state":"success"}]'
ok_run='{"id":55,"conclusion":"success","created_at":"2026-01-01T00:00:00Z","path":".github/workflows/pr-build.yml"}'
check "device-session: other comments post nothing" "(no comment)" "$(dsrun 'looks good')"
check "device-session: a non-reviewer is refused" "yes" "$(dsrun '/test desktop' PERM=read | grep -q 'Only reviewers' && echo yes)"
check "device-session: /test shows the commands" "yes" "$(dsrun '/test' | grep -q '/test extend' && echo yes)"
check "device-session: a failing scan blocks the session" "yes" "$(dsrun '/test desktop' "STATUSES=$ok_statuses" | grep -q . && dsrun '/test desktop' 'STATUSES=[{"context":"Fork build","state":"success"}]' | grep -q -- '- ClamAV: missing' && echo yes)"
check "device-session: a failed fork build blocks the session" "yes" "$(dsrun '/test desktop' "STATUSES=$ok_statuses" 'RUN={"id":55,"conclusion":"failure","created_at":"x","path":".github/workflows/pr-build.yml"}' | grep -q 'has not succeeded' && echo yes)"
check "device-session: an unavailable platform is said so" "yes" "$(dsrun '/test android' | grep -q 'not available' && echo yes)"
body='{"path":"/s/tok","expires_in":1800,"holder":{}}'
check "device-session: a green build starts a session and posts the link" "yes" "$(dsrun '/test desktop' "STATUSES=$ok_statuses" "RUN=$ok_run" SLOT_CODE=201 "SLOT_BODY=$body" | grep -q 'https://slot.test/s/tok' && echo yes)"
check "device-session: the link comment says who may sign in and for how long" "yes" "$(dsrun '/test desktop' "STATUSES=$ok_statuses" "RUN=$ok_run" SLOT_CODE=201 "SLOT_BODY=$body" | grep -q 'zedu-hng reviewers).* It ends in 30 minutes' && echo yes)"
busy='{"error":"busy","state":"active","holder":{"pr":"12","sha":"abc1234","who":"someone"},"expires_in":600}'
check "device-session: a busy slot names the holder" "yes" "$(dsrun '/test desktop' "STATUSES=$ok_statuses" "RUN=$ok_run" SLOT_CODE=409 "SLOT_BODY=$busy" | grep -q 'PR #12.*@someone.*11 minutes' && echo yes)"
rm -f "$DS_DIR/uploaded"
dsrun '/test android' "STATUSES=$ok_statuses" "RUN=$ok_run" SLOT_CODE=201 "SLOT_BODY=$body" PLATFORM=android ARTIFACT=android-apk ARTIFACT_NAME=android-apk ZIP_FILE=apk.zip TARBALL=app-release.apk > /dev/null
check "device-session: an APK artifact is uploaded wrapped as app.apk in a tarball" "app.apk" "$(tar -tzf "$DS_DIR/uploaded" 2> /dev/null | tr '\n' ' ' | sed 's/ $//')"
rm -f "$DS_DIR/uploaded"
dsrun '/test desktop' "STATUSES=$ok_statuses" "RUN=$ok_run" SLOT_CODE=201 "SLOT_BODY=$body" > /dev/null
check "device-session: a tarball artifact is uploaded as is" "tarball" "$(cat "$DS_DIR/uploaded" 2> /dev/null)"
check "device-session: stop ends the session" "yes" "$(dsrun '/test stop' | grep -q 'ended by @rev' && echo yes)"
check "device-session: the comment carries its marker" "yes" "$(dsrun '/test' | grep -q 'device-session' && echo yes)"
unset -f gh curl
rm -rf "$DS_DIR"

# devices/firewall.sh against stub docker and iptables: the rule order, --dry-run changes nothing, and
# --check says whether a reboot has dropped the rules.
FW_DIR=$(mktemp -d)
# shellcheck disable=SC2016 # the stub's $3 must stay literal
printf '#!/bin/sh\ncase "$3" in othernet) echo 10.9.1.0/24 ;; *) echo 10.9.0.0/24 ;; esac\n' > "$FW_DIR/docker"
# shellcheck disable=SC2016 # the stub's $ variables must stay literal
printf '#!/bin/sh\necho "$*" >> "$FW_LOG"\ncase "$1" in -C) exit "${IPT_C_RC:-0}" ;; -S) [ "${IPT_S_RC:-0}" = 0 ] || exit "$IPT_S_RC"; echo "-N $2"; echo "${IPT_LAST:--A $2 -j DROP}"; exit 0 ;; esac\nexit 0\n' > "$FW_DIR/iptables"
chmod +x "$FW_DIR/docker" "$FW_DIR/iptables"
fw() { FW_LOG="$FW_DIR/log" PATH="$FW_DIR:$PATH" bash devices/firewall.sh slotnet 1.2.3.4 "$@"; }
: > "$FW_DIR/log"
fw_out=$(fw --dry-run)
check "firewall: --dry-run runs no iptables" "0" "$(wc -l < "$FW_DIR/log" | tr -d ' ')"
check "firewall: the slot network only opens the proxy and agent ports" "1" "$(grep -c -- '-s 10.9.0.0/24 -d 10.9.0.0/24 -p tcp -m multiport --dports 4180,8080 -j ACCEPT' <<< "$fw_out")"
host_drop=$(grep -n -- '-d 1.2.3.4/32 -j DROP' <<< "$fw_out" | cut -d: -f1)
dns_udp=$(grep -n -- '-p udp --dport 53 -j ACCEPT' <<< "$fw_out" | cut -d: -f1)
web_open=$(grep -n -- '-p tcp -m multiport --dports 80,443 -j ACCEPT' <<< "$fw_out" | tail -1 | cut -d: -f1)
check "firewall: DNS is allowed only after the private and host drops" "yes" "$([ "$dns_udp" -gt "$host_drop" ] && [ "$dns_udp" -lt "$web_open" ] && echo yes)"
check "firewall: slot traffic to the box itself is hooked into INPUT" "1" "$(grep -c -- 'iptables -I INPUT -s 10.9.0.0/24 -j DEVICES-INPUT' <<< "$fw_out")"
check "firewall: the last rule of the egress chain drops" "1" "$(grep -- 'iptables -A DEVICES-EGRESS' <<< "$fw_out" | tail -1 | grep -c -- '-j DROP')"
fw_two=$(FW_LOG="$FW_DIR/log" PATH="$FW_DIR:$PATH" bash devices/firewall.sh "slotnet othernet" 1.2.3.4 --dry-run)
check "firewall: two networks share one chain, built once" "1" "$(grep -c -- 'iptables -N DEVICES-EGRESS' <<< "$fw_two")"
check "firewall: each network gets its own slot-port rule and hooks" "6" "$(grep -c -E -- '(-s 10.9.[01].0/24 -d 10.9.[01].0/24 -p tcp -m multiport --dports 4180,8080 -j ACCEPT|-I DOCKER-USER -s 10.9.[01].0/24|-I INPUT -s 10.9.[01].0/24)' <<< "$fw_two")"
fw_two_comma=$(FW_LOG="$FW_DIR/log" PATH="$FW_DIR:$PATH" bash devices/firewall.sh "slotnet,othernet" 1.2.3.4 --dry-run)
check "firewall: one slot cannot reach another slot's proxy or agent" "0" "$(grep -c -E -- '-s 10.9.0.0/24 -d 10.9.1.0/24|-s 10.9.1.0/24 -d 10.9.0.0/24' <<< "$fw_two")"
check "firewall: networks can be comma separated" "2" "$(grep -c -- '-I DOCKER-USER -s' <<< "$fw_two_comma")"
fw_one_gone=$(IPT_C_RC=1 FW_LOG="$FW_DIR/log" PATH="$FW_DIR:$PATH" bash devices/firewall.sh "slotnet othernet" 1.2.3.4 --check); fw_rc=$?
check "firewall: --check names the hook of each network that is missing" "1 2" "$fw_rc $(grep -c 'MISSING: hook in DOCKER-USER' <<< "$fw_one_gone")"
: > "$FW_DIR/log"
fw_ok=$(fw --check); fw_rc=$?
check "firewall: --check passes when the rules are in place" "0 OK" "$fw_rc ${fw_ok%%:*}"
check "firewall: --check changes nothing" "0" "$(grep -c -E '^-(A|I|N|F|D) ' "$FW_DIR/log")"
fw_gone=$(IPT_C_RC=1 IPT_S_RC=1 fw --check); fw_rc=$?
check "firewall: --check fails after a reboot dropped the rules" "1" "$fw_rc"
check "firewall: --check names what is missing" "yes" "$(grep -q 'MISSING: hook in DOCKER-USER' <<< "$fw_gone" && grep -q 'MISSING: chain DEVICES-EGRESS' <<< "$fw_gone" && echo yes)"
fw_half=$(IPT_LAST='-A DEVICES-EGRESS -p tcp -j ACCEPT' fw --check); fw_rc=$?
check "firewall: --check fails when a chain does not end in its DROP" "1 yes" "$fw_rc $(grep -q 'MISSING: final DROP in DEVICES-EGRESS' <<< "$fw_half" && echo yes)"
UNIT=devices/systemd/devices-firewall.service
check "firewall unit: starts after Docker and needs it" "yes" "$(grep -q '^After=docker.service' "$UNIT" && grep -q '^Requires=docker.service' "$UNIT" && echo yes)"
# shellcheck disable=SC2016 # ${NETWORK} is literal unit syntax
check "firewall unit: runs the script with the configured network and ip" "1" "$(grep -c '^ExecStart=/usr/local/sbin/devices-firewall.sh ${NETWORK} ${HOST_IP}$' "$UNIT")"
check "firewall unit: retries until the network exists" "yes" "$(grep -q '^Restart=on-failure' "$UNIT" && grep -q '^RestartSec=' "$UNIT" && echo yes)"
check "firewall unit: enabled at boot" "1" "$(grep -c '^WantedBy=multi-user.target' "$UNIT")"
unset -f fw
rm -rf "$FW_DIR"

# pr-rules: the real "Check rules" script against a stub gh. Everything is enforced by default; each
# enforce_* switch turns one rule into a "Not enforced" success, and the status is still posted.
PRT=$(mktemp -d)
mkdir -p "$PRT/bin" "$PRT/.zedu-ci/scripts/lib"
cp scripts/lib/status.sh "$PRT/.zedu-ci/scripts/lib/status.sh"
ruby -ryaml -e 'y = YAML.load_file(ARGV[0]); puts y["jobs"]["rules"]["steps"].find { |s| s["name"] == "Check rules" }["run"]' .github/workflows/pr-rules.yml > "$PRT/rules.sh"
cat > "$PRT/bin/gh" << 'GHSTUB'
#!/usr/bin/env bash
case "$*" in
  "api repos/o/r --jq "*) echo "" ;;
  "api repos/o/r/collaborators/"*"/permission --jq .permission") echo "${PERM:-read}" ;;
  "api --paginate repos/o/r/pulls/7/commits --jq "*) printf '%s\n' "$COMMIT_AUTHORS" ;;
  "api --paginate repos/o/r/pulls/7/files --jq "*) printf '%b' "$FILES" ;;
  "api repos/o/r/commits/"*"/status --jq "*) ;;
  "api repos/o/r/contents/"*) printf '%s' '- [ ] I read it' | base64 ;;
  "api repos/o/r/statuses/"*)
    ctx=""; st=""; desc=""
    while [ $# -gt 0 ]; do
      case "$1" in -f) kv=$2; shift; case "$kv" in context=*) ctx=${kv#context=} ;; state=*) st=${kv#state=} ;; description=*) desc=${kv#description=} ;; esac ;; esac
      shift
    done
    echo "$ctx|$st|$desc" >> "$STATUS_LOG" ;;
  *) echo "unexpected gh: $*" >&2; exit 1 ;;
esac
GHSTUB
chmod +x "$PRT/bin/gh"
prr() { # env assignments that override the defaults; prints "context|state|description" per posted status
  : > "$PRT/log"
  (cd "$PRT" && env PATH="$PRT/bin:$PATH" STATUS_LOG="$PRT/log" GH_TOKEN=x REPO=o/r PR_NUMBER=7 HEAD_REPO=fork/r \
    HEAD_REF=fix/12-x AUTHOR=intern LABELS="" ACTION=opened LABEL="" TITLE_CHANGED=false BODY_CHANGED=false \
    BASE_CHANGED=false SHA=aaaa BASE_REF=dev TITLE="fix(X-12): a thing" BODY="- [x] i read it" PROTECTED='^\.github/' \
    SIZE_EXCLUDE='lock$' SIZE_LIMIT=400 TEMPLATE=.github/t.md RUN_URL=u ENFORCE_SINGLE_AUTHOR=true \
    ENFORCE_BRANCH_NAME=true ENFORCE_SIZE=true COMMIT_AUTHORS=alice 'FILES=10\tmodified\tsrc/a.ts\n' \
    "$@" bash rules.sh > /dev/null 2>&1)
  sort "$PRT/log"
}
st() { grep "^$2|" <<< "$1" | head -1 | cut -d'|' -f2; } # st <log> <context> -> state
BAD=(COMMIT_AUTHORS=$'alice\nbob' HEAD_REF=consolidated-sprint-3 'TITLE=fix(X-9): a thing' 'FILES=900\tmodified\tsrc/a.ts\n')
out=$(prr)
check "pr-rules: a clean one-person PR posts every rule green" "0" "$(grep -c '|failure|' <<< "$out")"
check "pr-rules: all six rules post a status" "6" "$(grep -c -E '^(Branch name|Single author|Protected files|Size|PR title|PR template)\|' <<< "$out")"
out=$(prr "${BAD[@]}")
check "pr-rules: by default several authors fail Single author" "failure" "$(st "$out" 'Single author')"
check "pr-rules: by default a free-form branch fails Branch name" "failure" "$(st "$out" 'Branch name')"
check "pr-rules: by default 900 lines fail Size" "failure" "$(st "$out" 'Size')"
check "pr-rules: by default a title that does not match the branch fails PR title" "failure" "$(st "$out" 'PR title')"
out=$(prr "${BAD[@]}" ENFORCE_SINGLE_AUTHOR=false)
check "pr-rules: enforce_single_author=false passes Single author, says so" "success|Not enforced: a PR may combine a team's work" "$(grep '^Single author|' <<< "$out" | cut -d'|' -f2,3)"
check "pr-rules: ...and leaves Branch name and Size enforced" "failure failure" "$(st "$out" 'Branch name') $(st "$out" 'Size')"
out=$(prr "${BAD[@]}" ENFORCE_SIZE=false)
check "pr-rules: enforce_size=false passes Size, says so" "success|Not enforced" "$(grep '^Size|' <<< "$out" | cut -d'|' -f2,3)"
check "pr-rules: ...and leaves Single author and Branch name enforced" "failure failure" "$(st "$out" 'Single author') $(st "$out" 'Branch name')"
out=$(prr "${BAD[@]}" ENFORCE_BRANCH_NAME=false)
check "pr-rules: enforce_branch_name=false passes Branch name, says so" "success|Not enforced" "$(grep '^Branch name|' <<< "$out" | cut -d'|' -f2,3)"
check "pr-rules: ...and stops comparing the title with the branch" "success" "$(st "$out" 'PR title')"
check "pr-rules: ...but still checks the title format" "failure" "$(st "$(prr "${BAD[@]}" ENFORCE_BRANCH_NAME=false 'TITLE=consolidated work')" 'PR title')"
out=$(prr "${BAD[@]}" ENFORCE_SINGLE_AUTHOR=false ENFORCE_BRANCH_NAME=false ENFORCE_SIZE=false)
check "pr-rules: with all three off a consolidated PR has no failure" "0" "$(grep -c '|failure|' <<< "$out")"
check "pr-rules: all three still post their status, so required checks keep reporting" "3" "$(grep -c -E '^(Branch name|Single author|Size)\|success\|Not enforced' <<< "$out")"
rm -rf "$PRT"

# sync-merge.sh: a resolution may differ from an automatic merge only in the files that conflicted.
SM="$PWD/scripts/sync-merge.sh"
SMT=$(mktemp -d)
(
  cd "$SMT" || exit 1
  export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
  g() { git -c init.defaultBranch=dev -c core.hooksPath=/dev/null "$@" > /dev/null; }
  g init -q
  printf 'one\n' > a.txt; printf 'keep\n' > b.txt; printf 'keep\n' > c.txt
  printf '.github/\n' > exclude
  g add -A; g commit -q -m base
  g switch -q -c upstream
  printf 'theirs\n' > a.txt; printf 'new\n' > d.txt
  g commit -q -am source
  g switch -q dev
  printf 'ours\n' > a.txt
  g commit -q -am target
  g update-ref refs/remotes/origin/dev dev
  # A plain resolution: a.txt resolved, d.txt comes from the source.
  g switch -q -c good dev
  g merge -q --no-ff --no-commit upstream || true
  printf 'both\n' > a.txt; g add a.txt
  g commit -q -m resolve
  # The same plus a change to a file that never conflicted.
  g switch -q -c evil dev
  g merge -q --no-ff --no-commit upstream || true
  printf 'both\n' > a.txt; printf 'evil\n' > c.txt; g add a.txt c.txt
  g commit -q -m resolve
  g switch -q dev
) || echo "FAIL sync-merge setup"
sm() { (cd "$SMT" && TARGET=dev SOURCE_REF=upstream SOURCE_LABEL=upstream EXCLUDE_FILE=exclude DRY_RUN=1 RESOLUTION_REF="$1" bash "$SM" > /dev/null 2>&1; echo "$?|$(cat sync-result.md 2> /dev/null)"); }
good=$(sm good)
check "sync-merge: a resolution that only fixes the conflict is accepted" "0" "${good%%|*}"
evil=$(sm evil)
check "sync-merge: a hidden change to another file is refused" "3" "${evil%%|*}"
check "sync-merge: ...and names the file" "1" "$(grep -c -- '- .c.txt.' <<< "$evil")"
check "sync-merge: ...but not the conflicted one" "0" "$(grep -c -- '- .a.txt.' <<< "$evil")"
rm -rf "$SMT"

[ "$fails" -eq 0 ] || { echo "$fails test(s) failed"; exit 1; }

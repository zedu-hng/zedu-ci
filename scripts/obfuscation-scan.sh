#!/usr/bin/env bash
# Obfuscation scan: fails when a PR adds hidden or obfuscated code.
# Usage: bash obfuscation-scan.sh <base> [head]   (head defaults to HEAD)
#
# Built from the loader family found in zedu-fe #813 #828 #854 and zedu-vulcan/zedu-mobile 9332400:
# a ~29 KB obfuscated line pushed off-screen behind thousands of tabs, appended to a config file or
# saved as api.js, and started from package.json scripts. Reads the diff as text. Never runs PR code.
#
# Only the lines a PR adds are judged, so old code never fails a new PR. The PR controls the diff
# view, so files are diffed as text (-a), padding includes JS whitespace beyond space and tab, and
# rules follow content, not the file extension (Node loads an unknown extension as JavaScript).
# Padding is collapsed before the other rules run, so code hidden behind it is judged too. Findings:
#   whitespace   200+ whitespace characters followed by code on the same line (any file but docs)
#   long line    8000+ characters on one line (JS/TS files); 1500+ in config and entry-point files
#   obfuscated   _0x identifiers or hex arithmetic, the javascript-obfuscator shape (JS/TS files)
#   IOC          a line matching scripts/obfuscation-iocs.txt (JS/TS files; "@any" entries: any text file)
#   loader file  temp_*push.bat or branch_structure.json
#   known file   a file whose git blob SHA is in scripts/known-bad-blobs.txt
#   disguised    a font or image that is plain text, not binary
#   wiring       package.json runs a file the PR adds, or an install script fetches from the network
#   auto-run     .vscode/tasks.json with runOn folderOpen
#
# Exit 0 clean, 1 findings, 2 could not read the diff.
# Env: IOCS, BLOBS (file paths), PAD_MIN (200), LONG_MIN (8000), CFG_LONG_MIN (1500).
#      SWEEP=1 when scanning a whole tree (base = the empty tree): every file counts as added, so the
#      package.json "runs a file this PR adds" rule is skipped.
set -uo pipefail
export LC_ALL=C

base=${1:?usage: obfuscation-scan.sh <base> [head]}
head=${2:-HEAD}
here=$(cd "$(dirname "$0")" && pwd)
iocs=${IOCS:-$here/obfuscation-iocs.txt}
blobs=${BLOBS:-$here/known-bad-blobs.txt}
pad=${PAD_MIN:-200}
long=${LONG_MIN:-8000}
cfglong=${CFG_LONG_MIN:-1500}

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
found=0

# File names and messages are attacker-influenced, so strip anything that can start a workflow
# command or break the Markdown summary: control characters, and for paths also , : % and friends.
report() { # file line message
  local f m
  f=$(printf '%s' "$1" | LC_ALL=C tr -c 'A-Za-z0-9._/@+ ()[]=-' '?')
  m=$(printf '%s' "$3" | LC_ALL=C tr -d '\000-\037\177')
  found=$((found + 1))
  printf '::error file=%s,line=%s::%s\n' "$f" "$2" "$m"
  # shellcheck disable=SC2016 # literal backticks for Markdown
  printf -- '- `%s:%s` %s\n' "$f" "$2" "$m"
}

if ! git --literal-pathspecs diff --name-status -z --no-renames --no-ext-diff --diff-filter=AM "$base" "$head" > "$tmp/files.z"; then
  echo "::error::Obfuscation scan could not diff $base..$head. Check the checkout depth."
  exit 2
fi

# Files added by this PR, for the package.json wiring check.
while IFS= read -r -d '' status && IFS= read -r -d '' path; do
  [ "$status" = A ] && printf '%s\n' "$path" >> "$tmp/added.txt"
done < "$tmp/files.z"
touch "$tmp/added.txt"

# Awk over `git diff -U0` of one file. Prints "<line>\t<message>" per finding, or with dump=1
# "<line>\t<added text>" for every added line.
read -r -d '' awk_prog <<'AWK'
function cnt(s, re,   n) { n = 0; while (match(s, re)) { n++; s = substr(s, RSTART + RLENGTH) } return n }
function emit(l, m) { if (shown++ < 5) printf "%d\t%s\n", l, m }
BEGIN {
  for (i = 0; i < pad; i++) padre = padre "[ \t]"
  padre = padre "[ \t]*[^ \t\r]"
  # Whitespace JS accepts besides space and tab: VT, FF, NBSP, BOM, U+1680, U+2000-200A, U+202F,
  # U+205F, U+3000. Folded to a space (bytes, C locale) so padding with them is judged too.
  jsws = "[\013\014]|\302\240|\357\273\277|\341\232\200|\342\200[\200-\212\257]|\342\201\237|\343\200\200"
  if (!dump) {
    while ((getline p < iocs) > 0) {
      if (p ~ /^[ \t]*(#|$)/) continue
      if (p ~ /^@any[ \t]+/) { sub(/^@any[ \t]+/, "", p); any[++nany] = p } else ioc[++nioc] = p
    }
    close(iocs)
  }
}
/^@@/ { match($0, /\+[0-9]+/); ln = substr($0, RSTART + 1, RLENGTH - 1) + 0; hunk = 1; next }
!hunk { next }
/^\+/ {
  t = substr($0, 2); cur = ln++
  if (dump) { print cur "\t" t; next }
  u = t
  gsub(jsws, " ", u)
  # Markdown table rows are padded to align columns, and a line that starts with | is not code.
  if (!(mdtable && u ~ /^[ \t]*\|/) && match(u, padre)) {
    emit(cur, "code hidden after " pad "+ whitespace characters (column " RSTART ")")
    gsub(/[ \t][ \t]+/, " ", u)
  }
  for (i = 1; i <= nany; i++) if (u ~ any[i]) { emit(cur, "matches known malware indicator: " any[i]); break }
  if (cfg && length(u) >= cfglong) emit(cur, "config or entry-point line is " length(u) " characters long")
  if (longrule && !cfg && length(u) >= long) emit(cur, "line is " length(u) " characters long")
  # Patterns are strings: a /regex/ passed to a function would be evaluated as $0 ~ /regex/.
  if (obfrule && (cnt(u, "_0x[0-9a-fA-F][0-9a-fA-F][0-9a-fA-F]+") >= 3 || cnt(u, "0x[0-9a-fA-F]+ *[-+*]") >= 3))
    emit(cur, "obfuscated code (_0x identifiers or hex arithmetic)")
  if (iocrule) for (i = 1; i <= nioc; i++) if (u ~ ioc[i]) { emit(cur, "matches known malware indicator: " ioc[i]); break }
  next
}
AWK

# -a: judge every file as text. Without it git prints "Binary files differ" for a file with a NUL
# byte or a .gitattributes "-diff" entry (both set by the PR itself) and nothing is scanned.
# --literal-pathspecs: a file name is never glob or pathspec magic (":(exclude)" and the like).
diff_of() { git --literal-pathspecs diff -a -U0 --no-ext-diff --no-textconv --no-renames "$base" "$head" -- "$1"; }

while IFS= read -r -d '' status && IFS= read -r -d '' path; do
  name=${path##*/}
  ext=$(printf '%s' "${name##*.}" | tr '[:upper:]' '[:lower:]')
  # Node loads an unknown extension as JavaScript, so rules follow content, not the extension. Only
  # formats that cannot be loaded as code, or that are long by nature, are exempt from a rule.
  text=1; longrule=1; obfrule=1; iocrule=1; mdtable=0
  case "$ext" in md | mdx) mdtable=1 ;; esac
  case "$ext" in
    woff | woff2 | ttf | otf | eot | llf | png | jpg | jpeg | gif | ico | webp | pdf | zip | gz | mp3 | mp4 | mov | wasm) text=0 ;;
    json | svg | map | csv | snap | lock | yaml | yml) longrule=0; obfrule=0 ;;
    m | mm | swift | kt | java | c | h | cc | cpp | gradle) iocrule=0 ;;
  esac
  case "$name" in
    *.min.* | *-lock.json | pnpm-lock.yaml) longrule=0 ;;
  esac
  cfg=0
  case "$name" in
    babel.config.* | postcss.config.* | tailwind.config.* | next.config.* | eslint.config.* | .eslintrc* \
      | vite.config.* | vitest.config.* | webpack.config.* | metro.config.* | jest.config.* \
      | rollup.config.* | prettier.config.* | .prettierrc* | commitlint.config.* \
      | index.js | index.mjs | index.cjs | index.ts) cfg=1 ;;
  esac

  case "$name" in
    temp_auto_push.bat | temp_interactive_push.bat | branch_structure.json)
      report "$path" 1 "file used by the PolinRider loader to spread" ;;
  esac
  sha=$(git rev-parse "$head:$path" 2> /dev/null || true)
  if [ -n "$sha" ] && grep -qi "^$sha" "$blobs" 2> /dev/null; then
    report "$path" 1 "known malicious file (blob $sha)"
  fi

  case "$ext" in
    woff | woff2 | ttf | otf | eot | llf | png | jpg | jpeg | gif | ico | webp)
      size=$(git cat-file -s "$head:$path" 2> /dev/null || echo 0)
      printable_only=$(git show "$head:$path" 2> /dev/null | head -c 512 | tr -d '[:print:][:space:]' | wc -c)
      if [ "$size" -gt 0 ] && [ "$printable_only" -eq 0 ]; then
        report "$path" 1 "a .$ext file that is plain text, not binary (disguised payload)"
      fi ;;
  esac

  case "$path" in
    .vscode/tasks.json | */.vscode/tasks.json)
      git show "$head:$path" 2> /dev/null | grep -q folderOpen \
        && report "$path" 1 "task set to run when the folder opens (runOn: folderOpen)" ;;
  esac

  if [ "$text" = 1 ]; then
    while IFS=$'\t' read -r ln msg; do
      [ -n "$ln" ] && report "$path" "$ln" "$msg"
    done < <(diff_of "$path" | awk -v pad="$pad" -v long="$long" -v mdtable="$mdtable" -v longrule="$longrule" -v obfrule="$obfrule" -v iocrule="$iocrule" -v cfg="$cfg" -v cfglong="$cfglong" -v iocs="$iocs" -v dump=0 "$awk_prog")
  fi

  if [ "$name" = package.json ]; then
    while IFS=$'\t' read -r ln line; do
      for ref in $([ "${SWEEP:-0}" = 1 ] || printf '%s' "$line" | grep -oE 'node +(--?[A-Za-z-]+(=[^ ]+)? +)*[./A-Za-z0-9_@-]+' | awk '{print $NF}'); do
        ref=${ref#./}
        [ "$(dirname "$path")" != . ] && ref=$(dirname "$path")/$ref
        grep -qxF "$ref" "$tmp/added.txt" && report "$path" "$ln" "script runs $ref, a file this PR adds"
      done
      if printf '%s' "$line" | grep -qE '"(pre|post)?install"|"prepare"' && printf '%s' "$line" | grep -qE 'curl|wget|https?://'; then
        report "$path" "$ln" "install script fetches from the network"
      fi
    done < <(diff_of "$path" | awk -v pad="$pad" -v long="$long" -v iocs="$iocs" -v dump=1 "$awk_prog")
  fi
done < "$tmp/files.z"

if [ "$found" -gt 0 ]; then
  echo
  echo "$found finding(s). Do not run this code. Report the PR to a reviewer."
  exit 1
fi
echo "No obfuscated or hidden code found."

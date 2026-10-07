# shellcheck shell=bash
# Whether a PR changes only Markdown, so it needs no fork build. The fork's build gate skips the build
# for such a PR, and the review repo's Fork build relay marks it "no build needed"; both use this rule.
#
#   docs_only <total changed files>  (paths on stdin, one per line; the first 100 are enough)
#     Succeeds when the PR changes between 1 and 100 files and every one ends in ".md". Larger PRs
#     always build: their full file list would take more API calls than it saves.

docs_only() {
  local total=$1 paths
  [[ "$total" =~ ^[0-9]+$ ]] && [ "$total" -gt 0 ] && [ "$total" -le 100 ] || return 1
  paths=$(grep . || true)
  [ "$(grep -c . <<< "$paths")" -eq "$total" ] || return 1
  ! grep -qv '\.md$' <<< "$paths"
}

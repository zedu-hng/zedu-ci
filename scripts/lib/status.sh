# shellcheck shell=bash disable=SC2034 # status_outcome is read by the caller
# Commit statuses, written only when they change: every write is an API call on the repo's shared
# token, and GitHub caps statuses per commit and context. Needs REPO and GH_TOKEN.
#
#   status_set <sha> <context> <state> <description> [target_url]
#     Sets status_outcome to "posted" or "unchanged". Fails only when the write fails. The commit's
#     current statuses are read once per sha and kept up to date with this function's own writes, so
#     call it directly, not in $(...), or the cache is lost with the subshell.

status_set() {
  local sha=$1 context=$2 state=$3 desc=${4:0:140} url=${5:-}
  if [ "${_status_sha:-}" != "$sha" ]; then
    _status_current=$(gh api "repos/$REPO/commits/$sha/status" \
      --jq '.statuses[] | "\(.context)|\(.state)|\(.description)"') || _status_current=""
    _status_sha=$sha
  fi
  if grep -qxF "$context|$state|$desc" <<< "$_status_current"; then
    status_outcome=unchanged
    return 0
  fi
  gh api "repos/$REPO/statuses/$sha" -f context="$context" -f state="$state" -f description="$desc" \
    ${url:+-f target_url="$url"} >/dev/null || return 1
  _status_current=$(awk -F'|' -v c="$context" '$1 != c' <<< "$_status_current"; echo "$context|$state|$desc")
  status_outcome=posted
}

# shellcheck shell=bash
# Merge-conflict verdict for the "No merge conflicts" status.
#
#   conflict_verdict <mergeable> <base> <enforce>
#     <mergeable> is the pulls API value: true, false, or null while GitHub is still computing it.
#     Prints "<state>|<description>", or nothing when the answer is not known yet (the caller retries).
#     With <enforce> false it always prints success, so a required check keeps reporting.

conflict_verdict() {
  local mergeable=$1 base=$2 enforce=${3:-true}
  if [ "$enforce" != true ]; then
    echo "success|Not enforced"
    return 0
  fi
  case "$mergeable" in
    true) echo "success|No conflicts with $base." ;;
    false) echo "failure|Conflicts with $base. Merge or rebase $base, then push." ;;
  esac
}

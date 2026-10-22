#!/usr/bin/env bash
# Merge SOURCE_REF into TARGET with a merge commit and push it, so sync PRs never get squashed.
#
#   TARGET             review-org branch to update, e.g. central-staging or dev (fetched as origin/TARGET)
#   SOURCE_REF         ref to merge in, e.g. upstream/central-staging or origin/central-staging
#   SOURCE_LABEL       name used in the commit message, e.g. zeduchat/zedu-mobile:central-staging
#   EXCLUDE_FILE       review-org paths (default .github/upstream-exclude, from the current checkout)
#   RESOLUTION_REF     a reviewer's branch whose tip is the resolved merge; pushed instead of merging,
#                      only if that tip is one merge commit with parents exactly TARGET and SOURCE_REF
#   APPROVE_PROTECTED  1 = a reviewer checked the review-org path changes; merge them too
#   DRY_RUN            1 = merge locally, don't push
#
# The push needs ruleset bypass (the sync deploy key). It only pushes a clean merge that leaves the
# review-org paths alone: upstream rewriting our workflows or docs needs a reviewer's eyes first.
# Exit codes: 0 merged or already up to date, 3 conflict, 4 touches review-org paths.
# Writes the outcome to sync-result.md.
set -euo pipefail
diff_file=$(mktemp)
trap 'rm -f "$diff_file"' EXIT

: "${TARGET:?}" "${SOURCE_REF:?}" "${SOURCE_LABEL:?}"
EXCLUDE_FILE=${EXCLUDE_FILE:-.github/upstream-exclude}
excludes=$(sed -e 's/#.*//' -e 's/[[:space:]]*$//' "$EXCLUDE_FILE" | grep -v '^$')

is_excluded() {
  local path=$1 entry
  while IFS= read -r entry; do
    case "$entry" in
      */) [[ "$path" == "$entry"* ]] && return 0 ;;
      *)  [[ "$path" == "$entry" ]] && return 0 ;;
    esac
  done <<< "$excludes"
  return 1
}

base=$(git rev-parse "origin/$TARGET^{commit}")
source=$(git rev-parse "$SOURCE_REF^{commit}")

if git merge-base --is-ancestor "$source" "$base"; then
  echo "$TARGET already contains $SOURCE_LABEL (${source:0:7})." | tee sync-result.md
  exit 0
fi

if [ -n "${RESOLUTION_REF:-}" ]; then
  resolution=$(git rev-parse "$RESOLUTION_REF^{commit}")
  # Exactly one merge commit on top of TARGET: extra commits would ride the ruleset bypass unreviewed.
  if [ "$(git rev-list --parents -n1 "$resolution")" != "$resolution $base $source" ]; then
    echo "\`$RESOLUTION_REF\` must be one merge commit with parents \`$TARGET\` (${base:0:7}) then ${source:0:7}, nothing else. Recreate it from the current \`$TARGET\`." | tee sync-result.md
    exit 3
  fi
  git switch -q -C "sync-$TARGET" "$resolution"
else
  git switch -q -C "sync-$TARGET" "$base"
  if ! git merge -q --no-ff --no-edit -m "chore: sync $TARGET from $SOURCE_LABEL" "$source"; then
    git merge --abort
    {
      echo "Merging \`$SOURCE_LABEL\` (${source:0:7}) into \`$TARGET\` conflicts. A reviewer resolves it:"
      echo
      echo "1. Branch from \`$TARGET\`, run \`git merge --no-ff ${source:0:7}\`, resolve, push the branch."
      echo "2. Actions -> Sync upstream -> Run workflow, with \`resolution\` = \`$TARGET:<your-branch>\`."
    } | tee sync-result.md
    exit 3
  fi
fi

# Only what this merge brings into TARGET. NUL-delimited raw paths, no rename detection.
# Written to a file first: a failing git diff inside <(...) would skip the gate and push.
git diff --no-renames --name-only -z "$base" HEAD > "$diff_file"
protected=()
while IFS= read -r -d '' path; do
  is_excluded "$path" && protected+=("$path")
done < "$diff_file"

if [ "${#protected[@]}" -gt 0 ] && [ "${APPROVE_PROTECTED:-}" != 1 ]; then
  {
    echo "Merging \`$SOURCE_LABEL\` (${source:0:7}) into \`$TARGET\` changes review-org paths:"
    echo
    # shellcheck disable=SC2016 # literal backticks: Markdown code spans
    printf -- '- `%s`\n' "${protected[@]}"
    echo
    echo "Review the diff on this PR. If it's fine, run Actions -> Sync upstream -> Run workflow with"
    echo "\`approve_protected\` checked. The workflow merges it with a merge commit; don't merge this PR yourself."
  } | tee sync-result.md
  exit 4
fi

if [ -n "${DRY_RUN:-}" ]; then
  echo "Dry run: would push $(git rev-parse --short HEAD) to $TARGET." | tee sync-result.md
  exit 0
fi
# Plain push: if TARGET moved since the fetch, git rejects it and the next run retries.
git push -q origin "HEAD:refs/heads/$TARGET"
echo "Merged \`$SOURCE_LABEL\` (${source:0:7}) into \`$TARGET\` as $(git rev-parse --short HEAD)." | tee sync-result.md

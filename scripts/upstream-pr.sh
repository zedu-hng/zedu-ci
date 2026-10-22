#!/usr/bin/env bash
# Send a built upstream batch to zeduchat: push the branch here, then open the PR there.
#
#   BRANCH           batch branch built by upstream-batch.sh (checked out)
#   REVIEW_REPO      review-org repo, e.g. zedu-hng/zedu-mobile
#   UPSTREAM_REPO    upstream repo, e.g. zeduchat/zedu-mobile
#   UPSTREAM_BRANCH  upstream base branch, e.g. central-staging
#   SENT_FILE        batch-sent.tsv from upstream-batch.sh (<source sha><TAB><subject>, oldest first)
#   SUMMARY          batch-summary.md from upstream-batch.sh
#   UPSTREAM_TOKEN   optional. Token that can open PRs on UPSTREAM_REPO. Without it, only a prefilled
#                    link and the PR text are written to the run summary.
#   GH_TOKEN         read access to both repos (the workflow token)
#
# The PR title and body are those of the newest merged review-org PR in the batch, unchanged, plus a
# footer. A batch holds every commit not yet in zeduchat, so it also carries the earlier open batches:
# those PRs get a "superseded" note, and the footer lists the review-org PRs the batch includes.
# A batch whose tree matches an already open batch PR is not sent again.
set -euo pipefail

: "${BRANCH:?}" "${REVIEW_REPO:?}" "${UPSTREAM_REPO:?}" "${UPSTREAM_BRANCH:?}" "${SENT_FILE:?}" "${SUMMARY:?}"
owner=${REVIEW_REPO%/*}
out=${GITHUB_STEP_SUMMARY:-/dev/stdout}
marker='<!-- zedu-superseded -->'

# Review-org PR behind a source commit (the merged one), as "<number><TAB><title>".
pr_of() {
  gh api "repos/$REVIEW_REPO/commits/$1/pulls" \
    --jq '[.[] | select(.merged_at != null)][0] | select(. != null) | "\(.number)\t\(.title)"'
}

# Open batch PRs from this org's fork: "<number><TAB><head branch>".
open_batches() {
  gh pr list -R "$UPSTREAM_REPO" --state open --base "$UPSTREAM_BRANCH" --limit 50 \
    --json number,headRefName,headRepositoryOwner \
    --jq ".[] | select(.headRepositoryOwner.login == \"$owner\" and (.headRefName | startswith(\"batch/\"))) | \"\(.number)\t\(.headRefName)\""
}

# Nothing new if an open batch already has this exact tree.
tree=$(git rev-parse "HEAD^{tree}")
while IFS=$'\t' read -r num head; do
  [ -n "$num" ] || continue
  git fetch -q origin "$head" 2>/dev/null || continue
  if [ "$(git rev-parse "FETCH_HEAD^{tree}")" = "$tree" ]; then
    echo "Batch matches open PR $UPSTREAM_REPO#$num ($head). Nothing new to send." | tee -a "$out"
    exit 0
  fi
done < <(open_batches)

# Newest sent commit with a merged PR gives the text. Each older PR (a PR can have several commits)
# is listed once, in the order it was merged.
text_pr="" text_title="" included=""
declare -A titles=()
order=()
while IFS=$'\t' read -r sha _; do
  row=$(pr_of "$sha" || true)
  [ -n "$row" ] || continue
  text_pr=${row%%$'\t'*}
  text_title=${row#*$'\t'}
  if [ -z "${titles[$text_pr]+x}" ]; then order+=("$text_pr"); fi
  titles[$text_pr]=$text_title
done < "$SENT_FILE"
for n in "${order[@]+"${order[@]}"}"; do
  if [ "$n" != "$text_pr" ]; then
    included+="- $REVIEW_REPO#$n ${titles[$n]}"$'\n'
  fi
done

if [ -z "$text_pr" ]; then
  echo "::error::No merged $REVIEW_REPO PR found for the commits in this batch." >&2
  exit 1
fi

title=$text_title
body_file=$(mktemp)
trap 'rm -f "$body_file"' EXIT
gh api "repos/$REVIEW_REPO/pulls/$text_pr" --jq '.body // ""' > "$body_file"
{
  echo
  echo '---'
  if [ -n "$included" ]; then
    echo "This batch also carries earlier $REVIEW_REPO PRs:"
    printf '%s' "$included"
    echo
  fi
  echo "Reviewed and merged in $REVIEW_REPO#$text_pr."
} >> "$body_file"

git push -q origin "$BRANCH"

if [ -z "${UPSTREAM_TOKEN:-}" ]; then
  upstream_branch=$(jq -rn --arg v "$UPSTREAM_BRANCH" '$v|@uri')
  head="$owner:${REVIEW_REPO#*/}:$BRANCH"
  base_url="https://github.com/$UPSTREAM_REPO/compare/$upstream_branch...$head?expand=1&title=$(jq -rn --arg v "$title" '$v|@uri')"
  encoded=$(jq -sRr @uri < "$body_file")
  # Longer URLs are refused by GitHub, so the body is pasted by hand.
  if [ "${#encoded}" -le 6000 ]; then
    url="$base_url&body=$encoded"
    note="prefilled"
  else
    url=$base_url
    note="title only: the body is too long for a link, paste it from below"
  fi
  {
    cat "$SUMMARY"
    echo
    echo "**[Open the PR to \`$UPSTREAM_REPO:$UPSTREAM_BRANCH\`]($url)** ($note; merge with a merge commit, not squash)."
    echo
    echo "Title: \`$title\`"
    echo
    echo '<details><summary>PR body</summary>'
    echo
    echo '````markdown'
    cat "$body_file"
    echo '````'
    echo
    echo '</details>'
    echo
    echo "Open batch PRs this one supersedes (add \"Superseded by <new PR>. Merge it to land all.\"):"
    open_batches | cut -f1 | sed "s|^|- $UPSTREAM_REPO#|"
  } >> "$out"
  exit 0
fi

new_url=$(GH_TOKEN=$UPSTREAM_TOKEN gh pr create -R "$UPSTREAM_REPO" --base "$UPSTREAM_BRANCH" \
  --head "$owner:$BRANCH" --title "$title" --body-file "$body_file")
new=${new_url##*/}
{
  cat "$SUMMARY"
  echo
  echo "**Opened [$UPSTREAM_REPO#$new]($new_url)** (merge with a merge commit, not squash)."
} >> "$out"

# Older open batches are contained in the new one. Point them at it.
while IFS=$'\t' read -r num _; do
  if [ -z "$num" ] || [ "$num" = "$new" ]; then continue; fi
  old=$(mktemp)
  gh pr view "$num" -R "$UPSTREAM_REPO" --json body --jq .body > "$old"
  if ! grep -qF "$marker" "$old"; then
    {
      echo "> **Superseded by #$new.** It carries every commit in this PR. Merge #$new to land all."
      echo "> $marker"
      echo
      cat "$old"
    } > "$old.new"
    GH_TOKEN=$UPSTREAM_TOKEN gh pr edit "$num" -R "$UPSTREAM_REPO" --body-file "$old.new"
    echo "Marked $UPSTREAM_REPO#$num as superseded by #$new." >> "$out"
    rm -f "$old.new"
  fi
  rm -f "$old"
done < <(open_batches)

#!/usr/bin/env bash
# Publishes a checks workflow's results.tsv ("<context>\t<success|failure>\t<description>" per line)
# in the one format pr-review-comment.yml reads: pr-checks-results.json, plus a step summary table.
# Sets fail=<number of failed checks> in GITHUB_ENV. Needs SHA, WORKFLOW and RUN_URL.
# Does nothing when SKIP_PUBLISH=true.
set -euo pipefail

# A run that must not change the PR's statuses (a preview-only rebuild) sets SKIP_PUBLISH=true.
if [ "${SKIP_PUBLISH:-}" = true ]; then
  echo "fail=0" >> "$GITHUB_ENV"
  exit 0
fi
if [ ! -s results.tsv ]; then
  echo "::error::No check results were recorded."
  echo "fail=1" >> "$GITHUB_ENV"
  exit 0
fi
{
  echo "### $WORKFLOW for \`${SHA:0:7}\`"
  echo
  echo "| Check | Result |"
  echo "|---|---|"
  awk -F'\t' '{ printf "| %s | %s: %s |\n", $1, $2, $3 }' results.tsv
} >> "$GITHUB_STEP_SUMMARY"
jq -Rn --arg sha "$SHA" --arg url "$RUN_URL" \
  '{sha: $sha, url: $url, checks: [inputs | split("\t") | {context: .[0], state: .[1], description: .[2]}]}' \
  < results.tsv > pr-checks-results.json
echo "fail=$(awk -F'\t' '$2 != "success"' results.tsv | grep -c . || true)" >> "$GITHUB_ENV"

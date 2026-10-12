# shellcheck shell=bash
# Helpers for device-session.yml: one "/test ..." comment on a PR becomes a device-slot session.
# Pure functions first (tested without GitHub), then ds_main, which talks to GitHub and the slot.
#
# ds_main needs: GH_TOKEN, REPO, PR, WHO (the commenter), BODY (the comment), PLATFORM, SLOT_URL,
# ARTIFACT, TARBALL, REQUIRED (comma-separated status contexts), DEVICE_TOKEN.

# ds_command <comment body> -> none | help | stop | extend | start:<platform>
ds_command() {
  local first word
  first=$(printf '%s\n' "$1" | tr -d '\r' | head -1)
  case "$first" in
    "/test") echo help ;;
    "/test "*)
      read -r _ word _ <<< "$first"
      case "$word" in
        desktop | android) echo "start:$word" ;;
        stop | extend) echo "$word" ;;
        *) echo help ;;
      esac
      ;;
    *) echo none ;;
  esac
}

# ds_missing_statuses <commit statuses JSON, newest first> <comma-separated contexts>
# Prints "<context>: <state>" for each required context whose latest state is not success.
ds_missing_statuses() {
  jq -r --arg csv "$2" '
    ($csv | split(",") | map(gsub("^\\s+|\\s+$"; "")) | map(select(length > 0))) as $need
    | (reduce .[] as $s ({}; if has($s.context) then . else .[$s.context] = $s.state end)) as $by
    | $need[] | select(($by[.] // "missing") != "success") | "\(.): \($by[.] // "missing")"' <<< "$1"
}

# ds_pick_artifact <artifacts JSON from the Actions API> <name> -> the id of the newest unexpired one
ds_pick_artifact() {
  jq -r --arg n "$2" '[.artifacts[] | select(.name == $n and (.expired | not))] | sort_by(.created_at) | last | .id // empty' <<< "$1"
}

DS_MARK="<!-- device-session -->"

ds_comment() { # markdown body on stdin: edit this workflow's own comment, or create it
  local text id
  text="$DS_MARK"$'\n'"$(cat)"
  id=$(gh api "repos/$REPO/issues/$PR/comments" --paginate \
    --jq "[.[] | select(.body | contains(\"$DS_MARK\")) | .id] | first // empty" 2> /dev/null || true)
  if [ -n "$id" ]; then
    gh api -X PATCH "repos/$REPO/issues/comments/$id" -f body="$text" > /dev/null
  else
    gh api "repos/$REPO/issues/$PR/comments" -f body="$text" > /dev/null
  fi
}

ds_usage() {
  cat <<USAGE
Reviewers can start a device session on this PR's build:

- \`/test $PLATFORM\` starts it. One session at a time. It needs a green fork build and clean scans.
- \`/test extend\` adds 15 minutes, once.
- \`/test stop\` ends it.
USAGE
}

# slot <outfile> <curl args...>: calls the slot's API, prints the HTTP status
slot() {
  local out=$1
  shift
  curl -sS -m 120 -o "$out" -w '%{http_code}' -H "Authorization: Bearer $DEVICE_TOKEN" "$@" 2> /dev/null || echo 000
}

ds_main() {
  local cmd perm out code pr state sha head_repo missing run run_id artifacts art_id size work

  cmd=$(ds_command "$BODY")
  [ "$cmd" != none ] || return 0
  [[ "$PR" =~ ^[0-9]+$ ]] || { echo "Invalid PR number" >&2; return 1; }
  [[ "$WHO" =~ ^[A-Za-z0-9-]+(\[bot\])?$ ]] || { echo "Invalid login" >&2; return 1; }

  # Only reviewers: the workflow token cannot read org teams, so use repo write access (as /claim does).
  perm=$(gh api "repos/$REPO/collaborators/$WHO/permission" --jq .permission 2> /dev/null || echo none)
  case "$perm" in
    admin | maintain | write) ;;
    *)
      echo "Only reviewers can start a device session. @$WHO is not one." | ds_comment
      return 0
      ;;
  esac

  work=$(mktemp -d)
  out="$work/out.json"

  case "$cmd" in
    help)
      ds_usage | ds_comment
      return 0
      ;;
    stop)
      code=$(slot "$out" -X DELETE "$SLOT_URL/api/session")
      if [ "$code" = 200 ]; then
        echo "The $PLATFORM session was ended by @$WHO." | ds_comment
      else
        echo "Could not reach the $PLATFORM slot (HTTP $code). It ends by itself after 30 minutes." | ds_comment
      fi
      return 0
      ;;
    extend)
      code=$(slot "$out" -X POST "$SLOT_URL/api/extend")
      case "$code" in
        200) echo "The $PLATFORM session has $(($(jq -r .expires_in "$out") / 60)) minutes left (extended by @$WHO)." | ds_comment ;;
        409) echo "Nothing to extend: $(jq -r '.error' "$out")." | ds_comment ;;
        *) echo "Could not extend the $PLATFORM session (HTTP $code)." | ds_comment ;;
      esac
      return 0
      ;;
    "start:$PLATFORM") ;;
    start:*)
      echo "${cmd#start:} sessions are not available on this repo. Use \`/test $PLATFORM\`." | ds_comment
      return 0
      ;;
  esac

  pr=$(gh api "repos/$REPO/pulls/$PR" --jq '[.state, .head.sha, (.head.repo.full_name // "")] | @tsv')
  IFS=$'\t' read -r state sha head_repo <<< "$pr"
  if [ "$state" != open ] || [ -z "$head_repo" ] || [[ ! "$sha" =~ ^[0-9a-f]{40}$ ]]; then
    echo "This PR is not open or its fork is gone." | ds_comment
    return 0
  fi

  # The scans must have passed for this exact commit. A session runs the PR's build.
  missing=$(ds_missing_statuses "$(gh api "repos/$REPO/commits/$sha/statuses?per_page=100")" "$REQUIRED")
  if [ -n "$missing" ]; then
    {
      echo "No session for \`${sha:0:7}\` yet. These must pass first:"
      echo
      sed 's/^/- /' <<< "$missing"
    } | ds_comment
    return 0
  fi

  run=$(gh api "repos/$head_repo/actions/workflows/pr-build.yml/runs?head_sha=$sha&per_page=10" \
    --jq '[.workflow_runs[] | select(.path == ".github/workflows/pr-build.yml")] | sort_by(.created_at) | last // empty' 2> /dev/null || true)
  if [ -z "$run" ] || [ "$(jq -r .conclusion <<< "$run")" != success ]; then
    echo "The fork build for \`${sha:0:7}\` has not succeeded, so there is nothing to run. Comment \`/test $PLATFORM\` again once it has." | ds_comment
    return 0
  fi
  run_id=$(jq -r .id <<< "$run")
  artifacts=$(gh api "repos/$head_repo/actions/runs/$run_id/artifacts?per_page=100")
  art_id=$(ds_pick_artifact "$artifacts" "$ARTIFACT")
  if [[ ! "$art_id" =~ ^[0-9]+$ ]]; then
    echo "The fork build has no \`$ARTIFACT\` artifact (expired, or the build skipped it). Re-run **PR build** in the fork." | ds_comment
    return 0
  fi
  size=$(jq -r --arg id "$art_id" '.artifacts[] | select((.id | tostring) == $id) | .size_in_bytes' <<< "$artifacts")
  if [ "${size:-0}" -gt $((300 * 1024 * 1024)) ]; then
    echo "The \`$ARTIFACT\` artifact is $((size / 1048576)) MB, over the slot's 300 MB limit." | ds_comment
    return 0
  fi

  gh api "repos/$head_repo/actions/artifacts/$art_id/zip" > "$work/a.zip"
  unzip -p "$work/a.zip" "$TARBALL" > "$work/app.tar.gz" 2> /dev/null || true
  if [ ! -s "$work/app.tar.gz" ]; then
    echo "The artifact has no $TARBALL." | ds_comment
    return 0
  fi

  code=$(slot "$out" -X PUT -H 'Expect:' --data-binary @"$work/app.tar.gz" \
    "$SLOT_URL/api/session?pr=$PR&sha=${sha:0:7}&who=$WHO")
  case "$code" in
    201)
      {
        echo "**$PLATFORM session for \`${sha:0:7}\` is up.** Started by @$WHO."
        echo
        echo "$SLOT_URL$(jq -r .path "$out")"
        echo
        echo "Sign in with GitHub (zedu-hng reviewers). It ends in $(($(jq -r .expires_in "$out") / 60)) minutes."
        echo "\`/test extend\` adds 15 minutes, once. \`/test stop\` ends it."
      } | ds_comment
      ;;
    409)
      {
        echo "The $PLATFORM slot is busy: PR #$(jq -r .holder.pr "$out") (\`$(jq -r .holder.sha "$out")\`), started by @$(jq -r .holder.who "$out"), frees in about $(($(jq -r .expires_in "$out") / 60 + 1)) minutes."
        echo "Comment \`/test $PLATFORM\` again then, or ask them to \`/test stop\`."
      } | ds_comment
      ;;
    *)
      echo "The $PLATFORM slot did not start the build (HTTP $code: $(jq -r '.error // empty' "$out" 2> /dev/null | head -c 200)). Try again in a minute." | ds_comment
      ;;
  esac
  rm -rf "$work"
}

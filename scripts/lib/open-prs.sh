# shellcheck shell=bash
# Every open PR of REPO with what the queue and sweeps read, in one paginated GraphQL query instead of
# REST calls per PR. Needs REPO and GH_TOKEN. Each function fails on an API error: a refused call must
# never read as "no PRs".
#
# Page sizes are small on purpose. GitHub cuts a GraphQL request off after about 10 seconds (HTTP
# 502/504), and with a repo's full set of statuses per PR, a 100-PR page crossed that on zedu-fe
# (167 open PRs). Fields like mergeStateStatus and mergeable make GitHub compute mergeability per PR,
# so they stay out of open_prs and live only in the functions that need them.

# _open_prs_query <page size> <node fields>: paginated read of every open PR, retried once on failure.
_open_prs_query() {
  local size=$1 fields=$2 query pages attempt
  query="
    query(\$owner: String!, \$name: String!, \$endCursor: String) {
      repository(owner: \$owner, name: \$name) {
        pullRequests(states: OPEN, first: $size, after: \$endCursor) {
          pageInfo { hasNextPage endCursor }
          nodes { $fields }
        }
      }
    }"
  for attempt in 1 2; do
    # The parse is part of the attempt: a response without repository data (a partial GraphQL
    # error can exit 0) fails jq, is retried, and finally returns 1 rather than an empty list.
    if pages=$(gh api graphql --paginate -F owner="${REPO%%/*}" -F name="${REPO#*/}" -f query="$query") \
       && jq -se 'all(.[]; .data.repository.pullRequests.nodes | type == "array")' <<< "$pages" >/dev/null; then
      jq -s '[.[].data.repository.pullRequests.nodes[]]' <<< "$pages"
      return 0
    fi
    [ "$attempt" -eq 1 ] && { echo "::warning::Open-PR query failed; retrying in 10s." >&2; sleep 10; }
  done
  return 1
}

#   open_prs
#     Prints a JSON array of pullRequest nodes: number, createdAt, isDraft, baseRefName, headRefOid,
#     author.login, headRepository.nameWithOwner, headRepositoryOwner.login, labels (first 100, with
#     pageInfo), assignees.totalCount, and the head commit's status contexts (context, state,
#     description). Used by the review queue, the lead approval and fork build sweeps, and recheck.

open_prs() {
  _open_prs_query 30 '
    number createdAt isDraft baseRefName headRefOid
    author { login }
    headRepository { nameWithOwner }
    headRepositoryOwner { login }
    labels(first: 100) { pageInfo { hasNextPage } nodes { name } }
    assignees { totalCount }
    commits(last: 1) { nodes { commit { status { contexts { context state description } } } } }'
}

#   open_prs_merge_state
#     number, isDraft, baseRefName, author.login, headRepository.nameWithOwner,
#     headRepositoryOwner.login, labels (first 100) and mergeStateStatus. Only update-branch needs
#     mergeStateStatus, so only it pays for computing it.

open_prs_merge_state() {
  _open_prs_query 25 '
    number isDraft baseRefName
    author { login }
    headRepository { nameWithOwner }
    headRepositoryOwner { login }
    labels(first: 100) { nodes { name } }
    mergeStateStatus'
}

#   open_prs_with_review_state
#     Like open_prs without statuses, plus each PR's mergeability and unresolved review threads
#     (first 100). Only pr-nudges needs this, on a 2h schedule.

open_prs_with_review_state() {
  _open_prs_query 25 '
    number createdAt isDraft baseRefName headRefOid
    author { login }
    headRepository { nameWithOwner }
    headRepositoryOwner { login }
    labels(first: 100) { pageInfo { hasNextPage } nodes { name } }
    mergeable mergeStateStatus
    reviewThreads(first: 100) { totalCount nodes { isResolved } }'
}

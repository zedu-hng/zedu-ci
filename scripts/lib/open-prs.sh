# shellcheck shell=bash
# Every open PR of REPO with what the queue and sweeps read, in one paginated GraphQL query (about 2
# points per 100 PRs) instead of REST calls per PR. Needs REPO and GH_TOKEN.
#
#   open_prs
#     Prints a JSON array of pullRequest nodes: number, createdAt, isDraft, baseRefName, headRefOid,
#     author.login, headRepository.nameWithOwner, headRepositoryOwner.login, labels (first 100, with
#     pageInfo), assignees.totalCount, mergeStateStatus, and the head commit's status contexts
#     (context, state, description). Fails on an API error: a refused call must never read as "no PRs".

open_prs() {
  local pages
  # shellcheck disable=SC2016 # $owner etc. are GraphQL variables, not shell
  pages=$(gh api graphql --paginate -F owner="${REPO%%/*}" -F name="${REPO#*/}" -f query='
    query($owner: String!, $name: String!, $endCursor: String) {
      repository(owner: $owner, name: $name) {
        pullRequests(states: OPEN, first: 100, after: $endCursor) {
          pageInfo { hasNextPage endCursor }
          nodes {
            number createdAt isDraft baseRefName headRefOid
            author { login }
            headRepository { nameWithOwner }
            headRepositoryOwner { login }
            labels(first: 100) { pageInfo { hasNextPage } nodes { name } }
            assignees { totalCount }
            mergeStateStatus
            commits(last: 1) { nodes { commit { status { contexts { context state description } } } } }
          }
        }
      }
    }') || return 1
  jq -s '[.[].data.repository.pullRequests.nodes[]]' <<< "$pages"
}

#   open_prs_with_review_state
#     Like open_prs, plus each PR's author, mergeability and unresolved review threads (first 100).
#     Only pr-nudges needs this, on a 2h schedule, so the queue and the sweeps keep the lean open_prs
#     above rather than paying these extra fields every run. Fails on an API error, like open_prs.

open_prs_with_review_state() {
  local pages
  # shellcheck disable=SC2016 # $owner etc. are GraphQL variables, not shell
  pages=$(gh api graphql --paginate -F owner="${REPO%%/*}" -F name="${REPO#*/}" -f query='
    query($owner: String!, $name: String!, $endCursor: String) {
      repository(owner: $owner, name: $name) {
        pullRequests(states: OPEN, first: 100, after: $endCursor) {
          pageInfo { hasNextPage endCursor }
          nodes {
            number createdAt isDraft baseRefName headRefOid
            author { login }
            headRepository { nameWithOwner }
            headRepositoryOwner { login }
            labels(first: 100) { pageInfo { hasNextPage } nodes { name } }
            mergeable mergeStateStatus
            reviewThreads(first: 100) { totalCount nodes { isResolved } }
          }
        }
      }
    }') || return 1
  jq -s '[.[].data.repository.pullRequests.nodes[]]' <<< "$pages"
}

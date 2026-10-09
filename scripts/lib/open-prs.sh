# shellcheck shell=bash
# Every open PR of REPO with what the queue and sweeps read, in one paginated GraphQL query (about 2
# points per 100 PRs) instead of REST calls per PR. Needs REPO and GH_TOKEN.
#
#   open_prs
#     Prints a JSON array of pullRequest nodes: number, createdAt, isDraft, baseRefName, headRefOid,
#     headRepository.nameWithOwner, headRepositoryOwner.login, labels (first 100, with pageInfo),
#     assignees.totalCount, and the head commit's status contexts (context, state, description).
#     No mergeability fields: GitHub computes mergeStateStatus per PR, and asking for it alongside the
#     status contexts for 100 PRs makes the gateway return 502 on a busy repo. Fails on an API error:
#     a refused call must never read as "no PRs".

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
            headRepository { nameWithOwner }
            headRepositoryOwner { login }
            labels(first: 100) { pageInfo { hasNextPage } nodes { name } }
            assignees { totalCount }
            commits(last: 1) { nodes { commit { status { contexts { context state description } } } } }
          }
        }
      }
    }') || return 1
  jq -s '[.[].data.repository.pullRequests.nodes[]]' <<< "$pages"
}

#   open_prs_merge_state
#     The open PRs that update-branch reads: number, isDraft, baseRefName, author.login,
#     headRepository.nameWithOwner, headRepositoryOwner.login, labels (first 100) and mergeStateStatus.
#     It selects no commit statuses, so this query does not hit the gateway 502 that mergeStateStatus
#     next to the status contexts causes. Fails on an API error, like open_prs.

open_prs_merge_state() {
  local pages
  # shellcheck disable=SC2016 # $owner etc. are GraphQL variables, not shell
  pages=$(gh api graphql --paginate -F owner="${REPO%%/*}" -F name="${REPO#*/}" -f query='
    query($owner: String!, $name: String!, $endCursor: String) {
      repository(owner: $owner, name: $name) {
        pullRequests(states: OPEN, first: 100, after: $endCursor) {
          pageInfo { hasNextPage endCursor }
          nodes {
            number isDraft baseRefName
            author { login }
            headRepository { nameWithOwner }
            headRepositoryOwner { login }
            labels(first: 100) { nodes { name } }
            mergeStateStatus
          }
        }
      }
    }') || return 1
  jq -s '[.[].data.repository.pullRequests.nodes[]]' <<< "$pages"
}

#   open_prs_with_review_state
#     The open PRs that pr-nudges reads: number, isDraft, baseRefName, author.login,
#     headRepository.nameWithOwner, headRepositoryOwner.login, labels (first 100), mergeable and
#     unresolved review threads (first 100). Paged 25 at a time: mergeability is computed per PR, and
#     100 at once can make the gateway return 502. Fails on an API error, like open_prs.

open_prs_with_review_state() {
  local pages
  # shellcheck disable=SC2016 # $owner etc. are GraphQL variables, not shell
  pages=$(gh api graphql --paginate -F owner="${REPO%%/*}" -F name="${REPO#*/}" -f query='
    query($owner: String!, $name: String!, $endCursor: String) {
      repository(owner: $owner, name: $name) {
        pullRequests(states: OPEN, first: 25, after: $endCursor) {
          pageInfo { hasNextPage endCursor }
          nodes {
            number isDraft baseRefName
            author { login }
            headRepository { nameWithOwner }
            headRepositoryOwner { login }
            labels(first: 100) { nodes { name } }
            mergeable
            reviewThreads(first: 100) { totalCount nodes { isResolved } }
          }
        }
      }
    }') || return 1
  jq -s '[.[].data.repository.pullRequests.nodes[]]' <<< "$pages"
}

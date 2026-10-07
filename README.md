# zedu-ci

Shared review-org workflows for `zedu-hng/zedu-fe`, `zedu-hng/zedu-mobile` and `zedu-hng/zedu-desktop`.
Each repo keeps short caller workflows that set the triggers and permissions, then call the files here.

Nothing here ever runs against `zeduchat`. Release batches leave out `.github/` in every repo, so the
callers never ship upstream.

## How it fits together

- **Code is pinned.** Callers use `zedu-hng/zedu-ci/.github/workflows/<file>.yml@<commit sha>`, so a
  change here reaches a repo only when that repo bumps the SHA (in a PR, reviewed like any change).
- **Data is live.** `teams.yml` is read from this repo's `main` when a workflow runs, so registering a
  team or changing a lead is one PR here, for all three repos, with no caller bumps.
- **Callers own triggers, concurrency and permissions.** A called workflow can't widen the caller's
  token, so each caller job grants what the called workflow lists under "Caller permissions".
  Concurrency groups live in the callers only: the same group in both would deadlock.
- **Caller file names are fixed.** Workflows dispatch each other and look up runs by file name
  (`lead-approval.yml`, `fork-build.yml`, `pr-checks.yml`, `reviewer-notify.yml`), and by workflow
  name (`Lead approval`, `Lead approval review`, `Fork build`, `PR checks`, `PR scans`).
- **`IS_BOOTCAMP` is checked in the callers**, so a repo without it (a contributor fork) never
  starts these jobs.

## Workflows

| File | What it does | Caller trigger |
|---|---|---|
| `pr-rules.yml` | Branch name, Single author, Protected files, Size, PR title, PR template, each as a commit status | `pull_request_target` |
| `team-routing.yml` | Requests review from the fork's team leads | `pull_request_target` |
| `lead-approval.yml` | `Lead approved` status, plus a sweep for PRs not green yet | `pull_request_target`, `workflow_dispatch`, `schedule` |
| `lead-approval-relay.yml` | Re-checks Lead approved right after a review | `workflow_run` on `Lead approval review` |
| `reviewer-notify.yml` | Ready-for-review queue, 3 unclaimed PRs per team | `pull_request_target`, `workflow_run`, `schedule`, `workflow_dispatch` |
| `reviewer-claim.yml` | `/claim`, `/release`, 24h escalation and release | `issue_comment`, `schedule`, `workflow_dispatch` |
| `pr-review-comment.yml` | Posts PR checks / PR scans results as statuses, plus the review bot comment | `workflow_run` on `PR checks`, `PR scans` |
| `pr-review-recheck.yml` | Re-runs checks that failed only on PR review after a rule fix lands | `push` to dev and central-staging |

`lead-approval-review.yml` stays a plain workflow in each repo: it only exists to fire the relay.

## teams.yml

One entry per team, keyed by the GitHub org that owns the team's forks (the same org for all three
repos). See the comments in the file. Add a team or change leads with a PR here.

## Lint

Every PR runs actionlint (with shellcheck) and parses the data files. CodeRabbit reviews every PR.

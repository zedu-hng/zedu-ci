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

### Checks and builds

| File | What it does | Caller trigger |
|---|---|---|
| `pr-checks-node.yml` | One job: file policy, Gitleaks, malware heuristics, commit messages, audit, Prettier, ESLint, TypeScript, Jest, PR review (zedu-mobile) | `pull_request` |
| `pr-checks-flutter.yml` | One job: forbidden patterns, Lazarus scanner, analyze, format, tests, Trivy (zedu-desktop) | `pull_request` |
| `pr-scans.yml` | Semgrep and ClamAV, with per-repo rule packs, paths and excludes | `pull_request` |
| `fork-build.yml` | Relays the fork's PR build as `Fork build`, posts `Backend dependency`, comments the artifacts | `pull_request_target`, `issue_comment`, `workflow_dispatch`, `schedule` |
| `pr-build-react-native.yml` | Fork side: Android APK and iOS simulator build (zedu-mobile) | `push`, `workflow_dispatch` in the fork |
| `pr-build-flutter.yml` | Fork side: macOS, Windows and Linux builds (zedu-desktop) | `push`, `workflow_dispatch` in the fork |
| `build-gate.yml` | Nested in both PR builds: open-PR check, backend and `.env` | called by the two files above |

Checks run Zedu's own scripts and configs from the base branch, so a PR can't loosen them. Each
check is posted as its own commit status by `pr-review-comment.yml`.

## Backend for builds

Every fork build talks to our dev backend, `api.hng.groups.zedu.chat`, unless the PR description has
a line `Backend URL: https://api.<team>.groups.zedu.chat` (for a PR that needs backend work that isn't
on dev yet). Then:

- the build uses that backend, and `Backend dependency` stays red until the line is removed;
- the fork's build jobs are named `<target> · <backend host>`, and Fork build fails when that host
  doesn't match the PR description (the line changed after the build), until the fork rebuilds.

`.env` is written from `build/<repo>.env` at the same zedu-ci commit as the workflow, with
`{{backend}}` and `{{client}}` filled in. Public values only: anything in `.env` ships inside the app. Contributor forks
need no `APP_ENV_FILE` or other setup.

## teams.yml

One entry per team, keyed by the GitHub org that owns the team's forks (the same org for all three
repos). See the comments in the file. Add a team or change leads with a PR here.

## Shared code

Shared shell code lives in `scripts/`, and every workflow that uses it checks this repo out at its
own commit first (`ref: ${{ job.workflow_sha }}`, `path: .zedu-ci`), so the scripts are pinned with
the workflow and need no second SHA in the callers:

| Script | Used by |
|---|---|
| `lib/status.sh` (`status_set`: write a commit status only when it changes) | rules, lead approval, fork build, review comment |
| `lib/teams.sh` (`team_of`, `team_orgs`; teams.yml read live from `main`) | team routing, lead approval, reviewer notify |
| `lib/backend-url.sh` (`backend_from_body`) | build gate (fork side), fork build relay |
| `lib/docs-only.sh` (`docs_only`: a Markdown-only PR needs no build) | build gate (fork side), fork build relay |
| `lib/open-prs.sh` (`open_prs`: one GraphQL read of every open PR) | lead approval and fork build sweeps, reviewer notify, recheck |
| `publish-results.sh` (the results format `pr-review-comment.yml` reads) | PR checks (Node, Flutter), PR scans |

In the checks workflows the checkout comes last, so the scanners never see zedu-ci's files. Whole
jobs are shared as nested reusable workflows (`build-gate.yml`, called as
`./.github/workflows/build-gate.yml`, which also resolves to the same commit).

The steps around `publish-results.sh` (checkout, upload, fail) are still repeated YAML, marked
`# shared:publish-results begin/end`; `scripts/check-shared-blocks.rb` fails Lint when the copies
differ.

## Lint

Every PR runs actionlint (with shellcheck), shellcheck and `scripts/test.sh` on `scripts/`, the
shared-block check, and a parse of the data files. CodeRabbit reviews every PR.

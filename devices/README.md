# Device slots

Reviewer test sessions for the mobile and desktop apps, streamed to a browser from the box. A reviewer
comments `/test desktop` (later `/test android`) on a PR and gets a link to the running build. No
download, no Appetize time limits. One session at a time per platform.

Status: the desktop slot image, its agent and the egress rules. The `/test` workflow and the Android
slot come next.

## How a session runs

1. A trusted zedu-ci workflow checks the commenter is a reviewer, the fork build is green for the PR's
   head SHA and its scans passed, downloads the fork's `desktop-linux` artifact, and uploads it to the
   slot: `PUT /api/session?pr=&sha=&who=` with `Authorization: Bearer $DEVICE_TOKEN`.
2. The agent unpacks it into a tmpfs (`/session`, mounted `exec`), starts the display stack and the app, and answers `201` with a
   viewer path `/s/<token>`, valid until the session ends (a reload works). A busy slot answers `409` with the holder and the time left.
3. The reviewer opens `https://desktop.preview.groups.zedu.chat/s/<token>` and signs in with GitHub (an
   `oauth2-proxy` in front of the slot, limited to the `reviewers` team of zedu-hng; `/api/` and `/healthz`
   skip the login because the agent checks the bearer token). Then the viewer needs the link's token too. The link sets a
   `__Host-device` cookie (host-only, so a sibling preview page cannot shadow it) and redirects to noVNC.
4. After `TTL_SECONDS` (30 minutes, one `/api/extend` of 15 more), on `DELETE /api/session`, or when the
   app exits, the session ends and the process exits. Docker restarts the container with a clean
   read-only root and empty tmpfs, so nothing carries over.

## Commands

A reviewer (anyone with write access to the repo) comments on the PR. The repo's
`.github/workflows/device-session.yml` calls zedu-ci's reusable `device-session.yml`:

| Comment         | What                                                                                  |
| --------------- | ------------------------------------------------------------------------------------- |
| `/test desktop` | Starts a session on this PR's build. Needs the head commit's required statuses green. |
| `/test extend`  | Adds 15 minutes, once.                                                                |
| `/test stop`    | Ends the session.                                                                     |
| `/test`         | Shows these commands.                                                                 |

The workflow keeps one comment per PR and edits it. A busy slot's answer names the PR and who holds it.
The repo needs the secret `DEVICE_TOKEN` (the same value as the slot's) and the caller workflow.

## Files

| Path                         | What                                                                                      |
| ---------------------------- | ----------------------------------------------------------------------------------------- |
| `agent/agent.py`             | The slot agent. Stdlib Python, no Docker socket. Tests in `agent/test_agent.py`.          |
| `desktop/Dockerfile`         | Ubuntu 24.04, Xtigervnc, noVNC, openbox, a keyring, the libraries the bundle links, Mesa. |
| `desktop/session.sh`         | Starts the display stack and the app, in the foreground until the app exits.              |
| `desktop/needed-libs.txt`    | Libraries the Linux bundle needs. The image smoke test checks each.                       |
| `desktop/docker-compose.yml` | The slot for Coolify, with the container limits.                                          |
| `firewall.sh`                | Egress rules for the slots' Docker network.                                               |

CI: `device-images.yml` builds the image, checks the libraries, runs a session end to end against the
container (production flags, stub app, viewer link, cookie, busy slot) and publishes
`ghcr.io/zedu-hng/zedu-device-desktop:main` from `main`. Lint runs the agent tests.

## Box setup (once)

1. Create the GitHub OAuth app (org owner): zedu-hng → Settings → Developer settings → OAuth Apps. The
   callback URL is `https://desktop.preview.groups.zedu.chat/oauth2/callback`. A GitHub OAuth app has one
   callback host, so each slot (desktop, later android) gets its own app. Approve it for the org so
   team membership is readable. Keep the client ID and secret out of git and chat.
2. Create the Coolify service from `desktop/docker-compose.yml`. Coolify gives it its own Docker
   network, named after the service UUID. Set the domain `https://desktop.preview.groups.zedu.chat` on
   the **`auth`** service (port 4180), not on the slot, and set the secrets `DEVICE_TOKEN` (a long random
   string, also stored as `DEVICE_TOKEN` in the zedu-hng repos that call the slot), `GH_OAUTH_CLIENT_ID`,
   `GH_OAUTH_CLIENT_SECRET` and `OAUTH_COOKIE_SECRET` (`openssl rand -hex 16`). `GH_OAUTH_TEAM` defaults
   to `reviewers`. `*.groups.zedu.chat` already resolves to the box and `*.preview.groups.zedu.chat` has
   a wildcard cert.
3. Apply the egress rules with the service's network name:
   `sudo devices/firewall.sh <service network> <box public ip> --dry-run`, read the output, then run it
   without `--dry-run`. Persist them with `netfilter-persistent save`; re-running the script after a
   reboot rebuilds them. Slots may reach the internet (web ports and DNS) and the box's own 80 and 443
   (team backends sit behind Traefik), and the login proxy and agent ports inside their own network.
   Nothing else.
4. First run by hand (replace `<artifact>` with a downloaded `desktop-linux` bundle):

   ```bash
   curl -fsS -X PUT -H "Authorization: Bearer $DEVICE_TOKEN" -H 'Expect:' \
     --data-binary @<artifact>.tar.gz \
     'https://desktop.preview.groups.zedu.chat/api/session?pr=0&sha=manual&who=you'
   ```

   Open the returned path (it asks for the GitHub login first), then check these four things: the app renders under software GL, sign-in
   works (the keyring), the stream is responsive, and `DELETE /api/session` frees the slot.

## Limits and risks

The slot runs a PR's build. Containment, in order:

- Reviewers only start sessions (the workflow checks).
- Two users in the container. The agent runs as root with only `CHOWN`, `SETUID`, `SETGID` and `KILL`
  and holds `DEVICE_TOKEN`. Each session's app runs as the unprivileged `device` user (uid 10001), so
  it cannot read the agent's environment from `/proc`. CI checks this with a stub app.
- A read-only root, no other capabilities, no new privileges, a pids limit, 2 CPU and 2 GB, low CPU
  shares and a high OOM score so production wins.
- A dedicated network whose egress, and traffic to the box itself, is limited by `firewall.sh`. Inside
  the slot's own network the proxy and agent are not port-filtered on the box (Traefik reached the login
  proxy under rules that allowed only the agent port), so each relies on its own credentials: a GitHub
  login for the proxy and the bearer token for the agent.
- A GitHub login (`oauth2-proxy`, `zedu-hng` reviewers) in front of the viewer, and a viewer token that
  dies with the session. The VNC and noVNC ports bind to localhost.

What remains is a container or kernel escape, and a PR's build can still use the slot's CPU for its
30 minutes. If sessions become routine, move the slots to their own server.

The firewall rule that lets slots reach team backends matches connections addressed to the box's public
IP on 80 and 443 before Docker rewrites them (`--ctorigdst`). Verify it on the box after applying: a slot
must reach `api.<team>.groups.zedu.chat` and must not reach the Coolify dashboard port or another
container.

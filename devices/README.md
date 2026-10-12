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
   one-time path `/s/<token>`. A busy slot answers `409` with the holder and the time left.
3. The reviewer opens `https://desktop.preview.groups.zedu.chat/s/<token>`. The link sets a
   `__Host-device` cookie (host-only, so a sibling preview page cannot shadow it) and redirects to noVNC.
4. After `TTL_SECONDS` (30 minutes, one `/api/extend` of 15 more), on `DELETE /api/session`, or when the
   app exits, the session ends and the process exits. Docker restarts the container with a clean
   read-only root and empty tmpfs, so nothing carries over.

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

1. In Coolify, add a destination (Docker network) named `devices` on the server. Slots must be on this
   network only, and Traefik joins it so it can route to them.
2. Apply the egress rules: `sudo devices/firewall.sh devices <box public ip> --dry-run`, read the
   output, then run it without `--dry-run`. Persist them with `iptables-persistent`. Slots may reach
   the internet and the box's own 80 and 443 (team backends sit behind Traefik), and nothing else.
3. Create the Coolify application from `desktop/docker-compose.yml` on the `devices` destination. Set
   the domain `https://desktop.preview.groups.zedu.chat` (port 8080) and the secret `DEVICE_TOKEN` (a
   long random string, also stored as `DEVICE_TOKEN` in the zedu-hng repos that call the slot).
   `*.groups.zedu.chat` already resolves to the box and `*.preview.groups.zedu.chat` has a wildcard cert.
4. First run by hand (replace `<artifact>` with a downloaded `desktop-linux` bundle):

   ```bash
   curl -fsS -X PUT -H "Authorization: Bearer $DEVICE_TOKEN" -H 'Expect:' \
     --data-binary @<artifact>.tar.gz \
     'https://desktop.preview.groups.zedu.chat/api/session?pr=0&sha=manual&who=you'
   ```

   Open the returned path, then check these four things: the app renders under software GL, sign-in
   works (the keyring), the stream is responsive, and `DELETE /api/session` frees the slot.

## Limits and risks

The slot runs a PR's build. Containment, in order:

- Reviewers only start sessions (the workflow checks).
- Two users in the container. The agent runs as root with only `CHOWN`, `SETUID`, `SETGID` and `KILL`
  and holds `DEVICE_TOKEN`. Each session's app runs as the unprivileged `device` user (uid 10001), so
  it cannot read the agent's environment from `/proc`. CI checks this with a stub app.
- A read-only root, no other capabilities, no new privileges, a pids limit, 2 CPU and 2 GB, low CPU
  shares and a high OOM score so production wins.
- A dedicated network whose egress is limited by `firewall.sh`.
- A viewer token that dies with the session. The agent exposes only its own port; the VNC and noVNC
  ports bind to localhost.

What remains is a container or kernel escape, and a PR's build can still use the slot's CPU for its
30 minutes. If sessions become routine, move the slots to their own server.

The firewall rule that lets slots reach team backends matches connections addressed to the box's public
IP on 80 and 443 before Docker rewrites them (`--ctorigdst`). Verify it on the box after applying: a slot
must reach `api.<team>.groups.zedu.chat` and must not reach the Coolify dashboard port or another
container.

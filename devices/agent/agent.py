#!/usr/bin/env python3
"""Slot agent: runs one reviewer test session in a device-streaming container.

A trusted zedu-ci workflow uploads the PR's build artifact (PUT /api/session), the agent starts it
under a virtual display and hands back a link. The viewer is proxied to the container's noVNC
server only while the session's token is valid. A session ends at its TTL, on DELETE, or when the
app exits; the process then exits so the container restarts clean (read-only root, tmpfs home).

  GET    /healthz       200 ok (no auth; cheap, used for the container health check)
  GET    /api/status    state of the slot
  PUT    /api/session   body: the artifact (tar.gz); query: pr, sha, who. 201, or 409 when busy
  POST   /api/extend    one extension per session
  DELETE /api/session   end it now
  GET    /s/<token>     viewer entry: sets the __Host-device cookie, redirects to noVNC
  anything else         proxied to noVNC when the cookie is valid, 403 otherwise

/api needs `Authorization: Bearer $DEVICE_TOKEN`. Stdlib only.
"""
import asyncio
import hmac
import json
import os
import secrets
import shutil
import signal
import sys
import tarfile
import time
from urllib.parse import parse_qs, urlsplit

CFG = {
    "token": os.environ.get("DEVICE_TOKEN", ""),
    "port": int(os.environ.get("PORT", "8080")),
    "upstream_port": int(os.environ.get("UPSTREAM_PORT", "6080")),
    "ttl": int(os.environ.get("TTL_SECONDS", "1800")),
    "extend": int(os.environ.get("EXTEND_SECONDS", "900")),
    "max_bytes": int(os.environ.get("MAX_ARTIFACT_BYTES", str(300 * 1024 * 1024))),
    "work": os.environ.get("WORK_DIR", "/tmp/session"),
    "app_bin": os.environ.get("APP_BIN", "zedu"),
    "session_cmd": os.environ.get("SESSION_CMD", "/opt/agent/session.sh"),
    "exit_on_end": os.environ.get("EXIT_ON_END", "1") == "1",
    "ready_timeout": int(os.environ.get("READY_TIMEOUT", "30")),
    "app_uid": int(os.environ.get("APP_UID", "10001")),
    "app_gid": int(os.environ.get("APP_GID", "10001")),
}
COOKIE = "__Host-device"
VIEWER_PATH = "/vnc.html?autoconnect=1&resize=scale"
HEAD_LIMIT = 16 * 1024


class Slot:
    def __init__(self):
        self.reset()

    def reset(self):
        self.active = False
        self.starting = False
        self.token = ""
        self.holder = {}
        self.expires = 0.0
        self.extended = False
        self.proc = None
        self.ttl_task = None


slot = Slot()


def now():
    return time.time()


def json_resp(status, obj, extra=""):
    body = json.dumps(obj).encode()
    reason = {200: "OK", 201: "Created", 302: "Found", 400: "Bad Request", 401: "Unauthorized",
              403: "Forbidden", 409: "Conflict", 411: "Length Required", 413: "Payload Too Large",
              422: "Unprocessable Entity", 500: "Internal Server Error"}.get(status, "OK")
    head = (f"HTTP/1.1 {status} {reason}\r\nContent-Type: application/json\r\n"
            f"Content-Length: {len(body)}\r\nCache-Control: no-store\r\nConnection: close\r\n{extra}\r\n")
    return head.encode() + body


def text_resp(status, text, extra=""):
    body = text.encode()
    reason = {200: "OK", 302: "Found", 403: "Forbidden"}.get(status, "OK")
    head = (f"HTTP/1.1 {status} {reason}\r\nContent-Type: text/plain; charset=utf-8\r\n"
            f"Content-Length: {len(body)}\r\nCache-Control: no-store\r\nConnection: close\r\n{extra}\r\n")
    return head.encode() + body


def parse_head(raw):
    lines = raw.decode("latin-1").split("\r\n")
    method, target, _ = lines[0].split(" ", 2)
    headers = {}
    for line in lines[1:]:
        if ":" in line:
            k, v = line.split(":", 1)
            headers[k.strip().lower()] = v.strip()
    return method, target, headers


def cookie_of(headers, name):
    for part in headers.get("cookie", "").split(";"):
        k, _, v = part.strip().partition("=")
        if k == name:
            return v
    return ""


def valid_token(candidate):
    return bool(candidate) and slot.active and slot.token != "" and now() < slot.expires \
        and hmac.compare_digest(candidate, slot.token)


def authed(headers):
    got = headers.get("authorization", "")
    want = "Bearer " + CFG["token"]
    return CFG["token"] != "" and hmac.compare_digest(got.encode(), want.encode())


def status_obj():
    if not slot.active:
        return {"state": "starting" if slot.starting else "idle"}
    return {"state": "active", "holder": slot.holder, "expires_in": max(0, int(slot.expires - now())),
            "extended": slot.extended}


def app_user():
    """Spawn arguments that run the app as the unprivileged app user.

    The agent holds DEVICE_TOKEN in its environment. The app is a PR's build, so it must not share the
    agent's user: the same user can read /proc/<agent pid>/environ. In the container the agent runs as
    root (with only CHOWN, SETUID, SETGID and KILL) and the app as CFG["app_uid"]. Unprivileged runs
    (the tests) start the app as the current user."""
    if os.geteuid() != 0:
        return {}
    return {"user": CFG["app_uid"], "group": CFG["app_gid"], "extra_groups": []}


def hand_over(path):
    """Give the extracted app to the app user (no-op unless running as root)."""
    if os.geteuid() != 0:
        return
    os.lchown(path, CFG["app_uid"], CFG["app_gid"])
    for root, dirs, files in os.walk(path):
        for name in dirs + files:
            os.lchown(os.path.join(root, name), CFG["app_uid"], CFG["app_gid"])


def safe_extract(archive, dest):
    with tarfile.open(archive, "r:gz") as tf:
        for m in tf.getmembers():
            target = os.path.realpath(os.path.join(dest, m.name))
            if target != os.path.realpath(dest) and not target.startswith(os.path.realpath(dest) + os.sep):
                raise ValueError(f"unsafe path in archive: {m.name}")
            if m.issym() or m.islnk() or m.isdev():
                raise ValueError(f"links and devices are not allowed: {m.name}")
        tf.extractall(dest, filter="data")


async def end_session(reason):
    if not slot.active and not slot.starting:
        return
    proc = slot.proc
    task = slot.ttl_task
    slot.reset()
    if task and task is not asyncio.current_task():
        task.cancel()
    if proc:
        # The whole group, even when the main process already exited: helpers it started can outlive it.
        try:
            os.killpg(proc.pid, signal.SIGTERM)
        except (ProcessLookupError, PermissionError):
            pass
        try:
            await asyncio.wait_for(proc.wait(), 5)
        except asyncio.TimeoutError:
            pass
        try:
            os.killpg(proc.pid, signal.SIGKILL)
        except (ProcessLookupError, PermissionError):
            pass
    shutil.rmtree(CFG["work"], ignore_errors=True)
    print(f"session ended: {reason}", flush=True)
    if CFG["exit_on_end"]:
        asyncio.get_running_loop().call_later(1, os._exit, 0)


async def ttl_watch():
    try:
        while slot.active and now() < slot.expires:
            await asyncio.sleep(min(1.0, max(0.05, slot.expires - now())))
        if slot.active:
            await end_session("ttl")
    except asyncio.CancelledError:
        pass


async def app_watch(proc):
    await proc.wait()
    if slot.active and slot.proc is proc:
        await end_session("app exited")


async def wait_ready():
    deadline = now() + CFG["ready_timeout"]
    while now() < deadline:
        try:
            _, w = await asyncio.open_connection("127.0.0.1", CFG["upstream_port"])
            w.close()
            return True
        except OSError:
            await asyncio.sleep(0.25)
    return False


async def read_body(reader, writer, headers, dest):
    if "chunked" in headers.get("transfer-encoding", "").lower() or "content-length" not in headers:
        writer.write(json_resp(411, {"error": "Content-Length required"}))
        return False
    length = int(headers["content-length"])
    if length > CFG["max_bytes"]:
        writer.write(json_resp(413, {"error": "artifact too large"}))
        return False
    if headers.get("expect", "").lower() == "100-continue":
        writer.write(b"HTTP/1.1 100 Continue\r\n\r\n")
        await writer.drain()
    left = length
    with open(dest, "wb") as f:
        while left:
            chunk = await reader.read(min(65536, left))
            if not chunk:
                writer.write(json_resp(400, {"error": "body ended early"}))
                return False
            f.write(chunk)
            left -= len(chunk)
    return True


async def api(method, path, query, headers, reader, writer):
    if path == "/api/status" and method == "GET":
        writer.write(json_resp(200, status_obj()))
    elif path == "/api/session" and method == "PUT":
        if slot.active or slot.starting:
            writer.write(json_resp(409, {"error": "busy", **status_obj()}))
            return
        slot.starting = True
        try:
            await start_session(query, headers, reader, writer)
        finally:
            slot.starting = False
    elif path == "/api/extend" and method == "POST":
        if not slot.active:
            writer.write(json_resp(409, {"error": "no active session"}))
        elif slot.extended:
            writer.write(json_resp(409, {"error": "already extended", **status_obj()}))
        else:
            slot.extended = True
            slot.expires += CFG["extend"]
            writer.write(json_resp(200, status_obj()))
    elif path == "/api/session" and method == "DELETE":
        await end_session("deleted")
        writer.write(json_resp(200, {"state": "idle"}))
    else:
        writer.write(json_resp(400, {"error": "unknown endpoint"}))


async def start_session(query, headers, reader, writer):
    shutil.rmtree(CFG["work"], ignore_errors=True)
    os.makedirs(CFG["work"], mode=0o700)
    archive = os.path.join(CFG["work"], "artifact.tar.gz")
    appdir = os.path.join(CFG["work"], "app")
    os.makedirs(appdir)
    if not await read_body(reader, writer, headers, archive):
        shutil.rmtree(CFG["work"], ignore_errors=True)
        return
    try:
        safe_extract(archive, appdir)
    except (ValueError, tarfile.TarError, OSError) as e:
        shutil.rmtree(CFG["work"], ignore_errors=True)
        writer.write(json_resp(422, {"error": f"bad artifact: {e}"}))
        return
    os.remove(archive)
    hand_over(CFG["work"])
    binary = os.path.join(appdir, CFG["app_bin"])
    if not os.path.isfile(binary):
        shutil.rmtree(CFG["work"], ignore_errors=True)
        writer.write(json_resp(422, {"error": f"{CFG['app_bin']} not found in the artifact"}))
        return
    os.chmod(binary, 0o755)
    env = dict(os.environ, APP_DIR=appdir, APP_BIN=CFG["app_bin"], UPSTREAM_PORT=str(CFG["upstream_port"]),
               HOME="/home/device", USER="device")
    env.pop("DEVICE_TOKEN", None)
    proc = await asyncio.create_subprocess_exec(CFG["session_cmd"], appdir, env=env, start_new_session=True,
                                                **app_user())
    if not await wait_ready():
        slot.proc = proc
        slot.active = True
        await end_session("not ready")
        writer.write(json_resp(500, {"error": "the display did not come up"}))
        return
    slot.proc = proc
    slot.token = secrets.token_urlsafe(32)
    slot.holder = {k: query.get(k, [""])[0][:80] for k in ("pr", "sha", "who")}
    slot.expires = now() + CFG["ttl"]
    slot.extended = False
    slot.active = True
    slot.ttl_task = asyncio.create_task(ttl_watch())
    asyncio.create_task(app_watch(proc))
    writer.write(json_resp(201, {"path": f"/s/{slot.token}", "expires_in": CFG["ttl"], "holder": slot.holder}))


async def pipe(src, dst):
    try:
        while True:
            data = await src.read(65536)
            if not data:
                break
            dst.write(data)
            await dst.drain()
    except (ConnectionError, asyncio.CancelledError, OSError):
        pass
    finally:
        try:
            dst.close()
        except OSError:
            pass


async def handle(reader, writer):
    try:
        try:
            raw = await asyncio.wait_for(reader.readuntil(b"\r\n\r\n"), 10)
        except (asyncio.TimeoutError, asyncio.IncompleteReadError, asyncio.LimitOverrunError):
            return
        if len(raw) > HEAD_LIMIT:
            return
        method, target, headers = parse_head(raw[:-4])
        u = urlsplit(target)
        query = parse_qs(u.query)
        if u.path == "/healthz":
            writer.write(text_resp(200, "ok"))
        elif u.path.startswith("/api/"):
            if not authed(headers):
                writer.write(json_resp(401, {"error": "unauthorized"}))
            else:
                await api(method, u.path, query, headers, reader, writer)
        elif u.path.startswith("/s/"):
            if valid_token(u.path[3:].strip("/")):
                cookie = f"Set-Cookie: {COOKIE}={slot.token}; Path=/; Secure; HttpOnly; SameSite=Lax\r\n"
                writer.write(text_resp(302, "", f"Location: {VIEWER_PATH}\r\n{cookie}"))
            else:
                writer.write(text_resp(403, "No active session for this link.\n"))
        elif valid_token(cookie_of(headers, COOKIE)):
            await proxy(raw, reader, writer)
            return
        else:
            writer.write(text_resp(403, "No active session. Ask a reviewer to comment /test on the PR.\n"))
        await writer.drain()
    except (ConnectionError, OSError):
        pass
    finally:
        try:
            writer.close()
        except OSError:
            pass


async def proxy(raw, reader, writer):
    try:
        ur, uw = await asyncio.open_connection("127.0.0.1", CFG["upstream_port"])
    except OSError:
        writer.write(text_resp(403, "The session is not ready.\n"))
        await writer.drain()
        writer.close()
        return
    uw.write(raw)
    await uw.drain()
    await asyncio.gather(pipe(reader, uw), pipe(ur, writer))


async def main():
    if not CFG["token"]:
        sys.exit("DEVICE_TOKEN is not set")
    server = await asyncio.start_server(handle, "0.0.0.0", CFG["port"], limit=HEAD_LIMIT)
    print(f"agent listening on {CFG['port']}", flush=True)
    async with server:
        await server.serve_forever()


if __name__ == "__main__":
    asyncio.run(main())

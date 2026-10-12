"""Tests for agent.py: the real server, with a stub session script that serves a web page."""
import asyncio
import io
import os
import socket
import stat
import tarfile
import tempfile
import unittest

os.environ["DEVICE_TOKEN"] = "secret"
import agent  # noqa: E402


def free_port():
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


def tar_bytes(files, executable=("zedu",)):
    buf = io.BytesIO()
    with tarfile.open(fileobj=buf, mode="w:gz") as tf:
        for name, data in files.items():
            info = tarfile.TarInfo(name)
            info.size = len(data)
            info.mode = 0o755 if name in executable else 0o644
            tf.addfile(info, io.BytesIO(data))
    return buf.getvalue()


async def request(port, method, path, headers=None, body=b""):
    reader, writer = await asyncio.open_connection("127.0.0.1", port)
    head = f"{method} {path} HTTP/1.1\r\nHost: x\r\nContent-Length: {len(body)}\r\n"
    for k, v in (headers or {}).items():
        head += f"{k}: {v}\r\n"
    writer.write(head.encode() + b"\r\n" + body)
    await writer.drain()
    raw = await reader.read()
    writer.close()
    head, _, payload = raw.partition(b"\r\n\r\n")
    lines = head.decode().split("\r\n")
    status = int(lines[0].split()[1])
    hdrs = {k.lower(): v for k, v in (l.split(": ", 1) for l in lines[1:] if ": " in l)}
    return status, hdrs, payload


AUTH = {"Authorization": "Bearer secret"}


class AgentTest(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.tmp = tempfile.mkdtemp()
        self.upstream = free_port()
        stub = os.path.join(self.tmp, "session.sh")
        with open(stub, "w") as f:
            # stands in for session.sh: serves $APP_DIR over HTTP on the upstream port
            f.write('#!/bin/sh\ncd "$1" && exec python3 -m http.server "$UPSTREAM_PORT" --bind 127.0.0.1\n')
        os.chmod(stub, os.stat(stub).st_mode | stat.S_IEXEC)
        agent.CFG.update(session_cmd=stub, upstream_port=self.upstream, work=os.path.join(self.tmp, "w"),
                         exit_on_end=False, ttl=60, extend=30, ready_timeout=10, max_bytes=50 * 1024 * 1024)
        agent.slot.reset()
        self.port = free_port()
        self.server = await asyncio.start_server(agent.handle, "127.0.0.1", self.port)

    async def asyncTearDown(self):
        await agent.end_session("test over")
        self.server.close()
        await self.server.wait_closed()

    async def start(self, files=None, query="pr=12&sha=abc&who=lead"):
        body = tar_bytes(files or {"zedu": b"#!/bin/sh\n", "index.html": b"hello from the app"})
        return await request(self.port, "PUT", f"/api/session?{query}", AUTH, body)

    async def test_app_runs_as_the_app_user_when_the_agent_is_root(self):
        real = os.geteuid
        agent.CFG.update(app_uid=10001, app_gid=10001)
        try:
            os.geteuid = lambda: 0
            self.assertEqual(agent.app_user(), {"user": 10001, "group": 10001, "extra_groups": []})
            os.geteuid = lambda: 1000
            self.assertEqual(agent.app_user(), {})
        finally:
            os.geteuid = real

    async def test_the_token_never_reaches_the_app(self):
        stub = agent.CFG["session_cmd"]
        with open(stub, "w") as f:
            f.write('#!/bin/sh\necho "$DEVICE_TOKEN" > "$1/token-seen"\n'
                    'cd "$1" && exec python3 -m http.server "$UPSTREAM_PORT" --bind 127.0.0.1\n')
        status, _, _ = await self.start()
        self.assertEqual(status, 201)
        with open(os.path.join(agent.CFG["work"], "app", "token-seen")) as f:
            self.assertEqual(f.read().strip(), "")

    async def test_health_needs_no_auth(self):
        status, _, body = await request(self.port, "GET", "/healthz")
        self.assertEqual((status, body), (200, b"ok"))

    async def test_api_needs_the_token(self):
        self.assertEqual((await request(self.port, "GET", "/api/status"))[0], 401)
        self.assertEqual((await request(self.port, "GET", "/api/status", {"Authorization": "Bearer nope"}))[0], 401)
        self.assertEqual((await request(self.port, "GET", "/api/status", AUTH))[0], 200)

    async def test_session_flow(self):
        status, _, body = await self.start()
        self.assertEqual(status, 201)
        info = __import__("json").loads(body)
        self.assertTrue(info["path"].startswith("/s/"))
        # no cookie: nothing is proxied
        self.assertEqual((await request(self.port, "GET", "/index.html"))[0], 403)
        # a wrong link is refused
        self.assertEqual((await request(self.port, "GET", "/s/wrong"))[0], 403)
        # the link sets the host-only cookie and redirects to noVNC
        status, hdrs, _ = await request(self.port, "GET", info["path"])
        self.assertEqual(status, 302)
        self.assertIn("__Host-device=", hdrs["set-cookie"])
        self.assertIn("Secure", hdrs["set-cookie"])
        self.assertIn("/vnc.html", hdrs["location"])
        # with the cookie the upstream answers
        cookie = hdrs["set-cookie"].split(";")[0]
        status, _, payload = await request(self.port, "GET", "/index.html", {"Cookie": cookie})
        self.assertEqual((status, payload), (200, b"hello from the app"))

    async def test_busy_slot_names_the_holder(self):
        self.assertEqual((await self.start())[0], 201)
        status, _, body = await self.start(query="pr=99&sha=zzz&who=other")
        self.assertEqual(status, 409)
        info = __import__("json").loads(body)
        self.assertEqual(info["holder"]["pr"], "12")
        self.assertEqual(info["state"], "active")

    async def test_extend_once(self):
        await self.start()
        first = await request(self.port, "POST", "/api/extend", AUTH)
        self.assertEqual(first[0], 200)
        self.assertGreater(__import__("json").loads(first[2])["expires_in"], 60)
        self.assertEqual((await request(self.port, "POST", "/api/extend", AUTH))[0], 409)

    async def test_delete_frees_the_slot_and_kills_the_link(self):
        _, _, body = await self.start()
        path = __import__("json").loads(body)["path"]
        self.assertEqual((await request(self.port, "DELETE", "/api/session", AUTH))[0], 200)
        self.assertEqual((await request(self.port, "GET", path))[0], 403)
        self.assertEqual((await self.start())[0], 201)

    async def test_ttl_ends_the_session(self):
        agent.CFG["ttl"] = 1
        _, _, body = await self.start()
        path = __import__("json").loads(body)["path"]
        await asyncio.sleep(2.5)
        self.assertEqual((await request(self.port, "GET", path))[0], 403)
        status, _, body = await request(self.port, "GET", "/api/status", AUTH)
        self.assertEqual(__import__("json").loads(body)["state"], "idle")

    async def test_path_traversal_is_rejected(self):
        status, _, body = await self.start(files={"../escape": b"x", "zedu": b"x"})
        self.assertEqual(status, 422)
        self.assertEqual(__import__("json").loads((await request(self.port, "GET", "/api/status", AUTH))[2])["state"], "idle")

    async def test_missing_executable_is_rejected(self):
        status, _, body = await self.start(files={"index.html": b"x"})
        self.assertEqual(status, 422)
        self.assertIn("zedu not found", body.decode())

    async def test_oversize_artifact_is_rejected(self):
        agent.CFG["max_bytes"] = 10
        self.assertEqual((await self.start())[0], 413)

    async def test_app_exit_frees_the_slot(self):
        stub = agent.CFG["session_cmd"]
        with open(stub, "w") as f:
            f.write("#!/bin/sh\npython3 -m http.server $UPSTREAM_PORT --bind 127.0.0.1 &\nsleep 1\nexit 0\n")
        status, _, _ = await self.start()
        self.assertEqual(status, 201)
        await asyncio.sleep(2.5)
        status, _, body = await request(self.port, "GET", "/api/status", AUTH)
        self.assertEqual(__import__("json").loads(body)["state"], "idle")


if __name__ == "__main__":
    unittest.main()

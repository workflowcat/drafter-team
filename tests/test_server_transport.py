"""HTTP/1.1 keep-alive, chunked streaming, settings_load cache, and event-tap hot-path contracts.

No model weights loaded, no live data/ touched. Run: .venv/bin/python -B tests/test_server_transport.py
"""
import http.client
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
from pathlib import Path
import socket
import tempfile
import threading
import time
import types
import unittest
from unittest.mock import Mock

ROOT = Path(__file__).resolve().parents[1]
from server_src import lift


class SettingsLoadCache(unittest.TestCase):
    def test_caches_by_stat_returns_copy_and_invalidates_on_atomic_replace(self):
        with tempfile.TemporaryDirectory() as tmp:
            data = Path(tmp)
            sf = data / "settings.json"
            ns = lift(
                "settings_load",
                DATA=data,
                json=json,
                threading=threading,
                SETTINGS_LOCK=threading.Lock(),
                SETTINGS_CACHE={"key": None, "val": {}},
            )
            self.assertEqual(ns["settings_load"](), {})

            sf.write_text(json.dumps({"paused": False, "minGhost": 5}))
            first = ns["settings_load"]()
            self.assertEqual(first, {"paused": False, "minGhost": 5})

            # Caller mutation must not corrupt the cached dict
            first["paused"] = True
            self.assertEqual(ns["settings_load"]()["paused"], False)

            # Atomic replace with the exact same byte length still invalidates (new inode)
            tmpf = data / "settings.tmp"
            tmpf.write_text(json.dumps({"paused": False, "minGhost": 3}))
            tmpf.replace(sf)
            self.assertEqual(ns["settings_load"]()["minGhost"], 3)

            # Removed file returns {}
            sf.unlink()
            self.assertEqual(ns["settings_load"](), {})


class KeepAliveAndChunkedStream(unittest.TestCase):
    def setUp(self):
        self.ports = []
        self.ns = dict(
            BaseHTTPRequestHandler=BaseHTTPRequestHandler,
            json=json,
            time=time,
            threading=threading,
            LOCAL_HOSTS=set(),
            request_seq=lambda: 1,
            TYPED=[0],
            WANT=[""],
            ahead_key=lambda req, pack=None: req.get("before", ""),
            keep_running=Mock(),
        )

        def fake_complete(req, seq=None, on_part=None):
            if on_part is not None:
                on_part({"part": "hello", "src": "gate", "ms": 12})
            return {"text": "hello world", "src": "gate", "ms": 20}

        self.ns["complete"] = fake_complete
        lift("H", into=self.ns)
        base_H = self.ns["H"]
        ports = self.ports

        class RecordingH(base_H):
            def do_POST(self):
                ports.append(self.client_address[1])
                return super().do_POST()

        class TestServer(ThreadingHTTPServer):
            daemon_threads = True

        self.server = TestServer(("127.0.0.1", 0), RecordingH)
        self.port = self.server.server_address[1]
        self.ns["LOCAL_HOSTS"].add(f"127.0.0.1:{self.port}")
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()

    def tearDown(self):
        self.server.shutdown()
        self.server.server_close()

    def test_http11_reuses_socket_across_stream_and_json_posts(self):
        conn = http.client.HTTPConnection("127.0.0.1", self.port, timeout=5)
        try:
            headers = {"Content-Type": "application/json"}
            # 1) Streamed /complete over HTTP/1.1 (chunked NDJSON)
            conn.request("POST", "/complete", json.dumps({"before": "hi", "stream": True}), headers)
            r1 = conn.getresponse()
            self.assertEqual(r1.status, 200)
            self.assertEqual(r1.getheader("Transfer-Encoding"), "chunked")
            lines = [json.loads(l) for l in r1.read().decode().splitlines() if l.strip()]
            self.assertEqual(len(lines), 2)
            self.assertEqual(lines[0]["part"], "hello")
            self.assertTrue(lines[1]["final"])
            self.assertEqual(lines[1]["text"], "hello world")

            # 2) Plain /complete on the same connection reuses the exact same TCP socket
            conn.request("POST", "/complete", json.dumps({"before": "hi"}), headers)
            r2 = conn.getresponse()
            self.assertEqual(r2.status, 200)
            self.assertEqual(json.loads(r2.read())["text"], "hello world")

            # 3) Second streamed /complete still reuses the exact same TCP socket
            conn.request("POST", "/complete", json.dumps({"before": "hi", "stream": True}), headers)
            r3 = conn.getresponse()
            self.assertEqual(r3.status, 200)
            lines3 = [json.loads(l) for l in r3.read().decode().splitlines() if l.strip()]
            self.assertEqual(lines3[-1]["text"], "hello world")

            self.assertEqual(len(self.ports), 3)
            self.assertEqual(len(set(self.ports)), 1)
        finally:
            conn.close()

    def test_http10_stream_uses_non_chunked_ndjson_and_closes(self):
        body = json.dumps({"before": "hi", "stream": True}).encode()
        raw_req = (
            f"POST /complete HTTP/1.0\r\n"
            f"Host: 127.0.0.1:{self.port}\r\n"
            f"Content-Type: application/json\r\n"
            f"Content-Length: {len(body)}\r\n\r\n"
        ).encode() + body
        with socket.create_connection(("127.0.0.1", self.port), timeout=5) as s:
            s.sendall(raw_req)
            chunks = []
            while True:
                data = s.recv(4096)
                if not data:
                    break
                chunks.append(data)
        raw = b"".join(chunks).decode()
        head, payload = raw.split("\r\n\r\n", 1)
        self.assertNotIn("chunked", head.lower())
        self.assertIn("connection: close", head.lower())
        lines = [json.loads(l) for l in payload.splitlines() if l.strip()]
        self.assertEqual(lines[0]["part"], "hello")
        self.assertTrue(lines[1]["final"])

    def test_blocked_post_closes_so_its_body_is_never_a_second_request(self):
        # a cross-site text/plain POST whose body is a whole local JSON request: the 403 must close the connection
        hidden = json.dumps({"before": "smuggled"}).encode()
        inner = (f"POST /complete HTTP/1.1\r\nHost: 127.0.0.1:{self.port}\r\nContent-Type: application/json\r\n"
                 f"Content-Length: {len(hidden)}\r\n\r\n").encode() + hidden
        outer = (f"POST /complete HTTP/1.1\r\nHost: 127.0.0.1:{self.port}\r\nContent-Type: text/plain\r\n"
                 f"Content-Length: {len(inner)}\r\n\r\n").encode() + inner
        with socket.create_connection(("127.0.0.1", self.port), timeout=5) as s:
            s.sendall(outer)
            chunks = []
            while True:
                data = s.recv(4096)
                if not data:
                    break
                chunks.append(data)
        raw = b"".join(chunks).decode()
        self.assertIn(" 403 ", raw.split("\r\n", 1)[0])
        self.assertEqual(raw.count("HTTP/1."), 1)     # one reply only: the hidden request never ran
        self.assertEqual(len(self.ports), 1)

    def test_reconnect_succeeds_after_server_idle_close(self):
        """When the server closes an idle keep-alive socket, a fresh HTTP/1.1 connection succeeds cleanly."""
        self.ns["H"].timeout = 0.25
        conn = http.client.HTTPConnection("127.0.0.1", self.port, timeout=5)
        try:
            headers = {"Content-Type": "application/json"}
            conn.request("POST", "/complete", json.dumps({"before": "first"}), headers)
            r1 = conn.getresponse()
            self.assertEqual(r1.status, 200)
            r1.read()
            time.sleep(0.35)
            # Reconnect cleanly after server closed idle socket
            conn.close()
            conn2 = http.client.HTTPConnection("127.0.0.1", self.port, timeout=5)
            try:
                conn2.request("POST", "/complete", json.dumps({"before": "second"}), headers)
                r2 = conn2.getresponse()
                self.assertEqual(r2.status, 200)
                self.assertEqual(json.loads(r2.read())["text"], "hello world")
            finally:
                conn2.close()
        finally:
            self.ns["H"].timeout = 3600
            conn.close()


class EventTapAndLogContracts(unittest.TestCase):
    def test_keys_handle_decodes_unicode_once_and_never_calls_focus_focused_synchronously(self):
        src = (ROOT / "app/Keys.swift").read_text()
        self.assertEqual(src.count("keyboardGetUnicodeString("), 1)
        handle = src.split("    func handle(", 1)[1].split("\n    /// Double Shift", 1)[0]
        # Space expansion dispatches Focus.focused() onto DispatchQueue.main.async off the event tap
        self.assertNotIn("let revision = inputRevision, field = Focus.focused()", handle)
        self.assertIn("Snippets.afterSpace(revision: revision, expected: Focus.focused())", handle)

    def test_main_log_writes_off_main_thread_and_flushes_on_exit(self):
        src = (ROOT / "app/Main.swift").read_text()
        self.assertIn('DispatchQueue(label: "drafter.log", qos: .utility)', src)
        self.assertIn("logQueue.async {", src)
        self.assertIn("func flushLogs()", src)
        self.assertGreaterEqual(src.count("flushLogs()"), 3)


if __name__ == "__main__":
    unittest.main()

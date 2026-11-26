"""The engine's token and instance id: every route but GET /health needs X-Drafter-Token, /health names the instance,
data/engine.token is 0600, and the token never shows up in an answer.

Real HTTP on port 0 with the real handler lifted from engine/server.py; no model, no live data/ (a temp dir).
Run: .venv/bin/python -B tests/test_engine_auth.py
"""
import http.client
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import stat
import tempfile
import threading
import time
import types
import unittest
from unittest.mock import Mock, patch

from server_src import lift

ROOT = Path(__file__).resolve().parents[1]
TOKEN = "0123456789abcdef" * 4          # made up for the test
INSTANCE = "feedc0de" * 4


def health_stand_ins():
    """Everything GET /health reads, made up, so no model loads and nothing in data/ is touched."""
    model = types.SimpleNamespace(memory_gb=lambda: (0.1, 0.2), repo="synthetic/model", adapter=None, kv_gb=lambda: {},
                                  asleep=False, sleeps=0)
    stats = lambda: {}
    return dict(
        model=model, CURRENT={"entry": None}, FMT="raw", builder=types.SimpleNamespace(head_ids=[]),
        guard=types.SimpleNamespace(rss_gb=lambda: 0.5, _cap=[3.6]), FAST={"m": None, "used": 0, "loads": 0, "refused": 0},
        wordgate=lambda: None, gate=lambda: None, people_mem=types.SimpleNamespace(chats={}), ahead_stats=stats,
        knowledge=types.SimpleNamespace(stats=stats, people=lambda q: []), who=types.SimpleNamespace(stats={}),
        source_index=types.SimpleNamespace(stats=stats), dictionary=types.SimpleNamespace(load=lambda: {"words": []}),
        actions=types.SimpleNamespace(ALL=[], take_pending=lambda wait: []),
        provider=types.SimpleNamespace(kind=lambda: "", connected=lambda: False, state={"last_error": ""}),
        edits=types.SimpleNamespace(waiting=lambda: []),
    )


class EngineAuth(unittest.TestCase):
    def setUp(self):
        self.complete = Mock(return_value={"text": "synthetic"})
        self.ns = dict(BaseHTTPRequestHandler=BaseHTTPRequestHandler, json=json, time=time, threading=threading,
                       LOCAL_HOSTS=set(), INSTANCE=INSTANCE, request_seq=lambda: 1, TYPED=[0], WANT=[""],
                       ahead_key=lambda req, pack=None: req.get("before", ""), keep_running=Mock(),
                       complete=lambda req, seq=None, on_part=None: self.complete(req), **health_stand_ins())
        lift("H", into=self.ns)

        class TokenH(self.ns["H"]):
            token = TOKEN

        class TestServer(ThreadingHTTPServer):
            daemon_threads = True

        self.server = TestServer(("127.0.0.1", 0), TokenH)
        self.port = self.server.server_address[1]
        self.ns["LOCAL_HOSTS"].add(f"127.0.0.1:{self.port}")
        threading.Thread(target=self.server.serve_forever, daemon=True).start()

    def tearDown(self):
        self.server.shutdown()
        self.server.server_close()

    def call(self, method, path, body=None, token=None):
        conn = http.client.HTTPConnection("127.0.0.1", self.port, timeout=5)
        try:
            headers = {"Content-Type": "application/json"}
            if token is not None: headers["X-Drafter-Token"] = token
            conn.request(method, path, json.dumps(body).encode() if body is not None else None, headers)
            r = conn.getresponse()
            raw = r.read().decode()
            return r.status, raw
        finally:
            conn.close()

    def test_missing_token_is_refused_on_get_and_post(self):
        for method, path, body in (("GET", "/settings", None), ("GET", "/pending?wait=0", None), ("GET", "/edits", None),
                                   ("GET", "/people?q=x", None), ("POST", "/complete", {"before": "hi"}),
                                   ("POST", "/model-key", {"provider": "anthropic", "key": "made-up"})):
            status, raw = self.call(method, path, body)
            self.assertEqual((status, json.loads(raw)), (403, {"error": "forbidden"}), path)
        self.complete.assert_not_called()

    def test_wrong_token_is_refused(self):
        for bad in ("", "wrong", TOKEN[:-1], TOKEN + "0", TOKEN.upper()):
            self.assertEqual(self.call("GET", "/edits", token=bad)[0], 403, bad)
            self.assertEqual(self.call("POST", "/complete", {"before": "hi"}, token=bad)[0], 403, bad)
        self.complete.assert_not_called()

    def test_valid_token_passes(self):
        status, raw = self.call("GET", "/edits", token=TOKEN)
        self.assertEqual((status, json.loads(raw)), (200, {"edits": []}))
        status, raw = self.call("POST", "/complete", {"before": "hi"}, token=TOKEN)
        self.assertEqual((status, json.loads(raw)["text"]), (200, "synthetic"))
        self.assertEqual(self.call("GET", "/no-such-route", token=TOKEN)[0], 404)

    def test_health_is_open_and_names_the_instance(self):
        status, raw = self.call("GET", "/health")
        j = json.loads(raw)
        self.assertEqual((status, j["ok"], j["instance"]), (200, True, INSTANCE))
        self.assertEqual(self.call("GET", "/health?x=1")[0], 403)          # only /health itself is open

    def test_health_still_refuses_browsers(self):
        conn = http.client.HTTPConnection("127.0.0.1", self.port, timeout=5)
        try:
            conn.request("GET", "/health", headers={"Origin": "https://example.test"})
            self.assertEqual(conn.getresponse().status, 403)
        finally:
            conn.close()

    def test_no_answer_holds_the_token(self):
        answers = [self.call("GET", "/health")[1], self.call("GET", "/settings")[1], self.call("GET", "/edits", token=TOKEN)[1],
                   self.call("POST", "/complete", {"before": "hi"}, token="wrong")[1],
                   self.call("POST", "/complete", {"before": "hi"}, token=TOKEN)[1]]
        for raw in answers: self.assertNotIn(TOKEN, raw)

    def test_handler_without_a_token_lets_nothing_but_health_through(self):
        class NoTokenH(self.ns["H"]):
            token = None
        srv = ThreadingHTTPServer(("127.0.0.1", 0), NoTokenH)
        port = srv.server_address[1]
        self.ns["LOCAL_HOSTS"].add(f"127.0.0.1:{port}")
        threading.Thread(target=srv.serve_forever, daemon=True).start()
        try:
            for tok in ("", "None", TOKEN):
                conn = http.client.HTTPConnection("127.0.0.1", port, timeout=5)
                conn.request("GET", "/edits", headers={"X-Drafter-Token": tok})
                self.assertEqual(conn.getresponse().status, 403)
                conn.close()
            conn = http.client.HTTPConnection("127.0.0.1", port, timeout=5)
            conn.request("GET", "/health")
            self.assertEqual(conn.getresponse().status, 200)
            conn.close()
        finally:
            srv.shutdown(); srv.server_close()


class TokenFileAndEnv(unittest.TestCase):
    def test_token_file_is_0600_and_replaces_a_wider_one(self):
        ns = lift("write_token")
        with tempfile.TemporaryDirectory() as tmp:
            f = Path(tmp) / "engine.token"
            f.write_text("old"); os.chmod(f, 0o644)
            ns["write_token"](f, TOKEN)
            self.assertEqual(f.read_text(), TOKEN)
            self.assertEqual(stat.S_IMODE(f.stat().st_mode), 0o600)
            self.assertEqual(sorted(p.name for p in Path(tmp).iterdir()), ["engine.token"])   # no temp file left

    def test_env_sets_data_token_and_instance_and_token_leaves_the_env(self):
        with tempfile.TemporaryDirectory() as tmp, patch.dict(os.environ, {
                "DRAFTER_DATA": str(Path(tmp) / "d"), "DRAFTER_ENGINE_TOKEN": TOKEN, "DRAFTER_ENGINE_INSTANCE": INSTANCE}):
            ns = lift("DATA", "TOKEN", "INSTANCE", ROOT=ROOT)
            self.assertEqual(ns["DATA"], (Path(tmp) / "d").resolve())
            self.assertEqual((ns["TOKEN"], ns["INSTANCE"]), (TOKEN, INSTANCE))
            self.assertNotIn("DRAFTER_ENGINE_TOKEN", os.environ)          # helper processes never inherit it

    def test_without_env_a_fresh_token_and_instance(self):
        with patch.dict(os.environ, {}, clear=False):
            for k in ("DRAFTER_ENGINE_TOKEN", "DRAFTER_ENGINE_INSTANCE"): os.environ.pop(k, None)
            a = lift("TOKEN", "INSTANCE")
            b = lift("TOKEN", "INSTANCE")
        self.assertEqual((len(a["TOKEN"]), len(a["INSTANCE"])), (64, 32))
        self.assertNotEqual(a["TOKEN"], b["TOKEN"])

    def test_token_never_printed_or_passed_as_an_argument(self):
        src = (ROOT / "engine/server.py").read_text()
        for line in src.splitlines():
            if "print(" in line or "log(" in line: self.assertNotIn("TOKEN", line)
        self.assertIn("write_token(DATA / \"engine.token\", TOKEN)", src)
        swift = (ROOT / "app/Engine.swift").read_text()
        self.assertIn("p.arguments = [Home.server.path]", swift)
        self.assertIn('env["DRAFTER_ENGINE_TOKEN"] = newToken', swift)
        self.assertNotIn("log(\"\\(newToken", swift)

    def test_local_callers_send_the_token(self):
        for f in ("engine/entities.py", "bench/retrain.py", "bench/replay.py"):
            src = (ROOT / f).read_text()
            self.assertIn("X-Drafter-Token", src, f)
            self.assertIn("engine.token", src, f)

    def test_entities_reads_the_token_from_drafter_data(self):
        ns = lift("engine_headers", path=ROOT / "engine/entities.py", ROOT=ROOT)
        with tempfile.TemporaryDirectory() as tmp, patch.dict(os.environ, {"DRAFTER_DATA": tmp}):
            self.assertEqual(ns["engine_headers"](), {"Content-Type": "application/json"})
            (Path(tmp) / "engine.token").write_text(TOKEN + "\n")
            self.assertEqual(ns["engine_headers"](), {"Content-Type": "application/json", "X-Drafter-Token": TOKEN})


if __name__ == "__main__":
    unittest.main()

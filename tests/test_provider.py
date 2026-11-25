"""Connect a model (engine/provider.py): the Anthropic and OpenAI-compatible paths against a small local stand-in
server with made-up text, a refused key and a timeout. No real key and no network: nothing here reaches a provider.
The CLI path keeps its own tests (test_claude_argv.py, test_cloud_gate.py).

    .venv/bin/python -B tests/test_provider.py
"""
import json, sys, tempfile, threading, time, unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "engine"))
import provider, cloud

SEEN = []          # (path, headers, body) of every request the stand-in got


class Stub(BaseHTTPRequestHandler):
    def log_message(self, *a): pass

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers.get("Content-Length") or 0)))
        SEEN.append((self.path, {k.lower(): v for k, v in self.headers.items()}, body))
        key = self.headers.get("x-api-key") or (self.headers.get("authorization") or "").replace("Bearer ", "")
        if key == "made-up-refused": return self._send(401, {"error": {"type": "authentication_error"}})
        if body["messages"][-1]["content"] == "please be slow": time.sleep(2)
        text = "Made-up answer to: " + body["messages"][-1]["content"]
        if self.path == "/v1/messages":
            return self._send(200, {"content": [{"type": "text", "text": text}], "model": body["model"]})
        if self.path == "/v1/chat/completions":
            return self._send(200, {"choices": [{"message": {"role": "assistant", "content": text}}]})
        self._send(404, {})

    def _send(self, code, obj):
        data = json.dumps(obj).encode()
        self.send_response(code); self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data))); self.end_headers()
        try: self.wfile.write(data)
        except BrokenPipeError: pass


class Provider(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.server = ThreadingHTTPServer(("127.0.0.1", 0), Stub)
        cls.url = f"http://127.0.0.1:{cls.server.server_address[1]}"
        threading.Thread(target=cls.server.serve_forever, daemon=True).start()

    @classmethod
    def tearDownClass(cls): cls.server.shutdown()

    def setUp(self):
        SEEN.clear(); provider.forget_all()
        self.tmp = tempfile.TemporaryDirectory(); provider.SETTINGS = Path(self.tmp.name) / "settings.json"

    def tearDown(self): self.tmp.cleanup()

    def use(self, connect):
        provider.SETTINGS.write_text(json.dumps({"rework": True, "connect": connect}))

    def test_nothing_connected_is_local(self):
        self.assertEqual(provider.kind({}), "")
        self.assertFalse(provider.connected({}))
        self.assertFalse(cloud.allowed("rework", {"rework": True}))

    def test_anthropic_key_path(self):
        self.use({"provider": "anthropic", "baseURL": self.url})
        self.assertFalse(provider.connected())                       # no key handed over yet
        provider.set_key("anthropic", "made-up-key")
        self.assertTrue(provider.connected())
        st = json.loads(provider.SETTINGS.read_text())
        self.assertTrue(cloud.allowed("rework", st))
        self.assertEqual(provider.ask("hello Marta", 5), "Made-up answer to: hello Marta")
        path, headers, body = SEEN[-1]
        self.assertEqual(path, "/v1/messages")
        self.assertEqual(headers.get("x-api-key"), "made-up-key")
        self.assertEqual(body["model"], "claude-haiku-5-5")          # the fast helpers' default
        self.assertNotIn("made-up-key", provider.SETTINGS.read_text())  # the key is never in the settings file

    def test_worker_uses_the_careful_model_and_system_text(self):
        self.use({"provider": "anthropic", "baseURL": self.url}); provider.set_key("anthropic", "made-up-key")
        import claude_type
        w = claude_type.Worker("sonnet", "You rework made-up text.", max_tokens=50)
        self.assertIsInstance(w, provider.ApiWorker)
        text, first, ms = w.ask("teh cat", deadline=5, whole=True)
        self.assertEqual(text, "Made-up answer to: teh cat")
        body = SEEN[-1][2]
        self.assertEqual((body["model"], body["system"], body["max_tokens"]), ("claude-sonnet-5-5", "You rework made-up text.", 50))
        provider.set_key("anthropic", "")                            # disconnect: the worker is gone, nothing more is sent
        self.assertFalse(w.alive()); self.assertIsNone(w.ask("again", deadline=1))

    def test_models_are_settings(self):
        self.use({"provider": "anthropic", "baseURL": self.url, "fastModel": "made-up-fast", "carefulModel": "made-up-careful"})
        self.assertEqual((provider.model_for("haiku"), provider.model_for("sonnet")), ("made-up-fast", "made-up-careful"))

    def test_openai_compatible_endpoint(self):
        self.use({"provider": "openai", "baseURL": self.url + "/v1", "apiModel": "local-made-up-model"})
        provider.set_key("openai", "made-up-key")
        self.assertEqual(provider.ask("привіт, Сава", 5), "Made-up answer to: привіт, Сава")
        path, headers, body = SEEN[-1]
        self.assertEqual((path, body["model"]), ("/v1/chat/completions", "local-made-up-model"))
        self.assertEqual(headers.get("authorization"), "Bearer made-up-key")

    def test_refused_key_fails_quietly(self):
        self.use({"provider": "anthropic", "baseURL": self.url}); provider.set_key("anthropic", "made-up-refused")
        self.assertIsNone(provider.ask("hello", 5))
        self.assertIn("refused", provider.state["last_error"])
        self.assertNotIn("made-up-refused", provider.state["last_error"])

    def test_timeout_fails_quietly(self):
        self.use({"provider": "openai", "baseURL": self.url + "/v1", "apiModel": "m"}); provider.set_key("openai", "k")
        t = time.time()
        self.assertIsNone(provider.ask("please be slow", timeout=0.5))
        self.assertLess(time.time() - t, 1.8)

    def test_claude_worker_ask_goes_to_the_api(self):
        self.use({"provider": "anthropic", "baseURL": self.url}); provider.set_key("anthropic", "made-up-key")
        import claude_worker
        self.assertEqual(claude_worker.ask("summary of a made-up call", 5), "Made-up answer to: summary of a made-up call")

    def test_keys_never_go_on_a_command_line(self):
        src = (ROOT / "engine/provider.py").read_text() + (ROOT / "app/Connect.swift").read_text()
        self.assertNotIn("subprocess", src)
        self.assertNotIn("Process()", src)


if __name__ == "__main__":
    unittest.main()

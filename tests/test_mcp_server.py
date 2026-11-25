"""End-to-end stdio MCP tests. Every data file is synthetic and temporary.

    .venv/bin/python -B tests/test_mcp_server.py
"""
import io
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "engine"))
import mcp_server as mcp
from local_search import LocalSearchIndex


def request(method, params=None, ident=1):
    row = {"jsonrpc": "2.0", "method": method}
    if ident is not None:
        row["id"] = ident
    if params is not None:
        row["params"] = params
    return row


def call(name, arguments=None, ident=1):
    return request("tools/call", {"name": "drafter_" + name, "arguments": arguments or {}}, ident)


def encode(row, framed=False):
    raw = json.dumps(row, ensure_ascii=False).encode()
    return (f"Content-Length: {len(raw)}\r\n\r\n".encode() + raw) if framed else raw + b"\n"


def decode(raw):
    stream, rows = io.BytesIO(raw), []
    while line := stream.readline():
        if line.startswith(b"Content-Length:"):
            length = int(line.split(b":")[1])
            if stream.readline() != b"\r\n":
                raise AssertionError("Missing header terminator")
            line = stream.read(length)
        rows.append(json.loads(line))
    return rows


class MCPTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(dir=ROOT / "tests", prefix=".mcp-test-")
        self.addCleanup(self.tmp.cleanup)
        self.base = Path(self.tmp.name)
        self.data = self.base / "fixture"
        self.data.mkdir()
        self.service = mcp.Drafter(self.data)
        self.addCleanup(self.service.close)

    def write(self, relative, value):
        path = self.data / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(value if isinstance(value, str) else json.dumps(value), encoding="utf-8")
        return path

    def rpc(self, rows, framed=False, data=None):
        return self.raw(b"".join(encode(row, framed) for row in rows), data=data)

    def raw(self, payload, data=None):
        result = subprocess.run([sys.executable, "-B", str(ROOT / "engine/mcp_server.py"),
                                 "--data", str(data or self.data)], input=payload,
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE, cwd=self.base, timeout=10)
        self.assertEqual(result.returncode, 0, result.stderr.decode())
        self.assertEqual(result.stderr, b"")
        return decode(result.stdout)

    def value(self, response):
        self.assertNotIn("error", response)
        self.assertFalse(response["result"]["isError"], response)
        self.assertEqual(response["result"]["content"][0]["type"], "text")
        return json.loads(response["result"]["content"][0]["text"])

    def tool_error(self, response):
        self.assertTrue(response["result"]["isError"], response)

    def fixture(self, index_open=False):
        self.write("calls/older/meta.json", {"call": False, "started": 100, "app": "Demo Editor"})
        self.write("calls/older/transcript.txt", "A long orchard note.\nA second paragraph.\n")
        self.write("calls/newer/meta.json", {"title": "Orchard review", "call": True, "started": 200,
                   "app": "Demo Call", "event": {"title": "Calendar title", "people": ["Demo Person"]},
                   "place": "Demo Room", "password": "excluded-meta-value"})
        self.write("calls/newer/lines.json", [{"who": "Speaker 1", "start": 0, "text": "Orchard café plan."},
                                            {"who": "Speaker 2", "start": 3.25, "text": "Send the sketch."}])
        self.write("calls/newer/transcript.txt", "Older fallback transcript must not win.")
        self.write("calls/newer/my-notes.md", "My synthetic sketch note.")
        self.write("calls/newer/shots.json", [{"time": 1, "ocr": "excluded-shot-value"}, {"time": 2}])
        self.write("calls/newer/screen.mp4", "synthetic placeholder, never opened")
        (self.data / "calls/newer/me.wav").write_bytes(b"\0" * (44 + 32000 * 2))
        (self.data / "calls/newer/them.wav").write_bytes(b"\0" * (44 + 32000 * 4))
        self.write("notes/2026-01-01-old.md", "# Old summary\n\nRecording: calls/newer\n")
        self.write("notes/2026-01-02-review.md", "# Дзвінок: Saved title\n\nПро: Demo Guest\n\n"
                   "## Головне\n- Keep the orchard plan.\n\n## Розшифровка\nMade-up speech.\n"
                   "\n## Фоловапи\n- Send the sketch.\n\nЗапис: " + str(self.data / "calls/newer") + "\n")
        self.write("promises.json", {"rows": [
            {"id": "past", "t": 20, "what": "sketch", "person": "Demo Guest", "app": "Demo Chat", "due": 1, "done": None},
            {"id": "future", "t": 10, "what": "plan", "person": "Demo Person", "app": "Demo Mail", "due": 4102444800, "done": None},
            {"id": "done", "what": "finished task", "due": 1, "done": 30}]})
        self.write("settings.json", {"mcp": True, "contextPacks": True})
        self.write("entities.json", {"built_day": "2026-01-01", "records": [
            {"id": "demo:orchard", "name": "Orchard", "kind": "project", "who": "a synthetic project",
             "aliases": ["Demo Orchard"], "pack": {"facts": [], "pointers": [
                 {"label": "Link", "value": "https://orchard.example.test", "path": False}], "newest": "2099-01-01"}}],
            "surfaces": {"orchard": [[0, "name"]]}})
        for kind in ("mail", "beeper", "drive"):
            self.write("sources/" + kind + ".jsonl", json.dumps({
                "id": kind + ":1", "src": kind, "t": 100, "title": "Orchard plan",
                "text": "A synthetic orchard sketch", "who": [{"name": "Demo Person", "email": "demo@example.test"}],
                "url": "https://orchard.example.test/plan"}) + "\n")
        index = LocalSearchIndex(data_dir=self.data)
        self.assertNotIn("error", index.sync())
        if index_open:
            self.addCleanup(index.close)
        else:
            index.close()
        return index

    def all_calls(self):
        return [call("search_sources", {"query": "orchard"}), call("list_recordings"),
                call("read_recording", {"id": "newer"}), call("list_promises"),
                call("entity_context", {"query": "Orchard", "level": 3}), call("recent_notes")]

    def snapshot(self):
        return {str(p.relative_to(self.data)): (p.read_bytes(), p.stat().st_mtime_ns)
                for p in self.data.rglob("*") if p.is_file() and not p.is_symlink()}

    def test_handshake_both_transports(self):
        for framed in (False, True):
            with self.subTest(framed=framed):
                rows = self.rpc([request("initialize", {"protocolVersion": "2024-11-05", "capabilities": {},
                                 "clientInfo": {"name": "synthetic", "version": "1"}}, ident=0),
                                 request("notifications/initialized", ident=None), request("ping", ident=2),
                                 request("tools/list", ident="tools")], framed)
                self.assertEqual(len(rows), 3)
                self.assertEqual(rows[0], {"jsonrpc": "2.0", "id": 0, "result": {
                    "protocolVersion": "2024-11-05", "serverInfo": {"name": "drafter", "version": "1.0.0"}, "capabilities": {"tools": {}}}})
                self.assertEqual(rows[1]["result"], {})
                self.assertEqual(rows[2]["id"], "tools")
                self.assertEqual({t["name"] for t in rows[2]["result"]["tools"]}, set(mcp.TOOL_MAP))
                self.assertEqual(len(rows[2]["result"]["tools"]), 6)

    def test_protocol_fallback_and_unknown_notifications(self):
        rows = self.rpc([request("initialize", {"protocolVersion": "2099-01-01"}),
                         request("notifications/unknown", ident=None), request("ping", ident=2)])
        self.assertEqual(len(rows), 2)
        self.assertEqual(rows[0]["result"]["protocolVersion"], "2024-11-05")
        self.assertEqual(rows[1]["result"], {})

    def test_all_tools_both_transports_and_no_disk_writes(self):
        self.fixture()
        before = self.snapshot()
        for framed in (False, True):
            with self.subTest(framed=framed):
                values = [self.value(r) for r in self.rpc(self.all_calls(), framed)]
                self.assertEqual({r["kind"] for r in values[0]}, {"mail", "beeper", "drive"})
                self.assertEqual([r["id"] for r in values[1]], ["newer", "older"])
                self.assertEqual(values[1][0], {"id": "newer", "title": "Orchard review", "started": 200,
                    "call": True, "app": "Demo Call", "people": ["Demo Guest"], "duration_secs": 4.0,
                    "has_transcript": True, "has_video": True, "shot_count": 2})
                recording = values[2]
                self.assertEqual(recording["my_notes"], "My synthetic sketch note.")
                self.assertEqual(recording["note"]["summary"], ["Keep the orchard plan."])
                self.assertEqual(recording["note"]["todos"], ["Send the sketch."])
                self.assertIn("[3.25s] Speaker 2: Send the sketch.", recording["transcript"])
                self.assertNotIn("fallback", recording["transcript"])
                self.assertNotIn("excluded-", json.dumps(values))
                self.assertEqual([r["what"] for r in values[3]], ["sketch", "plan"])
                self.assertEqual([r["overdue"] for r in values[3]], [True, False])
                self.assertEqual(values[4]["context"]["name"], "Orchard")
                self.assertIn("synthetic project", values[4]["context"]["text"])
                self.assertEqual(values[5][0]["id"], "2026-01-02-review.md")
                self.assertEqual(self.snapshot(), before)

    def test_wal_reads_latest_commit_during_writer_and_stays_read_only(self):
        index = self.fixture(index_open=True)
        db = index._writer
        db.execute("UPDATE docs SET title='Latest orchard' WHERE src='mail'")
        db.commit()
        db.execute("BEGIN IMMEDIATE")
        db.execute("UPDATE docs SET title='Uncommitted orchard' WHERE src='mail'")
        before = self.snapshot()
        try:
            rows = self.value(self.rpc([call("search_sources", {"query": "latest"})])[0])
            self.assertEqual([r["title"] for r in rows], ["Latest orchard"])
            self.assertEqual(self.snapshot(), before)
        finally:
            db.rollback()

    def test_search_filters_boost_limits_and_punctuation(self):
        index = self.fixture(index_open=True)
        db = index._writer
        # Ranking boost is not a person filter; other people still appear.
        db.execute("UPDATE docs SET who_json=? WHERE src='drive'", (json.dumps([{"name": "Demo Guest", "email": ""}]),))
        db.commit()
        args = [{"query": "orchard", "kinds": ["mail"], "limit": 1},
                {"query": "orchard", "who": ["Demo Guest"]}, {"query": "orchard", "kinds": []},
                {"query": "\" * ; --"}]
        values = [self.value(r) for r in self.rpc([call("search_sources", a) for a in args])]
        self.assertEqual([r["kind"] for r in values[0]], ["mail"])
        self.assertEqual(values[1][0]["kind"], "drive")
        self.assertEqual(len(values[1]), 3)
        self.assertEqual(values[2:], [[], []])

    def test_recording_and_note_query_limits(self):
        self.fixture()
        values = [self.value(r) for r in self.rpc([
            call("list_recordings", {"query": "paragraph", "limit": 1}),
            call("list_recordings", {"query": "no match"}),
            call("recent_notes", {"query": "sketch", "limit": 1}),
            call("recent_notes", {"query": "no match"})])]
        self.assertEqual([r["id"] for r in values[0]], ["older"])
        self.assertEqual(values[1], [])
        self.assertEqual([r["title"] for r in values[2]], ["Saved title"])
        self.assertEqual(values[3], [])

    def test_paging_preserves_every_character_and_unicode(self):
        self.fixture()
        full = self.value(self.rpc([call("read_recording", {"id": "newer"})])[0])["transcript"]
        for budget in (1, 17, 50):
            offset, chunks = 0, []
            while offset is not None:
                page = self.value(self.rpc([call("read_recording", {"id": "newer", "offset": offset, "max_chars": budget})], True)[0])
                self.assertLessEqual(len(page["transcript"]), budget)
                self.assertEqual(page["offset"], offset)
                chunks.append(page["transcript"])
                next_offset = page["next_offset"]
                if next_offset is not None:
                    self.assertGreater(next_offset, offset)
                offset = next_offset
            self.assertEqual("".join(chunks), full)
        page = self.value(self.rpc([call("read_recording", {"id": "older", "offset": 1000})])[0])
        self.assertEqual(page["transcript"], "")
        self.assertIsNone(page["next_offset"])

    def test_default_transcript_limit_and_fallback(self):
        self.write("settings.json", {"mcp": True})
        self.write("calls/demo/transcript.txt", "x" * 13000)
        page = self.value(self.rpc([call("read_recording", {"id": "demo"})])[0])
        self.assertEqual(len(page["transcript"]), 12000)
        self.assertEqual(page["next_offset"], 12000)
        self.assertTrue(page["truncated"])

    def test_mcp_disabled_by_default_blocks_all_tools_before_reads(self):
        self.fixture()
        for settings in (None, {}, {"mcp": False}, {"mcp": "yes"}, "{bad", []):
            if settings is None:
                (self.data / "settings.json").unlink(missing_ok=True)
            else:
                self.write("settings.json", settings)
            with patch.object(mcp.entities.Store, "reload", side_effect=AssertionError("must not read entities")):
                for item in self.all_calls():
                    res = mcp.dispatch(self.service, item)
                    self.tool_error(res)
                    self.assertIn("mcp", res["result"]["content"][0]["text"].lower())

    def test_closed_cache_is_reused_without_rereading_bytes(self):
        self.fixture()
        real_read_bytes = Path.read_bytes
        reads = []
        def counted_read_bytes(p):
            if p.name == "search.sqlite":
                reads.append(p)
            return real_read_bytes(p)
        with patch.object(Path, "read_bytes", counted_read_bytes):
            first = self.value(mcp.dispatch(self.service, call("search_sources", {"query": "orchard"})))
            second = self.value(mcp.dispatch(self.service, call("search_sources", {"query": "sketch"})))
            self.assertEqual(len(first), 3)
            self.assertEqual(len(second), 3)
            self.assertEqual(len(reads), 1)
            # Re-open and modify the cache so mtime/size changes; next call reloads once.
            idx = LocalSearchIndex(data_dir=self.data)
            self.assertNotIn("error", idx.sync())
            idx._writer.execute("UPDATE docs SET title='Refreshed orchard' WHERE src='mail'")
            idx._writer.commit()
            idx.close()
            third = self.value(mcp.dispatch(self.service, call("search_sources", {"query": "refreshed"})))
            self.assertEqual([r["title"] for r in third], ["Refreshed orchard"])
            self.assertEqual(len(reads), 2)

    def test_context_switch_checked_before_entity_reads_and_reloaded(self):
        self.fixture()
        for settings in ({"mcp": True, "contextPacks": False}, {"mcp": True, "contextPacks": None}, "{bad", "", []):
            self.write("settings.json", settings)
            with patch.object(mcp.entities.Store, "reload", side_effect=AssertionError("must not read entities")):
                result = mcp.dispatch(self.service, call("entity_context", {"query": "Orchard"}))
            self.tool_error(result)
            self.tool_error(self.rpc([call("entity_context", {"query": "Orchard"})])[0])
        self.write("settings.json", {"mcp": True})
        levels = [self.value(r)["context"] for r in self.rpc([
            call("entity_context", {"query": "Orchard", "level": lv}) for lv in (1, 2, 3)])]
        self.assertEqual(levels[0]["text"], "Orchard")
        self.assertEqual([r["level"] for r in levels], [1, 2, 3])
        (self.data / "settings.json").unlink()
        self.tool_error(self.rpc([call("entity_context", {"query": "Orchard"})])[0])

    def test_missing_and_empty_data_dirs(self):
        # Missing directory has no settings.json -> MCP off by default, never creates directory.
        for item in self.all_calls():
            self.tool_error(self.rpc([item], data=self.base / "missing")[0])
        self.assertFalse((self.base / "missing").exists())
        # Empty data directory with mcp enabled returns empty lists cleanly.
        self.write("settings.json", {"mcp": True})
        calls = [r for r in self.all_calls() if r["params"]["name"] != "drafter_read_recording"]
        values = [self.value(r) for r in self.rpc(calls, data=self.data)]
        self.assertEqual(values[:3], [[], [], []])
        self.assertEqual(values[3]["entity"]["entities"], [])
        self.assertEqual(values[3]["context"]["found"], 0)
        self.assertEqual(values[4], [])

    def test_traversal_absolute_and_symlink_recording_rejected(self):
        self.fixture()
        outside = self.base / "outside"
        outside.mkdir()
        (outside / "transcript.txt").write_text("outside sentinel")
        (self.data / "calls/escape").symlink_to(outside, target_is_directory=True)
        for rid in ("../../etc/passwd", str(outside), "../outside", "..", ".", "a/b", "a\\b", "a\0b", "escape", "missing"):
            with self.subTest(id=rid):
                rows = self.rpc([call("read_recording", {"id": rid}), request("ping", ident=2)])
                self.tool_error(rows[0])
                self.assertEqual(rows[1]["result"], {})
                self.assertNotIn("outside sentinel", json.dumps(rows))
        self.assertEqual(len(self.value(self.rpc([call("list_recordings")])[0])), 2)

    def test_symlinks_in_files_and_directories_never_followed(self):
        outside = self.base / "outside.json"
        outside.write_text('{"mcp": true, "contextPacks": true, "rows": [], "records": []}')
        self.write("settings.json", {"mcp": True, "contextPacks": True})
        for relative, tool_call in [
            ("promises.json", call("list_promises")),
            ("entities.json", call("entity_context", {"query": "Demo"})),
            ("cache/search.sqlite", call("search_sources", {"query": "demo"})),
            ("calls/demo/transcript.txt", call("read_recording", {"id": "demo"}))]:
            with self.subTest(path=relative):
                path = self.data / relative
                path.parent.mkdir(parents=True, exist_ok=True)
                path.symlink_to(outside)
                self.tool_error(self.rpc([tool_call])[0])
                path.unlink()
        (self.data / "settings.json").unlink()
        (self.data / "settings.json").symlink_to(outside)
        self.tool_error(self.rpc([call("entity_context", {"query": "Demo"})])[0])
        (self.data / "settings.json").unlink()
        self.write("settings.json", {"mcp": True})
        (self.data / "notes").symlink_to(self.base, target_is_directory=True)
        self.tool_error(self.rpc([call("recent_notes")])[0])

    def test_bad_cache_never_repaired_or_rebuilt(self):
        self.write("settings.json", {"mcp": True})
        self.write("cache/search.sqlite", "synthetic corrupt database")
        self.write("sources/mail.jsonl", '{"id":"mail:1","text":"orchard"}\n')
        before = self.snapshot()
        self.tool_error(self.rpc([call("search_sources", {"query": "orchard"})])[0])
        self.assertEqual(self.snapshot(), before)
        with patch.object(LocalSearchIndex, "_reset", side_effect=AssertionError("must not reset")), \
             patch.object(LocalSearchIndex, "sync", side_effect=AssertionError("must not sync")):
            self.tool_error(mcp.dispatch(self.service, call("search_sources", {"query": "orchard"})))

    def test_schema_mismatch_does_not_rebuild(self):
        index = self.fixture(index_open=True)
        index._writer.execute("UPDATE meta SET val='wrong' WHERE key='schema_version'")
        index._writer.commit()
        before = self.snapshot()
        self.tool_error(self.rpc([call("search_sources", {"query": "orchard"})])[0])
        self.assertEqual(self.snapshot(), before)

    def test_invalid_params_unknown_tool_and_method_keep_loop_alive(self):
        cases = [call("unknown"), call("search_sources"), call("list_recordings", {"limit": 26}),
                 call("recent_notes", {"limit": 21}), call("recent_notes", {"limit": True}),
                 call("recent_notes", {"limit": 0}), call("recent_notes", {"limit": "5"}),
                 call("entity_context", {"query": "demo", "level": 4}),
                 call("read_recording", {"id": "demo", "offset": -1}),
                 call("read_recording", {"id": "demo", "max_chars": 100001}),
                 call("search_sources", {"query": "demo", "kinds": ["passwords"]}),
                 call("search_sources", {"query": "demo", "who": [3]}),
                 call("list_promises", {"path": "elsewhere"}),
                 request("tools/call", {"name": [], "arguments": {}}),
                 request("tools/call", {"name": "drafter_list_promises", "arguments": None}),
                 request("tools/call", [])]
        rows = self.rpc(cases + [request("unknown"), request("ping")])
        self.assertTrue(all(row["error"]["code"] == -32602 for row in rows[:-2]))
        self.assertEqual(rows[-2]["error"]["code"], -32601)
        self.assertEqual(rows[-1]["result"], {})

    def test_malformed_json_requests_and_frames_keep_loop_alive(self):
        for framed in (False, True):
            payload = b'{bad json}\n' if not framed else b'Content-Length: 5\r\n\r\n{bad}'
            rows = self.raw(payload + encode(None, framed) + encode([], framed) + encode(request("ping"), framed))
            self.assertEqual([r["error"]["code"] for r in rows[:-1]], [-32700, -32600, -32600])
            self.assertEqual(rows[-1]["result"], {})
        for header in (b"-1", b"no", b"9" * 5000):
            rows = self.raw(b"Content-Length: " + header + b"\r\n\r\n" + encode(request("ping")))
            self.assertEqual(rows[0]["error"]["code"], -32700)
            self.assertEqual(rows[-1]["result"], {})
        rows = self.raw(b"Content-Length: 99\r\n\r\n{}")
        self.assertEqual(len(rows), 1)
        self.assertEqual(rows[0]["error"]["code"], -32700)

    def test_mixed_framing_and_extra_headers(self):
        payload = b"Content-Type: application/json; charset=utf-8\r\n" + encode(request("ping"), True)
        payload += encode(request("ping", ident=2))
        rows = self.raw(payload)
        self.assertEqual([r["result"] for r in rows], [{}, {}])

    def test_invalid_unicode_and_bad_saved_data_keep_loop_alive(self):
        self.write("settings.json", {"mcp": True})
        rows = self.raw(b'{"jsonrpc":"2.0","id":"\\ud800","method":"ping"}\n' + encode(request("ping", ident=2)))
        self.assertEqual(rows[0]["result"], {})
        self.assertEqual(rows[1]["result"], {})
        self.write("promises.json", {"rows": [{"id": "bad", "due": "bad number"}]})
        rows = self.rpc([call("list_promises"), request("ping")])
        self.tool_error(rows[0])
        self.assertEqual(rows[1]["result"], {})
        self.assertNotIn("bad number", json.dumps(rows))

    def test_no_network_or_unapproved_data_reads(self):
        self.fixture()
        # The running server is isolated from network access and any unlisted data path.
        real_open, real_path_open = open, Path.open
        allowed = {"settings.json", "entities.json", "promises.json"}
        def guard(path):
            relative = Path(path).resolve().relative_to(self.data)
            if str(relative) not in allowed and relative.parts[0] not in ("calls", "notes", "cache"):
                raise AssertionError("unapproved read")
        def guarded_open(path, *args, **kwargs):
            guard(path)
            return real_open(path, *args, **kwargs)
        def guarded_path_open(path, *args, **kwargs):
            guard(path)
            return real_path_open(path, *args, **kwargs)
        with patch("builtins.open", guarded_open), patch.object(Path, "open", guarded_path_open), \
             patch("socket.socket", side_effect=AssertionError("network forbidden")), \
             patch("subprocess.Popen", side_effect=AssertionError("process forbidden")):
            for item in self.all_calls():
                self.value(mcp.dispatch(self.service, item))


if __name__ == "__main__":
    unittest.main()

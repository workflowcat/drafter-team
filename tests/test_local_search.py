"""Local search cache for sources on synthetic files only. No live data, models, network or app IO.

    .venv/bin/python -B tests/test_local_search.py
"""
import json
import os
from pathlib import Path
import re
import sqlite3
import sys
import tempfile
import threading
import time
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "engine"))
import local_search
from local_search import LocalSearchIndex, safe_fts_query
import sources


def row(src, ident, text="orchard plan", **extra):
    return {"id": f"{src}:{ident}", "src": src, "t": 100, "title": "Orchard plan",
            "text": text, "who": [{"name": "Demo Person", "email": "demo@example.test"}],
            "mine": False, "links": [], "files": ["orchard.pdf"], "url": "https://docs.example.test/" + str(ident),
            "chat": "group", **extra}


def legacy_find(rows, query, who=(), n=8, since=0):
    """Frozen pre-SQLite finder contract, independent of the production adapter."""
    fold = sources.fold
    words = re.findall(r"[^\W_]{3,}", fold(query))
    if not words:
        return []
    ws, out = {fold(x) for x in who if x}, []
    for name in ("mail", "drive", "beeper"):
        for r in sorted(rows.get(name, []), key=lambda r: -(r.get("t") or 0)):
            if (r.get("t") or 0) < since or not (r.get("links") or r.get("files") or r.get("url")):
                continue
            head = (r.get("text") or "")[:120 if name == "beeper" else 300]
            hay = fold(" ".join([r.get("title") or "", head] + (r.get("files") or []) + (r.get("links") or [])))
            hits = sum(w in hay for w in words)
            if not hits:
                continue
            with_them = bool(ws & ({fold(p.get("email")) for p in r.get("who") or []} |
                                   {fold(p.get("name")) for p in r.get("who") or []}))
            score = hits / len(words) + (0.5 if with_them else 0)
            sender = next((p.get("name") or p.get("email") for p in r.get("who") or []), "")
            targets = [(f, r.get("url") or "") for f in (r.get("files") or [])[:3]]
            targets += [("", u) for u in (r.get("links") or [])[:3] if any(w in fold(u) for w in words) or with_them]
            if name == "drive" and not r.get("files"):
                targets.append(("", r.get("url")))
            for f, u in targets:
                out.append((score, r["t"], {"title": r.get("title"), "file": f, "url": u,
                                           "src": name, "t": r["t"], "from": sender}))
    out.sort(key=lambda x: (-x[0], -x[1]))
    result, seen = [], set()
    for _, _, item in out:
        key = item["file"], item["url"]
        if key not in seen:
            seen.add(key)
            result.append(item)
            if len(result) >= n:
                break
    return result


class Base(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.data = Path(self.tmp.name)
        self.folder = self.data / "sources"
        self.folder.mkdir()
        self.index = LocalSearchIndex(data_dir=self.data)
        self.addCleanup(self.index.close)

    def write(self, kind, rows):
        path = self.folder / (kind + ".jsonl")
        path.write_text("".join(json.dumps(r, ensure_ascii=False) + "\n" for r in rows))
        return path

    def integrity(self):
        with sqlite3.connect(self.index.db_path) as db:
            self.assertEqual(db.execute("PRAGMA integrity_check").fetchone()[0], "ok")
            for table in ("docs_fts", "docs_find"):
                db.execute(f"INSERT INTO {table}({table},rank) VALUES('integrity-check',1)")


class Sync(Base):
    def test_schema_pragmas_and_stats(self):
        self.write("mail", [row("mail", 1)])
        self.index.sync()
        db = self.index._writer
        for pragma, value in (("journal_mode", "wal"), ("synchronous", 1), ("temp_store", 2), ("busy_timeout", 5000)):
            self.assertEqual(db.execute("PRAGMA " + pragma).fetchone()[0], value)
        self.assertEqual(db.execute("SELECT val FROM meta WHERE key='schema_version'").fetchone()[0], local_search.SCHEMA_VERSION)
        stats = self.index.stats()
        self.assertEqual(stats["src"], {"mail": 1})
        self.assertGreater(stats["db_bytes"], 0)
        self.assertGreaterEqual(stats["last_sync_ms"], 0)
        self.integrity()

    def test_noop_does_not_parse_or_write_even_after_reopen(self):
        self.write("mail", [row("mail", 1)])
        self.write("drive", [row("drive", 2)])
        self.index.sync()
        before = self.index._writer.total_changes
        with patch.object(self.index, "_read_jsonl", side_effect=AssertionError("reparsed JSONL")):
            self.assertEqual(self.index.sync()["changed"], [])
            self.assertEqual(self.index._writer.total_changes, before)
            self.index.close()
            self.assertEqual(self.index.sync()["changed"], [])
            self.assertEqual(len(self.index.search("orchard")), 2)
        self.integrity()

    def test_changed_files_only_update_delete_and_same_mtime_size_change(self):
        path = self.write("mail", [row("mail", 1, "oldtoken", title="Old")])
        self.write("beeper", [row("beeper", 2)])
        self.index.sync()
        stamp = path.stat()
        self.write("mail", [row("mail", 3, "replacementtoken much longer", title="New")])
        os.utime(path, ns=(stamp.st_atime_ns, stamp.st_mtime_ns))
        with patch.object(self.index, "_read_jsonl", wraps=self.index._read_jsonl) as read:
            self.assertEqual(self.index.sync()["changed"], ["mail"])
            self.assertEqual(read.call_args_list[0].args, (path,))
            self.assertEqual(read.call_count, 1)
        self.assertEqual(self.index.search("oldtoken"), [])
        self.assertEqual(self.index.search("replacementtoken")[0]["id"], "mail:3")
        path.unlink()
        self.index.sync()
        self.assertEqual(self.index.stats()["src"], {"beeper": 1})
        self.integrity()

    def test_mtime_alone_invalidates_same_size_file(self):
        path = self.write("mail", [row("mail", 1)])
        self.index.sync()
        st = path.stat()
        os.utime(path, ns=(st.st_atime_ns, st.st_mtime_ns + 1))
        with patch.object(self.index, "_read_jsonl", wraps=self.index._read_jsonl) as read:
            self.index.sync()
            self.assertEqual(read.call_count, 1)

    def test_disabled_and_reenabled_from_state_without_source_change(self):
        source = self.write("mail", [row("mail", 1)])
        original = source.read_bytes()
        state = sources.State(self.data / "sources.json")
        self.index.sync()
        state.update("mail", enabled=False)
        self.index.sync()
        self.assertEqual(self.index.search("orchard"), [])
        state.update("mail", enabled=True)
        self.index.sync()
        self.assertEqual(len(self.index.search("orchard")), 1)
        self.assertEqual(source.read_bytes(), original)
        self.index.sync(enabled={"mail": False})
        self.assertEqual(self.index.search("orchard"), [])
        self.index.sync(enabled=["mail"])
        self.assertEqual(len(self.index.search("orchard")), 1)
        self.integrity()

    def test_caps_duplicate_ids_bad_lines_and_mine(self):
        rows = [row("mail", i, mine=i % 2 == 0, t=i) for i in range(5)]
        path = self.write("mail", rows + [row("mail", 4, "last duplicate wins", mine=True, t=4)])
        with path.open("a") as stream:
            stream.write('broken json\n[]\n42\n{"text":"missing id"}\n')
        with patch.dict(sources.INDEX_MAX, {"mail": 2}):
            self.index.sync()
        got = self.index._writer.execute("SELECT doc_id,mine FROM docs ORDER BY t DESC").fetchall()
        self.assertEqual([tuple(r) for r in got], [("mail:4", 1), ("mail:3", 0)])
        self.assertEqual(len(self.index.search("duplicate")), 1)
        self.index.sync()  # changed cap invalidates the cache stamp
        self.assertEqual(self.index.stats()["src"]["mail"], 5)
        self.integrity()

    def test_mid_read_rewrite_is_retried(self):
        self.write("mail", [row("mail", 1)])
        original = self.index._read_jsonl
        def concurrent_write(*args):
            rows = original(*args)
            self.write("mail", [row("mail", 2, "newer revision")])
            return rows
        with patch.object(self.index, "_read_jsonl", side_effect=concurrent_write):
            self.index.sync()
        self.assertEqual(self.index.search("orchard"), [])
        self.index.sync()
        self.assertEqual(self.index.search("newer")[0]["id"], "mail:2")

    def test_explicit_paths_are_isolated(self):
        self.write("mail", [row("mail", 1)])
        cache = self.data / "cache/alternate.db"
        ix = LocalSearchIndex(db_path=cache)
        self.addCleanup(ix.close)
        ix.sync()
        self.assertEqual(len(ix.search("orchard")), 1)
        other = self.data / "other"
        other.mkdir()
        (other / "mail.jsonl").write_text(json.dumps(row("mail", 7, "separate folder")))
        ix.sync(sources_dir=other)
        self.assertEqual(ix.search("separate")[0]["id"], "mail:7")


class Queries(Base):
    def test_multilingual_literals_and_fts_syntax(self):
        text = 'English orchard Український проєкт Київ café résumé NOT OR AND foo-bar unclosed'
        self.write("mail", [row("mail", 1, text, title="Sample", files=["budget-v2_final.pdf"],
                                links=["https://example.test/path/item?x=1"], who=[{"email": "team@example.test"}])])
        self.index.sync()
        for query in ("English", "україн", "проєкт", "Київ", "cafe", "resume", "café", "NOT", "OR", "AND",
                      "foo-bar", '"unclosed', "budget-v2_final.pdf", "team@example.test",
                      "https://example.test/path/item?x=1", "x", "1", "(NOT OR AND)*"):
            with self.subTest(query=query):
                self.assertEqual(self.index.search(query)[0]["id"], "mail:1")
        for query in ("", "!!!", '"', "_-(){}:+*", "\x00", "🪴"):
            self.assertEqual(safe_fts_query(query), "")
            self.assertEqual(self.index.search(query), [])
        self.assertEqual(safe_fts_query('OR "NOT'), '"OR"* OR "NOT"*')
        for query in ('"* OR title:(test) NOT -foo ^bar', "a " * 10000, "a\x00b", "क़", "\u0345"):
            match = safe_fts_query(query)
            if match:
                self.index._writer.execute("SELECT rowid FROM docs_fts WHERE docs_fts MATCH ?", (match,)).fetchall()
        self.integrity()

    def test_cross_source_filters_boost_snippet_and_mine(self):
        for kind in ("mail", "beeper", "drive"):
            self.write(kind, [row(kind, 1, t=10, mine=kind == "drive")])
        self.index.sync()
        hits = self.index.search("orchard")
        self.assertEqual({h["kind"] for h in hits}, set(local_search.SOURCE_NAMES) - {"obsidian"})  # vault is off in this fixture
        self.assertEqual({h["kind"] for h in self.index.search("orchard", kinds=["drive"])}, {"drive"})
        self.assertEqual(self.index.search("orchard", kinds=[]), [])
        self.assertEqual(self.index.search("orchard", kinds=set()), [])
        self.assertEqual(self.index.search("orchard", kinds="unknown"), [])
        self.assertEqual(len(self.index.search("orchard", limit=2)), 2)
        self.assertEqual(self.index.search("orchard", limit=0), [])
        self.assertTrue(all(h["snippet"] for h in hits))
        self.assertEqual(set(hits[0]), {"id", "kind", "src", "t", "title", "snippet", "who", "links", "files", "url", "score"})
        mine = {r[0]: r[1] for r in self.index._writer.execute("SELECT doc_id,mine FROM docs")}
        self.assertEqual([mine[k] for k in ("mail:1", "beeper:1", "drive:1")], [0, 0, 1])
        self.write("mail", [row("mail", 1, t=10), row("mail", 2, t=900, who=[])])
        self.index.sync()
        self.assertEqual(self.index.search("orchard", kinds="mail")[0]["id"], "mail:2")
        self.assertEqual(self.index.search("orchard", kinds="mail", who=["DEMO@example.test"])[0]["id"], "mail:1")
        self.assertEqual(self.index.search("orchard", kinds="mail", who=[" demo  person "])[0]["id"], "mail:1")

    def test_legacy_find_parity_including_substrings_and_dedup(self):
        rows = {
            "mail": [row("mail", 1, "contract budget", title="Contract draft", t=10,
                         files=["draft.pdf", "second.pdf", "third.pdf", "fourth.pdf"],
                         links=["https://example.test/contract", "https://example.test/unrelated"]),
                     row("mail", 2, "contract budget", title="Contract draft", t=20, who=[], files=["draft.pdf"],
                         url="https://docs.example.test/1")],
            "drive": [row("drive", 3, title="Contract document", files=[], t=30),
                      row("drive", 4, title="Beforecontract", text="", t=40, who=[]),
                      row("drive", 5, title="Other", text="", files=[],
                          links=["https://example.test/path/abcdefghi"], t=50)],
            "beeper": [row("beeper", 6, "x" * 121 + " secret", title="Chat", files=["chat.txt"], t=60),
                       row("beeper", 7, "x" * 119 + "edge", title="Chat", files=["edge.txt"], t=70)]}
        for kind, items in rows.items():
            self.write(kind, items)
        self.index.sync()
        adapter = sources.Index(self.folder, sync=True)
        self.addCleanup(lambda: adapter._local and adapter._local.close())
        for query in ("contract", "contract budget", "draft pdf", "cdefg", "https://example.test/path/abcdefghi",
                      "secret", "missing", "!!!", "OR", "a", '"draft', "edge"):
            for who in ((), ("demo@example.test",), ("Demo Person",), ("missing@example.test",)):
                for n in (1, 8):
                    with self.subTest(query=query, who=who, n=n):
                        expected = legacy_find(rows, query, who=who, n=n)
                        self.assertEqual(self.index.find_links_files(query, who, n), expected)
                        self.assertEqual(adapter.find(query, who, n), expected)
        self.assertEqual(self.index.find_links_files("contract", since=25), legacy_find(rows, "contract", since=25))
        self.assertEqual(self.index.find_links_files("contract", n=0), [])
        self.assertEqual(adapter.stats(), {"mail": 2, "beeper": 2, "drive": 3})
        self.assertEqual(len(adapter.rows["mail"]), 2)
        self.assertIn("head", adapter.rows["beeper"][0])

    def test_topics_legacy_subject_and_chat_rules(self):
        self.write("mail", [row("mail", 1, title="Contract", t=10), row("mail", 2, title="Re: Contract", t=20),
                            row("mail", 3, title="Other topic", t=30, who=[]), row("mail", 4, title="", t=40)])
        self.write("beeper", [row("beeper", 1, title="Team room", t=10), row("beeper", 2, title="Team room", t=20),
                              row("beeper", 3, title="Demo Person", chat="direct", t=30),
                              row("beeper", 4, title="Other room", chat="other", t=40)])
        self.index.sync()
        self.assertEqual(self.index.topics(["DEMO@example.test"], [" demo  PERSON "]),
                         {"mail": ["Re: Contract"], "chats": ["Other room", "Team room"]})
        self.assertEqual(self.index.topics(names=["Demo Person"], n=1)["chats"], ["Other room"])
        self.assertEqual(self.index.topics(names=["De"]), {"mail": [], "chats": []})
        self.assertEqual(self.index.topics(["demo@example.test"], n=0), {"mail": [], "chats": []})


class Recovery(Base):
    def test_corrupt_file_before_open_rebuilt_without_source_writes(self):
        path = self.write("mail", [row("mail", 1)])
        original = path.read_bytes()
        self.index.db_path.parent.mkdir(parents=True)
        self.index.db_path.write_bytes(b"this is not a sqlite file")
        self.index.sync()
        self.assertEqual(len(self.index.search("orchard")), 1)
        self.assertEqual(path.read_bytes(), original)
        self.integrity()

    def test_sqlite_error_never_wipes_cache(self):
        self.write("mail", [row("mail", 1)])
        self.index.sync()
        inode_before = self.index.db_path.stat().st_ino
        err = sqlite3.OperationalError("no such column: bogus")
        err.sqlite_errorcode = sqlite3.SQLITE_ERROR
        with patch.object(self.index, "_open_reader", side_effect=err), \
                patch.object(self.index, "_reset") as reset:
            self.assertEqual(self.index.search("orchard"), [])
            reset.assert_not_called()
        with patch.object(self.index, "_sync_locked", side_effect=err), \
                patch.object(self.index, "_reset") as reset:
            self.assertIn("error", self.index.sync())
            reset.assert_not_called()
        self.assertEqual(self.index.db_path.stat().st_ino, inode_before)
        self.assertEqual(self.index.stats()["src"], {"mail": 1})
        self.integrity()

    def test_corrupt_error_during_sync_triggers_recovery(self):
        self.write("mail", [row("mail", 1)])
        self.write("drive", [row("drive", 2)])
        self.index.sync()
        self.write("mail", [row("mail", 3, "replacement")])
        original, calls = self.index._values, []
        def fail_once(*args):
            calls.append(1)
            if len(calls) == 1:
                exc = sqlite3.DatabaseError("database disk image is malformed")
                exc.sqlite_errorcode = sqlite3.SQLITE_CORRUPT
                raise exc
            return original(*args)
        with patch.object(self.index, "_values", side_effect=fail_once):
            self.index.sync()
        self.assertEqual({h["id"] for h in self.index.search("orchard")}, {"mail:3", "drive:2"})
        self.integrity()

    def test_source_paths_refused_and_busy_cache_not_deleted(self):
        path = self.write("mail", [row("mail", 1)])
        with self.assertRaises(ValueError):
            LocalSearchIndex(db_path=path)
        self.index.sync()
        error = sqlite3.OperationalError("database is locked")
        error.sqlite_errorcode = sqlite3.SQLITE_BUSY
        with patch.object(self.index, "_open_reader", side_effect=error), patch.object(self.index, "_reset") as reset:
            self.assertEqual(self.index.search("orchard"), [])
            reset.assert_not_called()
        self.integrity()

    def test_threads_and_two_connections_remain_consistent(self):
        self.write("mail", [row("mail", i) for i in range(10)])
        other = LocalSearchIndex(data_dir=self.data)
        self.addCleanup(other.close)
        self.index.sync()
        failures = []
        def run(ix):
            try:
                for _ in range(8):
                    ix.sync()
                    self.assertEqual(len(ix.search("orchard")), 10)
            except Exception as exc:
                failures.append(exc)
        threads = [threading.Thread(target=run, args=(ix,)) for ix in (self.index, other, self.index)]
        for thread in threads:
            thread.start()
        for thread in threads:
            thread.join(10)
            self.assertFalse(thread.is_alive())
        self.assertEqual(failures, [])
        self.integrity()


class CompatibilityAndSpeed(Base):
    def test_flat_custom_folder_and_cold_start_skip_jsonl(self):
        self.write("mail", [row("mail", 1)])
        flat = self.data / "custom"
        flat.mkdir()
        (flat / "mail.jsonl").write_bytes((self.folder / "mail.jsonl").read_bytes())
        first = sources.Index(flat, sync=True)
        self.addCleanup(lambda: first._local and first._local.close())
        self.assertEqual(len(first.find("orchard")), 1)
        self.assertEqual(first._local.db_path, flat / "cache/search.sqlite")
        second = sources.Index(flat, sync=True)
        self.addCleanup(lambda: second._local and second._local.close())
        with patch.object(LocalSearchIndex, "_read_jsonl", side_effect=AssertionError("cold start parsed JSONL")):
            self.assertEqual(second.find("orchard"), first.find("orchard"))
            self.assertEqual(second._rows, {})
            self.assertEqual(second.rows["mail"], first.rows["mail"])
        stamp = (flat / "mail.jsonl").stat()
        self.assertEqual(second.stamps["mail"], (stamp.st_mtime_ns, stamp.st_size))

    def test_reader_never_blocks_during_50k_background_sync(self):
        # Seed initial mail store so readers have live data while a huge 50k Beeper pull syncs in the background.
        self.write("mail", [row("mail", 1, "quarterly needle budget", title="Quarterly needle", files=["q4.pdf"])])
        self.index.sync()
        self.assertEqual(len(self.index.find_links_files("needle")), 1)

        # Write 50,000 Beeper rows to trigger a multi-hundred-ms background sync.
        beeper_path = self.folder / "beeper.jsonl"
        with beeper_path.open("w") as f:
            for i in range(50_000):
                f.write(json.dumps({"id": f"beeper:{i}", "src": "beeper", "t": i,
                                    "title": "Chat room", "text": f"message {i} orchard",
                                    "who": [{"name": "Demo Person"}], "mine": False,
                                    "links": [], "files": [], "url": "", "chat": "c1"}) + "\n")

        started = threading.Event()
        orig_read = self.index._read_jsonl
        def tracked_read(path):
            started.set()
            return orig_read(path)

        with patch.object(self.index, "_read_jsonl", side_effect=tracked_read):
            t = threading.Thread(target=self.index.sync)
            t.start()
            self.assertTrue(started.wait(5), "background sync did not start")
            # Sample reader latency repeatedly while background sync is running.
            latencies = []
            while t.is_alive() and len(latencies) < 20:
                t0 = time.perf_counter()
                found = self.index.find_links_files("needle")
                latencies.append((time.perf_counter() - t0) * 1000)
                self.assertGreaterEqual(len(found), 1)
                time.sleep(0.01)
            t.join(30)
            self.assertFalse(t.is_alive())

        self.assertGreater(len(latencies), 0, "did not observe reader call during background sync")
        self.assertLess(max(latencies), 150, f"reader blocked during 50k sync: max {max(latencies):.2f} ms")
        print(f"\n50k background sync: {len(latencies)} concurrent reads, max {max(latencies):.2f} ms")

    def test_5000_documents_query_under_50ms(self):
        rows = [row("mail", i, "Orchard planning with synthetic fruit and delivery dates.",
                    title=f"Batch {i}" + (" needle" if i % 100 == 0 else ""), t=i) for i in range(5000)]
        self.write("mail", rows)
        self.index.sync()
        self.assertEqual(self.index.stats()["src"]["mail"], 5000)
        times = []
        for _ in range(5):
            start = time.perf_counter()
            self.assertEqual(len(self.index.search("needle")), 20)
            times.append((time.perf_counter() - start) * 1000)
        self.assertLess(max(times), 50, f"FTS5 search took {times} ms")
        adapter = sources.Index(self.folder, sync=True)
        self.addCleanup(lambda: adapter._local and adapter._local.close())
        start = time.perf_counter()
        adapter.find("needle")
        cold = (time.perf_counter() - start) * 1000
        start = time.perf_counter()
        self.assertEqual(len(adapter.find("needle")), 8)
        warm = (time.perf_counter() - start) * 1000
        self.assertLess(warm, 10, f"sources.Index.find took {warm:.2f} ms")
        print(f"\n5000 docs: search max {max(times):.2f} ms; find cold {cold:.2f} ms, warm {warm:.2f} ms")


if __name__ == "__main__":
    unittest.main()

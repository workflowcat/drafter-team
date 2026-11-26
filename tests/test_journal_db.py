"""The journal in SQLite, phase 1 (engine/journal_db.py, scripts/journal_compare.py, app/JournalDB.swift), on made-up
rows in temporary folders only; never the live data/.

    .venv/bin/python -B tests/test_journal_db.py

Round-trip of every row shape the writers make (dates as their exact JSON tokens, ids, every field, the line byte for
byte), idempotent backfill, the follower across a restart, a line still being written, a rewrite and a truncation,
hide and unhide, the compare script catching planted differences, the setting off reading JSONL, a corrupt database
set aside, and the Swift reader against a database this module wrote.
"""
import hashlib
import json
import os
import shutil
import sqlite3
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "engine"))
sys.path.insert(0, str(ROOT / "scripts"))
import journal_db  # noqa: E402
import journal_compare  # noqa: E402

T7 = "1763900000.1234560"      # a 7-digit token that float repr would write differently
assert repr(float(T7)) != T7

# Every shape the code writes (engine/server.py /typed; app/History.swift take, watchClipboard, keepPick, addPicture),
# as raw lines so the exact tokens are kept. Made-up text only.
TYPED = [
    '{"t": 1763900000.123456, "app": "Notes", "text": "a made-up line he sent"}',
    '{"t": 1763900001.5, "app": "Telegram", "text": "made-up reply, привіт 👋", "context": "made-up chat above"}',
    '{"t": ' + T7 + ', "app": "Mail", "text": "made-up line with a \\"quote\\" and a \\\\ slash"}',
]
TAKES = [
    '{"id":"A1","t":1763900010.1234567,"text":"made-up take","secs":2.5,"app":"Notes","loud":false,"audio":"\\/tmp\\/x\\/A1.wav"}',
    '{"id":"A2","t":1763900011.25,"text":"made-up take two","secs":3,"app":"Mail","loud":true,"audio":"","raw":"made up take two raw"}',
    '{"id":"A3","t":1763900012.5,"text":"made-up three","secs":1.2,"app":"Notes","loud":false,"audio":"","raw":"made up","outcome":"cancelled"}',
    '{"id":"A4","t":1763900013,"text":"made-up four","secs":0.4,"app":"Notes","loud":false,"audio":"","outcome":"inserted"}',
    '{"t":1763900014.75,"text":"old take without an id","secs":1,"app":"Notes","loud":false,"audio":"\\/tmp\\/old.wav"}',
]
CLIPS = [
    '{"t":1763900020.1,"app":"Safari","text":"made-up copied text"}',
    '{"t":1763900021.1234567,"app":"Shot","kind":"image","text":"Image · 10 × 20","image":[10,20],"via":"capture","clip":"abc.png","bytes":123,"shot":"s1"}',
    '{"t":1763900022.5,"app":"Safari","kind":"link","text":"https:\\/\\/example.test\\/a","title":"Made-up page"}',
    '{"t":1763900023.5,"app":"Word","text":"made-up rich","rich":true,"shape":"table","table":[3,4],"data":"d.pboard"}',
    '{"t":1763900024.5,"app":"Finder","kind":"file","files":["\\/tmp\\/a.txt","\\/tmp\\/b.txt"],"text":"\\/tmp\\/a.txt\\n\\/tmp\\/b.txt","bytes":99,"shape":"files"}',
    '{"t":1763900025.5,"app":"Code","text":"let x = 1","rich":true,"shape":"code","lang":"swift","data":"e.pboard"}',
    '{"t":1763900026.5,"app":"Notes","text":"made","from":"take:A1","picked":[[0,4]],"via":"pick","mine":true}',
    '{"t":1763900027.5,"app":"Picker","text":"#FF8800","shape":"color","color":"#FF8800"}',
    '{"t":1763900028.5,"app":"Preview","kind":"image","shape":"pdf","text":"PDF · 3 pages","image":[600,800],"clip":"p.png","data":"p.pdf","bytes":5000}',
    '{"t":1763900029.5,"app":"Finder","kind":"file","files":["\\/tmp\\/c.pdf"],"text":"\\/tmp\\/c.pdf","clip":"q.png","page":[600,800,2]}',
    '{"t":1763900030.5,"app":"Notes","text":"made-up repeat"}',
    '{"t":1763900030.5,"app":"Notes","text":"made-up repeat"}',   # the very same line twice
]
SHAPES = {"typed": TYPED, "takes": TAKES, "clipboard": CLIPS}


def write(path, lines, mode="w"):
    with open(path, mode, encoding="utf-8") as f:
        for l in lines:
            f.write(l + "\n")


def token_t(line):
    return str(json.loads(line, parse_float=journal_db._Raw, parse_int=journal_db._Raw)["t"])


class Base(unittest.TestCase):
    def setUp(self):
        self.dir = Path(tempfile.mkdtemp(prefix="journal-db-test-"))
        for store, lines in SHAPES.items():
            write(self.dir / f"{store}.jsonl", lines)
        self.jdb = journal_db.JournalDB(self.dir)

    def tearDown(self):
        self.jdb.close()
        shutil.rmtree(self.dir, ignore_errors=True)

    def db(self):
        return sqlite3.connect(self.dir / "journal.sqlite")

    def live(self, store):
        with self.db() as c:
            return c.execute("SELECT line, t, t_raw, id, sha, seq, hidden FROM rows WHERE store=? AND removed_at IS NULL "
                             "ORDER BY seq", (store,)).fetchall()

    def compare(self):
        return journal_compare.main(["--data", str(self.dir), "--tries", "1"])


class RoundTrip(Base):
    def test_every_shape_round_trips(self):
        self.jdb.sync()
        for store, lines in SHAPES.items():
            rows = self.live(store)
            self.assertEqual(len(rows), len(lines), store)
            for i, (src, (line, t, t_raw, rid, h, seq, _)) in enumerate(zip(lines, rows)):
                self.assertEqual(bytes(line), src.encode("utf-8"), f"{store} line {i} byte for byte")
                self.assertEqual(json.loads(bytes(line)), json.loads(src), f"{store} every field")
                self.assertEqual(t_raw, token_t(src), f"{store} the date token as written")
                self.assertEqual(t, float(token_t(src)), f"{store} the date as a float")
                self.assertEqual(rid, json.loads(src).get("id"), f"{store} id")
                self.assertEqual(h, hashlib.sha256(src.encode()).hexdigest())
                self.assertEqual(seq, i)
        with self.db() as c:
            self.assertEqual(c.execute("SELECT val FROM meta WHERE key='schema_version'").fetchone()[0], journal_db.SCHEMA_VERSION)
            self.assertEqual(c.execute("PRAGMA journal_mode").fetchone()[0], "wal")
            dups = c.execute("SELECT dup FROM rows WHERE store='clipboard' AND text='made-up repeat' ORDER BY dup").fetchall()
            self.assertEqual(dups, [(0,), (1,)])
            # the 7-digit token survives where a float would not
            self.assertEqual(c.execute("SELECT t_raw FROM rows WHERE store='typed' AND seq=2").fetchone()[0], T7)

    def test_newest_matches_jsonl(self):
        self.jdb.sync()
        for store, lines in SHAPES.items():
            self.assertEqual(self.jdb.newest(store, 3), [json.loads(l) for l in lines[-3:]])

    def test_bad_line_kept_verbatim(self):
        write(self.dir / "typed.jsonl", ["not json at all", '["a list"]'], "a")
        self.jdb.sync()
        rows = self.live("typed")
        self.assertEqual(bytes(rows[-2][0]), b"not json at all")
        self.assertEqual(len(rows), len(TYPED) + 2)
        self.assertEqual(self.compare(), 0)


class Backfill(Base):
    def test_idempotent_and_read_only(self):
        before = {s: (self.dir / f"{s}.jsonl").read_bytes() for s in SHAPES}
        first = self.jdb.sync()
        self.assertEqual({s: first[s]["added"] for s in SHAPES}, {s: len(v) for s, v in SHAPES.items()})
        again = self.jdb.sync()
        self.assertEqual(sum(again[s]["added"] + again[s]["removed"] for s in SHAPES), 0)
        self.jdb.close()
        # a rerun from scratch state (sync marks dropped) matches every row again and adds nothing
        with self.db() as c:
            c.execute("DELETE FROM sync")
        rerun = journal_db.JournalDB(self.dir).sync()
        self.assertEqual(sum(rerun[s]["added"] + rerun[s]["removed"] for s in SHAPES), 0)
        with self.db() as c:
            self.assertEqual(c.execute("SELECT COUNT(*) FROM rows").fetchone()[0], sum(len(v) for v in SHAPES.values()))
        self.assertEqual(before, {s: (self.dir / f"{s}.jsonl").read_bytes() for s in SHAPES}, "JSONL never written")
        self.assertEqual(self.compare(), 0)


class Follow(Base):
    def test_restart_partial_rewrite_truncate(self):
        self.jdb.sync()
        self.jdb.close()
        # restart: a new instance continues from the stored offset
        write(self.dir / "takes.jsonl", ['{"id":"N1","t":1763900100.5,"text":"made-up new"}'], "a")
        with open(self.dir / "takes.jsonl", "a") as f:
            f.write('{"id":"N2","t":1763900101.5,"te')            # still being written
        j2 = journal_db.JournalDB(self.dir)
        out = j2.sync()
        self.assertEqual((out["takes"]["added"], out["takes"]["full"]), (1, False))
        self.assertFalse(j2.current("takes"), "a line still being written: the database is behind")
        self.assertIsNone(j2.newest("takes", 5))
        with open(self.dir / "takes.jsonl", "a") as f:
            f.write('xt":"made-up rest"}\n')
        out = j2.sync()
        self.assertEqual(out["takes"]["added"], 1)
        self.assertEqual([r[3] for r in self.live("takes")][-2:], ["N1", "N2"])
        self.assertEqual(self.compare(), 0)
        # a rewrite through a temporary file (clipboard trim, Quick panel forget): rows gone are marked, never deleted
        keep = CLIPS[2:6]
        tmp = self.dir / ".clipboard.jsonl.tmp"
        write(tmp, keep)
        os.replace(tmp, self.dir / "clipboard.jsonl")
        out = j2.sync()
        self.assertEqual((out["clipboard"]["added"], out["clipboard"]["removed"], out["clipboard"]["full"]), (0, len(CLIPS) - 4, True))
        self.assertEqual([bytes(r[0]).decode() for r in self.live("clipboard")], keep)
        with self.db() as c:
            self.assertEqual(c.execute("SELECT COUNT(*) FROM rows WHERE store='clipboard'").fetchone()[0], len(CLIPS))
            self.assertGreater(c.execute("SELECT COUNT(*) FROM events WHERE what='resync'").fetchone()[0], 0)
        self.assertEqual(self.compare(), 0)
        # truncated in place, then a new line
        with open(self.dir / "typed.jsonl", "r+") as f:
            f.truncate(0)
        write(self.dir / "typed.jsonl", ['{"t": 1763900200.5, "app": "Notes", "text": "made-up after truncation"}'], "a")
        out = j2.sync()
        self.assertEqual((out["typed"]["added"], out["typed"]["removed"]), (1, len(TYPED)))
        self.assertEqual(len(self.live("typed")), 1)
        # rewritten in place with the same size: bytes before the mark differ, a full resync
        p = self.dir / "takes.jsonl"
        b = p.read_bytes().replace(b"made-up take two", b"made-up TAKE two")
        with open(p, "r+b") as f:
            f.write(b)
        out = j2.sync()
        self.assertTrue(out["takes"]["full"])
        self.assertEqual((out["takes"]["added"], out["takes"]["removed"]), (1, 1))
        self.assertEqual(self.compare(), 0)
        # the file deleted: its rows stay, marked
        (self.dir / "typed.jsonl").unlink()
        j2.sync()
        self.assertEqual(len(self.live("typed")), 0)
        j2.close()

    def test_follower_thread_across_restart(self):
        f = journal_db.Follower(self.dir, every=0.05).start()
        try:
            self.wait_for(lambda: len(self.live("typed")) == len(TYPED))
            write(self.dir / "typed.jsonl", ['{"t": 1763900300.5, "app": "Notes", "text": "made-up while running"}'], "a")
            f.poke()
            self.wait_for(lambda: len(self.live("typed")) == len(TYPED) + 1)
        finally:
            f.stop()
        write(self.dir / "typed.jsonl", ['{"t": 1763900301.5, "app": "Notes", "text": "made-up while stopped"}'], "a")
        f2 = journal_db.Follower(self.dir, every=0.05).start()
        try:
            self.wait_for(lambda: len(self.live("typed")) == len(TYPED) + 2)
        finally:
            f2.stop()
        with self.db() as c:
            self.assertEqual(c.execute("SELECT COUNT(*) FROM rows WHERE store='typed'").fetchone()[0], len(TYPED) + 2)
        self.assertEqual(self.compare(), 0)

    def wait_for(self, cond, secs=5):
        end = time.time() + secs
        while time.time() < end:
            try:
                if cond():
                    return
            except sqlite3.OperationalError:
                pass
            time.sleep(0.02)
        self.fail("timed out")


class Hide(Base):
    def test_hide_and_unhide(self):
        self.jdb.sync()
        self.assertEqual(len(self.jdb.search("sent", stores=("typed",))), 1)
        # DraftHide (scripts/hide_bad_drafts.py) hides a sent line; the journal's archive a take, a clip and a sent line
        (self.dir / "drafts-hidden.json").write_text(json.dumps({"hidden": [{"kind": "sent", "t": 1763900000.123456}]}))
        (self.dir / "journal.json").write_text(json.dumps({"changes": {}, "items": [], "hidden": [
            "v:A2", "v:take-1763900014.75-/tmp/old.wav", "c:1763900020100:19", "t:sent1763900001.5", "d:call-1"]}))
        out = self.jdb.sync()
        self.assertTrue(out["hidden_changed"])
        self.assertEqual(self.jdb.search("sent", stores=("typed",)), [])
        self.assertEqual(self.jdb.search("привіт", stores=("typed",)), [])
        self.assertEqual(self.jdb.search("two", stores=("takes",)), [])
        self.assertEqual(self.jdb.search("without", stores=("takes",)), [])
        self.assertEqual(self.jdb.search("copied", stores=("clipboard",)), [])
        self.assertEqual([r["id"] for r in self.jdb.newest("takes", 10) if "id" in r], ["A1", "A3", "A4"])
        self.assertEqual(len(self.jdb.newest("takes", 10, visible=False)), len(TAKES))
        self.assertEqual(journal_db.takes_rows(self.dir, 10), self.jdb.newest("takes", 10))
        with self.db() as c:
            self.assertEqual(c.execute("SELECT COUNT(*) FROM hidden WHERE removed_at IS NULL").fetchone()[0], 6)
            self.assertEqual(c.execute("SELECT SUM(n) FROM events WHERE what='hidden'").fetchone()[0], 6)
        # unhide: back in search; the unhide is recorded
        (self.dir / "journal.json").write_text(json.dumps({"hidden": []}))
        self.jdb.sync()
        self.assertEqual(len(self.jdb.search("two", stores=("takes",))), 1)
        with self.db() as c:
            self.assertEqual(c.execute("SELECT SUM(n) FROM events WHERE what='unhidden'").fetchone()[0], 5)
        # a row removed from the file (Quick panel forget) is gone from search too
        write(self.dir / "takes.jsonl", [l for l in TAKES if '"A1"' not in l])
        self.jdb.sync()
        self.assertNotIn("A1", [r.get("id") for _, r in self.jdb.search("made-up take", stores=("takes",))])
        self.assertTrue(self.jdb.search("made-up take", stores=("takes",)))
        self.assertEqual(self.compare(), 0)


class Compare(Base):
    def test_planted_differences(self):
        self.jdb.sync()
        self.jdb.close()
        self.assertEqual(self.compare(), 0)
        p = self.dir / "takes.jsonl"
        good = p.read_bytes()
        # a changed line, same length, the database not told
        p.write_bytes(good.replace(b"made-up four", b"made-up FOUR"))
        self.assertEqual(self.compare(), 1)
        p.write_bytes(good)
        self.assertEqual(self.compare(), 0)
        # an appended line the database does not have
        write(p, ['{"id":"X","t":1,"text":"made-up extra"}'], "a")
        self.assertEqual(self.compare(), 1)
        p.write_bytes(good)
        # a date changed in the database only
        with self.db() as c:
            c.execute("UPDATE rows SET t_raw='1763900010.123457' WHERE store='takes' AND id='A1'")
        self.assertEqual(self.compare(), 1)
        with self.db() as c:
            c.execute("UPDATE rows SET t_raw='1763900010.1234567' WHERE store='takes' AND id='A1'")
            c.execute("UPDATE rows SET id='Z' WHERE store='takes' AND id='A2'")
        self.assertEqual(self.compare(), 1)
        with self.db() as c:
            c.execute("UPDATE rows SET id='A2' WHERE store='takes' AND id='Z'")
            c.execute("UPDATE rows SET line=CAST('{}' AS BLOB) WHERE store='clipboard' AND seq=0")
        self.assertEqual(self.compare(), 1, "stored bytes no longer match their hash")

    def test_prints_numbers_only(self):
        self.jdb.sync()
        r = subprocess.run([sys.executable, "-B", str(ROOT / "scripts/journal_compare.py"), "--data", str(self.dir), "--tries", "1"],
                           capture_output=True, text=True)
        self.assertEqual(r.returncode, 0)
        self.assertNotIn("made-up", r.stdout)
        self.assertIn("differences 0", r.stdout)


class Setting(Base):
    def test_off_reads_jsonl(self):
        self.jdb.sync()
        (self.dir / "journal.json").write_text(json.dumps({"hidden": ["v:A2"]}))
        self.jdb.sync()
        self.assertTrue(journal_db.enabled(self.dir), "on by default")
        self.assertNotIn("A2", [r.get("id") for r in journal_db.takes_rows(self.dir, 10)])
        (self.dir / "settings.json").write_text(json.dumps({"journalDB": False}))
        self.assertFalse(journal_db.enabled(self.dir))
        self.assertEqual(journal_db.takes_rows(self.dir, 10), [json.loads(l) for l in TAKES], "off: takes.jsonl as before")
        # on, but the database behind the file: JSONL too
        (self.dir / "settings.json").write_text(json.dumps({"journalDB": True}))
        write(self.dir / "takes.jsonl", ['{"id":"L","t":2,"text":"made-up late"}'], "a")
        self.assertEqual(journal_db.takes_rows(self.dir, 10)[-1]["id"], "L")


class Corrupt(Base):
    def test_corrupt_set_aside_and_rebuilt(self):
        (self.dir / "journal.sqlite").write_bytes(b"this is not a database at all" * 100)
        out = self.jdb.sync()
        self.assertEqual(out["typed"]["added"], len(TYPED))
        self.assertTrue(list(self.dir.glob("journal.sqlite.aside-*")), "the bad file is kept aside")
        self.assertEqual(self.compare(), 0)

    def test_other_schema_set_aside(self):
        self.jdb.sync(); self.jdb.close()
        with self.db() as c:
            c.execute("UPDATE meta SET val='99' WHERE key='schema_version'")
        self.assertIsNone(journal_db.JournalDB(self.dir).newest("typed", 3), "a reader never reads another schema")
        out = journal_db.JournalDB(self.dir).sync()
        self.assertEqual(out["typed"]["added"], len(TYPED))
        self.assertTrue(list(self.dir.glob("journal.sqlite.aside-*")))


DRIVER = r'''
import Foundation
@main struct D { static func main() {
    let a = CommandLine.arguments, dir = URL(fileURLWithPath: a[1])
    let r = JournalDBRead(dir.appendingPathComponent("journal.sqlite"))
    var out: [String: Any] = [:]
    for s in ["typed", "takes", "clipboard"] {
        let file = dir.appendingPathComponent(s + ".jsonl")
        let db = r.newest(s, file: file, n: 100)
        let f = JSONLFollow(file, keep: 100); f.refresh()
        out[s] = ["db": db.map { NSArray(array: $0).isEqual(to: f.newest(100)) } ?? "nil", "n": db?.count ?? -1]
        let off = JournalDBRules.pick(on: false, db: { db }, jsonl: { f.newest(100) })
        out[s + "-off"] = off.fromDB
    }
    print(String(data: try! JSONSerialization.data(withJSONObject: out, options: [.sortedKeys]), encoding: .utf8)!)
}}
'''


class SafeFts(unittest.TestCase):
    """safe_fts_query: literal Unicode prefixes; FTS operators and punctuation never reach MATCH as syntax."""
    def test_multilingual_literals_and_fts_syntax(self):
        q = journal_db.safe_fts_query
        for query in ("", "!!!", '"', "_-(){}:+*", "\x00", "🪴"):
            self.assertEqual(q(query), "")
        self.assertEqual(q('OR "NOT'), '"OR"* OR "NOT"*')
        self.assertEqual(q("Київ café"), '"Київ"* OR "café"*')
        db = sqlite3.connect(":memory:")
        db.execute("CREATE VIRTUAL TABLE docs_fts USING fts5(text)")
        db.execute("INSERT INTO docs_fts(text) VALUES ('English orchard Український проєкт Київ')")
        self.assertEqual(len(db.execute("SELECT rowid FROM docs_fts WHERE docs_fts MATCH ?", (q("україн"),)).fetchall()), 1)
        for query in ('"* OR title:(test) NOT -foo ^bar', "a " * 10000, "a\x00b", "क़", "\u0345"):
            match = q(query)
            if match:
                db.execute("SELECT rowid FROM docs_fts WHERE docs_fts MATCH ?", (match,)).fetchall()


class SwiftReader(Base):
    def test_swift_reads_what_python_wrote(self):
        if not shutil.which("swiftc"):
            self.skipTest("no swiftc")
        self.jdb.sync()
        (self.dir / "journal.json").write_text(json.dumps({"hidden": ["v:A2"]}))   # the window applies its own archive
        self.jdb.sync()
        self.jdb.close()
        build = Path(tempfile.mkdtemp(prefix="journal-db-swift-"))
        try:
            (build / "driver.swift").write_text(DRIVER)
            exe = build / "driver"
            files = [ROOT / "app" / n for n in ("JournalDB.swift", "QuickRead.swift", "DraftCaptureRules.swift", "Entry.swift", "PictureLookRules.swift",
                                                "ClipRules.swift", "QuickRules.swift")]
            subprocess.run(["swiftc", "-parse-as-library", *map(str, files), str(build / "driver.swift"), "-o", str(exe)],
                           check=True, capture_output=True)
            out = json.loads(subprocess.run([str(exe), str(self.dir)], check=True, capture_output=True, text=True).stdout)
            for s in SHAPES:
                self.assertEqual(out[s], {"db": True, "n": len(SHAPES[s])}, s)
                self.assertFalse(out[s + "-off"])
            write(self.dir / "typed.jsonl", ['{"t": 5, "app": "x", "text": "made-up not yet copied"}'], "a")
            out = json.loads(subprocess.run([str(exe), str(self.dir)], check=True, capture_output=True, text=True).stdout)
            self.assertEqual(out["typed"]["db"], "nil", "behind the file: the window reads JSONL")
        finally:
            shutil.rmtree(build, ignore_errors=True)


if __name__ == "__main__":
    unittest.main(verbosity=1)

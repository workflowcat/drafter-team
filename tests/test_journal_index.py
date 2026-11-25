"""Ask your day (engine/journal_index.py) over a made-up index: best match first, the day and tag filters, a new
index picked up without a restart, and "not ready" without an index or an encoder. A fake encoder stands in for
multilingual-e5-small (the real one is checked against torch on the server: bench/jobs.py smoke check).

    .venv/bin/python -B tests/test_journal_index.py
"""
import json, os, sys, tempfile, time, unittest
from datetime import datetime
from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "engine"))
import journal_index as J

WORDS = ["booklet", "invoice", "release", "client"]


class FakeEncoder:
    def encode(self, texts):
        out = []
        for t in texts:
            v = np.array([float(w in t) for w in WORDS], np.float32) + 0.01
            out.append(v / np.linalg.norm(v))
        return np.stack(out)


def write_index(folder, rows):
    folder.mkdir(parents=True, exist_ok=True)
    v = FakeEncoder().encode([r["text"] for r in rows]).astype(np.float16)
    np.save(folder / "vectors.npy", v)
    (folder / "items.json").write_text(json.dumps([{k: r[k] for k in ("id", "at", "kind", "tags")} for r in rows]))
    (folder / "tags.json").write_text(json.dumps([{"tag": "print booklet", "items": 2}]))
    (folder / "meta.json").write_text(json.dumps({"items": len(rows), "t": time.time()}))


class IndexTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(); self.dir = Path(self.tmp.name) / "journal-index"
        day1, day2 = datetime(2026, 11, 16, 12).timestamp(), datetime(2026, 11, 17, 12).timestamp()
        self.rows = [{"id": "v:1", "at": day1, "kind": "said", "tags": ["print booklet"], "text": "made-up booklet proofs"},
                     {"id": "v:2", "at": day2, "kind": "said", "tags": ["print booklet"], "text": "the booklet goes to print"},
                     {"id": "t:3", "at": day2, "kind": "typed", "tags": [], "text": "the invoice is late"}]
        write_index(self.dir, self.rows)
        self.ix = J.Index(self.dir); self.ix._enc = FakeEncoder(); self.ix._used = time.time()

    def tearDown(self): self.tmp.cleanup()

    def test_best_first(self):
        r = self.ix.ask("invoice?")
        self.assertTrue(r["ready"]); self.assertEqual(r["hits"][0]["id"], "t:3")

    def test_day_and_tag(self):
        self.assertEqual([h["id"] for h in self.ix.ask("booklet", day="2026-11-17")["hits"]][:1], ["v:2"])
        self.assertNotIn("t:3", [h["id"] for h in self.ix.ask("booklet", tag="print booklet")["hits"]])
        self.assertEqual(self.ix.tag_list()[0]["tag"], "print booklet")

    def test_new_index_without_restart(self):
        self.ix.ask("x")
        write_index(self.dir, self.rows[:1])
        os.utime(self.dir / "meta.json", (time.time() + 5, time.time() + 5))
        self.assertEqual(len(self.ix.ask("booklet")["hits"]), 1)

    def test_not_ready(self):
        self.assertFalse(J.Index(Path(self.tmp.name) / "none").ask("x")["ready"])
        ix = J.Index(self.dir, encoder_folder=None)
        J.embed_np.local_folder = lambda *a, **k: None
        r = ix.ask("x")
        self.assertFalse(r["ready"]); self.assertIn("encoder", r["why"])


if __name__ == "__main__":
    unittest.main(verbosity=1)

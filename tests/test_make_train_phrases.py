"""bench/make_train.py phrases mode (the live layer's pipeline): held set and date cut. Made-up lines only.
    .venv/bin/python -B tests/test_make_train_phrases.py"""
import json, sys, tempfile, unittest
from pathlib import Path
from unittest import mock
ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "bench"))
import make_train


class Phrases(unittest.TestCase):
    def test_held_set_and_cut(self):
        with tempfile.TemporaryDirectory() as d:
            d = Path(d)
            ph = [{"src": "claude", "t": 10 + i, "text": f"made up prompt number {i} about the garden"} for i in range(100)]
            ph.append({"src": "claude", "t": 5, "text": "the held line about a blue kettle and tea"})
            ph.append({"src": "voice", "t": 0, "text": "an undated voice line about the river"})
            (d / "p.jsonl").write_text("".join(json.dumps(r) + "\n" for r in ph))
            (d / "typed.jsonl").write_text(json.dumps({"t": 500, "app": "Claude", "text": "a late typed line about the moon"}) + "\n")
            (d / "held.json").write_text(json.dumps([{"text": "the held line about a blue kettle and tea"}]))
            real = make_train.Held
            with mock.patch.object(make_train, "Held", lambda lines=None: real(lines if lines is not None else [])):
                train, valid = make_train.from_phrases(d / "p.jsonl", d / "typed.jsonl", d / "out", d / "held.json", before=100)
            texts = [r["text"] for r in train + valid]
            self.assertFalse(any("blue kettle" in t for t in texts))          # held set left out
            self.assertFalse(any("the moon" in t for t in texts))             # dated after the cut
            self.assertTrue(any("the river" in t for t in texts))             # undated rows stay
            self.assertEqual(len(texts), 91)                                  # t 10..99 + the voice line
            self.assertTrue((d / "out/train.jsonl").exists())


if __name__ == "__main__":
    unittest.main()

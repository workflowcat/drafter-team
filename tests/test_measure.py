"""Round four (2026-11-14): the one replay every typing bench scores through (bench/measure.py). Made-up lines only.

    .venv/bin/python -B tests/test_measure.py
"""
import json, sys, tempfile, unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "bench")); sys.path.insert(0, str(ROOT / "engine"))
import measure as M


def always(text_by_pos, ms=20):
    """A policy that offers the rest of the line from these positions."""
    def pol(row, before, src):
        return (text_by_pos.get(len(before), "") if src == "claude" else ""), ms
    return pol


class FirstWord(unittest.TestCase):
    def test_word_boundary(self):
        self.assertTrue(M.first_right("plan ", "plan for today"))
        self.assertTrue(M.first_right("plan", "plan, then"))
        self.assertFalse(M.first_right("plan", "planning it"))
        self.assertFalse(M.first_right("plan ", "planning it"))
        self.assertTrue(M.first_right("ning it", "ning it"))      # the rest of a half-typed word
        self.assertFalse(M.first_right("the ", "then"))


class Replay(unittest.TestCase):
    items = [{"src": "claude", "text": "please check the build"}, {"src": "beeper", "text": "привіт як справи"}]

    def rows(self):
        return {(i, p): {"toks": []} for i, it in enumerate(self.items) for p in range(1, len(it["text"]))}

    def test_counts_first_display_tab_and_type_through(self):
        pol = always({7: "check the ", 17: "bild"})
        res, per = M.replay(self.items, self.rows(), pol)
        c = res["claude"]
        self.assertEqual(c["shown"], 2)            # one right ghost taken word by word, then one wrong one
        self.assertEqual(c["right"], 50.0)
        self.assertEqual(c["saved"], round(100 * ((6 - 1) + (4 - 1)) / 22, 1))
        self.assertEqual(c["taken"], 50.0)
        self.assertIn("claude/en", res); self.assertIn("beeper/uk", res)
        self.assertEqual(res["beeper"]["shown"], 0)
        self.assertGreater(c["keys"], 10)
        self.assertEqual(c["wrong_1k"], round(1000 / 22, 1))

    def test_a_late_answer_is_not_shown_at_that_key(self):
        res, _ = M.replay(self.items, self.rows(), always({7: "check the "}, ms=200), gap_ms=150)
        self.assertEqual(res["claude"]["shown"], 0); self.assertEqual(res["claude"]["late"], 1)
        res, _ = M.replay(self.items, self.rows(), always({7: "check the "}, ms=100), gap_ms=150)
        self.assertEqual(res["claude"]["shown"], 1)

    def test_intervals_resample_whole_lines(self):
        items = [{"src": "claude", "text": f"line number {i} here"} for i in range(30)]
        rows = {(i, p): {"toks": []} for i, it in enumerate(items) for p in range(1, len(it["text"]))}
        pol = lambda row, before, src: ("number " if before == "line " else "", 10)
        res, per = M.replay(items, rows, pol)
        lo, hi = M.interval(per, "claude", "right")
        self.assertEqual((lo, hi), (100.0, 100.0))
        self.assertEqual(M.paired(per, per, "claude", "saved"), (0.0, 0.0))


class Split(unittest.TestCase):
    def test_versions_of_one_message_stay_on_one_side_and_dates_order_them(self):
        long = "this is a long message that he typed and then sent a second time"
        items = [{"text": "newest line he sent"}, {"text": long}, {"text": long + " with more"}, {"text": "oldest line"}]
        with tempfile.TemporaryDirectory() as d:
            p = Path(d) / "typed.jsonl"
            p.write_text("".join(json.dumps({"t": t, "text": x}) + "\n" for t, x in
                                 ((300, "newest line he sent"), (200, long), (250, long + " with more"), (100, "oldest line"))))
            cal, test = M.split(items, 0.7, p)
        self.assertEqual(sorted(cal), [1, 2, 3])   # groups by date: oldest, the long pair (200) | newest
        self.assertEqual(test, [0])


if __name__ == "__main__":
    unittest.main()

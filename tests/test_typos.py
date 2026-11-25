"""engine/typos.py on made-up lines and log lines, in a temp folder."""
import json, random, sys, tempfile, unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "engine"))
import typos


class Typos(unittest.TestCase):
    def test_bigrams_from_corpus_skip_tests_numbers_and_rare(self):
        with tempfile.TemporaryDirectory() as tmp:
            d = Path(tmp)
            rows = [{"src": "typed", "text": "fresh zorba again. fresh zorba"}, {"src": "typed", "text": "fresh zorba ⟦drafter-test⟧"},
                    {"src": "other", "text": "fresh zorba"}, {"src": "beeper", "text": "свіжа квасоля, свіжа квасоля v2 v2"}]
            (d / "corpus.jsonl").write_text("\n".join(json.dumps(r, ensure_ascii=False) for r in rows))
            pairs = typos.bigrams(typos.lines_of(d))
            self.assertEqual(pairs[("fresh", "zorba")], 2)
            self.assertEqual(pairs[("свіжа", "квасоля")], 2)
            self.assertNotIn(("v2", "v2"), pairs)
            self.assertNotIn(("zorba", "again"), pairs)
            typos.write_bigrams(pairs, d / "typo-bigrams.tsv")
            self.assertIn("fresh\tzorba\t2\n", (d / "typo-bigrams.tsv").read_text())

    def test_labels_from_log(self):
        f = " f=1.00,3.00,2.00,0.00,6.00,0.00,1.00,0.00,1.00;p=0.80"
        log = ["t fix offer space typo taken 400ms" + f, "t fix offer space typo typed 90ms" + f, "t fix offer space typo changed 9ms" + f,
               "t autocorrect typo 6 -> 6 chars" + f, "t autocorrect taken back (typo) 800ms",
               "t autocorrect typo 6 -> 6 chars" + f, "t autocorrect kept, backspace 90ms is his own (typo)",
               "t autocorrect typo 6 -> 7 chars" + f, "t fix offer space typo expired 6000ms" + f, "t autocorrect typo 6 -> 7 chars"]
        self.assertEqual([y for _, y in typos.labels(log)], [1, 0, 0, 0, 1])  # taken, typed, taken back, expired, kept

    def test_fit_learns_made_up_labels_and_picks_a_threshold(self):
        rnd = random.Random(7)
        rows = []
        for _ in range(400):
            cost = rnd.uniform(0, 3); count = rnd.uniform(0, 5)
            y = 1 if rnd.random() < 1 / (1 + 2.718 ** -(2 - 2 * cost + 0.5 * count)) else 0
            rows.append(([cost, count, 1, 0, 6, 0, 1, 0, 1], y))
        g = typos.gate(rows)
        self.assertLess(g["weights"][0], -1)
        self.assertGreater(g["weights"][1], 0.1)
        shown = [y for f, y in rows if typos.prob(g["bias"], g["weights"], f) >= g["offerAt"]]
        self.assertGreaterEqual(sum(shown) / len(shown), 0.8)
        self.assertEqual(len(g["trade"]), 5)
        self.assertIsNone(typos.gate(rows[:39]))

    def test_main_writes_only_into_the_given_folder(self):
        with tempfile.TemporaryDirectory() as tmp:
            d = Path(tmp)
            (d / "corpus.jsonl").write_text(json.dumps({"src": "typed", "text": "fresh zorba. fresh zorba"}))
            sys.argv = ["typos.py", "--data", tmp]
            typos.main()
            self.assertTrue((d / "typo-bigrams.tsv").exists())
            self.assertFalse((d / "typo-gate.json").exists())


if __name__ == "__main__":
    unittest.main()

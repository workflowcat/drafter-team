"""Offline synonyms (engine/synonyms.py) on tiny made-up thesaurus files and made-up word counts in a temp folder.

    .venv/bin/python -B tests/test_synonyms.py
"""
import json, sys, tempfile, unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "engine"))
import synonyms as S

UK = """UTF-8
швидкий|1
|скорий|(рухливий) прудкий|(заст.) борзий
говорити|1
|казати|(з ким) розмовляти
машина|1
|автомобіль|авто
абетка|1
|(див.) азбука
азбука|1
|алфавіт|абетка
"""
EN = """UTF-8
fast|2
(adj)|quick|speedy (similar term)|slow (antonym)
(adv)|rapidly
car|1
(noun)|auto|automobile|vehicle (generic term)
look up|1
(verb)|consult|refer
"""


class Synonyms(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        t = Path(self.tmp.name)
        (t / "th").mkdir(); (t / "data").mkdir()
        (t / "th" / "th_uk_UA.dat").write_text(UK); (t / "th" / "th_en_US_v2.dat").write_text(EN)
        (t / "data" / "mywords.txt").write_text("розмовляю\nautos\n")
        (t / "data" / "myword-counts.json").write_text(json.dumps({"прудкий": 40, "speedy": 9}))
        S.THES, S.DATA = t / "th", t / "data"
        S._index.clear(); S._vocab["mtime"] = None

    def tearDown(self): self.tmp.cleanup()

    def texts(self, sel, **kw): return [i["text"] for i in S.handle(dict(text=sel, **kw))["items"]]

    def test_base_form_his_word_first_old_last(self):
        self.assertEqual(self.texts("швидкий"), ["прудкий", "скорий", "борзий"])

    def test_adjective_takes_the_selected_ending(self):
        r = S.handle({"text": "швидкого"})
        self.assertEqual(r["base"], "швидкий")
        self.assertEqual([i["text"] for i in r["items"]], ["прудкого", "скорого", "борзого"])
        self.assertTrue(all(i["form"] == "guessed" for i in r["items"]))

    def test_verb_form_only_when_he_wrote_it(self):
        r = S.handle({"text": "говорю"})
        self.assertEqual([(i["text"], i["form"]) for i in r["items"]], [("розмовляю", "matched"), ("казати", "base")])
        self.assertTrue(r["base_forms"])

    def test_noun_of_another_class_stays_base(self):
        self.assertEqual([(i["text"], i["form"]) for i in S.handle({"text": "машину"})["items"]],
                         [("автомобіль", "base"), ("авто", "base")])

    def test_see_reference_is_followed_once(self):
        self.assertEqual(self.texts("абетка"), ["азбука", "алфавіт"])

    def test_english_case_punctuation_space_kept_antonym_dropped(self):
        out = self.texts(" Fast, ")
        self.assertEqual(out[0], " Speedy, ")
        self.assertIn(" Quick, ", out)
        self.assertFalse(any("Slow" in o for o in out))

    def test_english_plural(self):
        self.assertEqual(self.texts("cars")[:2], ["autos", "automobiles"])

    def test_phrase(self):
        self.assertEqual(self.texts("look up"), ["consult", "refer"])

    def test_too_long_numbers_unknown_and_missing_file(self):
        for sel in ("це надто довга фраза тут", "15:00", "xyzzy", "", "a" * 50):
            self.assertEqual(S.handle({"text": sel})["items"], [], sel)
        (S.THES / "th_uk_UA.dat").unlink(); S._index.clear()
        self.assertEqual(S.handle({"text": "швидкий"})["items"], [])
        self.assertTrue(self.texts("fast"))

    def test_at_most_six_and_rerank(self):
        many = "UTF-8\nbig|1\n(adj)|" + "|".join(f"w{c}" for c in "abcdefghij") + "\n"
        (S.THES / "th_en_US_v2.dat").write_text(many); S._index.clear()
        self.assertEqual(len(self.texts("big")), 6)
        r = S.handle({"text": "big", "before": "a"}, score=lambda b, c, a: 10.0 if c == "wh" else 0.0)
        self.assertEqual(r["items"][0]["text"], "wh")
        self.assertIn("rerank_ms", r)


class RealFiles(unittest.TestCase):
    """The downloaded files, when present: shape only."""
    def test_real(self):
        th = Path(__file__).resolve().parents[1] / "models" / "thesaurus"
        if not (th / "th_uk_UA.dat").exists(): self.skipTest("no thesaurus downloaded")
        S.THES, S.DATA = th, Path(tempfile.mkdtemp()); S._index.clear(); S._vocab["mtime"] = None
        r = S.handle({"text": "гарного"})
        self.assertEqual(r["base"], "гарний")
        self.assertTrue(all(i["text"].endswith("ого") for i in r["items"]))
        self.assertLess(r["ms"], 100)


if __name__ == "__main__":
    unittest.main()

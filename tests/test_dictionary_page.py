"""The Dictionary page's writes (engine/dictionary.py edit and loose): a spelling fix, heard forms, a removal undone,
loose pairs. Temporary folders only, made-up words only.

    .venv/bin/python -B tests/test_dictionary_page.py
"""
import json, sys, tempfile, unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "engine"))
import dictionary


class Page(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(); self.file = Path(self.tmp.name) / "words.json"
        self.file.write_text(json.dumps({"words": [
            {"text": "Brumblex", "lang": "en", "kind": "term", "source": "menu", "heard": ["brum blacks"]},
            {"text": "Квіточка", "lang": "uk", "kind": "name", "source": "aleph"}],
            "loose_heard": {"zorvo": "Zorvox"}}))
        self.d = dictionary.load(self.file)

    def tearDown(self): self.tmp.cleanup()

    def saved(self):
        return json.loads(Path(self.file).read_text()) if dictionary.save(self.d, self.file) else None

    def word(self, t): return next((w for w in self.d["words"] if w["text"] == t), None)

    def test_spelling_and_heard(self):
        w = dictionary.edit("brumblex", "Brumblux", ["Brum Blocks ", "brum blocks", "brumblux", ""], d=self.d)
        self.assertEqual(w["text"], "Brumblux")
        self.assertEqual(w["heard"], ["brum blocks"])              # lower case, once, never the word itself
        self.assertIsNone(self.word("Brumblex"))
        out = self.saved()
        self.assertEqual(out["heard"]["brum blocks"], "Brumblux")
        self.assertNotIn("brum blacks", out["heard"])

    def test_no_heard_drops_the_key(self):
        w = dictionary.edit("Brumblex", "Brumblex", [], d=self.d)
        self.assertNotIn("heard", w)

    def test_two_words_never_one(self):
        self.assertIsNone(dictionary.edit("Brumblex", "квіточка", [], d=self.d))
        self.assertIsNotNone(self.word("Brumblex"))

    def test_undo_of_a_removal_adds_it_back(self):
        self.d["words"] = [w for w in self.d["words"] if w["text"] != "Квіточка"]
        w = dictionary.edit("Квіточка", "Квіточка", ["квиточка"], d=self.d)
        self.assertEqual((w["lang"], w["heard"]), ("uk", ["квиточка"]))

    def test_a_loose_pair_moves_onto_its_word(self):
        dictionary.edit("", "Zorvox", ["zorvo"], d=self.d)
        self.assertNotIn("zorvo", self.d["loose_heard"])
        self.assertEqual(self.saved()["heard"]["zorvo"], "Zorvox")

    def test_loose_pairs(self):
        dictionary.loose("zorvo", "zor vo", "Zorvox", d=self.d)
        self.assertEqual(self.d["loose_heard"], {"zor vo": "Zorvox"})
        dictionary.loose("zor vo", "", "", d=self.d)
        self.assertEqual(self.d["loose_heard"], {})

    def test_bad_text(self):
        self.assertIsNone(dictionary.edit("Brumblex", "  ", [], d=self.d))
        self.assertIsNone(dictionary.edit("Brumblex", "x" * 61, [], d=self.d))


if __name__ == "__main__":
    unittest.main()

"""The live dictionary holds the user's contacts, so it lives in the untracked data/ folder (open-source round
2026-11-14). The old tracked dictionary/words.json is moved there once; a new install starts from the made-up seed.
Temporary folders only, made-up names only.

    .venv/bin/python -B tests/test_dictionary_move.py
"""
import json, subprocess, sys, tempfile, unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "engine"))
import dictionary


def words(path):
    return [w["text"] for w in json.loads(Path(path).read_text())["words"]]


class Move(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(); r = Path(self.tmp.name)
        (r / "dictionary").mkdir()
        self.file, self.old, self.seed = r / "data/words.json", r / "dictionary/words.json", r / "dictionary/words.example.json"
        self.seed.write_text(json.dumps({"words": [{"text": "Seedy Name", "kind": "name"}]}))

    def tearDown(self): self.tmp.cleanup()

    def ensure(self): return dictionary.ensure(self.file, self.old, self.seed, git=False)

    def test_old_file_moves_once_and_a_link_stays(self):
        self.old.write_text(json.dumps({"words": [{"text": "Oksana Madeup", "kind": "name"}]}))
        self.ensure()
        self.assertEqual(words(self.file), ["Oksana Madeup"])
        self.assertTrue(self.old.is_symlink())
        self.assertEqual(words(self.old), ["Oksana Madeup"])        # apps reading the old place still see it

    def test_existing_new_file_is_never_touched(self):
        self.file.parent.mkdir(); self.file.write_text(json.dumps({"words": [{"text": "Kept Person"}]}))
        self.old.write_text(json.dumps({"words": [{"text": "Older Person"}]}))
        self.ensure()
        self.assertEqual(words(self.file), ["Kept Person"])
        self.assertFalse(self.old.is_symlink())

    def test_new_install_starts_from_the_seed(self):
        self.ensure()
        self.assertEqual(words(self.file), ["Seedy Name"])

    def test_save_writes_through_the_link(self):
        self.old.write_text(json.dumps({"words": []}))
        self.ensure()
        saved = dictionary.FILE
        try:
            dictionary.FILE = self.file
            d = json.loads(self.file.read_text()); d.setdefault("keep", []); d.setdefault("loose_heard", {})
            dictionary.add("Taras Invented", kind="name", d=d); dictionary.save(d)
        finally:
            dictionary.FILE = saved
        self.assertIn("Taras Invented", words(self.old))


class Paths(unittest.TestCase):
    def test_live_file_is_in_data(self):
        self.assertEqual(dictionary.FILE, ROOT / "data" / "words.json")

    def test_seed_is_tracked_and_made_up(self):
        seed = json.loads(dictionary.SEED.read_text())
        self.assertLessEqual(len(seed["words"]), 10)
        self.assertTrue(all(w["source"] == "seed" for w in seed["words"]))

    def test_personal_file_is_ignored(self):
        out = subprocess.run(["git", "-C", str(ROOT), "check-ignore", "-q", "dictionary/words.json"])
        self.assertEqual(out.returncode, 0)
        tracked = subprocess.run(["git", "-C", str(ROOT), "ls-files", "dictionary/words.json"], capture_output=True, text=True)
        self.assertEqual(tracked.stdout.strip(), "")

    def test_no_reader_uses_the_old_path(self):
        hits = []
        for f in list((ROOT / "engine").glob("*.py")) + list((ROOT / "bench").glob("*.py")) + list((ROOT / "app").glob("*.swift")):
            for i, line in enumerate(f.read_text().splitlines(), 1):
                if ('dictionary/words.json' in line or '"dictionary", "words.json"' in line or '"dictionary" / "words.json"' in line) \
                        and f.name not in ("dictionary.py", "Main.swift"):
                    hits.append(f"{f.name}:{i}")
        self.assertEqual(hits, [])


if __name__ == "__main__":
    unittest.main()

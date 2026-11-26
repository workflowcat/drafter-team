"""scripts/link_data.sh: with a data folder outside the clone, data/ in the clone becomes a link to it, so training, the
nightly job and the bench scripts (which write data/...) use the same folder as the app and the engine. It never moves
or deletes a file. Temporary folders only.

    .venv/bin/python -B tests/test_link_data.py
"""
import os, shutil, subprocess, tempfile, unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SCRIPT = ROOT / "scripts" / "link_data.sh"


class LinkData(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.t = Path(self.tmp.name).resolve()
        self.clone = self.t / "clone"; (self.clone / "scripts").mkdir(parents=True)
        shutil.copy(SCRIPT, self.clone / "scripts" / "link_data.sh")
        self.out = self.t / "outside"

    def tearDown(self):
        self.tmp.cleanup()

    def run_it(self, *args, env_data=None):
        env = {k: v for k, v in os.environ.items() if k != "DRAFTER_DATA"}
        if env_data is not None: env["DRAFTER_DATA"] = env_data
        return subprocess.run(["/bin/bash", str(self.clone / "scripts" / "link_data.sh"), *args],
                              env=env, capture_output=True, text=True, timeout=20)

    def test_nothing_without_a_folder(self):
        r = self.run_it()
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertFalse((self.clone / "data").exists() or (self.clone / "data").is_symlink())

    def test_no_data_yet_links_to_the_folder(self):
        r = self.run_it(env_data=str(self.out))
        self.assertEqual(r.returncode, 0, r.stderr)
        link = self.clone / "data"
        self.assertTrue(link.is_symlink())
        self.assertEqual(link.resolve(), self.out.resolve())
        (link / "review").mkdir()                       # what scripts/install-login.sh does
        self.assertTrue((self.out / "review").is_dir())

    def test_an_empty_data_folder_becomes_the_link(self):
        (self.clone / "data").mkdir()
        r = self.run_it(str(self.out))
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertTrue((self.clone / "data").is_symlink())

    def test_data_with_files_is_left_alone(self):
        (self.clone / "data").mkdir(); (self.clone / "data" / "typed.jsonl").write_text("{}\n")
        r = self.run_it(env_data=str(self.out))
        self.assertEqual(r.returncode, 1)
        self.assertIn("nothing was moved", r.stderr)
        self.assertFalse((self.clone / "data").is_symlink())
        self.assertEqual((self.clone / "data" / "typed.jsonl").read_text(), "{}\n")

    def test_a_link_elsewhere_is_repointed_and_the_old_folder_kept(self):
        old = self.t / "old"; old.mkdir(); (old / "keep.txt").write_text("x")
        (self.clone / "data").symlink_to(old)
        r = self.run_it(env_data=str(self.out))
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual((self.clone / "data").resolve(), self.out.resolve())
        self.assertEqual((old / "keep.txt").read_text(), "x")

    def test_the_same_link_twice_changes_nothing(self):
        self.assertEqual(self.run_it(env_data=str(self.out)).returncode, 0)
        r = self.run_it(env_data=str(self.out))
        self.assertEqual((r.returncode, r.stdout), (0, ""))

    def test_data_in_the_clone_itself_is_not_linked(self):
        (self.clone / "data").mkdir(); (self.clone / "data" / "a").write_text("1")
        r = self.run_it(env_data=str(self.clone / "data"))
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertFalse((self.clone / "data").is_symlink())

    def test_the_link_is_ignored_by_git(self):
        lines = (ROOT / ".gitignore").read_text().split()
        self.assertIn("/data", lines)   # "data/" matches folders only, so a link named data needs its own line


if __name__ == "__main__":
    unittest.main()

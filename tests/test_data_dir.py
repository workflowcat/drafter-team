"""Where the user's data lives (engine/data_dir.py): DRAFTER_DATA first, then data/ in the clone, then Application
Support only when asked for, else data/ in the clone as before. Temporary folders only.

    .venv/bin/python -B tests/test_data_dir.py
"""
import importlib, os, subprocess, sys, tempfile, unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "engine"))
import data_dir as dd

KEYS = ("DRAFTER_DATA", "DRAFTER_APP_SUPPORT", "DRAFTER_LOCAL", "HOME")


class DataDir(unittest.TestCase):
    def setUp(self):
        self.saved = {k: os.environ.get(k) for k in KEYS}
        for k in ("DRAFTER_DATA", "DRAFTER_APP_SUPPORT", "DRAFTER_LOCAL"): os.environ.pop(k, None)
        self.tmp = tempfile.TemporaryDirectory()
        self.t = Path(self.tmp.name).resolve()
        self.root = self.t / "clone"; self.root.mkdir()

    def tearDown(self):
        for k, v in self.saved.items():
            if v is None: os.environ.pop(k, None)
            else: os.environ[k] = v
        self.tmp.cleanup()

    def test_env_wins_over_the_clone(self):
        (self.root / "data").mkdir()
        os.environ["DRAFTER_DATA"] = str(self.t / "elsewhere")
        self.assertEqual(dd.data_dir(self.root), self.t / "elsewhere")

    def test_env_expands_the_tilde(self):
        os.environ["HOME"] = str(self.t)
        os.environ["DRAFTER_DATA"] = "~/mydata"
        self.assertEqual(dd.data_dir(self.root), self.t / "mydata")

    def test_empty_env_is_ignored(self):
        os.environ["DRAFTER_DATA"] = "  "
        self.assertEqual(dd.data_dir(self.root), self.root / "data")

    def test_existing_clone_data_wins_over_app_support(self):
        (self.root / "data").mkdir()
        os.environ["DRAFTER_APP_SUPPORT"] = "1"
        self.assertEqual(dd.data_dir(self.root), self.root / "data")

    def test_app_support_only_when_asked(self):
        os.environ["HOME"] = str(self.t)
        os.environ["DRAFTER_APP_SUPPORT"] = "1"
        self.assertEqual(dd.data_dir(self.root), self.t / "Library" / "Application Support" / "Drafter")

    def test_default_is_the_clone_data_even_when_missing(self):
        self.assertFalse((self.root / "data").exists())
        self.assertEqual(dd.data_dir(self.root), self.root / "data")
        self.assertFalse((self.root / "data").exists())      # never created by asking

    def test_symlinked_data_resolves(self):
        real = self.t / "real"; real.mkdir()
        (self.root / "data").symlink_to(real)
        self.assertEqual(dd.data_dir(self.root), real)

    def test_engine_modules_follow_the_env(self):
        os.environ["DRAFTER_DATA"] = str(self.t / "d")
        import memory, words, people, provider, dictionary, local, journal_db, local_search
        for m in (memory, words, people, provider, dictionary): importlib.reload(m)
        self.assertEqual(memory.DATA, self.t / "d")
        self.assertEqual(words.DATA, self.t / "d")
        self.assertEqual(people.PATH, self.t / "d" / "people.json")
        self.assertEqual(provider.SETTINGS, self.t / "d" / "settings.json")
        self.assertEqual(dictionary.FILE, self.t / "d" / "words.json")
        self.assertEqual(local.path(), self.t / "d" / "drafter.local.json")
        self.assertEqual(journal_db.JournalDB().data_dir, self.t / "d")
        self.assertEqual(local_search.LocalSearchIndex().data_dir, self.t / "d")

    def test_command_line_prints_it(self):
        env = {k: v for k, v in os.environ.items() if k not in KEYS[:3]}
        env["DRAFTER_DATA"] = str(self.t / "cli")
        out = subprocess.run([sys.executable, str(ROOT / "engine/data_dir.py")], env=env, capture_output=True, text=True)
        self.assertEqual(out.stdout.strip(), str(self.t / "cli"))


class Wiring(unittest.TestCase):
    """The app and the scripts use the same folder."""
    def test_app_reads_env_then_plist(self):
        src = (ROOT / "app/Main.swift").read_text()
        self.assertIn('environment["DRAFTER_DATA"]', src)
        self.assertIn('"DrafterData"', src)
        self.assertIn("Library/Application Support/Drafter", src)
        self.assertIn('env["DRAFTER_DATA"] = Home.data.path', (ROOT / "app/Voice.swift").read_text())

    def test_build_and_doctor(self):
        build = (ROOT / "app/build.sh").read_text()
        self.assertIn(":DrafterData", build)
        self.assertIn("DRAFTER_APP_OUT", build)
        self.assertIn("from data_dir import data_dir", (ROOT / "scripts/doctor.py").read_text())

    def test_setup_installs_the_lock_as_it_is(self):
        setup = (ROOT / "scripts/setup.sh").read_text()
        self.assertIn('uv pip sync --python "$venv/bin/python" requirements-lock.txt', setup)
        self.assertNotIn("uv pip compile", setup)
        self.assertIn("uv pip compile", (ROOT / "scripts/check_lock.sh").read_text())

    def test_package_never_installs_or_opens(self):
        src = (ROOT / "scripts/package_app.sh").read_text()
        self.assertIn('DRAFTER_APP_OUT="$app"', src)
        code = [l for l in src.splitlines() if not l.lstrip().startswith(("#", "echo"))]
        self.assertFalse([l for l in code if l.lstrip().startswith("open ") or " open " in l or "launchctl" in l])
        self.assertNotIn("Applications/Drafter.app", "\n".join(code))
        for f in ("scripts/package_app.sh", "scripts/check_lock.sh"):
            self.assertTrue(os.access(ROOT / f, os.X_OK), f)
        out = subprocess.run([str(ROOT / "scripts/package_app.sh"), "--help"], capture_output=True, text=True)
        self.assertEqual(out.returncode, 0)
        self.assertIn("build/dist", out.stdout)


if __name__ == "__main__":
    unittest.main()

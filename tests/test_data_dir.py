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
        import memory, words, provider, dictionary, local, journal_db
        for m in (memory, words, provider, dictionary): importlib.reload(m)
        self.assertEqual(memory.DATA, self.t / "d")
        self.assertEqual(words.DATA, self.t / "d")
        self.assertEqual(provider.SETTINGS, self.t / "d" / "settings.json")
        self.assertEqual(dictionary.FILE, self.t / "d" / "words.json")
        self.assertEqual(local.path(), self.t / "d" / "drafter.local.json")
        self.assertEqual(journal_db.JournalDB().data_dir, self.t / "d")

    def test_more_engine_modules_follow_the_env(self):
        """The rest of the engine the server and the CLIs load, in a fresh process so module constants are read anew."""
        d = self.t / "d"; d.mkdir()
        (d / "settings.json").write_text('{"voiceFast": "test/fast", "voiceCareful": "test/careful"}')
        (d / "names.json").write_text('{"voice": ["Zorblat"]}')
        (d / "gate.json").write_text('{"names": "not these"}')
        (d / "offline").write_text("")
        probe = r"""
import json, os, sys, types
from pathlib import Path
from unittest.mock import Mock
sys.path.insert(0, sys.argv[1])
mx = types.ModuleType("mlx.core"); mx.set_cache_limit = Mock(); mlx = types.ModuleType("mlx"); mlx.core = mx
fake = {"mlx": mlx, "mlx.core": mx, "stand_ins": types.SimpleNamespace(install=Mock()),
        "parakeet_mlx": types.SimpleNamespace(from_pretrained=Mock()), "parakeet_mlx.audio": types.SimpleNamespace(get_logmel=Mock()),
        "guard": types.SimpleNamespace(start=Mock())}
saved = {k: sys.modules.get(k) for k in fake}
sys.modules.update(fake)
import voice
for k, v in saved.items():
    if v is None: sys.modules.pop(k, None)
    else: sys.modules[k] = v
import voice_settings, actions, snippets, command, edits, notes, word_fixes, router, model, names, know, gatecore, speakers, typos
out = {
    "voice": [voice.MODEL, voice.CAREFUL, voice.HINT],
    "voice_settings": list(voice_settings.load_models()),
    "actions": str(actions.SETTINGS), "snippets": str(snippets.FILE), "command": str(command.SNIPPETS),
    "edits": [str(edits.TAKES), str(edits.EDITS)], "notes": str(notes.NOTES), "notes_names": notes.names(),
    "word_fixes": str(word_fixes.DATA), "router": router.online(), "model": model.HEAD_CACHE,
    "names": str(names.DATA), "gatecore": gatecore.load(),
}
print(json.dumps(out))
"""
        env = {k: v for k, v in os.environ.items() if k not in KEYS[:3] + ("DRAFTER_VOICE_SETTINGS", "DRAFTER_WORDS",
                                                                          "DRAFTER_NAMES", "DRAFTER_HEAD_CACHE", "DRAFTER_OFFLINE")}
        env["DRAFTER_DATA"] = str(d)
        run = subprocess.run([sys.executable, "-B", "-c", probe, str(ROOT / "engine")], env=env, capture_output=True, text=True)
        self.assertEqual(run.returncode, 0, run.stderr)
        got = __import__("json").loads(run.stdout.strip().splitlines()[-1])
        self.assertEqual(got["voice"], ["test/fast", "test/careful", "Glossary: Zorblat."])
        self.assertEqual(got["voice_settings"], ["test/fast", "test/careful"])
        self.assertEqual(got["actions"], str(d / "settings.json"))
        self.assertEqual(got["snippets"], str(d / "snippets.json"))
        self.assertEqual(got["command"], str(d / "snippets.json"))
        self.assertEqual(got["edits"], [str(d / "takes.jsonl"), str(d / "edits.jsonl")])
        self.assertEqual(got["notes"], str(d / "notes"))
        self.assertEqual(got["notes_names"], [])
        self.assertEqual(got["word_fixes"], str(d))
        self.assertFalse(got["router"])                       # d/offline forces local
        self.assertEqual(got["model"], str(d / "cache"))
        self.assertEqual(got["names"], str(d))
        self.assertIsNone(got["gatecore"])                    # read d/gate.json, whose names do not match

    def test_cli_defaults_follow_the_env(self):
        """know.build, speakers and typos take their default folders from DRAFTER_DATA at call time."""
        os.environ["DRAFTER_DATA"] = str(self.t / "d")
        import know, gatecore, voice_settings
        (self.t / "d").mkdir()
        (self.t / "d" / "words.json").write_text('{"words": [{"text": "Zorblat", "kind": "project"}]}')
        (self.t / "d" / "snippets.json").write_text("{}")
        pack = know.build(dictionary=None, snippets=None, now=1)
        self.assertTrue((self.t / "d" / "know.json").exists())
        self.assertIn("zorblat", __import__("json").dumps(pack).lower())
        (self.t / "d" / "settings.json").write_text('{"voiceCareful": "local/c"}')
        saved = os.environ.pop("DRAFTER_VOICE_SETTINGS", None)
        try: self.assertEqual(voice_settings.load_models()[1], "local/c")
        finally:
            if saved is not None: os.environ["DRAFTER_VOICE_SETTINGS"] = saved
        self.assertIsNone(gatecore.load())
        for f, defaults in (("speakers.py", ('str(data / "voiceprint.json")', 'str(data / "audio")', 'str(data / "calls")')),
                            ("typos.py", ('default=str(data_dir())',))):
            src = (ROOT / "engine" / f).read_text()
            self.assertIn("from data_dir import data_dir", src)
            for x in defaults: self.assertIn(x, src)
            self.assertNotIn('ROOT / "data"', src)

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

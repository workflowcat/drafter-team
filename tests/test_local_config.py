"""The user's local config (data/drafter.local.json, untracked): every Claude prompt and the local prompt head build
from it; with no file they are neutral and name nobody. Made-up config only.

    .venv/bin/python -B tests/test_local_config.py
"""
import importlib, json, os, sys, tempfile, unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "engine"))
sys.path.insert(0, str(ROOT / "actions"))

MADE_UP = {"user": {"name": "Marta Example", "short_name": "Marta", "own_names": ["Marta"], "own_stems": ["mart"],
                    "about": "She builds boats and writes to her crew.", "style_rules": "Marta writes short lines.",
                    "timezone": "Europe/Lisbon", "city": "Porto", "email": "marta@example.com"},
           "integrations": {"vault": {"enabled": True, "path": "~/Notes"}}}


def prompts():
    import local, prompt, rework, command, dictionary
    return {"rules": prompt.rules(), "rework": rework.system(),
            "command": command.PROMPT.replace("{user}", local.short_name()), "ask": local.possessive(),
            "skip": dictionary.SKIP.pattern}


class Config(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.file = Path(self.tmp.name) / "drafter.local.json"
        os.environ["DRAFTER_LOCAL"] = str(self.file)
        import local; local._cache["key"] = None

    def tearDown(self):
        os.environ.pop("DRAFTER_LOCAL", None); self.tmp.cleanup()

    def test_no_config_is_neutral(self):
        text = json.dumps(prompts(), ensure_ascii=False)
        for word in ("Andrii", "Андрій", "Madeupenko", "Marta Example", "Kyiv"):
            self.assertNotIn(word, text)
        self.assertIn("the user", text)

    def test_made_up_config_fills_every_prompt(self):
        self.file.write_text(json.dumps(MADE_UP))
        import dictionary; importlib.reload(dictionary)
        p = prompts()
        self.assertIn("Marta Example", p["rework"])
        self.assertEqual(p["rules"], "Marta writes short lines.")
        self.assertIn("one line Marta typed", p["command"])
        self.assertEqual(p["ask"], "Marta's")
        self.assertIn("|^Marta\\b", p["skip"])

    def test_paths_expand_and_integrations_follow_the_file(self):
        import local
        self.assertFalse(local.enabled("vault"))
        self.file.write_text(json.dumps(MADE_UP)); local._cache["key"] = None
        self.assertTrue(local.enabled("vault"))
        self.assertEqual(local.setting("vault", "path"), str(Path.home() / "Notes"))
        self.assertEqual(local.timezone(), "Europe/Lisbon")

    def test_snippets_seed_only_a_new_file(self):
        import local
        self.file.write_text(json.dumps(MADE_UP)); local._cache["key"] = None
        snips = Path(self.tmp.name) / "snippets.json"
        self.assertTrue(local.seed_snippets(snips))
        self.assertEqual(json.loads(snips.read_text()), {";mail": "marta@example.com"})
        snips.write_text('{";x": "kept"}')
        self.assertFalse(local.seed_snippets(snips))
        self.assertEqual(json.loads(snips.read_text()), {";x": "kept"})

    def test_example_file_has_every_default_key_and_no_values(self):
        import local
        ex = json.loads((ROOT / "drafter.local.example.json").read_text())
        for section, keys in local.DEFAULTS.items():
            if isinstance(keys, dict):
                self.assertTrue(set(keys) <= set(ex.get(section, {})), section)
        self.assertEqual(ex["user"]["name"], "")
        self.assertTrue(all(v.get("enabled") is False for v in ex["integrations"].values()))

    def test_build_keys_default_empty_and_follow_the_file(self):
        import local, subprocess
        self.assertEqual(local.codesign_identity(), "")
        self.assertEqual(local.build_data_dir(), "")
        self.file.write_text(json.dumps({"build": {"codesign_identity": " Developer ID Application: Made Up (TEAM123) ",
                                                   "data_dir": "~/DrafterData"}})); local._cache["key"] = None
        self.assertEqual(local.codesign_identity(), "Developer ID Application: Made Up (TEAM123)")
        self.assertEqual(local.build_data_dir(), str(Path.home() / "DrafterData"))
        ex = json.loads((ROOT / "drafter.local.example.json").read_text())["build"]
        self.assertEqual((ex["codesign_identity"], ex["data_dir"]), ("", ""))
        run = lambda *a: subprocess.run([sys.executable, str(ROOT / "engine/local.py"), "--get", *a],
                                        capture_output=True, text=True, env=dict(os.environ))
        self.assertEqual(run("codesign_identity").stdout.strip(), "Developer ID Application: Made Up (TEAM123)")
        self.assertEqual(run("data_dir").stdout.strip(), str(Path.home() / "DrafterData"))
        self.assertEqual(run("bundle_id").stdout.strip(), local.PUBLIC_BUNDLE_ID)
        self.assertEqual(run("no_such_key").returncode, 2)

    def test_config_file_follows_drafter_data(self):
        import local
        os.environ.pop("DRAFTER_LOCAL", None)
        saved = os.environ.get("DRAFTER_DATA")
        os.environ["DRAFTER_DATA"] = self.tmp.name
        try:
            self.assertEqual(local.path(), Path(self.tmp.name).resolve() / "drafter.local.json")
        finally:
            if saved is None: os.environ.pop("DRAFTER_DATA", None)
            else: os.environ["DRAFTER_DATA"] = saved


if __name__ == "__main__":
    unittest.main()

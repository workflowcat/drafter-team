"""Every feature that sends text to Claude is off for a new install (open-source round, 2026-11-14), and an existing
settings file keeps what it had: a one-time migration writes the old effective value (on) of each Claude switch it
does not name. Temporary files only.

    .venv/bin/python -B tests/test_cloud_defaults.py
"""
import json, re, sys, tempfile, unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "engine"))
import cloud


class Migrate(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(); self.file = Path(self.tmp.name) / "settings.json"

    def tearDown(self): self.tmp.cleanup()

    def test_new_install_is_all_local(self):
        self.assertEqual(cloud.migrate(self.file), [])
        self.assertFalse(self.file.exists())
        for feature in cloud.OWNERS:
            if cloud.OWNERS[feature]: self.assertFalse(cloud.allowed(feature, {}), feature)

    def test_existing_user_keeps_what_he_had(self):
        before = {"paused": False, "proofread": False, "voice": True}      # an older file: most Claude keys absent
        self.file.write_text(json.dumps(before))
        # before: the CLI was the one way, so a feature ran when its owning switches were on (missing = on)
        effective_before = {f: all(before.get(k, cloud.OLD_DEFAULTS[k]) is True for k in cloud.OWNERS[f]) for f in cloud.OWNERS}
        wrote = cloud.migrate(self.file)
        st = json.loads(self.file.read_text())
        self.assertEqual(set(wrote), set(cloud.DEFAULTS) - {"proofread"} | {"connect"})
        self.assertEqual(st["connect"], {"provider": "cli"})                 # he stays connected through the CLI
        self.assertIs(st["proofread"], False)                               # his own choice stays
        self.assertEqual(st["cloudDefaults"], "off")
        self.assertEqual({k: st[k] for k in before}, before)
        effective_after = {f: cloud.allowed(f, st) for f in effective_before}
        self.assertEqual(effective_after, effective_before)

    def test_runs_once(self):
        self.file.write_text(json.dumps({"cloudDefaults": "off"}))
        self.assertEqual(cloud.migrate(self.file), [])
        self.assertEqual(json.loads(self.file.read_text()), {"cloudDefaults": "off"})

    def test_unreadable_file_is_left_alone(self):
        self.file.write_text("{not json")
        self.assertEqual(cloud.migrate(self.file), [])
        self.assertEqual(self.file.read_text(), "{not json")


class Defaults(unittest.TestCase):
    def test_engine_and_app_agree_on_off(self):
        self.assertTrue(all(v is False for v in cloud.DEFAULTS.values()))
        src = (ROOT / "app/Settings.swift").read_text()
        for k in cloud.DEFAULTS:
            self.assertRegex(src, rf"\n\s+var {k} = false\b", k)
        keys = re.search(r"static let cloudKeys = \[(.*?)\]", src).group(1)
        self.assertEqual(set(re.findall(r'"(\w+)"', keys)), set(cloud.DEFAULTS))

    def test_app_migrates_before_it_decodes(self):
        src = (ROOT / "app/Settings.swift").read_text()
        load = src[src.index("static func load() -> Settings {"):]
        self.assertLess(load.index("migrateCloud()"), load.index("decode(d)"))
        self.assertIn('if j["connect"] == nil { j["connect"] = ["provider": "cli"] }', src)   # stays connected through the CLI

    def test_engine_migrates_at_start_and_marks_files_it_makes(self):
        src = (ROOT / "engine/server.py").read_text()
        self.assertIn('cloud.migrate(DATA / "settings.json")', src)
        self.assertIn('settings_load() or {cloud.MARK: "off"}', src)


if __name__ == "__main__":
    unittest.main()

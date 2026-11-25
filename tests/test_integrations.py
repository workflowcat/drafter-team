"""Private integrations are optional and quiet (open-source round, 2026-11-14): each is on only when the local config
turns it on AND its tool answers; off, its chips and actions are not offered at all. Temporary folders, made-up config.

    .venv/bin/python -B tests/test_integrations.py
"""
import json, os, sys, tempfile, unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
TMP = tempfile.TemporaryDirectory()
CONFIG = Path(TMP.name) / "drafter.local.json"
os.environ["DRAFTER_LOCAL"] = str(CONFIG)      # before any engine import: the module constants read it
sys.path.insert(0, str(ROOT / "engine"))
import local, integrations, actions
import provider
provider.SETTINGS = Path(TMP.name) / "settings.json"   # never the live settings: "connected through the CLI" there would turn claude on


def use(cfg):
    CONFIG.write_text(json.dumps(cfg)); local._cache["key"] = None; integrations._seen.clear()


class Off(unittest.TestCase):
    def setUp(self): use({})

    def test_everything_is_off_without_a_config(self):
        self.assertEqual({n for n, s in integrations.state().items() if s["available"]}, set())

    def test_every_integration_has_a_check(self):
        self.assertEqual(set(integrations.TABLE), set(integrations.CHECKS))
        self.assertEqual(set(integrations.TABLE), set(local.DEFAULTS["integrations"]))

    def test_actions_that_need_an_integration_are_not_offered(self):
        need = {a.ID for a in actions.ALL if getattr(a, "NEEDS", ())}
        self.assertTrue({"beeper.draft", "followup", "thread.reply", "vault.note"} <= need)
        for a in actions.ALL:
            self.assertTrue(hasattr(a, "NEEDS"), a.ID)
            self.assertEqual(actions.usable(a), not a.NEEDS, a.ID)
        # a line that would trigger the follow-up chip: no chip at all
        self.assertIsNone(next((f for f in [actions.detect("нагадай написати Марті завтра")] if f and f.mod.ID == "followup"), None))
        self.assertIn("off on this Mac", actions.run_python("followup", {"what": "x", "due": "2026-01-01T10:00"})["error"])

    def test_command_plans_drop_off_integrations(self):
        import command
        self.assertIsNone(command.option("task", {"what": "write to Marta"}))
        self.assertIsNone(command.option("note", {"title": "t", "text": "x"}))
        self.assertEqual(command.plan(";docs plan")["options"], [])

    def test_engine_never_starts_claude_when_off(self):
        import claude_type, claude_worker, router
        self.assertFalse(Path(claude_type.CLI).exists())
        self.assertFalse(Path(claude_worker.CMD[0]).exists())
        router._state["at"] = 0
        self.assertFalse(router.online())

    def test_knowledge_pack_builds_without_aleph(self):
        import know
        out = Path(TMP.name) / "know.json"
        pack = know.build(out, dictionary=Path(TMP.name) / "none.json", snippets=Path(TMP.name) / "none.json", contacts=[])
        self.assertEqual(pack["entries"], [])

    def test_style_does_not_crash_without_beeper(self):
        import style
        self.assertIsNone(style.build())


class On(unittest.TestCase):
    def test_on_only_when_enabled_and_present(self):
        folder = Path(TMP.name) / "vault"; folder.mkdir(exist_ok=True)
        use({"integrations": {"vault": {"enabled": True, "path": str(folder)}, "inbox": {"enabled": True, "path": str(folder / "missing")},
                              "voice_notes": {"enabled": False, "path": str(folder)}}})
        self.assertTrue(integrations.available("vault"))
        self.assertFalse(integrations.available("inbox"))         # turned on, but its folder is not there
        self.assertFalse(integrations.available("voice_notes"))   # there, but not turned on
        self.assertFalse(integrations.available("nonsense"))


if __name__ == "__main__":
    try: unittest.main()
    finally: TMP.cleanup()

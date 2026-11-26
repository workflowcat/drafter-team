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
        for a in actions.ALL:
            self.assertTrue(hasattr(a, "NEEDS"), a.ID)
            self.assertEqual(actions.usable(a), not a.NEEDS, a.ID)

    def test_command_plans_drop_off_integrations(self):
        import command
        self.assertIsNone(command.option("note", {"title": "t", "text": "x"}))   # no note action any more

    def test_engine_never_starts_claude_when_off(self):
        import claude_type, claude_worker, router
        self.assertFalse(Path(claude_type.CLI).exists())
        self.assertFalse(Path(claude_worker.CMD[0]).exists())
        router._state["at"] = 0
        self.assertFalse(router.online())

    def test_knowledge_pack_builds_from_nothing(self):
        import know
        out = Path(TMP.name) / "know.json"
        pack = know.build(out, dictionary=Path(TMP.name) / "none.json", snippets=Path(TMP.name) / "none.json")
        self.assertEqual(pack["entries"], [])


class On(unittest.TestCase):
    def test_on_only_when_enabled_and_present(self):
        fake = Path(TMP.name) / "claude"; fake.write_text("#!/bin/sh\n"); fake.chmod(0o755)
        use({"integrations": {"claude": {"enabled": False, "bin": str(fake)}}})
        self.assertFalse(integrations.available("claude"))        # a path, but not turned on
        use({"integrations": {"claude": {"enabled": True, "bin": str(fake)}}})
        self.assertTrue(integrations.available("claude"))
        self.assertEqual(set(integrations.TABLE), {"claude"})
        for gone in ("voice_guide", "nonsense"):                  # removed or unknown: never available
            self.assertFalse(integrations.available(gone), gone)


if __name__ == "__main__":
    try: unittest.main()
    finally: TMP.cleanup()

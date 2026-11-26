"""Claude cleanup after a voice take (engine/voice_claude.py, server.voice_claude). Made-up lines only; no model, no
network, no `claude` process; a throwaway data folder for the spend ledger.

    .venv/bin/python -B tests/test_voice_claude.py
"""
import json, sys, tempfile, types, unittest
from pathlib import Path
from unittest.mock import Mock

ENGINE = Path(__file__).resolve().parent.parent / "engine"
sys.path.insert(0, str(ENGINE))
import cloud
import voice_claude as vc
from server_src import lift

TAKE = "send the deck to marta by friday"


class Rules(unittest.TestCase):
    def test_accept(self):
        self.assertEqual(vc.accept("Send the deck to Marta by Friday.", TAKE), "Send the deck to Marta by Friday.")
        self.assertEqual(vc.accept("«Send the deck to Marta by Friday.»", TAKE), "Send the deck to Marta by Friday.")
        self.assertEqual(vc.accept("", TAKE), "")
        self.assertEqual(vc.accept(TAKE, TAKE), "")                                   # nothing changed: no swap
        self.assertEqual(vc.accept("Sure.", TAKE), "")                                 # far too short
        self.assertEqual(vc.accept(TAKE + " " + TAKE + " and more words here", TAKE), "")   # far too long
        self.assertEqual(vc.accept("Send the deck\nto Marta by Friday.", TAKE), "")    # a new line break
        self.assertEqual(vc.accept("Here is the text: send deck to Marta", TAKE), "")  # talks about the text

    def test_prompt_holds_only_what_was_given(self):
        p = vc.build(TAKE, "clean", hint="Keyboard now: English.\n", screen="made-up line before", names=["Marta", 3, ""])
        self.assertIn("Dictation:\n" + TAKE, p)
        self.assertIn("Names as they are spelled: Marta", p)
        self.assertIn("made-up line before", p)
        self.assertIn("Keep his words", p)
        self.assertNotIn("His mode", p); self.assertNotIn("His note", p)
        p = vc.build(TAKE, "polished", mode="an email to a client", note="short lines")
        self.assertIn("read as written text", p); self.assertIn("an email to a client", p); self.assertIn("short lines", p)
        self.assertLessEqual(len(vc.build(TAKE, screen="x" * 5000)), len(TAKE) + vc.MAX_SCREEN + 600)

    def test_cap_and_ledger(self):
        with tempfile.TemporaryDirectory() as d:
            now = 1_763_400_000.0
            self.assertTrue(vc.room(d, 0.5, 0.001, now))
            vc.charge(d, 0.2, now); vc.charge(d, 0.25, now)
            self.assertAlmostEqual(vc.spent(d, now), 0.45)
            self.assertTrue(vc.room(d, 0.5, 0.04, now))
            self.assertFalse(vc.room(d, 0.5, 0.06, now))
            # old days in the shared ledger
            led = Path(d) / "backoffice" / "spend.json"
            data = json.loads(led.read_text()); data["2000-01-01"] = 1.0; led.write_text(json.dumps(data))
            vc.charge(d, 0.01, now)
            self.assertNotIn("2000-01-01", json.loads(led.read_text()))       # older than 60 days: dropped

    def test_estimate_is_small(self):
        self.assertLess(vc.estimate(vc.build(TAKE), TAKE), 0.001)

    def test_gate(self):
        self.assertEqual(cloud.OWNERS["voice_claude"], ("voiceClaude",))
        self.assertFalse(cloud.DEFAULTS["voiceClaude"])
        self.assertIn("voiceClaude", cloud.NEVER_ON)
        self.assertFalse(cloud.allowed("voice_claude", {"connect": {"provider": "cli"}}))
        self.assertTrue(cloud.allowed("voice_claude", {"voiceClaude": True, "connect": {"provider": "cli"}}))


class Server(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.settings = {"voiceClaude": True}
        self.online = True
        self.cw = types.SimpleNamespace(ask=Mock(return_value="Send the deck to Marta by Friday."))
        self.who = types.SimpleNamespace(hint=Mock(return_value=""))
        self.ns = lift("claude_on", "voice_claude", cloud=cloud, router=types.SimpleNamespace(online=lambda: self.online), vclaude=vc,
                       settings_load=lambda: {"connect": {"provider": "cli"}, **self.settings},
                       claude_worker=self.cw, who=self.who, DATA=Path(self.tmp.name), time=__import__("time"))

    def tearDown(self): self.tmp.cleanup()

    def ask(self, **kw): return self.ns["voice_claude"]({"text": TAKE, "level": "clean", **kw})

    def test_on(self):
        r = self.ask()
        self.assertEqual(r["text"], "Send the deck to Marta by Friday.")
        self.assertEqual(self.cw.ask.call_args.args[1], vc.DEADLINE)
        self.assertGreater(vc.spent(self.tmp.name), 0)

    def test_off_offline_raw_send_nothing(self):
        self.settings = {"voiceClaude": False}
        self.assertEqual(self.ask()["text"], "")
        self.settings = {"voiceClaude": True}; self.online = False
        self.assertEqual(self.ask()["text"], "")
        self.online = True
        self.assertEqual(self.ask(level="raw")["text"], "")
        self.assertEqual(self.ask(text="x" * (vc.MAX_TEXT + 1))["text"], "")
        self.cw.ask.assert_not_called(); self.who.hint.assert_not_called()   # not even the person block is built

    def test_cap_stops_it(self):
        self.settings = {"voiceClaude": True, "backOfficeCap": 0.01}
        vc.charge(self.tmp.name, 0.01)
        self.assertEqual(self.ask()["why"], "cap")
        self.cw.ask.assert_not_called()

    def test_slow_keeps_parakeet(self):
        self.cw.ask.return_value = None
        r = self.ask()
        self.assertEqual((r["text"], r["why"]), ("", "slow"))
        self.assertEqual(vc.spent(self.tmp.name), 0)


if __name__ == "__main__":
    unittest.main()

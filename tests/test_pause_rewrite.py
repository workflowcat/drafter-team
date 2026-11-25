"""The pause rewrite (engine/pause_rewrite.py, route /pause_rewrite): when it asks, what it keeps, the marks, the cap
shared with the back office, and that nothing goes out with the setting off. Made-up lines only; no model, no network,
no `claude` process; the data folder is a throwaway copy.

    .venv/bin/python -B tests/test_pause_rewrite.py
"""
import json, sys, tempfile, unittest
from pathlib import Path
from unittest import mock

ENGINE = Path(__file__).resolve().parent.parent / "engine"
sys.path.insert(0, str(ENGINE))
import cloud, pause_rewrite as pr, rework
from server_src import lift

NOW = 1795392000.0      # a fixed made-up moment
DAY = __import__("datetime").datetime.fromtimestamp(NOW).strftime("%Y-%m-%d")
TEXT = "привіт, звіт буде в четверь до обіду. дані від вас прийшли вчора"
GOOD = "привіт, звіт буде в четвер до обіду. дані від вас прийшли вчора"


class Ready(unittest.TestCase):
    def test_needs_a_sentence_and_six_words(self):
        self.assertEqual(pr.ready("ок, дякую"), "short")
        self.assertEqual(pr.ready("so I was thinking we could maybe meet"), "no sentence")
        self.assertEqual(pr.ready("Ok. Fine. Sure. Yes, we can meet then"), "no sentence")   # no sentence of 3+ words yet
        self.assertEqual(pr.ready("Sure, I'll send the notes tonight. Talk on"), "")
        self.assertEqual(pr.ready(TEXT), "")
        self.assertEqual(pr.ready("слово " * 200 + "."), "long")


class Marks(unittest.TestCase):
    def test_changed_words_in_utf16(self):
        m = pr.marks(TEXT, GOOD)
        self.assertEqual(len(m), 1)
        at, n = m[0]
        self.assertEqual(GOOD.encode("utf-16-le")[at * 2:(at + n) * 2].decode("utf-16-le"), "четвер")

    def test_emoji_counts_two_units(self):
        m = pr.marks("ok 👍 see you tomorow then", "ok 👍 see you tomorrow then")
        self.assertEqual(m, [[len("ok 👍 see you ".encode("utf-16-le")) // 2, 8]])

    def test_inserted_words_are_marked(self):
        self.assertEqual(pr.marks("send it tonight please", "send it over tonight please"), [[8, 4]])


class Run(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(); self.data = Path(self.tmp.name)

    def tearDown(self): self.tmp.cleanup()

    def ask(self, out, by="haiku", cached=False):
        return mock.Mock(return_value={"text": out, "by": by, "ms": 640, **({"cached": True} if cached else {})})

    def test_keeps_a_close_rewrite_and_charges_the_day(self):
        a = self.ask(GOOD)
        r = pr.run(TEXT, 0.5, a, data=self.data, now=NOW)
        a.assert_called_once_with(TEXT)
        self.assertEqual(r["text"], GOOD); self.assertEqual(len(r["marks"]), 1); self.assertGreater(r["usd"], 0)
        spent = json.loads((self.data / "backoffice/spend.json").read_text())[DAY]   # the one ledger
        self.assertAlmostEqual(spent, r["usd"], places=6)
        self.assertLess(spent, 0.001)            # Haiku: well under a tenth of a cent a call

    def test_not_ready_asks_nothing(self):
        a = self.ask(GOOD)
        self.assertEqual(pr.run("ок, дякую", 0.5, a, data=self.data, now=NOW), {"skip": "short"})
        a.assert_not_called()

    def test_cap_counts_the_back_office_too(self):
        (self.data / "backoffice").mkdir()
        (self.data / "backoffice/spend.json").write_text(json.dumps({DAY: 0.49999}))
        a = self.ask(GOOD)
        self.assertEqual(pr.run(TEXT, 0.5, a, data=self.data, now=NOW), {"skip": "cap"})
        a.assert_not_called()
        self.assertEqual(pr.run(TEXT, 1.0, a, data=self.data, now=NOW)["text"], GOOD)   # a higher cap: it asks
        import voice_claude
        self.assertGreater(voice_claude.spent(self.data, NOW), 0.49999)   # the voice cleanup's cap sees this spend too

    def test_drops_same_far_local_and_tick(self):
        for out, by, why in ((TEXT, "haiku", "same"), ("Зовсім інше повідомлення без його слів тут.", "haiku", "far"),
                             (GOOD, "local", "none"), ("", "haiku", "none")):
            self.assertEqual(pr.run(TEXT, 0.5, self.ask(out, by), data=self.data, now=NOW), {"skip": why}, out)

    def test_cached_answer_is_not_charged(self):
        pr.run(TEXT, 0.5, self.ask(GOOD, cached=True), data=self.data, now=NOW)
        self.assertFalse((self.data / "backoffice/spend.json").exists())


class Polish(unittest.TestCase):
    def test_polish_is_a_rework_command_and_tick_is_dropped(self):
        self.assertIn("polish", rework.COMMANDS)
        self.assertFalse(rework.kept(TEXT, "✓", "polish"))
        self.assertFalse(rework.kept("meet at 15:00 tomorrow, ok?", "meet tomorrow, ok?", "polish"))   # a time dropped
        self.assertTrue(rework.kept(TEXT, GOOD, "polish"))


class Gate(unittest.TestCase):
    def test_off_by_default_and_never_on(self):
        self.assertEqual(cloud.OWNERS["pause_rewrite"], ("pauseRewrite",))
        self.assertIs(cloud.DEFAULTS["pauseRewrite"], False)
        self.assertIn("pauseRewrite", cloud.NEVER_ON)
        live = {"connect": {"provider": "cli"}}
        self.assertFalse(cloud.allowed("pause_rewrite", live))
        self.assertFalse(cloud.allowed("pause_rewrite", {**live, "rework": True, "backOffice": True}))   # its own switch only
        self.assertTrue(cloud.allowed("pause_rewrite", {**live, "pauseRewrite": True}))

    def route(self, st, ask):
        """server.pause_rewrite from its source with stand-ins: importing server would load the local model."""
        import types
        tmp = tempfile.TemporaryDirectory(); self.addCleanup(tmp.cleanup)
        ns = lift("pause_rewrite", settings_load=lambda: st, claude_on=lambda f, s: cloud.allowed(f, s),   # online, as far as this test goes
                  who=types.SimpleNamespace(hint=lambda req, task: "Chat with: Made Up Person\n"), DATA=Path(tmp.name))
        with mock.patch.object(rework, "rework", ask): return ns["pause_rewrite"]

    def test_route_off_sends_nothing(self):
        rw = mock.Mock()
        self.assertEqual(self.route({"connect": {"provider": "cli"}}, rw)({"text": TEXT}), {"skip": "off"})
        rw.assert_not_called()

    def test_route_on_uses_the_rework_path_with_haiku(self):
        rw = mock.Mock(return_value={"text": GOOD, "by": "haiku", "ms": 700})
        st = {"connect": {"provider": "cli"}, "pauseRewrite": True, "backOfficeCap": 0.5}
        fn = self.route(st, rw)
        with mock.patch.object(rework, "rework", rw):
            r = fn({"text": TEXT, "app": "Slack"})
        self.assertEqual(r["text"], GOOD)
        a, k = rw.call_args
        self.assertEqual((a[0], a[1], k["model"], k["local"], k["hint"]), (TEXT, "polish", "haiku", None, "Chat with: Made Up Person\n"))

if __name__ == "__main__":
    unittest.main()

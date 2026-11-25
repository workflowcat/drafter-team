"""The Claude back office (engine/backoffice.py): the jobs read local files, ask in batches, store results, stay under
the daily cap and never send an item twice. Made-up rows in a temporary folder; a stand-in ask, no `claude`, no network.

    .venv/bin/python -B tests/test_backoffice.py
"""
import json, sys, tempfile, time, unittest
from pathlib import Path
from unittest import mock

ENGINE = Path(__file__).resolve().parent.parent / "engine"
sys.path.insert(0, str(ENGINE))
import backoffice as bo

NOW = time.mktime((2026, 11, 17, 21, 0, 0, 0, 0, -1))


def jl(path, rows):
    path.write_text("".join(json.dumps(r, ensure_ascii=False) + "\n" for r in rows))


class Fake:
    """Answers by job, from the prompt's own numbered items; counts calls and charges a fixed price."""
    def __init__(self, usd=0.01): self.calls, self.usd = [], usd

    def __call__(self, prompt, tier, job):
        self.calls.append((job, tier, prompt))
        if job == "tags":
            n = sum(1 for line in prompt.split("Items")[1].splitlines() if line[:1].isdigit())
            return json.dumps([{"i": i, "topic": "launch plan", "project": "Orchard", "person": "Mira"} for i in range(n)]), self.usd
        if job == "grades":
            n = sum(1 for line in prompt.splitlines() if line[:1].isdigit() and "\tapp=" in line)
            return "```json\n" + json.dumps([{"i": i, "good": i % 2 == 0, "why": "fits"} for i in range(n)]) + "\n```", self.usd
        if job == "calls":
            return json.dumps({"summary": "They agreed on the pilot.", "decisions": ["pilot in March"],
                               "next_steps": [{"who": "Andrii", "what": "send the plan", "when": "Friday"}], "said": []}), self.usd
        if job == "people":
            return json.dumps({"role": "designer", "company": "Orchard", "now": ["the pilot"], "open": [], "facts": []}), self.usd
        if job == "snippets":
            return json.dumps([{"cue": ";addr", "text": "12 Example Street", "seen": 4}]), self.usd
        if job == "review":
            return "## Open promises\n- send the plan to Mira", self.usd
        return None, 0.0


class BackOffice(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(); self.d = Path(self.tmp.name)
        t = NOW - 3600
        jl(self.d / "typed.jsonl", [{"t": t + i, "app": "Telegram", "text": f"made-up line {i} about the orchard pilot", "context": ""} for i in range(50)]
           + [{"t": t + 99, "app": "Notes", "text": "⟦drafter-test⟧ never sent", "context": ""}])
        jl(self.d / "takes.jsonl", [{"t": t + 200, "app": "Mail", "text": "a made-up voice note", "id": "x", "audio": "", "secs": 2.0, "loud": False}])
        jl(self.d / "clipboard.jsonl", [{"t": NOW - 30 * 86400, "app": "Safari", "text": "an old copy", "rich": False}])
        jl(self.d / "accepted.jsonl", [{"t": t + i, "app": "Telegram", "text": " the pilot", "before": "made-up line", "ghost_len": 2, "src": "local"} for i in range(5)])
        call = self.d / "calls" / "2026-11-17T10-00-00Z"; call.mkdir(parents=True)
        (call / "transcript.txt").write_text("me: made-up words about a pilot plan. " * 20)
        (call / "meta.json").write_text(json.dumps({"call": True, "app": "Zoom", "started": NOW - 7200}))
        (self.d / "entities.json").write_text(json.dumps({"records": [{"kind": "project", "name": "Orchard", "heat": 3},
                                                                     {"kind": "person", "name": "Hidden", "private": True}]}))
        (self.d / "promises.json").write_text(json.dumps({"rows": [{"what": "send the plan", "person": "Mira", "due": NOW, "done": False}]}))
        self.st = {"backOffice": True, "backOfficeCap": 1.0}

    def tearDown(self): self.tmp.cleanup()

    def run_(self, jobs, fake, st=None, now=NOW, **kw):
        return bo.run(jobs, st=st or self.st, data=self.d, ask=fake, now=now, force=True, **kw)

    def test_tags_batch_store_and_never_twice(self):
        f = Fake()
        r = self.run_(["tags"], f)
        self.assertEqual(len(f.calls), 2)                     # 51 items -> batches of 40 and 11; the test row is out
        tags = json.loads((self.d / "backoffice/tags.json").read_text())
        self.assertEqual(len(tags), 51)
        self.assertEqual(r["jobs"]["tags"]["tagged"], 51)
        self.assertNotIn("drafter-test", "".join(p for _, _, p in f.calls))
        self.assertIn("Orchard", f.calls[0][2]); self.assertNotIn("Hidden", f.calls[0][2])   # private names never go
        self.assertEqual(f.calls[0][1], "haiku")
        self.run_(["tags"], f)
        self.assertEqual(len(f.calls), 2)                     # nothing new: nothing sent

    def test_cap_stops_before_passing_it(self):
        f = Fake(usd=0.30)
        r = self.run_(["tags", "calls", "grades"], f, st={"backOffice": True, "backOfficeCap": 0.5})
        self.assertTrue(r["capped"])
        self.assertLessEqual(len(f.calls), 2)
        self.assertLessEqual(r["today"], 0.61)
        spend = json.loads((self.d / "backoffice/spend.json").read_text())
        self.assertIn("2026-11-17", spend)

    def test_cache_by_prompt(self):
        f = Fake()
        o = bo.Office(self.d, cap=1, ask=f, now=NOW)
        a = o.ask("same prompt", "review"); b = o.ask("same prompt", "review")
        self.assertEqual(a, b); self.assertEqual(len(f.calls), 1); self.assertEqual(o.report["cached"], 1)

    def test_calls_cleaned_once(self):
        f = Fake()
        self.run_(["calls"], f)
        out = json.loads((self.d / "backoffice/calls/2026-11-17T10-00-00Z.json").read_text())
        self.assertEqual(out["decisions"], ["pilot in March"]); self.assertEqual(out["app"], "Zoom")
        self.assertEqual(f.calls[0][1], "sonnet")
        self.run_(["calls"], f)
        self.assertEqual(len(f.calls), 1)

    def test_grades_pair_ghost_with_sent_line(self):
        f = Fake()
        r = self.run_(["grades"], f)
        rows = [json.loads(l) for l in (self.d / "backoffice/ghost-grades.jsonl").read_text().splitlines()]
        self.assertEqual(len(rows), 5); self.assertEqual(r["jobs"]["grades"]["graded"], 5)
        self.assertTrue(all(r["sent"].startswith("made-up line") for r in rows))
        self.assertEqual({r["good"] for r in rows}, {True, False})
        self.run_(["grades"], f)
        self.assertEqual(len(f.calls), 1)                     # graded rows are not sent again

    def test_people_needs_sources_and_cards_new_ones(self):
        f = Fake()
        with mock.patch.object(bo, "source_items", return_value=[]):
            r = self.run_(["people"], f)
        self.assertIn("skipped", r["jobs"]["people"]); self.assertEqual(f.calls, [])
        items = [{"id": f"mail:{i}", "src": "mail", "t": NOW - 1000 - i, "title": "Pilot", "who": [{"name": "Mira", "email": "m@example.com"}],
                  "mine": i % 2 == 0, "text": "made-up mail text", "chat": "pilot"} for i in range(4)]
        with mock.patch.object(bo, "source_items", return_value=items):
            self.run_(["people"], f); self.run_(["people"], f)
        self.assertEqual(len(f.calls), 1)
        card = json.loads((self.d / "backoffice/people.json").read_text())["Mira"]
        self.assertEqual(card["role"], "designer"); self.assertEqual(len(card["from"]), 4)

    def test_review_weekly_with_promises_and_unanswered(self):
        f = Fake()
        items = [{"id": "beeper:c:1", "src": "beeper", "t": NOW - 2 * 86400, "title": "Mira", "who": [{"name": "Mira"}], "mine": False, "chat": "c", "text": "made-up"}]
        with mock.patch.object(bo, "source_items", return_value=items):
            self.run_(["tags", "review"], f)
        md = list((self.d / "backoffice").glob("review-*.md"))
        self.assertEqual(len(md), 1)
        prompt = f.calls[-1][2]
        self.assertIn("send the plan", prompt); self.assertIn("unanswered", prompt); self.assertIn("Orchard", prompt)
        with mock.patch.object(bo, "source_items", return_value=items):
            r = self.run_(["review"], f, now=NOW + 86400)
        self.assertIn("skipped", r["jobs"]["review"])

    def test_snippets_weekly(self):
        f = Fake()
        self.run_(["snippets"], f); self.run_(["snippets"], f)
        self.assertEqual(len(f.calls), 1)
        ideas = json.loads((self.d / "backoffice/snippet-ideas.json").read_text())["ideas"]
        self.assertEqual(ideas[0]["cue"], ";addr")

    def test_dry_run_sends_nothing_and_estimates(self):
        f = Fake()
        r = self.run_(None, f, dry=True)
        self.assertEqual(f.calls, []); self.assertGreater(r["estimate"], 0)
        self.assertFalse((self.d / "backoffice/last.json").exists())

    def test_off_sends_nothing(self):
        f = Fake()
        with mock.patch.object(bo, "allowed", return_value=False):
            r = bo.run(None, st={"backOffice": False}, data=self.d, ask=f, now=NOW)
        self.assertEqual(r, {"skipped": "off or offline"}); self.assertEqual(f.calls, [])

    def test_parse_json(self):
        self.assertEqual(bo.parse_json('Here: [{"i": 0}] done'), [{"i": 0}])
        self.assertEqual(bo.parse_json('```json\n{"a": 1}\n```'), {"a": 1})
        self.assertIsNone(bo.parse_json("no json"))

    def test_estimate_prices(self):
        self.assertAlmostEqual(bo.estimate("x" * 35000, "tags"), (10000 * 0.10 + 1500 * 0.50) / 1e6)


if __name__ == "__main__":
    unittest.main()

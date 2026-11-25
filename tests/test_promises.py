"""Promises (engine/promises.py): spotting promises in made-up sent lines, their due times, the store and the
offer. Made-up lines only; a temporary folder, never data/.

    .venv/bin/python -B tests/test_promises.py
"""
import json, sys, tempfile, unittest
from datetime import datetime, timedelta
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "engine"))
import promises as P

# a fixed "now": Tuesday 17 November 2026, 14:00 local time
NOW = datetime(2026, 11, 17, 14, 0).timestamp()


def at(days, hour):
    return round((datetime(2026, 11, 17, hour, 0) + timedelta(days=days)).timestamp())


# (line, what, due) for promises; due None = not checked
POSITIVE = [
    ("I'll send it tomorrow", "", at(1, 10)),
    ("will share the deck", "the deck", round(NOW + 86400)),
    ("I'll get back to you by Friday", "getting back to you", at(3, 10)),
    ("I will send the contract on Monday", "the contract", at(6, 10)),
    ("ok, I'll forward the invoice tonight", "the invoice", at(0, 18)),
    ("I'm going to share the slides next week", "the slides", at(6, 10)),
    ("Sure! I'll send you the link in 2 hours.", "the link", round(NOW + 7200)),
    ("We'll send the draft in 3 days", "the draft", round(NOW + 3 * 86400)),
    ("I’ll just email the report today", "the report", at(0, 18)),
    ("Let me send you the budget tomorrow", "the budget", at(1, 10)),
    ("завтра скину", "", at(1, 10)),
    ("надішлю договір в понеділок", "договір", at(6, 10)),
    ("скину посилання ввечері", "посилання", at(0, 18)),
    ("Окей, перешлю рахунок через 2 години", "рахунок", round(NOW + 7200)),
    ("поділюсь презентацією наступного тижня", "презентацією", at(6, 10)),
    ("я передзвоню в четвер", "дзвінок", at(2, 10)),
    ("відправлю макет у пʼятницю", "макет", at(3, 10)),
    ("Добре, підготую кошторис до середи", "кошторис", at(1, 10)),
    ("дам знати завтра", "відповідь", at(1, 10)),
    ("гляну документ сьогодні", "документ", at(0, 18)),
    ("скину тобі файл через 3 дні", "файл", round(NOW + 3 * 86400)),
    ("I'll check the numbers on Sunday", "the numbers", at(5, 10)),
]

NEGATIVE = [
    "will you send the deck tomorrow?",
    "I won't send it today",
    "I will not share the slides",
    "he will send the contract tomorrow",
    "she'll forward the invoice tonight",
    "they will get back to you by Friday",
    "Claude: I'll send the deck tomorrow",
    "Claude: завтра скину",
    "скинеш посилання?",
    "чи скину я це завтра",
    "не скину сьогодні, вибач",
    "він надішле договір в понеділок",
    "можливо скину ввечері",
    "maybe I'll send it later",
    "can you share the deck tomorrow",
    "thanks for the deck",
    "дякую, все отримав",
    "the meeting is on Friday",
    "I sent the contract yesterday",
    "надіслав договір вчора",
    "скинь посилання будь ласка",
    "I'll send the deck tomorrow ⟦drafter-test⟧",
    "we'll see",
]


class Detect(unittest.TestCase):
    def test_promises_and_due_times(self):
        for line, what, due in POSITIVE:
            with self.subTest(line=line):
                got = P.detect(line, NOW)
                self.assertEqual(len(got), 1, got)
                self.assertEqual(got[0]["what"], what)
                if due is not None: self.assertEqual(got[0]["due"], due)
                self.assertEqual(got[0]["lang"], P.lang_of(line))

    def test_no_promise(self):
        for line in NEGATIVE:
            with self.subTest(line=line):
                self.assertEqual(P.detect(line, NOW), [])

    def test_many_lines(self):
        self.assertGreaterEqual(len(POSITIVE) + len(NEGATIVE), 30)

    def test_tonight_after_six_is_soon(self):
        late = datetime(2026, 11, 17, 21, 0).timestamp()
        self.assertEqual(P.detect("скину посилання ввечері", late)[0]["due"], round(late + 7200))


class Store(unittest.TestCase):
    def setUp(self):
        self.d = tempfile.TemporaryDirectory(); self.dir = Path(self.d.name)
        self.book = P.Book(self.dir / "promises.json")

    def tearDown(self): self.d.cleanup()

    def found(self, line, now=NOW): return P.detect(line, now)

    def test_add_dedupe_and_open(self):
        r = self.book.add(self.found("will share the deck"), chat="c1", person="p1", app="Beeper", now=NOW)
        self.assertEqual(len(r), 1)
        self.assertEqual(self.book.add(self.found("I'll send the deck tomorrow"), chat="c1", now=NOW + 3600), [])
        self.assertEqual(len(self.book.add(self.found("I'll send the deck tomorrow"), chat="c2", now=NOW + 3600)), 1)
        self.assertEqual(len(self.book.add(self.found("I'll send the deck"), chat="c1", now=NOW + 3 * 86400)), 1)
        rows = self.book.open(NOW + 3 * 86400)
        self.assertEqual(len(rows), 3)
        self.assertGreaterEqual(rows[0]["t"], rows[-1]["t"])
        self.assertTrue(all(r["overdue"] for r in rows[1:]))
        row = json.loads((self.dir / "promises.json").read_text())["rows"][0]
        self.assertEqual(set(row) - {"lang"}, {"id", "t", "due", "what", "phrase", "chat", "person", "app", "done"})

    def test_done_drop_and_cap(self):
        for i in range(P.MAX_OPEN + 5):
            self.book.add([{"what": f"thing{i}", "due": NOW, "phrase": "x", "lang": "en"}], chat="c", now=NOW + i)
        rows = self.book.open(NOW)
        self.assertEqual(len(rows), P.MAX_OPEN)
        self.assertNotIn("thing0", {r["what"] for r in rows})
        self.assertTrue(self.book.done(rows[0]["id"]))
        self.assertFalse(self.book.done(rows[0]["id"]))
        self.assertTrue(self.book.drop(rows[1]["id"]))
        self.assertEqual(len(self.book.open(NOW)), P.MAX_OPEN - 2)

    def test_test_rows_never_kept(self):
        self.assertEqual(self.book.add([{"what": "deck", "due": NOW, "phrase": "deck ⟦drafter-test⟧"}], chat="c"), [])

    def test_due_for_chat(self):
        self.book.add(self.found("will share the deck tomorrow"), chat="c1", now=NOW)
        self.assertIsNone(self.book.due("c1", NOW + 60))          # just sent: not offered yet
        self.assertIsNone(self.book.due("c1", NOW + 3600))        # due in 19 h: not yet
        self.assertIsNotNone(self.book.due("c1", at(1, 0)))       # 10 h before: due soon
        self.assertIsNone(self.book.due("c2", at(1, 12)))         # another chat
        self.assertIsNone(self.book.due(None, at(1, 12)))


class Offer(unittest.TestCase):
    def setUp(self):
        self.d = tempfile.TemporaryDirectory(); self.dir = Path(self.d.name)

    def tearDown(self): self.d.cleanup()

    def test_saved_link_then_clipboard_then_followup(self):
        row = {"what": "the deck", "lang": "en", "phrase": "will share the deck"}
        self.assertEqual(P.offer(row, self.dir), ("Following up on the deck - ", "followup"))
        clips = [{"t": 1, "text": "https://example.com/files/pitch-deck-v2", "kind": "link"},
                 {"t": 2, "text": "some copied words about a deck"},
                 {"t": 3, "text": "https://example.com/deck ⟦drafter-test⟧"}]
        (self.dir / "clipboard.jsonl").write_text("\n".join(json.dumps(c) for c in clips) + "\n")
        self.assertEqual(P.offer(row, self.dir), ("https://example.com/files/pitch-deck-v2", "link"))
        (self.dir / "snippets.json").write_text(json.dumps({";deck": "https://example.com/our-deck", ";mail": "a@example.com"}))
        self.assertEqual(P.offer(row, self.dir), ("https://example.com/our-deck", "link"))

    def test_ukrainian_followup_and_case_forms(self):
        row = {"what": "договір", "lang": "uk", "phrase": "надішлю договір"}
        self.assertEqual(P.offer(row, self.dir), ("Повертаюсь щодо договір - ", "followup"))
        (self.dir / "replacements.json").write_text(json.dumps({";договору": "https://example.com/contract"}))
        self.assertEqual(P.offer(row, self.dir), ("https://example.com/contract", "link"))
        self.assertEqual(P.followup({"what": "", "lang": "uk"}), "Повертаюсь, як обіцяв - ")


class Person(unittest.TestCase):
    def test_chat_person_and_private(self):
        import people, whom
        with tempfile.TemporaryDirectory() as d:
            names = Path(d) / "names.json"
            names.write_text(json.dumps({"entries": [
                {"id": "p-olena", "kind": "person", "uk": "Олена Коваль", "latin": "Olena Koval"},
                {"id": "p-secret", "kind": "person", "uk": "Тарас Бондар", "private": True}]}))
            pm = people.People(Path(d) / "people.json")
            pm.chats = {"c1": {"mine": ["a"], "who": ["Olena Koval"]}, "c2": {"mine": ["a"], "who": ["Тарас Бондар"]},
                        "c3": {"mine": ["a"], "who": ["Olena Koval", "Someone Else"], "group": True}}
            w = whom.Who(pm, names)
            self.assertEqual(w.person("c1"), "p-olena")
            self.assertEqual(w.display("p-olena"), "Олена Коваль")
            self.assertIsNone(w.person("c2"))
            self.assertIsNone(w.person("c3"))
            self.assertIsNone(w.person(None))


if __name__ == "__main__":
    unittest.main()

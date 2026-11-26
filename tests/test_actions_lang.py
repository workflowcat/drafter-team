"""Action prompts follow the line's language: an English line sends no Cyrillic to the model, a Ukrainian line keeps
its Ukrainian instructions. A fake `ask` stands in for the model; no model runs.

.venv/bin/python -B tests/test_actions_lang.py
"""
import importlib.util, json, os, re, sys, tempfile, unittest
from datetime import datetime, timedelta
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
os.environ["DRAFTER_LOCAL"] = str(Path(tempfile.mkdtemp()) / "none.json")   # no real config: neutral defaults
sys.path.insert(0, str(ROOT / "actions"))
sys.path.insert(0, str(ROOT / "engine"))
import _ask


def load(name):
    spec = importlib.util.spec_from_file_location("action_" + name, ROOT / "actions" / f"{name}.py")
    m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
    return m


calendar, reminder = load("calendar_event"), load("reminder")
CYR = re.compile(r"[Ѐ-ӿ]")


class Fake:
    """Records every prompt and answers with the given text."""
    def __init__(self, answer): self.answer, self.prompts = answer, []

    def __call__(self, prompt):
        self.prompts.append(prompt); return self.answer


def tomorrow(h, m=0):
    d = datetime.now().date() + timedelta(1)
    return datetime(d.year, d.month, d.day, h, m)


class HelperTests(unittest.TestCase):
    def test_is_cyrillic(self):
        self.assertTrue(_ask.is_cyrillic("створи зустріч"))
        self.assertTrue(_ask.is_cyrillic("meet Мілу"))
        self.assertFalse(_ask.is_cyrillic("create a meeting"))
        self.assertFalse(_ask.is_cyrillic(""))
        self.assertFalse(_ask.is_cyrillic(None))

    def test_english_framing(self):
        p = _ask.prompt({"uk": "Витягни.", "en": "Take it."}, "save this", ["title", "text"])
        self.assertEqual(p, 'Take it.\nReply with JSON only using keys: title, text.\nText: "save this"')

    def test_ukrainian_framing(self):
        p = _ask.prompt({"uk": "Витягни.", "en": "Take it."}, "збережи це", ["title"])
        self.assertEqual(p, "Витягни.\nВідповідай лише JSON з ключами: title.\nТекст: «збережи це»")

    def test_plain_string_instruction_still_works(self):
        p = _ask.prompt("Take it.", "hello", ["a"])
        self.assertTrue(p.startswith("Take it.\nReply with JSON only"))

    def test_json_and_recovery(self):
        keys = ["title", "who"]
        self.assertEqual(_ask.fields(Fake('Sure: {"title": "Sync", "who": "Mila"}'), "x", "a", keys),
                         {"title": "Sync", "who": "Mila"})
        self.assertEqual(_ask.fields(Fake('{"title": "Sync", "who": null'), "x", "a", keys), {"title": "Sync", "who": ""})
        self.assertEqual(_ask.fields(Fake('{"title": "Project road'), "x", "a", keys), {"title": "Project road", "who": ""})
        self.assertEqual(_ask.fields(Fake("no json here"), "x", "a", keys), {})
        self.assertEqual(_ask.fields(Fake(""), "x", "a", keys), {})
        self.assertEqual(_ask.fields(Fake(None), "x", "a", keys), {})


class EnglishTests(unittest.TestCase):
    def assertEnglish(self, fake):
        self.assertEqual(len(fake.prompts), 1)
        self.assertIsNone(CYR.search(fake.prompts[0]), fake.prompts[0])
        self.assertIn("Reply with JSON only using keys:", fake.prompts[0])

    def test_calendar(self):
        line = "create a meeting with Mila tomorrow at 3pm"
        self.assertTrue(calendar.TRIGGER.search(line))
        fake = Fake('{"title": "Meeting", "who": "Mila"}')
        r = calendar.extract(line, fake)
        self.assertEnglish(fake)
        self.assertIn(f'Text: "{line}"', fake.prompts[0])
        self.assertEqual(r["fields"]["title"], "Meeting: Mila")
        self.assertEqual(r["fields"]["start"], tomorrow(15).isoformat())
        self.assertIsNone(CYR.search(r["chip"]), r["chip"])
        self.assertTrue(r["chip"].startswith("Calendar event «Meeting: Mila» · "))

    def test_calendar_truncated_json(self):
        fake = Fake('{"title": "Roadmap sync", "who": "Mila')
        r = calendar.extract("schedule a call with Mila tomorrow at 10", fake)
        self.assertEnglish(fake)
        self.assertEqual(r["fields"]["title"], "Roadmap sync: Mila")
        self.assertEqual(r["fields"]["start"], tomorrow(10).isoformat())

    def test_calendar_echo_falls_back(self):
        line = "create a meeting with Mila tomorrow at 3pm"
        r = calendar.extract(line, Fake(json.dumps({"title": line, "who": "Mila"})))
        self.assertEqual(r["fields"]["title"], "Meeting: Mila")
        r = calendar.extract("schedule a call tomorrow at 10", Fake('{"title": "schedule a call", "who": ""}'))
        self.assertEqual(r["fields"]["title"], "Call")

    def test_calendar_cyrillic_answer_on_english_line(self):
        r = calendar.extract("create a meeting with Mila tomorrow at 3pm", Fake('{"title": "Зустріч", "who": "Міла"}'))
        self.assertEqual(r["fields"]["title"], "Meeting")
        self.assertIsNone(CYR.search(r["chip"]))

    def test_calendar_no_time_stays_quiet(self):
        fake = Fake('{"title": "x"}')
        self.assertIsNone(calendar.extract("create a meeting with Mila", fake))
        self.assertEqual(fake.prompts, [])

    def test_reminder(self):
        line = "remind me tomorrow at 10 to call Alex"
        self.assertTrue(reminder.TRIGGER.search(line))
        fake = Fake('{"title": "Call Alex"}')
        r = reminder.extract(line, fake)
        self.assertEnglish(fake)
        self.assertEqual(r["fields"], {"title": "Call Alex", "due": tomorrow(10).isoformat()})
        self.assertTrue(r["chip"].startswith("Reminder «Call Alex» · "))
        self.assertIsNone(CYR.search(r["chip"]))

    def test_reminder_fallbacks(self):
        line = "remind me tomorrow at 10 to call Alex"
        for answer in ("", "nothing", '{"title": ""}', json.dumps({"title": line}), '{"title": "Подзвонити"}'):
            r = reminder.extract(line, Fake(answer))
            self.assertEqual(r["fields"]["title"], "Call Alex", answer)
        r = reminder.extract("remind me to send the invoice on friday", Fake(""))
        self.assertEqual(r["fields"]["title"], "Send the invoice")
        r = reminder.extract("remind me to send the contract", Fake('{"title": "Send the con'))
        self.assertEqual(r["fields"]["title"], "Send the con")
        self.assertIsNone(r["fields"]["due"])
        self.assertTrue(r["chip"].endswith("no time set"))


class UkrainianTests(unittest.TestCase):
    def assertUkrainian(self, fake, instruction):
        self.assertEqual(len(fake.prompts), 1)
        p = fake.prompts[0]
        self.assertTrue(p.startswith(instruction + "\nВідповідай лише JSON з ключами: "), p)
        self.assertNotIn("Reply with JSON", p)

    def test_calendar(self):
        line = "створи зустріч з Савою у вівторок о 15"
        self.assertTrue(calendar.TRIGGER.search(line))
        fake = Fake('{"title": "Зустріч", "who": "Сава"}')
        r = calendar.extract(line, fake)
        self.assertUkrainian(fake, calendar.INSTRUCTION["uk"])
        self.assertIn("називному відмінку", fake.prompts[0])
        self.assertIn(f"Текст: «{line}»", fake.prompts[0])
        start = datetime.fromisoformat(r["fields"]["start"])
        self.assertEqual((start.weekday(), start.hour, start.minute), (1, 15, 0))
        self.assertEqual(r["fields"]["title"], "Зустріч: Сава")
        self.assertTrue(r["chip"].startswith("Calendar event «Зустріч: Сава» · Tue "))

    def test_calendar_echo_falls_back(self):
        line = "створи зустріч з Савою у вівторок о 15"
        r = calendar.extract(line, Fake(json.dumps({"title": line, "who": "Сава"}, ensure_ascii=False)))
        self.assertEqual(r["fields"]["title"], "Зустріч: Сава")

    def test_reminder(self):
        line = "нагадай мені завтра о 10 подзвонити Мілі"
        self.assertTrue(reminder.TRIGGER.search(line))
        fake = Fake('{"title": "Подзвонити Мілі"}')
        r = reminder.extract(line, fake)
        self.assertUkrainian(fake, reminder.INSTRUCTION["uk"])
        self.assertEqual(r["fields"], {"title": "Подзвонити Мілі", "due": tomorrow(10).isoformat()})
        r = reminder.extract(line, Fake(""))                       # no answer: the line without the trigger, as before
        self.assertEqual(r["fields"]["title"], "мені завтра о 10 подзвонити Мілі")

    def test_instructions_unchanged(self):
        self.assertEqual(calendar.INSTRUCTION["uk"],
                         "З команди створити подію в календарі витягни коротку назву події (як у календарі, мовою команди) "
                         "і хто буде (імена в називному відмінку, через кому; порожньо, якщо нікого).")
        self.assertEqual(reminder.INSTRUCTION["uk"],
                         "З команди-нагадування витягни, про що нагадати: коротко, з дієсловом, мовою команди, без дати й часу.")
        for m in (calendar, reminder):
            self.assertIsNone(CYR.search(m.INSTRUCTION["en"]))


if __name__ == "__main__":
    unittest.main(verbosity=1)

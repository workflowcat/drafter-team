"""Instant replies (engine/instant.py): whose turn it is, the language, the parse. Made-up lines only.
.venv/bin/python -B tests/test_instant.py (from the main checkout)"""
import sys, unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "engine"))
import instant


class Turn(unittest.TestCase):
    def test_theirs_last(self):
        ok, last = instant.last_theirs("Вони: Привіт, зможеш у четвер о 15?")
        self.assertTrue(ok); self.assertIn("четвер", last)

    def test_mine_last(self):
        self.assertFalse(instant.last_theirs("Вони: Привіт\nЯ: Привіт, так")[0])

    def test_assistant_last(self):
        self.assertFalse(instant.last_theirs("Я: write a poem\nАсистент: Here is a poem")[0])

    def test_named_lines(self):
        self.assertTrue(instant.last_theirs("Олег: can we move the call to Friday?")[0])
        self.assertFalse(instant.last_theirs("Олег: can we move the call?\nЯ: sure")[0])

    def test_empty(self):
        self.assertFalse(instant.last_theirs("")[0])


class Lang(unittest.TestCase):
    def test_lang(self):
        self.assertEqual(instant.lang("Зможеш завтра?"), "uk")
        self.assertEqual(instant.lang("Can you do tomorrow?"), "en")
        self.assertEqual(instant.lang("Чи можеш глянути PR #12?"), "uk")


class Parse(unittest.TestCase):
    def test_three(self):
        raw = "Y: Так, давай о 15\nN: Ні, в четвер не вийде, вибач\nL: Можна я відпишу ввечері?"
        out = instant.parse(raw, "uk")
        self.assertEqual([o["shape"] for o in out], ["yes", "no", "later"])
        self.assertEqual(out[0]["label"], "так"); self.assertEqual(out[0]["text"], "Так, давай о 15")

    def test_order_and_noise(self):
        raw = "Sure, here they are:\n- L: Later today?\n1) Yes, works for me\n2. \"No, sorry, can't\"\n"
        out = instant.parse(raw, "en")
        self.assertEqual([o["shape"] for o in out], ["yes", "no", "later"])
        self.assertEqual(out[1]["text"], "No, sorry, can't")

    def test_duplicates_and_missing(self):
        out = instant.parse("Y: ok\nN: ok\nY: again", "en")
        self.assertEqual([o["text"] for o in out], ["ok"])

    def test_name_prefix_and_length(self):
        out = instant.parse("Y: Я: так, буду\nN: " + "ні " * 100, "uk")
        self.assertEqual(out[0]["text"], "так, буду")
        self.assertLessEqual(len(out[1]["text"]), instant.LINE_MAX)

    def test_nothing(self):
        self.assertEqual(instant.parse("", "en"), [])
        self.assertEqual(instant.parse("just text without tags", "en"), [])


class Prompt(unittest.TestCase):
    def test_messages(self):
        m = instant.messages("Вони: Будеш на зустрічі?", app="Beeper", name="Andrii")
        u = m[0]["content"]
        self.assertIn("Y:", u); self.assertIn("N:", u); self.assertIn("L:", u)
        self.assertIn("Будеш на зустрічі?", u)


if __name__ == "__main__":
    unittest.main(verbosity=1)

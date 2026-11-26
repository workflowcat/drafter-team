"""The keyboard line, the names reference and the screen-name smart fields (engine/whom.py). Every person, company and line here is made up."""
import json, sys, tempfile, unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "engine"))
import whom


def entry(eid, kind, uk="", latin="", short=(), forms=(), links=(), weight=1, **kw):
    e = {"id": eid, "kind": kind, "uk": uk, "latin": latin, "short": list(short), "forms": list(forms), "links": list(links),
         "weight": weight, "hidden": False, "sources": ["entities"]}
    e.update(kw)
    return e


STORE = {"entries": [
    entry("p1", "person", "Мирослава Квітка", "Myroslava Kvitka", short=["Мирося"], forms=["Мирослави", "Мирославі", "Мирославою", "Миросю"],
          links=["c1", "j1", "j2", "p2"]),
    entry("p2", "person", "Тарас Вербенко", "Taras Verbenko", forms=["Тараса", "Тарасу"]),
    entry("p3", "person", "Остап Секретний", "Ostap Sekretnyi", private=True),
    entry("p4", "person", "Злата Схована", "Zlata Skhovana", hidden=True),
    entry("p5", "person", "Ніна Тест", "Nina Test", sources=["private"]),
    entry("c1", "company", "Ромашка Лабс", "Romashka Labs", weight=5),
    entry("j1", "project", "Ліхтар", "Lantern", weight=3),
    entry("j2", "project", "Компас", "Compass", weight=1),
    entry("j3", "project", "Вежа", "Tower"),
    entry("a1", "person", "Ігор Двійко", "Ihor Dviiko"), entry("a2", "person", "Ігор Двійко", "Ihor Dviiko"),
]}

def names_file(d):
    p = Path(d) / "names.json"; p.write_text(json.dumps(STORE, ensure_ascii=False)); return p


class Keyboard(unittest.TestCase):
    def test_names(self):
        self.assertEqual(whom.kb_name("uk"), "Ukrainian")
        self.assertEqual(whom.kb_name("en-US"), "English")
        self.assertEqual(whom.kb_name(""), "")
        self.assertEqual(whom.kb_name(None), "")
        self.assertEqual(whom.kb_name("xx<script>"), "xxs")   # letters only, at most three

    def test_line_says_hint_and_mixed(self):
        line = whom.kb_line("uk")
        self.assertTrue(line.startswith("Keyboard now: Ukrainian."))
        self.assertIn("mixed messages stay mixed", line)
        self.assertIn("never change the language", whom.kb_line("en", "proofread"))
        self.assertIn("task decides", whom.kb_line("en", "rework"))
        self.assertEqual(whom.kb_line(""), "")


class Match(unittest.TestCase):
    def setUp(self): self.n = whom.Names(None).load(STORE)

    def test_full_name_either_script(self):
        self.assertEqual(self.n.match("Myroslava Kvitka")["id"], "p1")
        self.assertEqual(self.n.match("Мирослава  Квітка")["id"], "p1")
        self.assertEqual(self.n.match("Мирося")["id"], "p1")

    def test_words_of_a_label_in_a_longer_name(self):
        self.assertEqual(self.n.match("Kvitka Myroslava (Romashka)")["id"], "p1")

    def test_private_hidden_shared_and_one_word_names_nothing(self):
        for name in ("Остап Секретний", "Zlata Skhovana", "Nina Test", "Ігор Двійко", "Myroslava", "x"):
            self.assertIsNone(self.n.match(name), name)

    def test_group_title_names_a_project(self):
        self.assertEqual(self.n.match("Вежа", ("project", "company"))["id"], "j3")
        self.assertIsNone(self.n.match("Вежа"))


class WhoHint(unittest.TestCase):
    def test_hint_is_the_keyboard_line_only(self):
        with tempfile.TemporaryDirectory() as d:
            w = whom.Who(names_file(d))
            self.assertEqual(w.hint({"kb": "uk", "app": "Telegram", "context": "Мирослава Квітка: привіт"}), whom.kb_line("uk"))
            self.assertEqual(w.hint({}), "")
            self.assertEqual(w.stats["asked"], 2)

    def test_display_of_old_promise_rows(self):
        with tempfile.TemporaryDirectory() as d:
            w = whom.Who(names_file(d))
            self.assertEqual(w.display("p1"), "Мирослава Квітка")
            self.assertEqual(w.display("p3"), "")      # private
            self.assertEqual(w.display(None), "")


class SmartFields(unittest.TestCase):
    """Smart snippet fields (Who.fields): the name on their last line on screen, else gaps."""
    def who(self, d):
        return whom.Who(names_file(d))

    def test_screen_name(self):
        with tempfile.TemporaryDirectory() as d:
            f = self.who(d).fields("Telegram", "Олег Петренко: привіт")
            self.assertEqual(f["name"], "Олег Петренко"); self.assertEqual(f["first name"], "Олег")
            f = self.who(d).fields("Mail", "Олег Петренко: коли буде рахунок?\nЯ: завтра")
            self.assertEqual(f["name"], "Олег Петренко"); self.assertEqual(f["first name"], "Олег")
            self.assertEqual(f["company"], ""); self.assertEqual(f["last link to them"], "")

    def test_nothing_known(self):
        with tempfile.TemporaryDirectory() as d:
            f = self.who(d).fields("Notes", "просто текст без імен")
            self.assertEqual(set(f.values()), {""})

if __name__ == "__main__":
    unittest.main()

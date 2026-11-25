"""Who the chat is with and the keyboard line (engine/whom.py). Every person, company and line here is made up."""
import json, sys, tempfile, unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "engine"))
import people
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

CHAT_A = ["Мирося, глянь будь ласка макет до четверга", "скинув файл у теку по Ліхтарю", "Мирославі передам завтра",
          "ок, домовились на десяту ранку"]
OTHER_A = ["привіт, макет готовий майже весь", "дякую, подивлюсь увечері сьогодні"]


class FakePeople:
    def __init__(self, chats): self.chats = chats
    def chat_for(self, context):
        for cid, c in self.chats.items():
            if any(l in context for l in c["screen"]): return cid
        return None
    def info(self, chat):
        c = self.chats.get(chat)
        return c and {"who": c.get("who", []), "title": c.get("title", ""), "group": c.get("group", False), "mine": c.get("mine", [])}


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


class Card(unittest.TestCase):
    def test_block_holds_who_company_projects_forms_lines_under_cap(self):
        n = whom.Names(None).load(STORE)
        b = whom.card(n.match("Myroslava Kvitka"), n.by_id, CHAT_A)
        self.assertTrue(b.startswith("Chat with: Мирослава Квітка (Myroslava Kvitka)"))
        self.assertIn("Company: Ромашка Лабс", b)
        self.assertIn("Projects: Ліхтар, Компас", b)          # by weight; the linked person is not listed
        self.assertNotIn("Тарас", b)
        self.assertIn("He calls them: Мирося, Мирославі", b)
        self.assertIn("Name forms: Мирослави", b)
        self.assertIn("- ок, домовились на десяту ранку", b)
        self.assertLessEqual(len(b), whom.BLOCK_MAX)

    def test_long_lines_are_cut_to_the_cap(self):
        n = whom.Names(None).load(STORE)
        b = whom.card(n.match("Myroslava Kvitka"), n.by_id, ["довгий рядок " * 30] * 10, limit=300)
        self.assertLessEqual(len(b), 300)
        self.assertTrue(b.startswith("Chat with:"))


class WhoHint(unittest.TestCase):
    def test_beeper_chat_matched_and_fixed_per_chat(self):
        with tempfile.TemporaryDirectory() as d:
            fp = FakePeople({"chat-a": {"screen": OTHER_A, "who": ["Myroslava Kvitka"], "mine": list(CHAT_A)}})
            w = whom.Who(fp, names_file(d))
            ctx = "\n".join(OTHER_A)
            h = w.hint({"app": "Beeper Desktop", "context": ctx, "kb": "uk"})
            self.assertTrue(h.startswith("Keyboard now: Ukrainian."))
            self.assertIn("Chat with: Мирослава Квітка", h)
            fp.chats["chat-a"]["mine"].append("новий рядок після першого запиту")
            self.assertEqual(w.hint({"app": "Beeper Desktop", "context": ctx, "kb": "uk"}), h)   # same for the ttl
            self.assertEqual(w.stats["matched"], 2)

    def test_no_block_outside_beeper_or_unmatched_or_group(self):
        with tempfile.TemporaryDirectory() as d:
            fp = FakePeople({"chat-a": {"screen": OTHER_A, "who": ["Myroslava Kvitka"], "mine": CHAT_A},
                             "chat-g": {"screen": ["усі в групі пишуть тут щось"], "who": ["Myroslava Kvitka", "Taras Verbenko"], "group": True, "mine": CHAT_A},
                             "chat-u": {"screen": ["хтось невідомий пише тут"], "who": ["Невідома Людина"], "mine": CHAT_A}})
            w = whom.Who(fp, names_file(d))
            self.assertEqual(w.hint({"app": "Telegram", "context": "\n".join(OTHER_A)}), "")
            self.assertEqual(w.hint({"app": "Beeper", "context": "хтось невідомий пише тут"}), "")
            self.assertEqual(w.hint({"app": "Beeper", "context": "усі в групі пишуть тут щось"}), "")   # a group: no one person
            self.assertEqual(w.hint({"app": "Beeper", "context": "", "kb": "en"})[:22], "Keyboard now: English.")

    def test_group_title_gives_project_block(self):
        with tempfile.TemporaryDirectory() as d:
            fp = FakePeople({"chat-g": {"screen": ["усі в групі пишуть тут щось"], "who": ["A B", "C D"], "group": True, "title": "Вежа", "mine": []}})
            h = whom.Who(fp, names_file(d)).block("Beeper", "усі в групі пишуть тут щось")
            self.assertTrue(h.startswith("Group chat Вежа: about Вежа (project)"))

    def test_no_names_file_no_block(self):
        fp = FakePeople({"chat-a": {"screen": OTHER_A, "who": ["Myroslava Kvitka"], "mine": CHAT_A}})
        self.assertEqual(whom.Who(fp, "/nonexistent/names.json").block("Beeper", "\n".join(OTHER_A)), "")


class PeopleWho(unittest.TestCase):
    def test_note_who_keeps_their_names_and_title(self):
        c = {"mine": []}
        hist = [{"isSender": False, "senderName": "Myroslava  Kvitka"}, {"isSender": True, "senderName": "Me"},
                {"isSender": False, "senderName": "Myroslava Kvitka"}]
        people.note_who(c, hist, ("Myroslava Kvitka", False))
        self.assertEqual(c["who"], ["Myroslava Kvitka"]); self.assertEqual(c["title"], "Myroslava Kvitka"); self.assertNotIn("group", c)
        people.note_who(c, [{"isSender": True}])                         # only his lines: the names stay
        self.assertEqual(c["who"], ["Myroslava Kvitka"])
        people.note_who(c, [{"isSender": False, "senderName": "A B"}, {"isSender": False, "senderName": "C D"}])
        self.assertTrue(c["group"])

    def test_info_of_a_real_people_store(self):
        with tempfile.TemporaryDirectory() as d:
            p = people.People(Path(d) / "people.json")
            p.chats["x"] = {"mine": ["рядок один тут", "рядок два тут"], "key": "", "who": ["Myroslava Kvitka"]}
            i = p.info("x")
            self.assertEqual(i["who"], ["Myroslava Kvitka"]); self.assertFalse(i["group"]); self.assertEqual(len(i["mine"]), 2)
            self.assertIsNone(p.info("nope"))



class SmartFields(unittest.TestCase):
    """Smart snippet fields (Who.fields): a matched person, a screen name, gaps; private entries give nothing."""
    def who(self, d, chats):
        return whom.Who(FakePeople(chats), names_file(d))

    def test_matched_person(self):
        with tempfile.TemporaryDirectory() as d:
            w = self.who(d, {"a": {"screen": OTHER_A, "who": ["Myroslava Kvitka"],
                                   "mine": CHAT_A + ["ось чернетка https://example.test/doc/42."]}})
            f = w.fields("Beeper", "\n".join(OTHER_A))
            self.assertEqual(f["name"], "Мирослава Квітка")
            self.assertEqual(f["first name"], "Мирося")
            self.assertEqual(f["company"], "Ромашка Лабс")
            self.assertEqual(f["last link to them"], "https://example.test/doc/42")

    def test_private_gives_gaps(self):
        with tempfile.TemporaryDirectory() as d:
            w = self.who(d, {"a": {"screen": OTHER_A, "who": ["Ostap Sekretnyi"], "mine": CHAT_A}})
            f = w.fields("Beeper", "\n".join(OTHER_A))
            self.assertEqual(f["company"], ""); self.assertNotIn("Остап", f["name"])

    def test_screen_name_fallback(self):
        with tempfile.TemporaryDirectory() as d:
            w = self.who(d, {})
            f = w.fields("Mail", "Олег Петренко: коли буде рахунок?\nЯ: завтра")
            self.assertEqual(f["name"], "Олег Петренко"); self.assertEqual(f["first name"], "Олег")
            self.assertEqual(f["company"], ""); self.assertEqual(f["last link to them"], "")

    def test_nothing_known(self):
        with tempfile.TemporaryDirectory() as d:
            f = self.who(d, {}).fields("Notes", "просто текст без імен")
            self.assertEqual(set(f.values()), {""})

if __name__ == "__main__":
    unittest.main()

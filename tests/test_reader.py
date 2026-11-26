"""Reader check before sending (engine/reader.py). Made-up lines only; never the live data/.
    .venv/bin/python -B tests/test_reader.py"""
import sys, unittest
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "engine"))
import reader, words
from server_src import lift

LINES = (["я вже подивився на документи", "не знаю чи встигну сьогодні", "давай завтра після обіду",
          "рахунок надішлю завтра зранку", "тіма норм, шо там по проєкту", "i think the plan works",
          "привіт, як справи", "receive the invoice tomorrow"] * 6)


def W():
    w = words.Words()
    for l in LINES: w.add(l, rebuild=False)
    w.vocab = sorted(w.uni)
    return w


WORDS = W()
SYS = {"the", "plan", "think", "works", "receive", "invoice", "tomorrow", "hello"}


def pairs(text, keep=()):
    found, _ = reader.slips(text, WORDS, set(keep), SYS)
    return [(e["old"], e["new"]) for e in found]


class Slips(unittest.TestCase):
    def test_planted_slips(self):
        self.assertEqual(pairs("я вже подвиився на документи"), [("подвиився", "подивився")])
        self.assertEqual(pairs("рахунок надішлю звтра зранку"), [("звтра", "завтра")])
        self.assertEqual(pairs("i will recieve the invoice"), [("recieve", "receive")])

    def test_layout_and_join(self):
        self.assertEqual(pairs("ok ghbdsn як справи"), [("ghbdsn", "привіт")])
        self.assertEqual(pairs("я незнаю чи встигну"), [("незнаю", "не знаю")])

    def test_his_words_stay(self):
        self.assertEqual(pairs("тіма норм, шо там по проєкту"), [])
        self.assertEqual(pairs("рахунок звтра надішлю", keep={"звтра"}), [])   # a word the user took back
        self.assertEqual(pairs("Kyiv Mykola sqlite треба"), [])                 # names, new words: no target
        self.assertEqual(pairs("привіт як справи"), [])

    def test_case_kept(self):
        self.assertEqual(pairs("Подвиився на документи вже"), [("Подвиився", "Подивився")])

    def test_too_many_says_nothing(self):
        self.assertEqual(pairs("звтра подвиився рахнок документі встигнну"), [])

    def test_check_offsets_utf16(self):
        r = reader.check("👍 рахунок надішлю звтра", "", WORDS, set(), SYS)
        self.assertEqual(r["edits"][0]["old"], "звтра")
        self.assertEqual(r["edits"][0]["at"], len("👍 рахунок надішлю ".encode("utf-16-le")) // 2)
        self.assertEqual(r["fixed"], "👍 рахунок надішлю завтра")
        self.assertLess(r["ms"], 50)


class Asked(unittest.TestCase):
    CTX = "Я: привіт\nВони: коли буде рахунок за жовтень?"

    def test_open_question(self):
        self.assertEqual(reader.unanswered(self.CTX, "давай завтра після обіду"), "they asked about рахунок жовтень")

    def test_answered(self):
        self.assertEqual(reader.unanswered(self.CTX, "рахунок надішлю завтра"), "")
        self.assertEqual(reader.unanswered(self.CTX, "рахунки вже готові"), "")   # another form of the word

    def test_yes_no(self):
        ctx = "Вони: ти будеш на зустрічі завтра?"
        self.assertEqual(reader.unanswered(ctx, "так, буду"), "")
        self.assertTrue(reader.unanswered(ctx, "привіт").startswith("they asked about"))
        self.assertTrue(reader.unanswered("Вони: when is the demo?", "yes sure").startswith("they asked about"))

    def test_quiet_without_marks_or_after_his_reply(self):
        self.assertEqual(reader.unanswered("коли буде рахунок?", "привіт"), "")
        self.assertEqual(reader.unanswered("Вони: коли буде рахунок?\nЯ: завтра", "і ще одне"), "")
        self.assertEqual(reader.unanswered("Вони: дякую!", "будь ласка"), "")
        self.assertEqual(reader.unanswered("", "будь ласка"), "")


class Route(unittest.TestCase):
    """server.reader_check alone (taken from the source, no models, no live settings)."""
    def fn(self, settings):
        import tempfile
        ns = lift("reader_check", settings_load=lambda: settings, finisher=WORDS, DATA=Path(tempfile.mkdtemp()))
        return ns["reader_check"]

    def test_off_by_default(self):
        self.assertEqual(self.fn({})({"text": "рахунок надішлю звтра"}), {"edits": [], "ask": "", "src": "off"})

    def test_on(self):
        reader._kept.update(at=9e18, words=set())   # no live keep list
        r = self.fn({"readerCheck": True})({"text": "рахунок надішлю звтра", "context": "Вони: коли буде рахунок?"})
        self.assertEqual([e["new"] for e in r["edits"]], ["завтра"])
        self.assertEqual(r["ask"], "")


if __name__ == "__main__":
    unittest.main()

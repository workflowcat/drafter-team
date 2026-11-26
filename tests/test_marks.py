"""Edit mode marks (engine/marks.py). Made-up lines only; never the live data/.
    .venv/bin/python -B tests/test_marks.py"""
import sys, unittest
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "engine"))
import marks, words
from server_src import lift

LINES = (["я вже подивився на документи", "рахунок надішлю завтра зранку", "давай завтра після обіду",
          "i think the plan works", "receive the invoice tomorrow", "привіт як справи"] * 6)


def W():
    w = words.Words()
    for l in LINES: w.add(l, rebuild=False)
    w.vocab = sorted(w.uni)
    return w


WORDS = W()
SYS = {"the", "plan", "think", "works", "receive", "invoice", "tomorrow", "will", "is", "it", "a", "we", "this", "and"}


def run(text, context="", person=None):
    return marks.marks(text, context, person, WORDS, set(), SYS)["marks"]


def kinds(text, context=""):
    return [(m["kind"], m["old"], m["new"]) for m in run(text, context)]


VY_CTX = "Я: Добрий день, надішліть вам рахунок?\nВони: так, дякую\nЯ: Чи зручно вам завтра о десятій?\nЯ: Добрий день, ваш файл отримав"
TY_CTX = "Я: привіт, ти завтра будеш?\nВони: так\nЯ: скинь мені твій файл\nЯ: привіт, тобі зручно о десятій?"


class Typo(unittest.TestCase):
    def test_uk_and_en(self):
        self.assertIn(("typo", "звтра", "завтра"), kinds("рахунок надішлю звтра зранку"))
        self.assertIn(("typo", "recieve", "receive"), kinds("i will recieve the invoice"))

    def test_utf16_offsets(self):
        m = run("👍 рахунок надішлю звтра")[0]
        self.assertEqual(m["at"], len("👍 рахунок надішлю ".encode("utf-16-le")) // 2)
        self.assertEqual(m["len"], 5)
        self.assertLessEqual(len(m["why"]), 60)


class Unclear(unittest.TestCase):
    def test_doubled(self):
        self.assertIn(("unclear", "the the", "the"), kinds("we think the the plan works"))

    def test_long_sentence(self):
        s = ("я подивився всі документи які ти надіслав учора ввечері після зустрічі з командою, але деякі цифри "
             "в таблиці не сходяться з тими що ми обговорювали минулого тижня на дзвінку з клієнтом і бухгалтером")
        ms = [m for m in run(s) if m["kind"] == "unclear"]
        self.assertEqual(len(ms), 1)
        self.assertEqual((ms[0]["old"], ms[0]["new"]), (", але", ". Але"))
        self.assertIn("split", ms[0]["why"])

    def test_long_and(self):
        s = ("we looked at every file the team sent over last night after the call with the client, and the numbers in "
             "the second table do not match the ones we agreed on during the meeting last week")
        m = [m for m in run(s) if m["kind"] == "unclear"][0]
        self.assertEqual((m["old"], m["new"]), (", and t", ". T"))

    def test_space_before(self):
        self.assertIn(("unclear", " ,", ","), kinds("давай завтра , після обіду"))


class Tone(unittest.TestCase):
    def test_ty_to_vy(self):
        k = kinds("Добрий день, чи зручно тобі завтра? Скинь твій файл", VY_CTX)
        self.assertIn(("tone", "тобі", "вам"), k)
        self.assertIn(("tone", "твій", "ваш"), k)

    def test_vy_to_ty(self):
        self.assertIn(("tone", "вам", "тобі"), kinds("привіт, вам зручно о десятій?", TY_CTX))

    def test_greeting(self):
        self.assertIn(("tone", "привіт", "добрий день"), kinds("привіт, файл отримав", VY_CTX))
        self.assertIn(("tone", "Добрий день", "Привіт"), kinds("Добрий день, файл отримав", TY_CTX))

    def test_needs_evidence(self):
        one = "Я: Чи зручно вам завтра?\nВони: так"
        self.assertEqual([k for k in kinds("чи зручно тобі завтра", one) if k[0] == "tone"], [])
        self.assertEqual([k for k in kinds("чи зручно тобі завтра", "") if k[0] == "tone"], [])
        # no marks on screen: whose line is whose cannot be told
        self.assertEqual([k for k in kinds("чи зручно тобі завтра", "Чи зручно вам?\nваш файл тут") if k[0] == "tone"], [])

    def test_loud(self):
        calm = "Я: ок, завтра\nВони: супер\nЯ: файл отримав\nЯ: давай після обіду"
        k = kinds("супер!!! дякую! до завтра! 🎉🎉 🙂", calm)
        self.assertIn(("tone", "!!!", "!"), k)
        self.assertTrue(any(x[1] == "!" and x[2] == "." for x in k))


class Clean(unittest.TestCase):
    def test_no_false_marks(self):
        self.assertEqual(run("рахунок надішлю завтра зранку"), [])
        self.assertEqual(run("i think the plan works"), [])
        self.assertEqual(run("Добрий день, чи зручно вам завтра?", VY_CTX), [])
        self.assertEqual(run("привіт, ти завтра будеш?", TY_CTX), [])
        self.assertEqual(run("так так, дуже дуже добре"), [])
        self.assertEqual(run(""), [])


class Rank(unittest.TestCase):
    def test_order_and_overlaps(self):
        ms = [{"at": 10, "len": 5, "kind": "unclear", "score": 0.7, "old": "a", "new": "b"},
              {"at": 12, "len": 4, "kind": "typo", "score": 0.9, "old": "a", "new": "b"},
              {"at": 0, "len": 3, "kind": "tone", "score": 0.8, "old": "a", "new": "b"},
              {"at": 30, "len": 3, "kind": "unclear", "score": 0.5, "old": "a", "new": "b"}]
        r = marks.rank(ms)
        self.assertEqual([m["kind"] for m in r], ["typo", "tone", "unclear"])
        self.assertEqual([m["at"] for m in r], [12, 0, 30])

    def test_limit(self):
        ms = [{"at": i * 10, "len": 3, "kind": "typo", "score": 0.9, "old": "a", "new": "b"} for i in range(9)]
        self.assertEqual(len(marks.rank(ms)), 5)
        self.assertEqual(len(marks.rank(ms, limit=2)), 2)

    def test_mixed_text_fast(self):
        s = "привіт, вам зручно звтра? the the plan works !! " * 3
        r = marks.marks(s, TY_CTX, None, WORDS, set(), SYS)
        self.assertLessEqual(len(r["marks"]), 5)
        self.assertEqual(r["marks"][0]["kind"], "typo")
        self.assertLess(r["ms"], 20)


class Routes(unittest.TestCase):
    """/marks and /mystyle from engine/server.py, lifted out with stubs: local only, never Claude."""
    def fns(self, st):
        import time
        calls = []
        class NoCloud:
            def __getattr__(self, k): raise AssertionError("cloud touched: " + k)
        g = lift("edit_marks", "my_style", settings_load=lambda: st, finisher=WORDS, DATA=Path("/nonexistent"), time=time,
                 claude_worker=NoCloud(), claude_on=NoCloud(),
                 local_rewrite=lambda text, instr, notes="", layer=False: calls.append((text, instr, notes, layer)) or "інший текст")
        return g, calls

    def test_marks_route(self):
        import reader
        reader._kept.update(at=1e18, words=set())   # no data/ read
        g, _ = self.fns({})
        r = g["edit_marks"]({"text": "the the plan works", "context": ""})
        self.assertEqual([m["new"] for m in r["marks"]], ["the"])
        g, _ = self.fns({"editMarks": False})
        self.assertEqual(g["edit_marks"]({"text": "the the plan"})["marks"], [])

    def test_mystyle_local(self):
        g, calls = self.fns({"writingNote": "коротко"})
        r = g["my_style"]({"text": "Шановний пане, повідомляю що файл отримано.", "context": TY_CTX})
        self.assertEqual((r["text"], r["by"]), ("інший текст", "local"))
        self.assertEqual(calls[0][2], "коротко"); self.assertTrue(calls[0][3])   # the user's layer on
        self.assertIn("тобі зручно", calls[0][1])                     # the user's earlier lines to them as the voice
        g, calls = self.fns({"editMarks": False})
        self.assertEqual(g["my_style"]({"text": "x"})["text"], "")
        self.assertEqual(calls, [])


if __name__ == "__main__":
    unittest.main(verbosity=1)

import sys, unittest
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "engine"))
import words as w


def vocab():
    v = w.Words()
    lines = ["я скину документи завтра", "глянь документи по договору", "привіт, як справи", "можемо поговорити завтра",
             "send the draft tonight", "the idea is simple", "hello there, send it", "завтра о 15:00"]
    for _ in range(6):
        for l in lines: v.add(l, rebuild=False)
    v.vocab = sorted(v.uni)
    return v


class Fix(unittest.TestCase):
    def setUp(self): self.v = vocab()

    def test_typos(self):
        self.assertIsNone(self.v.fix("я скину докумн"))                          # the first unknown letter: wait one more
        self.assertIsNone(self.v.fix("я скину докумнт"))                         # the second unknown letter: still waits
        self.assertEqual(self.v.fix("я скину докумнти")["new"], "документи")     # a missed letter, then finished
        self.assertEqual(self.v.fix("можемо поговрити")["new"], "поговорити")
        self.assertEqual(self.v.fix("я напишу завтар")["new"], "завтра")          # two letters swapped
        self.assertEqual(self.v.fix("I will sned")["new"], "send")
        self.assertEqual(self.v.fix("send the drsft")["new"], "draft")
        self.assertIsNone(self.v.fix("the ideq"))                                  # "ide" starts his words: one more letter

    def test_layout(self):
        f = self.v.fix("ghbdsn")
        self.assertEqual((f["new"], f["kind"]), ("привіт", "layout uk"))
        self.assertEqual(self.v.fix("руддщ")["new"], "hello")

    def test_quiet(self):
        self.assertIsNone(self.v.fix("я скину доку"))           # a start of his word: the finisher's job
        self.assertIsNone(self.v.fix("глянь документи"))        # his word
        self.assertIsNone(self.v.fix("abc"))                    # too short
        self.assertIsNone(self.v.fix("файл v2_3"))              # digits and underscores
        self.assertIsNone(self.v.fix("я скину xyzw"))           # nothing near
        self.assertIsNone(self.v.fix("я скину "))               # no word being typed
        self.assertIsNone(self.v.fix("можемо поговр"))          # could be a new word yet

    def test_capital(self):
        self.assertEqual(self.v.fix("Завтар")["new"], "Завтра")
        self.assertEqual(self.v.fix("Завтар")["old"], "Завтар")


if __name__ == "__main__": unittest.main()

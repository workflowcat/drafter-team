"""engine/words.py, engine memory round (2026-11-17): tables holding one word become One; answers stay the same,
before and after more lines come in. Made-up lines only.

    .venv/bin/python -B tests/test_words_compact.py
"""
import random, sys, unittest
from collections import Counter
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "engine"))
import words as W

VOCAB = ("let me know what you think about the plan for tomorrow we can meet at noon "
         "дякую за відповідь можемо поговорити про проєкт завтра вранці Kyiv Drafter").split()


def lines(seed, n):
    r = random.Random(seed)
    return [" ".join(r.choice(VOCAB[: r.randint(3, len(VOCAB))]) for _ in range(r.randint(2, 9))) + "." for _ in range(n)]


PROBES = ["let me kn", "we can m", "дякую за ", "можемо пог", "the pl", "Kyi", "about the ", "meet at n", "x"]


def answers(w):
    return [(w.finish(p, 2, 0.6, 1), w.candidate(p), w.dist(p)) for p in PROBES]


class Compact(unittest.TestCase):
    def test_same_answers_and_counts(self):
        plain, small = W.Words(), W.Words()
        for l in lines(1, 400): plain.add(l, rebuild=False); small.add(l, rebuild=False)
        plain.vocab = sorted(plain.uni); small.vocab = sorted(small.uni)
        n = small.compact()
        self.assertGreater(n, 0)
        self.assertTrue(any(type(t) is W.One for t in small.tri.values()))
        self.assertEqual(answers(plain), answers(small))
        for l in lines(2, 200): plain.add(l); small.add(l)          # a One meets a second word: a Counter again
        self.assertEqual(answers(plain), answers(small))
        for name in ("tri", "bi", "case", "inner_case"):
            a, b = getattr(plain, name), getattr(small, name)
            self.assertEqual({k: dict(v) for k, v in a.items() if v}, {k: dict(v.items()) for k, v in b.items() if v})

    def test_one_reads_like_a_counter(self):
        o, c = W.One("так", 3), Counter({"так": 3})
        for f in (lambda t: list(t.items()), lambda t: list(t.values()), lambda t: list(t), len, bool,
                  lambda t: t["так"], lambda t: t["ні"], lambda t: t.get("ні", 0), lambda t: "так" in t,
                  lambda t: t.most_common(1), lambda t: t.most_common(2), lambda t: sum(t.values())):
            self.assertEqual(f(o), f(c))


if __name__ == "__main__":
    unittest.main()

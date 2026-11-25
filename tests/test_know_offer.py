"""Names from the pack are offered again with the selector on (2026-11-16): /health know.offered stayed 0 because
the only paths that offered a name (finish_with_source as the gate's fallback, the words-first path) were closed
while data/selector.json exists. words.know_only and the server's fallback after the model. Made-up names only.

    .venv/bin/python -B tests/test_know_offer.py
"""
import sys, threading, unittest
from collections import Counter
from pathlib import Path
from types import SimpleNamespace

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "engine"))
import know, words


def entry(name, heat=1, forms=(), kind="person"):
    return dict(name=name, kind=kind, tokens=[name], aliases=[], forms=list(forms), heat=heat, common=[], handles={})


def pack(*entries):
    p = know.Pack(); p.entries = list(entries); return p


def finisher(own=()):
    own = Counter(own)
    pre = Counter()
    for w, n in own.items():
        for k in range(1, len(w) + 1): pre[w[:k]] += n
    return SimpleNamespace(lock=threading.Lock(), own_folded=own, own_prefix=pre)


class KnowOnly(unittest.TestCase):
    def test_a_name_finishes(self):
        self.assertEqual(words.know_only(finisher(), "ask Zorvald", pack(entry("Zorvaldine", 5))), "ine")

    def test_nothing_without_a_pack_or_a_clear_name(self):
        self.assertEqual(words.know_only(finisher(), "ask Zorv", None), "")
        self.assertEqual(words.know_only(finisher(), "ask zorv", pack(entry("Zorvaldine"))), "")      # no capital
        self.assertEqual(words.know_only(finisher(), "ask Zo", pack(entry("Zorvaldine"), entry("Zolmira"))), "")

    def test_his_other_words_with_these_letters_win(self):
        # he writes other words starting with these letters and never the name: no offer
        self.assertEqual(words.know_only(finisher({"zorvex": 5, "zorvy": 4}), "ask Zor", pack(entry("Zorvaldine"))), "")


class Server(unittest.TestCase):
    def test_fallback_wired_with_the_selector(self):
        src = (ROOT / "engine/server.py").read_text()
        self.assertIn("words_mod.know_only(finisher, before, pack)", src)
        i = src.index("words_mod.know_only(finisher, before, pack)")
        self.assertIn("knowledge.offered += 1", src[i:i + 600])
        self.assertIn('"src": "know"', src[i:i + 600])


if __name__ == "__main__":
    unittest.main()

"""Round five (2026-11-14): the model stops as soon as the ghost can no longer change (engine/gatecore.py settled,
engine/model.py SETTLE). Made-up lines only.

    .venv/bin/python -B tests/test_settle.py
"""
import sys, unittest
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "engine"))
import gatecore


def toks(pieces):
    """[(token text, p)] -> recorded tokens: [text so far, p, p2]"""
    out, text = [], ""
    for piece, p in pieces:
        text += piece; out.append([text, p, 0.0])
    return out


def run(pieces, settle, **k):
    """The loop's own stop (model.complete_gated, tail on) on recorded tokens, with or without the settled stop.
    -> (ghost, tokens used)"""
    k = dict(dict(more=0.5, max_words=3, grow_bar=0.05, grow_words=6, min_letters=5, tail=0.2, tail_words=8), **k)
    seen = []
    for tok in toks(pieces):
        seen.append(tok)
        text, p = tok[0], tok[1]
        now, _ = gatecore.shape(seen, **k)
        if settle and gatecore.settled(text, now, k["min_letters"]): break
        short = gatecore.letters(gatecore.extend(seen, gatecore.next_word(text), k["more"], k["max_words"])) < k["min_letters"]
        if p < (min(k["more"], k["grow_bar"], k["tail"]) if short else min(k["more"], k["tail"])): break
    return gatecore.shape(seen, **k)[0], len(seen)


class Settled(unittest.TestCase):
    def test_turned_down_word_settles(self):
        # "meeting" is sure, " tomorrow" is under the tail bar and whole (a space follows): nothing can be added
        self.assertTrue(gatecore.settled(" meeting tomorrow ", " meeting ", 5))

    def test_word_still_being_written_does_not(self):
        self.assertFalse(gatecore.settled(" meeting tomor", " meeting ", 5))

    def test_short_ghost_never_settles(self):
        # under min letters: grow may still reach it with the next word
        self.assertFalse(gatecore.settled(" a big ", " a ", 5))
        self.assertTrue(gatecore.settled(" a big ", " a ", 0))

    def test_sentence_end_after_ghost(self):
        self.assertTrue(gatecore.settled(" see you soon.", " see you ", 5))

    def test_ghost_not_in_raw(self):
        self.assertFalse(gatecore.settled(" hello there ", " goodbye ", 5))

    def test_leading_space_dropped_by_clean(self):
        self.assertTrue(gatecore.settled(" planning next ", "planning ", 5))


class SameGhostFewerTokens(unittest.TestCase):
    def test_tail_stops_at_first_weak_whole_word(self):
        # a short sure part keeps the loop going while tokens stay >= 0.05 (grow); the tail turned " next" down already
        pieces = [(" go", 0.9), (" to", 0.3), (" the", 0.06), (" next", 0.1), (" week", 0.3), (" and", 0.06), (" then", 0.07), (" more", 0.02)]
        old, n_old = run(pieces, False)
        new, n_new = run(pieces, True)
        self.assertEqual(old, new)
        self.assertLess(n_new, n_old)

    def test_same_ghost_on_many_made_up_runs(self):
        import random
        rnd = random.Random(5)
        words = [" we", " should", " ship", " the", " draft", " today", ",", " then", " review", " it", "."]
        for _ in range(400):
            pieces = [(rnd.choice(words), rnd.choice([0.03, 0.08, 0.15, 0.25, 0.45, 0.7, 0.95])) for _ in range(rnd.randint(2, 14))]
            old, n_old = run(pieces, False)
            new, n_new = run(pieces, True)
            self.assertEqual(old, new, pieces)
            self.assertLessEqual(n_new, n_old)


class ShapeMatchesModel(unittest.TestCase):
    def test_shape_is_the_old_inline_rule(self):
        t = toks([(" send", 0.9), (" it", 0.3), (" to", 0.2), (" Anna", 0.25), (" now", 0.04), (" ", 0.5)])
        text = gatecore.extend(t, gatecore.next_word(t[-1][0]), 0.5, 3)
        text = gatecore.grow(t, text, 0.05, 6, 5)
        sure = len(text)
        text = gatecore.more_words(t, text, 0.2, 8)
        self.assertEqual(gatecore.shape(t, 0.5, 3, 0.05, 6, 5, 0.2, 8), (text, sure))


if __name__ == "__main__":
    unittest.main()

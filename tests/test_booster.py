"""The word booster: his own next words (Words.dist) mixed into the model's token probabilities (Model.booster)."""
import math, sys, unittest
import numpy as np
from types import SimpleNamespace
from unittest.mock import patch
from collections import Counter
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "engine"))
import words
from server_src import lift


class Dist(unittest.TestCase):
    def setUp(self):
        self.w = words.Words()
        for line in ["можемо зробити завтра"] * 5 + ["можемо зробити завдання", "let me know", "let me know", "let me check"]:
            self.w.add(line, rebuild=False)
        self.w.vocab = sorted(self.w.uni)

    def test_after_two_words_his_word_leads(self):
        d = self.w.dist("можемо зробити зав")
        self.assertEqual(d[0][0], "тра")
        self.assertGreater(d[0][1], 0.6)
        self.assertAlmostEqual(sum(p for _, p in d), 6 / 7, places=2)   # shares among words with these letters

    def test_word_start_needs_a_word_before(self):
        self.assertEqual(self.w.dist("\n"), [])
        self.assertEqual(self.w.dist("let me ")[0][0], "know")

    def test_targets_keep_the_healed_half_word(self):
        t = words.boost_targets(self.w, "let me kn", " kn")
        self.assertEqual(t[0][0], " know")
        self.assertEqual(words.boost_targets(self.w, "let me,", "")[0][0][0], " ")   # a space before a new word


class Mix(unittest.TestCase):
    def setUp(self):
        # Compile just the processor method against NumPy, never import model/MLX.
        mx = SimpleNamespace(array=np.array, zeros=np.zeros,
                             logsumexp=lambda a, axis, keepdims: np.logaddexp.reduce(a, axis=axis, keepdims=keepdims))
        ns = lift('booster', path=Path(__file__).resolve().parents[1] / 'engine/model.py', cls='Model', mx=mx, math=math)
        m = SimpleNamespace()
        m.booster = lambda *a, **kw: ns['booster'](m, *a, **kw)
        self.m, self.mx = m, mx
        m.encode = lambda t: {"ab": [2, 3]}[t]

    def test_mixture_sums_to_one_and_follows_the_path(self):
        m, mx = self.m, self.mx
        proc = m.booster([("ab", 0.8)], n_prompt=1, lam=0.5)
        logits = mx.zeros((1, 5))
        out = proc(mx.array([0]), logits)
        p = [math.exp(x) for x in out.reshape(-1).tolist()]
        self.assertAlmostEqual(sum(p), 1.0, places=4)
        self.assertAlmostEqual(p[2], 0.5 / 0.9, places=4)        # (0.5 * 0.2 + 0.5 * 0.8) / 0.9
        out = proc(mx.array([0, 2]), logits)                     # the model took token 2: on to token 3
        p = [math.exp(x) for x in out.reshape(-1).tolist()]
        self.assertAlmostEqual(sum(p), 1.0, places=4)
        self.assertAlmostEqual(p[3], 0.84, places=4)
        self.assertIs(proc(mx.array([0, 2, 3]), logits), logits)  # the word is done: nothing changes after it

    def test_ended_path_keeps_longer_candidates_boosted_with_only_their_mass(self):
        m, mx = self.m, self.mx
        for short, long in [('за', 'зараз'), ('що', 'щоб'), ('на', 'навіть'), ('can', "can't")]:
            with self.subTest(short=short):
                m.encode = lambda t: {short: [2], long: [2, 3]}[t]
                proc = m.booster([(short, .4), (long, .4)], 1, .3)
                logits = mx.zeros((1, 5))
                proc(mx.array([0]), logits)
                probabilities = np.exp(proc(mx.array([0, 2]), logits))
                # The short path contributes its .4 mass to the base continuation.
                self.assertAlmostEqual(probabilities[0, 3], ((.7 * .2 + .3 * .4) * .2 + .3 * .4) / (.7 * .2 + .3 * .8))
                self.assertAlmostEqual(float(probabilities.sum()), 1)
                self.assertIs(proc(mx.array([0, 2, 3]), logits), logits)
                off = m.booster([(short, .4), (long, .4)], 1, .3)
                off(mx.array([0]), logits)
                self.assertIs(off(mx.array([0, 4]), logits), logits)

    def test_za_mass_does_not_transfer_to_zaraz_over_multiple_tokens(self):
        m = self.m
        m.encode = lambda t: {'за': [2], 'зараз': [2, 3, 4]}[t]
        proc = m.booster([('за', .50), ('зараз', .05)], 1, .3)
        logits = np.log(np.array([[.90, .02, .01, .03, .04]]))
        proc(np.array([0]), logits)
        p = np.exp(proc(np.array([0, 2]), logits))
        base = .7 * .01 + .3 * .50
        self.assertAlmostEqual(p[0, 3], (base * .03 + .3 * .05) / (base + .3 * .05))
        self.assertLess(p[0, 3], .12)  # dropping .50 used to inflate this above .69
        self.assertAlmostEqual(p.sum(), 1)
        p = np.exp(proc(np.array([0, 2, 3]), logits))
        base *= .03  # ended mass now follows the unboosted model
        self.assertAlmostEqual(p[0, 4], (base * .04 + .3 * .05) / (base + .3 * .05))
        self.assertAlmostEqual(p.sum(), 1)



class WordRegressions(unittest.TestCase):
    def test_rare_prefix_has_unknown_mass_and_bare_prefix_is_not_a_target(self):
        w = words.Words()
        w.add('we saw zeppelin')
        self.assertEqual(w.dist('zep'), [('pelin', 0.5)])
        w.add('we saw car')
        w.add('we saw carpet')
        self.assertTrue(all(rest for rest, _ in w.dist('car')))
        self.assertLess(sum(p for _, p in w.dist('car')), 0.5)
        self.assertNotIn('car', [text for text, _ in words.boost_targets(w, 'car', 'car')])

    def test_sentence_capitals_do_not_leak_but_names_and_acronyms_stay(self):
        w = words.Words()
        for _ in range(8): w.add('Tomorrow we meet')
        w.add('see tomorrow')
        w.add('see Mila')
        w.add('use API')
        self.assertIn('tomorrow', dict(w.dist('see ')))
        self.assertNotIn('Tomorrow', dict(w.dist('see ')))
        self.assertIn('Mila', dict(w.dist('see ')))
        self.assertIn('API', dict(w.dist('use ')))
        self.assertEqual(w.dist('see TO')[0][0], 'MORROW')

    def test_dist_case_fits_the_typed_prefix(self):
        w = words.Words()
        w.add('use API'); w.add('use GitHub')
        self.assertEqual(w.dist('use ap')[0][0], 'i')
        self.assertEqual(w.dist('use AP')[0][0], 'I')
        self.assertEqual(w.dist('use git')[0][0], 'hub')
        self.assertEqual(w.dist('use Git')[0][0], 'Hub')

    def test_dictionary_keeps_two_and_three_letter_names(self):
        import json
        def read(path, *a, **kw):
            if path.name == 'words.json': return json.dumps({'words': ['Сава', 'Іра', 'Bo']})
            if path.name == 'phrases.jsonl':
                return '\n'.join(json.dumps({'text': name + ' arrives'}) for name in ['Сава', 'Іра', 'Bo'])
            return ''
        with patch.object(Path, 'read_text', read):
            w = words.Words(); w.load()
        for name in ['Сава', 'Іра', 'Bo']:
            self.assertEqual(w.inner_case[name.lower()].most_common(1)[0][0], name)
            self.assertEqual(w.dist('call ' + name[:1])[0][0], name[1:])
            w.add('call ' + name)
            self.assertIn(name, dict(w.dist('call ')))

    def test_midword_distribution_scans_unigrams_once(self):
        class Counted(Counter):
            scans = 0
            def values(self):
                self.scans += 1
                return super().values()
        w = words.Words()
        w.add('we see car carpet carbon')
        w.uni = Counted(w.uni)
        with patch.object(w, '_wb', wraps=w._wb) as wb:
            w.dist('we see car')
        self.assertEqual(wb.call_count, 1)
        self.assertEqual(w.uni.scans, 1)


if __name__ == "__main__":
    unittest.main()

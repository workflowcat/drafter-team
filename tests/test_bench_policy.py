"""Bench-only modes on fictional recordings; historical outputs frozen before the adapter change.

Run: .venv/bin/python -B tests/test_bench_policy.py
"""
import argparse
import json
import math
from pathlib import Path
import sys
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
sys.path[:0] = [str(ROOT / "bench"), str(ROOT / "bench/big"), str(ROOT / "engine")]
import earlier, gatecore, measure, request_policy as R, score, selector


class Words:
    def finish(self, *args): return ""
    def candidate(self, *args): return None


class Memory:
    def __init__(self, text): self.text = text
    def suggest(self, before): return self.text, 2


def tokens(pieces, probabilities=None):
    text, out = "", []
    for i, piece in enumerate(pieces):
        text += piece
        out.append([text, probabilities[i] if probabilities else 0.9, 0.05, 10.0 * (i + 1)])
    return out


def sample():
    items = [{"src": "claude", "text": "See red paper boats float very far."}]
    rows = {(0, 4): {"_key": (0, 4), "max_tokens": 24, "prefill_ms": 80, "_prefill50": 30,
                     "toks": tokens(["red", " paper", " boats", " float", " very", " far", ".", " "])}}
    return items, rows, {(0, 4): 0.8}


def gate(p):
    return {"w": [math.log(p / (1 - p))] + [0.0] * (len(gatecore.NAMES) - 1), "th": {"ai": 0.4, "chat": 0.4}}


def selector_weights(p):
    return [math.log(p / (1 - p))] + [0.0] * (len(gatecore.SEL_NAMES) - 1)


LIVE = ({"ai": [1] * 9, "chat": [1] * 9}, [13], [54])
WORD_GATE = {"w": [0.0] * len(gatecore.WORD_NAMES)}


def historical_snapshot(E=earlier, B=score, S=selector):
    """Exercise public adapters, metrics, shades and timing without any corpus or model."""
    items, rows, P = sample()
    row, before = rows[(0, 4)], items[0]["text"][:4]
    out = {"earlier": {}, "big": {}, "selector": {}}
    for name, run in E.VARIANTS.items():
        for guess in (None, 0.3):
            pol = E.Policy({(0, 4): 0.35} if guess else P, guess=guess, **run)
            key = name + str(guess)
            out["earlier"][key] = E.score(items, rows, pol)[0]
    for name, run, pk, kw in E.WAIT_VARIANTS:
        if kw.get("zero"): continue
        out["earlier"][name] = E.waits(items, rows, E.Policy(P, **pk, **run), LIVE, seeds=(1,), **kw)
    pol = B.Sentence(P)
    out["big"]["answer"] = pol(row, before, "claude")
    out["big"]["info"] = pol.info
    out["big"]["replay"] = measure.replay(items, rows, pol)
    sources = S.Sources(Words(), Memory("paper boats"), gate(0.8), WORD_GATE,
                        {"min_letters": 5, "grow": 0.05, "tail": 0.2, "tail_words": 8})
    out["selector"]["offers"] = sources.offers(row, before, "claude")
    for fast in (False, True):
        for p in (0.2, 0.8):
            out["selector"][f"{fast}/{p}"] = S.Selector(sources, selector_weights(p), 0.65, fast)(row, before, "claude")
    return json.loads(json.dumps(out))


class Historical(unittest.TestCase):
    def test_outputs_match_before_adapters(self):
        expected = json.loads((ROOT / "tests/fixtures/bench_policy_history.json").read_text())
        self.assertEqual(historical_snapshot(), expected)

    def test_named_defaults_and_sweeps(self):
        for old in (R.EARLIER, R.BIG, R.SELECTOR):
            parser = argparse.ArgumentParser()
            R.add_argument(parser, old)
            self.assertEqual(parser.parse_args([]).policy_mode, old)
            self.assertEqual(parser.parse_args(["--policy-mode", R.CURRENT]).policy_mode, R.CURRENT)
        self.assertEqual(len(earlier.length_cases(R.EARLIER, "0.35,0.3,0.25,0.2")), 25)
        self.assertEqual(earlier.wait_cases(R.EARLIER), earlier.WAIT_VARIANTS)
        _, rows, P = sample()
        row = rows[(0, 4)]
        self.assertEqual(earlier.Policy(P)(row, "See ", "claude"),
                         earlier.Policy(P, policy_mode=R.EARLIER)(row, "See ", "claude"))
        self.assertEqual(score.Sentence(P)(row, "See ", "claude"),
                         score.Sentence(P, policy_mode=R.BIG)(row, "See ", "claude"))


class Current(unittest.TestCase):
    def sources(self, p=0.35, memory=None):
        return selector.Sources(Words(), memory, gate(p), WORD_GATE, policy_mode=R.CURRENT)

    def test_shared_flags_and_fresh_presets(self):
        expected = {"length": "words", "floor": 0.1, "cap": 24, "words_min": 3, "words_max": 5,
                    "min_letters": 3, "guess": True, "guess_shade": True, "keep_on": True}
        for pol in (earlier.Policy({}, policy_mode=R.CURRENT), score.Sentence({}, policy_mode=R.CURRENT), self.sources()):
            self.assertEqual(pol.request_policy.request, expected)
            self.assertEqual(pol.request_policy.guess_bar, 0.3)
        R.build(R.CURRENT).request["words_min"] = 1
        self.assertEqual(R.build(R.CURRENT).request, expected)
        with self.assertRaises(ValueError): R.build("misspelled")

    def test_guesses_and_five_word_cap_keep_each_timing_rule(self):
        _, rows, _ = sample()
        row = rows[(0, 4)]
        p = {(0, 4): 0.35}
        ep = earlier.Policy(p, policy_mode=R.CURRENT)
        bp = score.Sentence(p, policy_mode=R.CURRENT)
        sp = selector.Selector(self.sources(), selector_weights(0.1), 0.65)
        expected = "red paper boats float very "
        self.assertEqual(ep(row, "See ", "claude"), (expected, 0.0))  # first word, cold-prefill adjustment
        self.assertEqual(ep.info["shade"], "guess")
        self.assertEqual(bp(row, "See ", "claude"), (expected, 70.0))  # full recorded time
        self.assertEqual(sp(row, "See ", "claude"), (expected, 70.0))
        self.assertEqual(earlier.Policy(p)(row, "See ", "claude"), ("", 0))
        self.assertEqual(score.Sentence(p)(row, "See ", "claude"), ("", 0))

    def test_guess_boundary_and_three_letter_minimum(self):
        row = {"_key": (0, 4), "toks": tokens(["fox", " "]), "max_tokens": 24}
        for p, shown in ((0.299, False), (0.3, True), (0.4, True)):
            for factory in (earlier.Policy, score.Sentence):
                with self.subTest(p=p, factory=factory.__name__):
                    self.assertEqual(bool(factory({(0, 4): p}, policy_mode=R.CURRENT)(row, "See ", "claude")[0]), shown)
        short = dict(row, toks=tokens(["ox", " "]))
        self.assertEqual(self.sources().model(short, "See ", "claude"), ("", 0))
        self.assertEqual(selector.Selector(self.sources(0.29), selector_weights(0.1), 0.65)(row, "See ", "claude"), ("", 0))

    def test_selector_instant_priority_and_rejected_model_guess(self):
        _, rows, _ = sample()
        sources = self.sources(memory=Memory("fox"))
        pol = selector.Selector(sources, selector_weights(0.8), 0.65)
        with patch.object(sources, "model", side_effect=AssertionError("instant winner must not ask model")):
            self.assertEqual(pol(rows[(0, 4)], "See ", "claude"), ("fox", 1))
        with self.assertRaises(ValueError):
            selector.Sources(Words(), None, gate(0.5), WORD_GATE, {"tail": 0.2}, policy_mode=R.CURRENT)

    def test_current_waits_retain_in_flight_work(self):
        cases = earlier.wait_cases(R.CURRENT)
        self.assertEqual(len(cases), 1)
        name, run, pk, timing = cases[0]
        self.assertEqual(name, R.CURRENT)
        self.assertEqual(timing, {"keep": True})
        items, rows, P = sample()
        # A fictional slow answer spans several keys. Only retained work can reach those keys.
        for row in rows.values():
            row["prefill_ms"] = 0
            for t in row["toks"]: t[3] += 180
        live = ({"ai": [1] + [0] * 8, "chat": [1] + [0] * 8}, [0], [0])
        kept = earlier.waits(items, rows, earlier.Policy(P, **pk, **run), live, seeds=(1,), ahead=False, **timing)
        dropped = earlier.waits(items, rows, earlier.Policy(P, **pk, **run), live, seeds=(1,), ahead=False, keep=False)
        self.assertGreater(kept["visible"], dropped["visible"])
        self.assertEqual(earlier.length_cases(R.CURRENT, "0.9"), [(R.CURRENT, {"policy_mode": R.CURRENT})])


if __name__ == "__main__":
    unittest.main()

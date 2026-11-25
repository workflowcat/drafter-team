"""Cadence round: the routing rule (engine/cadence.py) and the bench policy (bench/cadence_replay.py) on made-up rows.

Run: .venv/bin/python -B tests/test_cadence.py
"""
from pathlib import Path
import sys
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path[:0] = [str(ROOT / "bench"), str(ROOT / "bench/big"), str(ROOT / "engine")]
import cadence as rules
import importlib.util
spec = importlib.util.spec_from_file_location("cadence_replay", ROOT / "bench/cadence_replay.py")
bench = importlib.util.module_from_spec(spec); spec.loader.exec_module(bench)
import earlier, request_policy as R


def tokens(pieces, step):
    text, out = "", []
    for i, piece in enumerate(pieces):
        text += piece
        out.append([text, 0.9, 0.05, step * (i + 1)])
    return out


class Route(unittest.TestCase):
    def test_fast_only_on_quick_keys_with_combo(self):
        req = {"combo": True, "gap_ms": 80}
        self.assertEqual(rules.route(req, True, "qwen3-4b-mine"), "fast")
        self.assertEqual(rules.route(dict(req, gap_ms=150), True, "qwen3-4b-mine"), "big")
        self.assertEqual(rules.route(dict(req, gap_ms=120), True, "qwen3-4b-mine"), "big")      # the edge goes to the 4B

    def test_everything_else_stays_on_the_picked_model(self):
        req = {"combo": True, "gap_ms": 80}
        self.assertEqual(rules.route(req, False, "qwen3-4b-mine"), "big")                      # slot not loaded
        self.assertEqual(rules.route(req, True, "live"), "big")                                 # the fast one is picked
        self.assertEqual(rules.route(req, True, None), "big")                                   # a bench model
        self.assertEqual(rules.route(dict(req, combo=False), True, "qwen3-4b-mine"), "big")
        self.assertEqual(rules.route(dict(req, idle=True), True, "qwen3-4b-mine"), "big")
        self.assertEqual(rules.route(dict(req, mid=True), True, "qwen3-4b-mine"), "big")
        for gap in (None, -1, 0, "x"):
            self.assertEqual(rules.route(dict(req, gap_ms=gap), True, "qwen3-4b-mine"), "big")

    def test_wanted(self):
        self.assertTrue(rules.wanted({"combo": True}, "qwen3-4b-mine"))
        self.assertFalse(rules.wanted({"combo": True}, "live"))
        self.assertFalse(rules.wanted({}, "qwen3-4b-mine"))


class BenchPolicy(unittest.TestCase):
    def setUp(self):
        self.rows_fast = {(0, 4): {"_key": (0, 4), "max_tokens": 24, "prefill_ms": 30, "_prefill50": 30,
                                   "toks": tokens(["red", " paper", " boats"], 5.0)}}
        self.rows_big = {(0, 4): {"_key": (0, 4), "max_tokens": 24, "prefill_ms": 30, "_prefill50": 30,
                                  "toks": tokens(["red", " paper", " boats", " float", " far", " away", "."], 12.0)}}
        P = {(0, 4): 0.9}
        self.pol = lambda **kw: bench.Cadence(earlier.Policy(P, policy_mode=R.CURRENT), earlier.Policy(P, policy_mode=R.CURRENT),
                                              self.rows_big, 120, **kw)

    def test_routes_by_the_gap_before_the_key(self):
        pol = self.pol(extend=False)
        pol.see(80, 90)
        text, ms = pol(self.rows_fast[(0, 4)], "See ", "claude")
        self.assertEqual(pol.info["src"], "fast"); self.assertEqual(ms, 10.0)
        pol.see(300, 90)
        text, ms = pol(self.rows_fast[(0, 4)], "See ", "claude")
        self.assertEqual(pol.info["src"], "big"); self.assertEqual(ms, 24.0)
        pol.see(None, None)
        pol(self.rows_fast[(0, 4)], "See ", "claude")
        self.assertEqual(pol.info["src"], "big")

    def test_extension_only_when_it_starts_with_the_whole_ghost(self):
        pol = self.pol()
        pol.see(80, 80)
        pol(self.rows_fast[(0, 4)], "See ", "claude")
        self.assertEqual([o[3] for o in pol.opts], ["fast", "ext"])
        self.assertTrue(pol.opts[1][1].startswith(pol.opts[0][1].rstrip()))
        self.assertTrue(bench.agrees("See ", "red paper boats", "red paper boats float far"))
        self.assertFalse(bench.agrees("See ", "red paper boats", "red paper ships float"))
        self.assertFalse(bench.agrees("See ", "red paper boats", "red paper boats"))

    def test_cadence_signal(self):
        self.assertTrue(bench.fast_cadence(80, 300, 120))
        self.assertFalse(bench.fast_cadence(80, 300, 120, "mean2"))
        self.assertFalse(bench.fast_cadence(None, None, 120))


if __name__ == "__main__":
    unittest.main()

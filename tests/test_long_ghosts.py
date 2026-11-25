"""Long ghosts round (2026-11-14): the sentence run rule (engine/gatecore.py run_words), the futures budget and letters,
/futures and the in-flight join (engine/server.py), and the bench policy (bench/long_ghosts.py). Made-up lines only.

    .venv/bin/python -B tests/test_long_ghosts.py
"""
import sys, threading, time, types, unittest
from collections import OrderedDict
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "engine")); sys.path.insert(0, str(ROOT / "bench"))
import gatecore as g
from server_src import lift


def toks(words, ps):
    """Recorded tokens: one token per piece, the text so far after each."""
    out, t = [], ""
    for w, p in zip(words, ps):
        t += w; out.append([t, p, 0.1, 10.0 * (len(out) + 1)])
    return out


class RunWords(unittest.TestCase):
    def test_runs_to_the_sentence_end(self):
        text, sure, why, conf = g.run_words(toks(["I", " think", " we", " should", " go", " home", ".", " Then", " "], [.9] * 9))
        self.assertEqual((text, why), ("I think we should go home. ", "sentence"))
        self.assertEqual(len(conf), 5)

    def test_one_unsure_word_does_not_cut_it_but_a_run_of_them_does(self):
        # prod floor 0.1: 0.4 then 0.9s keeps going; then three weak words fall under the floor
        t = toks(["We", " can", " ship", " it", " today", " maybe", " perhaps", " soon", " "], [.9, .4, .9, .9, .9, .3, .3, .3, .9])
        text, _, why, _ = g.run_words(t, floor=0.1)
        self.assertEqual((text, why), ("We can ship it today ", "floor"))

    def test_garbage_word_stops_at_once(self):
        text, _, why, _ = g.run_words(toks(["I", " think", " xq", " so", " "], [.9, .9, .001, .9, .9]))
        self.assertEqual((text, why), ("I think ", "floor"))

    def test_open_word_waits_and_cap_drops_it(self):
        t = toks(["I", " think", " we", " sho"], [.9] * 4)
        self.assertEqual(g.run_words(t)[2], "open")
        self.assertFalse(g.run_settled("open"))
        text, _, why, _ = g.run_words(t, closed="cap")
        self.assertEqual((text, why), ("I think we ", "cap"))
        text, _, why, _ = g.run_words(t, closed="eos")            # the model ended there: the word is whole
        self.assertEqual((text, why), ("I think we sho", "end"))

    def test_line_end_and_clause_and_comma(self):
        self.assertEqual(g.run_words(toks(["I", " think", " we", "\n", "Go"], [.9] * 5))[:3:2], ("I think we", "line"))
        self.assertEqual(g.run_words(toks(["I", " think", ",", " we", " go", " "], [.9] * 6), mode="phrase")[:3:2], ("I think, ", "clause"))
        self.assertEqual(g.run_words(toks(["a", ";", " b", " "], [.9] * 4))[2], "clause")
        words = ["one"] + [f" w{i}" for i in range(7)] + [",", " next", " "]
        text, _, why, _ = g.run_words(toks(words, [.99] * len(words)))
        self.assertEqual(why, "comma")
        self.assertTrue(text.endswith(", "))

    def test_word_cap(self):
        words = ["a"] + [" b"] * 10 + [" "]
        text, _, why, _ = g.run_words(toks(words, [.99] * len(words)), mode="phrase")
        self.assertEqual((len(text.split()), why), (6, "words"))

    def test_sure_part_is_where_the_running_chance_stays_likely(self):
        t = toks(["I", " think", " we", " can", " go", " "], [.9, .9, .5, .5, .9, .9])
        text, sure, _, conf = g.run_words(t, floor=0.05, likely=0.3)
        self.assertEqual(text[:sure], "I think we ")         # 0.9, then 0.45 >= 0.3; 0.225 < 0.3
        self.assertEqual(conf, [0.9, 0.45, 0.225, 0.2025])

    def test_short_ghost_grows_before_the_floor(self):
        # "I" adds 1 letter: under min_letters the next word needs only each token >= grow
        t = toks(["I", " am", " so", " "], [.9, .06, .9, .9])
        self.assertEqual(g.run_words(t, floor=0.1, min_letters=0)[0], "I ")
        self.assertEqual(g.run_words(t, floor=0.1, min_letters=4)[0], "I am so ")

    def test_mean_kind_forgives_one_weak_word(self):
        t = toks(["We", " can", " ship", " it", " "], [.9, .2, .9, .9, .9])
        self.assertEqual(g.run_words(t, floor=0.3)[0], "We ")                       # product 0.2 < 0.3
        self.assertEqual(g.run_words(t, floor=0.3, kind="mean")[0], "We can ship it ")


def server_ns(names, **extra):
    return lift(*names, **extra)


class Futures(unittest.TestCase):
    def test_budget_from_his_gaps_and_the_answer_time(self):
        ns = server_ns({"futures_k"}, FUTURES=4, BRANCHES=2, GAPS=[], COSTS=[], power_low=lambda: False,
                       model=types.SimpleNamespace(memory_gb=lambda: (1.0, 1.0)))
        self.assertEqual(ns["futures_k"](), 2)                       # no numbers yet: as before
        ns["GAPS"][:] = [150.0] * 50; ns["COSTS"][:] = [40.0] * 50
        self.assertEqual(ns["futures_k"](), 2)                       # (150 - 40) // 40
        ns["GAPS"][:] = [400.0] * 50
        self.assertEqual(ns["futures_k"](), 4)                       # capped at FUTURES
        ns["GAPS"][:] = [60.0] * 50
        self.assertEqual(ns["futures_k"](), 1)                       # at least one
        self.assertEqual(ns["futures_k"](0), 0)                      # the request may switch them off

    def test_none_on_low_battery_or_near_the_memory_cap(self):
        ns = server_ns({"futures_k"}, FUTURES=4, BRANCHES=2, GAPS=[150.0] * 50, COSTS=[40.0] * 50, power_low=lambda: True,
                       model=types.SimpleNamespace(memory_gb=lambda: (1.0, 1.0)))
        self.assertEqual(ns["futures_k"](), 0)
        ns["power_low"] = lambda: False
        ns["model"] = types.SimpleNamespace(memory_gb=lambda: (3.5, 3.5))
        self.assertEqual(ns["futures_k"](), 0)

    def test_letters_model_first_then_its_alternatives_and_his_words(self):
        fin = types.SimpleNamespace(dist=lambda before, k: [("build", .5), ("send", .2)])
        ns = server_ns({"branch_letters"}, BRANCHES=2, finisher=fin)
        self.assertEqual(ns["branch_letters"]("check the ", " ship it", "", 4, ["t", "p"]), ["s", "t", "b", "p"])
        self.assertEqual(ns["branch_letters"]("check the ", " ship it", "ship", 4, ["t", "p"]), ["t", "b", "p"])

    def test_futures_route_gives_the_prepared_ideas(self):
        AHEAD = OrderedDict()
        ns = server_ns({"futures"}, AHEAD=AHEAD, AHEAD_LOCK=threading.Lock(), AHEAD_TTL=30.0, futures_k=lambda: 2,
                       ahead_key=lambda r: r["before"], FUT_INDEX=OrderedDict({"see the ": [("b", "see the b"), ("p", "see the p")]}))
        AHEAD["see the b"] = (time.time(), {"text": "ook", "unsure": ""})
        out = ns["futures"]({"before": "see the "})
        self.assertEqual(out["futures"], [{"letter": "b", "text": "ook", "unsure": ""}])   # "p" not ready yet

    def test_cancel_spares_the_look_ahead_he_now_wants(self):
        latest, WANT = [5], ["k1"]
        ns = server_ns({"stale"}, latest=latest, LATEST_LOCK=threading.Lock())
        stale = ns["stale"]
        keep = lambda key: (lambda: stale(4) and WANT[0] != key)
        self.assertFalse(keep("k1")())      # older id, but the newest request asks for exactly this text
        self.assertTrue(keep("k2")())


class BenchPolicy(unittest.TestCase):
    def test_policy_runs_to_the_sentence_and_says_why(self):
        import long_ghosts as L
        W = types.SimpleNamespace(finish=lambda *a: "")
        gate = {"w": [30.0] + [0.0] * (len(g.NAMES) - 1), "th": {"ai": 0.4, "chat": 0.4}}
        pol = L.ModelPolicy(W, gate, "sentence", floor=0.05)
        row = {"toks": toks([" we", " should", " go", " home", ".", " Then", " "], [.9] * 7), "max_tokens": 24}
        out, ms = pol(row, "I think ", "claude")
        self.assertEqual(out, "we should go home.")      # stops at the period, nothing waits for the space
        self.assertEqual(pol.info["why"], "sentence")
        self.assertEqual(pol.info["first_ms"], 20.0)        # the first word is whole at the second token


if __name__ == "__main__":
    unittest.main()

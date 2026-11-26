"""Round four (2026-11-14): the user's own word first (engine/words.py Words.candidate, engine/gatecore.py word_features and
extends, bench/wordgate.py). Made-up lines only.

    .venv/bin/python -B tests/test_wordgate.py
"""
import sys, unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "bench")); sys.path.insert(0, str(ROOT / "engine"))
import gatecore, words
from server_src import lift


class Candidate(unittest.TestCase):
    def setUp(self):
        self.w = words.Words()
        for line in ["please check the build", "please check the build again", "please check the branch",
                     "we ship the build today", "the bridge is open"]:
            self.w.add(line)

    def test_two_words_back_first(self):
        c = self.w.candidate("please check the bu")
        self.assertEqual(c["rest"], "ild")
        self.assertEqual(c["level"], 2)
        self.assertEqual(c["n"], 2)
        self.assertAlmostEqual(c["share"], 1.0)      # shares among the words that start with the typed letters
        self.assertEqual(c["prefix"], 2)
        c = self.w.candidate("please check the b")
        self.assertEqual(c["rest"], "uild")
        self.assertAlmostEqual(c["share"], 2 / 3); self.assertAlmostEqual(c["second"], 1 / 3)

    def test_falls_back_to_the_word_alone(self):
        c = self.w.candidate("nothing like it bri")
        self.assertEqual((c["rest"], c["level"]), ("dge", 0))

    def test_none_without_a_half_word_or_a_match(self):
        self.assertIsNone(self.w.candidate("please check "))
        self.assertIsNone(self.w.candidate("zzz"))

    def test_features_line_up_with_names(self):
        c = self.w.candidate("please check the bu")
        f = gatecore.word_features(c, "please check the bu", True)
        self.assertEqual(len(f), len(gatecore.WORD_NAMES))
        self.assertEqual(f[gatecore.WORD_NAMES.index("level2")], 1.0)
        self.assertEqual(f[gatecore.WORD_NAMES.index("claude")], 1.0)
        self.assertIsNone(gatecore.word_features(None, "x", False))


class Extends(unittest.TestCase):
    def test_only_whole_word_extensions(self):
        self.assertTrue(gatecore.extends("ild", "ild"))
        self.assertTrue(gatecore.extends("ild again", "ild"))
        self.assertTrue(gatecore.extends("ild, then", "ild"))
        self.assertFalse(gatecore.extends("ilding", "ild"))
        self.assertFalse(gatecore.extends("anch", "ild"))
        self.assertFalse(gatecore.extends("", "ild"))
        self.assertFalse(gatecore.extends("ild", ""))


class WordSpan(unittest.TestCase):
    def test_a_weak_space_after_a_word_does_not_count_for_it(self):
        toks = [["hello", .9, 0], ["hello world", .9, 0], ["hello world,", .9, 0], ["hello world, ", .05, 0],
                ["hello world, next", .9, 0]]
        self.assertEqual(gatecore.word_ps(toks, 5, 12), [.9, .9])                  # " world" and ","
        self.assertEqual(gatecore.extend(toks, "hello", .5, 3), "hello world, ")
        toks = [["hello", .9, 0], ["hello world ", .8, 0], ["hello world next", .9, 0]]
        self.assertEqual(gatecore.word_ps(toks, 5, 11), [.8])                       # a token that holds the word and its space


class Policy(unittest.TestCase):
    def test_word_first_keeps_an_extending_model_ghost_and_drops_another(self):
        import wordgate
        w = words.Words()
        for _ in range(5): w.add("please check the build")
        g = {"w": [5.0] + [0.0] * (len(gatecore.WORD_NAMES) - 1), "th": 0.5}
        wf = wordgate.WordsFirst(lambda row, before, src: ("ild again", 80), w, g)
        self.assertEqual(wf(None, "please check the bu", "claude"), ("ild again", 1))
        wf = wordgate.WordsFirst(lambda row, before, src: ("ilding", 80), w, g)
        self.assertEqual(wf(None, "please check the bu", "claude"), ("ild", 1))
        wf = wordgate.WordsFirst(lambda row, before, src: ("the", 80), w, g)
        self.assertEqual(wf(None, "please check ", "claude"), ("the", 80))   # no half word: the live answer


class Server(unittest.TestCase):
    """engine/server.py _complete with the word path, run from its source with stand-ins (no model, no data)."""
    def build(self, model_text, parts=(), sel=None, said=("", 0)):
        import math, re, time, types
        w = words.Words()
        for _ in range(5): w.add("please check the build")
        sent = []

        def complete_gated(ids, heal, decide, on_part=None, **kw):
            if decide([[model_text, 0.9, 0.05]]) is None: return "", None, 10.0, 30.0
            for p in parts:
                if on_part: on_part(p, len(p))
            return model_text, 0.9, 10.0, 30.0
        model = types.SimpleNamespace(asleep=False, loading=False, complete_gated=complete_gated, timing={}, last_sure=None)
        ns = lift("_complete", "word_first", "clean", "short", "offers_now", "extras", re=re, time=time, math=math, selector=lambda: sel, gatecore=gatecore, model=model, finisher=w, words_mod=words, WRITTEN={"seq": None, "text": ""},
                  wordgate=lambda: {"w": [5.0] + [0.0] * (len(gatecore.WORD_NAMES) - 1), "th": 0.5, "min_letters": 3},
                  gate=lambda: {"th": {"ai": 0.4, "chat": 0.4}, "w": [5.0] + [0.0] * (len(gatecore.NAMES) - 1), "words": (2, 0.6, 1)},
                  parts=lambda r, remember=True: (r["before"], r.get("app", "Claude"), "", "", ""),
                  builder_for=lambda f: types.SimpleNamespace(ids=lambda *a: ([1], ""), ids_stable=lambda *a: ([1], "", 0)), FMT="raw",
                  snippets=types.SimpleNamespace(offer=lambda b: None),
                  phrases=types.SimpleNamespace(suggest=lambda b: said),
                  actions=types.SimpleNamespace(detect=lambda b: None),
                  knowledge=types.SimpleNamespace(snapshot=lambda: None, offered=0), earlier=lambda *a, **k: "",
                  run=lambda job, low=False, seq=None, cancel=None: job(lambda: False), AI_APPS=("claude",), MAX_TOKENS=8, GROW=0.05,
                  GROW_WORDS=6, MIN_P=0.6, MAX_WORDS=3, FUTURES=0)
        return ns["_complete"], sent

    def test_word_streams_first_then_only_an_extension(self):
        go, _ = self.build("ild again", parts=("ilding", "ild again"))
        sent = []
        res = go({"before": "please check the bu"}, on_part=sent.append)
        self.assertEqual([m["part"] for m in sent], ["ild", "ild again"])   # "ilding" never shows
        self.assertEqual(sent[0]["src"], "words")
        self.assertEqual(res["text"], "ild again")

    def test_model_that_disagrees_leaves_the_word(self):
        go, _ = self.build("anch")
        res = go({"before": "please check the bu"}, on_part=lambda m: None)
        self.assertEqual((res["text"], res["src"]), ("ild", "words"))

    def test_without_streaming_the_word_comes_at_once(self):
        go, _ = self.build("ild again")
        res = go({"before": "please check the bu"})
        self.assertEqual((res["text"], res["src"]), ("ild", "words"))

    def test_off_by_request(self):
        go, _ = self.build("ild again")
        res = go({"before": "please check the bu", "word_first": False})
        self.assertEqual((res["text"], res["src"]), ("ild again", "gate"))

    def sel(self, bias, kind_bonus):
        w = dict.fromkeys(gatecore.SEL_NAMES, 0.0); w["bias"] = bias; w.update(kind_bonus)
        word = {"names": gatecore.WORD_NAMES, "w": [5.0] + [0.0] * (len(gatecore.WORD_NAMES) - 1), "th": 0.5}
        return {"names": gatecore.SEL_NAMES, "w": [w[k] for k in gatecore.SEL_NAMES], "th": 0.65, "wordgate": word,
                "min": {"memory": 5, "words": 3}}

    def test_selector_his_word_answers_at_once(self):
        go, _ = self.build("anch", sel=self.sel(-2.0, {"word_p": 4.0}))
        res = go({"before": "please check the bu", "min_letters": 5})
        self.assertEqual((res["text"], res["src"]), ("ild", "words"))      # 3 letters is enough for the user's word

    def test_selector_memory_first_when_sure(self):
        go, _ = self.build("anch", sel=self.sel(-2.0, {"memory": 4.0}), said=("check the build", 3))
        res = go({"before": "please "})
        self.assertEqual((res["text"], res["src"]), ("check the build", "memory"))

    def test_selector_holds_the_model_to_its_bar(self):
        go, _ = self.build("ild again", sel=self.sel(-2.0, {}))           # nothing clears the bar
        self.assertEqual(go({"before": "please check the bu"})["text"], "")
        go, _ = self.build("ild again", sel=self.sel(-2.0, {"model_p": 4.0}))
        self.assertEqual(go({"before": "please check the bu"})["text"], "ild again")


class BranchLetters(unittest.TestCase):
    """engine/server.py branch_letters and look_ahead: what the gap prepares (round four, bench/branches.py)."""
    def ns(self, dist):
        import re, threading, time, types
        from collections import OrderedDict
        asked = []
        ns = lift("branch_letters", "look_ahead", re=re, time=time, threading=types.SimpleNamespace(Thread=lambda target, **k: types.SimpleNamespace(start=target), Event=threading.Event),
                  BRANCHES=2, finisher=types.SimpleNamespace(dist=lambda before, k: dist), LATEST_LOCK=threading.Lock(), latest=[5],
                  stale=lambda seq: False, ahead_key=lambda r: r["before"], AHEAD=OrderedDict(), AHEAD_LOCK=threading.Lock(),
                  AHEAD_STATS={"made": 0}, AHEAD_KIND={}, ahead_count=lambda **k: None, complete=lambda r, low, seq, keep=None: asked.append(r["before"]) or {"text": "x"},
                  futures_k=lambda cap=None: 2, FUT_INDEX=OrderedDict(), INFLIGHT={}, COSTS=[])
        return ns, asked

    def test_model_word_then_his_word_never_the_shown_ghosts_letter(self):
        ns, _ = self.ns([("build", 0.5), ("bridge", 0.2), ("send", 0.1)])
        self.assertEqual(ns["branch_letters"]("check the ", " ship it", ""), ["s", "b"])
        self.assertEqual(ns["branch_letters"]("check the ", " ship it", "ship it"), ["b"])
        self.assertEqual(ns["branch_letters"]("check the ", "", ""), ["b", "s"])

    def test_gap_prepares_the_taken_ghost_then_the_branches(self):
        ns, asked = self.ns([("uild", 0.6)])
        ns["look_ahead"]({"before": "check the b"}, "", 5, raw="ranch")
        self.assertEqual(asked, ["check the br", "check the bu"])
        asked.clear()
        ns["look_ahead"]({"before": "check the b"}, "uild ", 5, raw="uild now")
        self.assertEqual(asked, ["check the build "])                    # both branches start like the ghost
        self.assertEqual(ns["AHEAD_STATS"]["made"], 3)


if __name__ == "__main__":
    unittest.main()

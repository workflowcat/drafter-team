"""Mid-line ghosts, fill in the middle (engine/fim.py, engine/prompt.py MID_FORM, engine/model.py complete_gated mid,
engine/server.py mid_line / mid_result). Made-up lines only; no MLX, no model.

    .venv/bin/python -B tests/test_fim.py
"""
import math, re, sys, threading, time, types, unittest
from pathlib import Path
from unittest.mock import Mock
import numpy as np

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "engine"))
import fim
from server_src import lift


def toks(pieces):
    """[(piece, p, p_rest)] -> (toks [[text so far, p, p2]], rests)"""
    out, rests, text = [], [], ""
    for piece, p, pr in pieces:
        text += piece; out.append([text, p, 0.0]); rests.append(pr)
    return out, rests


class Cut(unittest.TestCase):
    def test_runs_into_the_rest(self):
        self.assertEqual(fim.cut(" to the park. Then", " park."), " to the")
        self.assertEqual(fim.cut(" to the pa", " park."), " to the")     # a half word of the rest (the app's rule)

    def test_whole_ghost_is_the_rest(self):
        self.assertEqual(fim.cut(" park", " park."), "")

    def test_one_line(self):
        self.assertEqual(fim.cut(" big\nnew line", " house"), " big")

    def test_no_sentence_end_before_a_rest_that_goes_on(self):
        self.assertEqual(fim.cut(" now.", " and then"), " now")
        self.assertEqual(fim.cut(" later,", ", then"), " later")

    def test_sentence_end_kept_before_a_capital(self):
        self.assertEqual(fim.cut(" now.", " Then we go"), " now.")

    def test_no_trailing_space_before_a_spaced_rest(self):
        self.assertEqual(fim.cut(" very ", " good"), " very")

    def test_no_rest_leaves_the_ghost(self):
        self.assertEqual(fim.cut(" to the park", ""), " to the park")


class Shape(unittest.TestCase):
    def test_stops_where_the_rest_is_likely(self):
        t, r = toks([(" to", .9, .01), (" the", .8, .02), (" park", .7, .6), (".", .9, .1)])
        self.assertEqual(fim.shape(t, r, " park.", stop=.3), (" to the", "rest"))

    def test_nothing_missing(self):
        t, r = toks([(" to", .9, .5), (" the", .8, .02)])
        self.assertEqual(fim.shape(t, r, " park.", stop=.3), ("", "none"))

    def test_half_word_ignores_the_first_step(self):
        # he is spelling a word: the first step re-spells it, its rest p does not mean "nothing missing"
        t, r = toks([("o", .9, .5), (" the", .8, .02), (" park", .7, .9)])
        self.assertEqual(fim.shape(t, r, " park.", heal=" t", stop=.3)[0], "o the")

    def test_word_cap_and_bar(self):
        t, r = toks([(" a", .9, 0), (" b", .9, 0), (" c", .9, 0), (" d", .9, 0), (" e", .9, 0), (" f", .9, 0)])
        self.assertEqual(fim.shape(t, r, " zz", words=4, stop=.3), (" a b c d", "words"))
        t, r = toks([(" a", .9, 0), (" b", .2, 0), (" c", .9, 0)])
        self.assertEqual(fim.shape(t, r, " zz", stop=.3), (" a", "bar"))

    def test_open_while_the_word_is_being_written(self):
        t, r = toks([(" to", .9, 0)])
        self.assertEqual(fim.shape(t, r, " park.", stop=.3), ("", "open"))
        self.assertEqual(fim.shape(t, r, " park.", stop=.3, closed=True)[0], " to")

    def test_text_rule_without_the_stop(self):
        t, r = toks([(" to", .9, .9), (" the", .8, .9), (" park", .7, .9), (".", .9, .1)])
        self.assertEqual(fim.shape(t, r, " park.", stop=None)[0], " to the")


class Prompt(unittest.TestCase):
    def setUp(self):
        import prompt
        self.prompt = prompt

    def test_empty_after_is_the_same_as_no_after(self):
        cases = [("we walked to", "Notes", "", "", "", "", ""), ("Привіт, як", "Beeper", "Chat", "Вони: ну що?", "мої", "a copy", ""),
                 ("tell me", "Claude", "t", "", "", "", "short"), ("", "", "", "", "", "", "")]
        for c in cases:
            self.assertEqual(self.prompt.tail(*c, after=""), self.prompt.tail(*c), c)

    def test_after_goes_right_above_his_text_and_stays_put(self):
        old = self.prompt.MID_FORM
        try:
            self.prompt.MID_FORM = "after"
            t = self.prompt.tail("we walked", "Notes", after=" park.\nnext line")
            self.assertTrue(t.endswith("Після курсора: park. / next line\nwe walked"), t)
            s = self.prompt.tail("", "Notes", after=" park.\nnext line")
            self.assertTrue(t.startswith(s))     # the part that stays put while he types in the gap holds it
        finally:
            self.prompt.MID_FORM = old

    def test_default_is_plain_continuation(self):
        self.assertEqual(self.prompt.MID_FORM, "none")
        self.assertEqual(self.prompt.tail("we walked", "Notes", after=" park."), self.prompt.tail("we walked", "Notes"))

    def test_form_none_leaves_it_out(self):
        old = self.prompt.MID_FORM
        try:
            self.prompt.MID_FORM = "none"
            self.assertEqual(self.prompt.tail("we walked", "Notes", after=" park."), self.prompt.tail("we walked", "Notes"))
        finally:
            self.prompt.MID_FORM = old


class Server(unittest.TestCase):
    def load(self, fake):
        import prompt
        return lift("mid_line", "mid_result", "complete", fim=fim, prompt_mod=prompt, _complete=fake,
                    request_seq=lambda: 1, earlier=lambda *a, **k: "", knowledge=types.SimpleNamespace(snapshot=lambda: None),
                    look_ahead=lambda *a, **k: None, model=types.SimpleNamespace(asleep=False, loading=False))

    def test_no_mid_reads_as_before(self):
        seen = []
        ns = self.load(lambda req, **k: seen.append(k) or {"text": " to the park", "unsure": " park"})
        self.assertEqual(ns["mid_line"]({"before": "x", "after": " y", "after_line": " y"}), ("", ""))
        self.assertEqual(ns["mid_line"]({"before": "x", "mid": True, "after_line": "  "}), ("", ""))
        res = ns["complete"]({"before": "we walked", "ahead": False}, on_part="P")
        self.assertEqual(res, {"text": " to the park", "unsure": " park"})       # untouched
        self.assertEqual(seen[0]["on_part"], "P")

    def test_mid_cuts_any_answer(self):
        seen = []
        ns = self.load(lambda req, **k: seen.append(k) or {"text": " to the park", "unsure": " park", "src": "memory"})
        req = {"before": "we walked", "mid": True, "after": " park.\nmore", "after_line": " park.", "ahead": False}
        self.assertEqual(ns["mid_line"](req), (" park.\nmore", " park."))
        res = ns["complete"](req, on_part="P")
        self.assertEqual((res["text"], res["more"], "unsure" in res), (" to the", False, False))
        self.assertNotIn("on_part", seen[0])                                      # the whole answer at once
        self.assertEqual(ns["complete"](req, low=True)["text"], " to the")      # worked out ahead: cut too
        ns["_complete"] = lambda req, **k: {"text": "word", "replace": "wrod"}
        self.assertEqual(ns["complete"](req)["replace"], "wrod")


def model_ns():
    class Cancelled(Exception): pass
    return lift("complete_gated", path=ROOT / "engine/model.py", cls="Model", DIST=False, SETTLE=True, time=time, math=math,
                END=re.compile(r"[.!?…)\n]"), mx=types.SimpleNamespace(array=np.array, exp=np.exp, topk=lambda a, k: np.sort(a)[-k:]),
                Model=types.SimpleNamespace(Cancelled=Cancelled))


def fake(script, pieces):
    """A model stand-in: generate_step yields the scripted (token, {token: p}) steps."""
    V = len(pieces)
    def gen(*a, **k):
        for tok, ps in script:
            lp = np.full(V, -30.0)
            for t, p in ps.items(): lp[t] = math.log(p)
            yield tok, lp
    m = types.SimpleNamespace(lock=threading.Lock(), model=object(), _switch=Mock(), _feed=Mock(return_value=[0]),
                              cache=[], sampler=None, ids=[], healer=Mock(), russian_mask=lambda s: 0,
                              tok=types.SimpleNamespace(eos_token_id=0, decode=lambda ids: "".join(pieces[i] for i in ids)))
    return m, gen


class ModelMid(unittest.TestCase):
    pieces = ["<eos>", " to", " the", " park", ".", " big"]

    def test_ghost_ends_where_the_rest_is_likely(self):
        ns = model_ns()
        script = [(1, {1: .9, 3: .01}), (2, {2: .8, 3: .02}), (3, {3: .7}), (4, {4: .9})]
        m, ns["generate_step"] = fake(script, self.pieces)
        text, g, _, _ = ns["complete_gated"](m, [7], "", lambda toks: .9, max_tokens=12, mid={"rest": 3, "text": " park.", "stop": .3})
        self.assertEqual(text, " to the")
        self.assertEqual([round(x, 4) for x in m.last_rests[:3]], [.01, .02, .7])

    def test_nothing_missing_shows_nothing(self):
        ns = model_ns()
        m, ns["generate_step"] = fake([(1, {1: .5, 3: .45}), (2, {2: .8})], self.pieces)
        decide = Mock(return_value=.9)
        text, g, _, _ = ns["complete_gated"](m, [7], "", decide, max_tokens=12, mid={"rest": 3, "text": " park.", "stop": .3})
        self.assertEqual((text, g), ("", None)); decide.assert_not_called()

    def test_without_mid_the_loop_is_unchanged(self):
        ns = model_ns()
        script = [(1, {1: .9}), (2, {2: .8}), (3, {3: .7}), (4, {4: .9})]
        m, ns["generate_step"] = fake(script, self.pieces)
        text, *_ = ns["complete_gated"](m, [7], "", lambda toks: .9, max_tokens=12)
        self.assertEqual(text, " to the park.")     # first word, sure words, the sentence end (as before)


class ServerJob(unittest.TestCase):
    """engine/server.py _complete's model path with stand-ins: what reaches the prompt and complete_gated."""
    def build(self):
        import gatecore, words
        calls, prompts = [], []

        def complete_gated(ids, heal, decide, **kw):
            calls.append(kw)
            return (" to the" if kw.get("mid") else " to the park"), 0.9, 10.0, 30.0
        model = types.SimpleNamespace(asleep=False, loading=False, complete_gated=complete_gated, timing={}, last_sure=None,
                                      encode=lambda s: [42, 43] if s else [])
        import prompt
        ns = lift("_complete", "clean", "short", "extras", "mid_line", re=re, time=time, math=math, selector=lambda: None, gatecore=gatecore, model=model, finisher=words.Words(), words_mod=words,
                  wordgate=lambda: None, fim=fim, prompt_mod=prompt,
                  gate=lambda: {"th": {"ai": 0.4, "chat": 0.4}, "w": [5.0] + [0.0] * (len(gatecore.NAMES) - 1), "words": (2, 0.6, 1)},
                  parts=lambda r, remember=True: (r["before"], r.get("app", "Claude"), "", "", ""),
                  builder_for=lambda f: types.SimpleNamespace(ids_stable=lambda *a: prompts.append(a) or ([1], "", 0)), FMT="raw",
                  snippets=types.SimpleNamespace(offer=lambda b: None), phrases=types.SimpleNamespace(suggest=lambda b: ("", 0)),
                  actions=types.SimpleNamespace(detect=lambda b: None), knowledge=types.SimpleNamespace(snapshot=lambda: None, offered=0),
                  earlier=lambda *a, **k: "", run=lambda job, low=False, seq=None, cancel=None: job(lambda: False), AI_APPS=("claude",),
                  MAX_TOKENS=8, GROW=0.05, GROW_WORDS=6, MIN_P=0.6, MAX_WORDS=3, FUTURES=0)
        return ns["_complete"], calls, prompts

    def test_mid_reaches_the_model_and_the_prompt(self):
        complete, calls, prompts = self.build()
        req = {"before": "we walked ", "app": "Notes", "mid": True, "after": " park.", "after_line": " park.", "length": "sentence",
               "words": False, "memory": False}
        complete(req)
        self.assertEqual(calls[0]["mid"], {"rest": 42, "text": " park."})
        self.assertIsNone(calls[0]["run"]); self.assertIsNone(calls[0]["tail"]); self.assertEqual(calls[0]["max_tokens"], fim.TOKENS)
        self.assertEqual(prompts[0][-1], " park.")

    def test_no_mid_no_change(self):
        complete, calls, prompts = self.build()
        complete({"before": "we walked ", "app": "Notes", "after": " park.", "after_line": " park.", "words": False, "memory": False})
        self.assertNotIn("mid", calls[0])
        self.assertEqual(prompts[0][-1], "")      # `after` empty: the prompt is the old one (Prompt tests)


if __name__ == "__main__":
    unittest.main()

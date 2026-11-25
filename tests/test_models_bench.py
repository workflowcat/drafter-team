"""The models round's scripts (bench/models/) on made-up rows and lines: no model, no data/ read.

    .venv/bin/python -B tests/test_models_bench.py
"""
import importlib, json, sys, tempfile, unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "bench/models")); sys.path.insert(0, str(ROOT / "engine"))
import record as R
import shared as S
import twotier as T
import context as CX
import trial as TR


class WordTok:
    """A made-up tokenizer: one token per word or space run, so cuts are easy to check."""
    def encode(self, s):
        import re
        return re.findall(r"\s+|\S+", s)

    def decode(self, ids):
        return "".join(ids)


class CharTok:
    def encode(self, s): return list(s)
    def decode(self, ids): return "".join(ids)


class Cut(unittest.TestCase):
    def test_short_text_kept(self):
        t = WordTok()
        self.assertEqual(R.cut_tokens("один два", 10, t.encode, t.decode), "один два")
        self.assertEqual(R.cut_tokens("один два", None, t.encode, t.decode), "один два")

    def test_cut_keeps_last_tokens(self):
        t = WordTok()
        self.assertEqual(R.cut_tokens("one two three four", 3, t.encode, t.decode), "three four")

    def test_cut_never_leaves_half_a_word(self):
        t = CharTok()
        out = R.cut_tokens("перший другий третій", 8, t.encode, t.decode)
        self.assertEqual(out, "третій")                 # "і третій" -> starts at a word
        self.assertEqual(R.cut_tokens("abc", 0, t.encode, t.decode), "")


class Head(unittest.TestCase):
    rules = staticmethod(lambda: "Пише коротко.")
    words = staticmethod(lambda: ["Кіт", "Drafter"])
    ex = staticmethod(lambda: ["перше повідомлення", "друге"])

    def test_all_parts_equal_engine_head(self):
        import prompt
        old = (prompt.rules, prompt.words, prompt.load_json)
        try:
            prompt.rules, prompt.words = self.rules, self.words
            prompt.load_json = lambda p, d: {"examples": self.ex()}
            self.assertEqual(R.head_from(set(R.PARTS), self.rules, self.words, self.ex), prompt.head())
        finally:
            prompt.rules, prompt.words, prompt.load_json = old

    def test_parts_left_out(self):
        h = R.head_from({"words"}, self.rules, self.words, self.ex)
        self.assertIn("Кіт", h); self.assertNotIn("Пише", h); self.assertNotIn("перше", h)
        self.assertEqual(R.head_from(set(), self.rules, self.words, self.ex), "###\n")

    def test_patch_cuts_screen_text_in_the_prompt(self):
        import prompt
        try:
            class FakeModel:
                tok = WordTok()
                def bos(self): return []
                def encode(self, s): return WordTok().encode(s)
            R.patch(prompt, keep=["words"], ctx_tokens=3)
            prompt.words = self.words
            prompt.rules = self.rules
            b = prompt.Builder(FakeModel())
            self.assertNotIn("Пише", b.head)
            ids, heal = b.ids("Привіт як", app="Beeper", context="раз два три чотири п'ять")
            text = "".join(ids)
            self.assertIn("чотири п'ять", text); self.assertNotIn("два", text)
            self.assertNotIn("розмовно", text)      # no style line without the rules part
            self.assertEqual(heal, " як")
        finally:
            importlib.reload(prompt)

    def test_take(self):
        argv = ["repo", "--head", "rules", "--n", "3"]
        self.assertEqual(R.take(argv, "--head"), "rules")
        self.assertEqual(argv, ["repo", "--n", "3"])
        self.assertIsNone(R.take(argv, "--ctx-tokens"))


class Shared(unittest.TestCase):
    def test_timing(self):
        rows = [{"toks": [["a", .9, .1, 40.0, "a"], ["ab", .9, .1, 47.0, "b"], ["abc", .9, .1, 55.0, "c"]]},
                {"toks": [["x", .9, .1, 60.0, "x"]]}, {"toks": []}]
        t = S.timing(rows)
        self.assertEqual(t["first_ms_p50"], 50.0)
        self.assertEqual(t["token_ms_p50"], 7.5)

    def test_line_start(self):
        rows = {(0, 1): {"toks": [["a", 1, 0, 200.0]]}, (0, 2): {"toks": [["a", 1, 0, 30.0]]},
                (1, 3): {"toks": [["a", 1, 0, 100.0]]}}
        self.assertEqual(S.line_start_ms(None, rows)["line_start_ms_p50"], 150.0)

    def test_peak(self):
        self.assertEqual(S.peak_gb(["  10 items, 5s, peak 2.10 GB, free 60%", "x: 3 items, peak 2.65 GB"]), 2.65)
        self.assertIsNone(S.peak_gb(["nothing"]))

    def test_best_recipe(self):
        with tempfile.TemporaryDirectory() as d:
            w = lambda n, g, r: (Path(d) / f"train-{n}.json").write_text(json.dumps({"variant": n, "recipe": r, "vs_live": {"gain_points": g}}))
            self.assertEqual(S.best_recipe(d), (None, None))
            w("ref", 0.4, {"rank": 8}); w("dora", 0.9, {"fine_tune_type": "dora"}); w("r4", 0.2, {"rank": 4})
            (Path(d) / "train-iters-3000-smoke.json").write_text(json.dumps({"variant": "iters-3000", "vs_live": {"gain_points": 5}}))
            self.assertEqual(S.best_recipe(d), ("dora", {"fine_tune_type": "dora"}))
            w("dora", 0.3, {"fine_tune_type": "dora"})
            self.assertEqual(S.best_recipe(d), (None, None))    # ref is best: nothing new to try

    def test_candidates_have_caps(self):
        for n, c in S.CANDIDATES.items():
            self.assertGreater(c["guard"], c["cap"], n)
            self.assertGreater(c["train_cap"], c["cap"], n)


class Trial(unittest.TestCase):
    def test_train_args(self):
        c = {"repo": "made/up-model", "rev": None, "batch": 2, "ckpt": True}
        r = {**TR.TS.LIVE}
        a = list(map(str, TR.train_args(c, r, Path("/tmp/x"), Path("/tmp/d"), smoke=True)))
        self.assertEqual(a[0], "20")
        self.assertEqual(a[a.index("--model") + 1], "made/up-model")
        self.assertEqual(a[a.index("--batch-size") + 1], "2")
        self.assertIn("--grad-checkpoint", a)
        self.assertEqual(a[a.index("--num-layers") + 1], "16")


class Context(unittest.TestCase):
    def test_variants_and_delta(self):
        self.assertTrue(set(CX.QUICK) <= set(CX.VARIANTS) and set(CX.SMOKE) <= set(CX.VARIANTS))
        rows = {"full": {"claude": {"saved": 25.0, "right": 60.0, "first_ms_p50": 40.0}},
                "ctx-0": {"claude": {"saved": 23.5, "right": 61.0, "first_ms_p50": 30.0}}}
        CX.delta(rows)
        self.assertEqual(rows["ctx-0"]["claude"]["d_saved"], -1.5)
        self.assertEqual(rows["ctx-0"]["claude"]["d_first_ms_p50"], -10.0)
        self.assertEqual(rows["full"]["claude"]["d_saved"], 0)


class TwoTier(unittest.TestCase):
    def test_parse_gaps(self):
        lines = ["2026-11-20T10:00:00Z late com.example.app 300ms typed 2",
                 "2026-11-20T10:00:01Z late com.example.app 90ms typed 1 predicted",
                 "2026-11-20T10:00:02Z shown com.example.app 80ms engine 60ms ctx"]
        g, src = T.parse_gaps(lines)
        self.assertEqual((sorted(g), src), ([90.0, 150.0], "late"))
        kg = "2026-11-20T10:01:00Z keygap chat lt60 1 lt90 0 lt120 2 lt150 0 lt200 0 lt300 0 lt500 0 lt1000 1 pause 1 ghost 2"
        g, src = T.parse_gaps(lines + [kg])
        self.assertEqual((g, src), ([30.0, 105.0, 105.0, 750.0, T.PAUSE_MS], "keygap"))    # histogram lines win
        self.assertEqual(T.parse_gaps([]), ([], "none"))

    def test_keygap_lines(self):
        lines = ["2026-11-20T10:01:00Z keygap chat lt60 1 lt90 3 lt120 0 lt150 0 lt200 0 lt300 0 lt500 0 lt1000 0 pause 0 ghost 1",
                 "2026-11-20T10:02:00Z keygap ai lt60 0 lt90 0 lt120 0 lt150 2 lt200 1 lt300 0 lt500 0 lt1000 0 pause 2 ghost 4",
                 "2026-11-20T10:02:30Z keygap chat lt60 0 lt90 1 lt120 0 lt150 0 lt200 0 lt300 0 lt500 0 lt1000 0 pause 0 ghost 0",
                 "2026-11-20T10:03:00Z keygap com.example.app 140ms",          # the old per-gap shape: not read
                 "2026-11-20T10:03:01Z shown com.example.app 80ms engine 60ms ctx"]
        hist, pauses, ghost = T.keygap_hist(lines)
        self.assertEqual((hist[60], hist[90], hist[150], hist[200], pauses, ghost), (1, 4, 2, 1, 2, 5))
        hist, pauses, ghost = T.keygap_hist(lines, kind="chat")
        self.assertEqual((sum(hist.values()), pauses, ghost), (5, 0, 1))
        self.assertEqual(T.parse_gaps(lines, kind="chat"), ([30.0, 75.0, 75.0, 75.0, 75.0], "keygap"))
        g, src = T.parse_gaps(lines, kind="ai")
        self.assertEqual((sorted(g), src), ([135.0, 135.0, 175.0, T.PAUSE_MS, T.PAUSE_MS], "keygap"))
        self.assertEqual(T.parse_gaps(lines, kind="mail"), ([], "none"))      # no late lines either
        self.assertEqual(T.hist_gaps({}, 0), [])

    def test_deciles(self):
        d = T.deciles(list(range(1, 101)))
        self.assertEqual(len(d), 10); self.assertEqual(d[0], 6); self.assertEqual(d[-1], 96)

    def test_in_time(self):
        self.assertTrue(T.in_time(300, 100, 150, 3))
        self.assertFalse(T.in_time(240, 100, 150, 3))      # came after the next key
        self.assertFalse(T.in_time(90, 100, 10, 3))         # he typed before the pause ended

    def test_spot_stats(self):
        spots = [
            {"small": ("hello", 40, False), "big": ("help me", 100, True)},     # big fixes a wrong small ghost
            {"small": ("the plan", 40, True), "big": ("the plan for", 100, True)},   # big extends a right one
            {"small": ("", 40, False), "big": ("", 100, False)},                # nothing either way
            {"small": ("yes", 40, True), "big": ("no way", 100, False)},        # big would break a right one
        ]
        s = T.spot_stats(spots, gaps=[500], pause=50, ipc=3)
        self.assertEqual(s["arrives"], 75.0)                     # 3 of 4 spots have a big ghost in time
        self.assertEqual(s["right_where_small_wrong"], 50.0)     # 1 of 2 (wrong one, empty one)
        self.assertEqual(s["wrong_where_small_right"], 50.0)     # 1 of 2
        self.assertEqual(s["extends_small"], 25.0)
        slow = T.spot_stats(spots, gaps=[120], pause=50, ipc=3)
        self.assertEqual(slow["arrives"], 0.0)

    def test_pair_policy(self):
        small = lambda row, b, s: ("small", 40)
        big = lambda row, b, s: ("big ghost", 100)
        pol = T.pair_policy(small, big, {(0, 1): {}}, pause=50, ipc=3, gap=200)
        self.assertEqual(pol({"_key": (0, 1)}, "", "claude"), ("big ghost", 153))
        self.assertEqual(pol({"_key": (0, 2)}, "", "claude"), ("small", 40))
        late = T.pair_policy(small, big, {(0, 1): {}}, pause=50, ipc=3, gap=120)
        self.assertEqual(late({"_key": (0, 1)}, "", "claude"), ("small", 40))


if __name__ == "__main__":
    unittest.main(verbosity=1)

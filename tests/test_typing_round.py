"""Typing round of 13 November 2026: ghost length (minimum letters, growing a short ghost), the merged LoRA layers,
the held-out set and the kept-letters measure. Synthetic data only; no model, MLX or personal records."""
import json
from pathlib import Path
import sys
import types
import unittest
from unittest.mock import Mock

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "engine")); sys.path.insert(0, str(ROOT / "bench"))
import gatecore
from server_src import lift


def toks(*pieces):
    """Recorded tokens as typebench writes them: [text so far, p, p2, ms, piece]."""
    out, text = [], ""
    for i, (piece, p) in enumerate(pieces):
        text += piece
        out.append([text, p, 0.01, 10.0 * (i + 1), piece])
    return out


class Letters(unittest.TestCase):
    def test_spaces_do_not_count(self):
        self.assertEqual(gatecore.letters(" the "), 3)
        self.assertEqual(gatecore.letters("ing, "), 4)
        self.assertEqual(gatecore.letters(""), 0)


class Grow(unittest.TestCase):
    def test_short_ghost_grows_while_tokens_are_sure_enough(self):
        t = toks((" to", 0.9), (" the", 0.4), (" repo", 0.35), (" and", 0.05), (" ", 0.5))
        first = gatecore.next_word(t[-1][0])
        sure = gatecore.extend(t, first, 0.5, 3)
        self.assertEqual(sure, " to ")
        self.assertEqual(gatecore.grow(t, sure, 0.3, 6, 5), " to the ")

    def test_stops_as_soon_as_long_enough(self):
        t = toks((" to", 0.9), (" the", 0.4), (" repo", 0.35), (" now", 0.9), (" ", 0.9))
        self.assertEqual(gatecore.grow(t, " to ", 0.3, 6, 5), " to the ")

    def test_never_gets_there_returns_the_short_ghost(self):
        t = toks((" to", 0.9), (" a", 0.1), (" b", 0.9))
        self.assertEqual(gatecore.grow(t, " to ", 0.3, 6, 5), " to ")

    def test_a_word_the_token_limit_cut_is_not_taken(self):
        # "repos" may go on ("repository"): only a word something follows is whole
        t = toks((" to", 0.9), (" repo", 0.9))
        self.assertEqual(gatecore.grow(t, " to ", 0.3, 6, 5), " to ")

    def test_cleaned_ghost_without_its_leading_space(self):
        t = toks((" to", 0.9), (" the", 0.9), (" ", 0.9))
        self.assertEqual(gatecore.grow(t, "to ", 0.3, 6, 5), "to the ")

    def test_long_enough_is_left_alone(self):
        t = toks((" deploy", 0.9), (" it", 0.9))
        self.assertEqual(gatecore.grow(t, " deploy ", 0.3, 6, 5), " deploy ")


class ServerShort(unittest.TestCase):
    def setUp(self):
        self.ns = lift("short", gatecore=gatecore)

    def test_minimum_from_the_request(self):
        short = self.ns["short"]
        self.assertTrue(short({"min_letters": 5}, "ing "))
        self.assertFalse(short({"min_letters": 5}, "ation "))
        self.assertFalse(short({}, "a"))                    # other callers (Aleph) set none
        self.assertFalse(short({"min_letters": 5}, ""))     # nothing is not "short"


class MergedLayers(unittest.TestCase):
    """model.lora swaps the merged copies in and the plain layers back (or, merged only, the LoRA at minus its scale)."""
    def setUp(self):
        self.ns = lift("lora", path=ROOT / "engine/model.py", cls="Model")

    def test_swap(self):
        parent = types.SimpleNamespace(q_proj="merged")
        lora_mod = types.SimpleNamespace(linear="plain", scale=20.0)
        m = types.SimpleNamespace(adapter="x", strength=1.0, fused=[(parent, "q_proj", lora_mod, "merged", 20.0)])
        self.ns["lora"](m, False); self.assertEqual(parent.q_proj, "plain")      # plain kept (DRAFTER_LORA_KEEP_PLAIN=1)
        self.ns["lora"](m, True); self.assertEqual(parent.q_proj, "merged")
        self.assertEqual(lora_mod.scale, 20.0)

    def test_merged_only_runs_minus_the_layer(self):
        # engine memory round: no plain copy; layer off = the LoRA module at minus its scale on the merged layer
        parent = types.SimpleNamespace(q_proj="merged")
        lora_mod = types.SimpleNamespace(linear="merged", scale=20.0)
        m = types.SimpleNamespace(adapter="x", strength=0.5, fused=[(parent, "q_proj", lora_mod, "merged", 20.0)])
        self.ns["lora"](m, False); self.assertIs(parent.q_proj, lora_mod); self.assertEqual(lora_mod.scale, -10.0)
        self.ns["lora"](m, True); self.assertEqual(parent.q_proj, "merged")

    def test_unmerged_keeps_the_scale_switch(self):
        LoRALinear = type("LoRALinear", (), {})
        lm = LoRALinear(); lm.scale = 20.0
        m = types.SimpleNamespace(adapter="x", fused=[], model=types.SimpleNamespace(modules=lambda: [lm]))
        self.ns["lora"](m, False); self.assertEqual(lm.scale, 0.0)
        self.ns["lora"](m, True); self.assertEqual(lm.scale, 20.0)


class HeldSet(unittest.TestCase):
    def test_only_lines_after_the_cutoff_each_app_kind(self):
        import make_held
        rows = [{"t": 5, "app": "Claude", "text": "old line one two three"},
                {"t": 20, "app": "Claude", "text": "please check the deploy now", "context": "screen"},
                {"t": 21, "app": "Claude", "text": "please check the deploy now"},          # the same line again
                {"t": 22, "app": "Beeper", "text": "ok see you at five then"},
                {"t": 23, "app": "Beeper", "text": "too short"},
                {"t": 24, "app": "Notes", "text": "not a chat or an AI app here"}]
        out = make_held.pick(rows, cut=10, ai_n=5, chat_n=5)
        self.assertEqual(sorted(o["text"] for o in out), ["ok see you at five then", "please check the deploy now"])
        self.assertEqual({o["src"] for o in out}, {"claude", "beeper"})


class LengthPolicy(unittest.TestCase):
    """bench/lengths.py mirrors model.complete_gated: a short sure ghost grows at the lower bar or is hidden."""
    def policy(self, **knobs):
        import lengths
        W = types.SimpleNamespace(finish=lambda *a: "")
        gate = {"th": {"ai": 0.0, "chat": 0.0}, "w": [10.0] + [0.0] * 14, "words": (2, 0.6, 1)}
        lengths.finish_with_source = lambda *a, **k: ("", "")
        return lengths.policy(W, None, gate, **knobs)

    def test_live_shows_the_short_word(self):
        row = {"toks": toks((" to", 0.9), (" the", 0.4), (" repo", 0.35), (" now", 0.05), (" ", 0.5))}
        self.assertEqual(self.policy()(row, "push it", "claude")[0], " to ")

    def test_tail_adds_lighter_words(self):
        row = {"toks": toks((" to", 0.9), (" the", 0.9), (" repo", 0.3), (" and", 0.25), (" then", 0.05), (" ", 0.5))}
        self.assertEqual(self.policy(min_letters=5)(row, "push it", "claude")[0], " to the ")
        self.assertEqual(self.policy(min_letters=5, tail=0.2, tail_words=8)(row, "push it", "claude")[0], " to the repo and ")

    def test_minimum_hides_or_grows(self):
        row = {"toks": toks((" to", 0.9), (" the", 0.4), (" repo", 0.35), (" now", 0.05), (" ", 0.5))}
        self.assertEqual(self.policy(min_letters=5)(row, "push it", "claude")[0], "")
        self.assertEqual(self.policy(min_letters=5, grow=0.3)(row, "push it", "claude")[0], " to the ")


class KeptLetters(unittest.TestCase):
    def test_taken_text_that_survives_into_the_sent_line(self):
        import kept
        acc = [{"t": 100, "app": "Claude", "text": "deploy ", "before": "please ", "ghost_len": 13, "src": "gate"},
               {"t": 101, "app": "Claude", "text": "staging", "before": "please deploy ", "ghost_len": 7, "src": "gate"},
               {"t": 200, "app": "Beeper", "text": "tomorrow ", "before": "see you ", "ghost_len": 9, "src": "gate"}]
        sent = [{"t": 110, "app": "Claude", "text": "please deploy prod"},
                {"t": 260, "app": "Beeper", "text": "see you tomorrow at 5"}]
        r = kept.measure(acc, sent, [])
        self.assertEqual(r["Claude"]["taken"], 13)        # letters, spaces left out
        self.assertEqual(r["Claude"]["kept"], 6)          # "staging" was changed to "prod"
        self.assertEqual(r["Beeper"]["kept"], 8)
        self.assertEqual(r["Claude"]["by"]["10-14"], [6, 6])
        self.assertEqual(r["Claude"]["by"]["5-9"], [7, 0])


class TwoStepGhost(unittest.TestCase):
    """Round two: parts are drawn up to the last whole word, the lighter tail follows sure enough tokens."""
    def test_whole_words_never_show_a_word_still_being_spelled(self):
        self.assertEqual(gatecore.whole_words(" to the", 3), (" to ", 3))
        self.assertEqual(gatecore.whole_words(" to the ", 8), (" to the ", 8))
        self.assertEqual(gatecore.whole_words("ing", 3), ("", 0))
        self.assertEqual(gatecore.whole_words("ing, ", 5), ("ing, ", 5))

    def test_tail_goes_on_while_tokens_clear_the_bar(self):
        t = toks((" to", 0.9), (" the", 0.9), (" repo", 0.3), (" and", 0.25), (" then", 0.05), (" go", 0.9), (" ", 0.9))
        sure = gatecore.extend(t, gatecore.next_word(t[-1][0]), 0.5, 3)
        self.assertEqual(sure, " to the ")
        self.assertEqual(gatecore.more_words(t, sure, 0.2, 8), " to the repo and ")
        self.assertEqual(gatecore.more_words(t, sure, 0.2, 3), " to the repo ")
        self.assertEqual(gatecore.more_words(t, sure, 0.5, 8), " to the ")

    def test_stream_writes_parts_then_the_answer(self):
        ns = lift("stream", cls="H")
        import io
        out = io.BytesIO()
        me = types.SimpleNamespace(wfile=out, send_response=Mock(), send_header=Mock(), end_headers=Mock())

        def work(part):
            part({"part": "deploy "}); part({"part": "deploy it "})
            return {"text": "deploy it now ", "unsure": "now "}
        ns["stream"](me, work)
        lines = [json.loads(l) for l in out.getvalue().splitlines()]
        self.assertEqual([l.get("part") for l in lines[:2]], ["deploy ", "deploy it "])
        self.assertEqual(lines[-1], {"text": "deploy it now ", "unsure": "now ", "final": True})
        self.assertTrue(me.close_connection)


class BeeperUnderLaunchd(unittest.TestCase):
    """The nightly runs with launchd's PATH; the 8 November retrain drew no Beeper lines and people_fresh.py died."""
    def test_found_outside_path(self):
        import os, tempfile
        sys.modules.pop("people", None)
        import people
        with tempfile.TemporaryDirectory() as home:
            bin_dir = Path(home) / ".npm-global/bin"; bin_dir.mkdir(parents=True)
            exe = bin_dir / "beeper"; exe.write_text("#!/bin/sh\n"); exe.chmod(0o755)
            old = os.environ.get("HOME"); os.environ["HOME"] = home
            try:
                self.assertEqual(people.beeper_bin("/usr/bin:/bin:/usr/sbin:/sbin"), str(exe))
            finally:
                os.environ["HOME"] = old
        with tempfile.TemporaryDirectory() as empty:
            old = os.environ.get("HOME"); os.environ["HOME"] = empty
            try:
                found = people.beeper_bin(empty)
                self.assertTrue(found == "beeper" or not found.startswith(empty))
            finally:
                os.environ["HOME"] = old

    def test_nightly_sets_path(self):
        self.assertIn(".npm-global/bin", (ROOT / "bench/nightly.sh").read_text())


if __name__ == "__main__":
    unittest.main()

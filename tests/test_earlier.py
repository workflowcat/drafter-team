"""Earlier round (2026-11-16): the 3-5 words run (engine/gatecore.py run_words mode "words"), the lower gate's bar per
model (gatecore.guess_bar), the request numbers (gatecore.ghost_words), the engine path that marks guesses (read from
engine/server.py, never imported: it loads a model) and the bench policy (bench/earlier.py). Made-up lines only.

    .venv/bin/python -B tests/test_earlier.py
"""
import sys, types, unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "engine")); sys.path.insert(0, str(ROOT / "bench"))
import gatecore as g
from server_src import lift


def toks(words, ps):
    out, t = [], ""
    for w, p in zip(words, ps):
        t += w; out.append([t, p, 0.1, 10.0 * (len(out) + 1)])
    return out


class Words(unittest.TestCase):
    def test_three_words_shown_even_when_unsure(self):
        # the sentence run stops after "can" (0.05 under the floor); words mode keeps 3 words whatever their chance
        t = toks(["We", " can", " ship", " it", " today", " now", " "], [.9, .05, .2, .05, .05, .9, .9])
        self.assertEqual(g.run_words(t, "sentence")[0], "We ")
        text, _, why, _ = g.run_words(t, "words")
        self.assertEqual((text, why), ("We can ship ", "floor"))

    def test_at_most_five(self):
        t = toks(["We", " can", " ship", " it", " today", " after", " lunch", " "], [.99] * 8)
        text, _, why, _ = g.run_words(t, "words")
        self.assertEqual((text, why), ("We can ship it today ", "words"))

    def test_sure_words_go_on_to_five_between_min_and_max(self):
        t = toks(["We", " can", " ship", " it", " today", " "], [.9, .9, .9, .9, .9, .9])
        self.assertEqual(g.run_words(t, "words")[0], "We can ship it today ")

    def test_sentence_end_and_line_break_end_it_sooner(self):
        self.assertEqual(g.run_words(toks(["Yes", ".", " We", " go", " "], [.9] * 5), "words")[:3:2], ("Yes. ", "sentence"))
        self.assertEqual(g.run_words(toks(["Ok", " then", "\n", "Go", " "], [.9] * 5), "words")[:3:2], ("Ok then", "line"))

    def test_no_clause_or_comma_stop(self):
        t = toks(["Well", ",", " we", " can", " go", " "], [.9] * 6)
        self.assertEqual(g.run_words(t, "words")[0], "Well, we can go ")

    def test_garbage_word_still_ends_it(self):
        self.assertEqual(g.run_words(toks(["We", " xq", " go", " "], [.9, .001, .9, .9]), "words")[:3:2], ("We ", "floor"))

    def test_min_and_max_from_the_request(self):
        t = toks(["a", " b", " c", " d", " e", " f", " "], [.01] * 7)
        self.assertEqual(g.run_words(t, "words", min_words=2, words=2)[0], "a b ")
        self.assertEqual(g.ghost_words({}), {"min_words": 3, "max_words": 5})
        self.assertEqual(g.ghost_words({"words_min": 9, "words_max": 1}), {"min_words": 5, "max_words": 5})
        self.assertEqual(g.ghost_words({"words_min": "x", "words_max": None}), {"min_words": 3, "max_words": 5})

    def test_other_modes_unchanged(self):
        t = toks(["I", " think", " we", " should", " go", " home", ".", " Then", " "], [.9] * 9)
        self.assertEqual(g.run_words(t)[0], "I think we should go home. ")


class Guess(unittest.TestCase):
    def test_bar_per_model(self):
        self.assertEqual(g.guess_bar({}, "live"), 0.15)              # more-bold round, 17 November 2026
        self.assertEqual(g.guess_bar({}, "qwen3-4b-mine"), 0.15)
        self.assertEqual(g.guess_bar({}, "unknown"), g.GUESS_DEFAULT)
        self.assertEqual(g.guess_bar({"guess": 0.33}, "live"), 0.33)
        self.assertEqual(g.guess_bar({"guess": 0.33}, "live", "0.2"), 0.2)
        self.assertEqual(g.guess_bar(None, "live", "bad"), 0.15)
        self.assertTrue(all(v < 0.4 for v in g.GUESS.values()))   # under the gates' own 0.4

    def test_his_setting(self):
        """guessBar (Bolder / Careful) comes as the request's "guess_bar": over the gate file and the catalog, under
        the env, kept inside GUESS_RANGE; a bad value falls through."""
        self.assertEqual(g.guess_bar({"guess": 0.33}, "live", None, 0.25), 0.25)
        self.assertEqual(g.guess_bar({}, "live", "0.2", 0.3), 0.2)
        self.assertEqual(g.guess_bar({}, "live", None, 0.0), g.GUESS_RANGE[0])
        self.assertEqual(g.guess_bar({}, "live", None, 0.9), g.GUESS_RANGE[1])
        self.assertEqual(g.guess_bar({}, "live", None, "x"), 0.15)
        self.assertLess(g.GUESS_RANGE[1], 0.4)

    def test_selector_bar_moves_with_it(self):
        self.assertEqual(g.bolder_sel(0.65, 0.3), 0.65)            # the bar the selector was set with
        self.assertEqual(g.bolder_sel(0.65, 0.15), 0.575)          # the default: half a step lower
        self.assertEqual(g.bolder_sel(0.65, 0.35), 0.675)          # careful: higher
        self.assertEqual(g.bolder_sel(0.65, None), 0.65)
        self.assertEqual(g.bolder_sel(0.35, 0.05, 1.0), 0.3)       # never under 0.3

    def test_server_reads_his_setting(self):
        src = (ROOT / "engine/server.py").read_text()
        self.assertIn('os.environ.get("DRAFTER_GUESS"), req.get("guess_bar")) if req.get("guess") else None', src)
        self.assertIn('sel = dict(sel, th=gatecore.bolder_sel(sel["th"], gatecore.guess_bar(', src)

    def test_server_marks_guesses(self):
        src = (ROOT / "engine/server.py").read_text()
        self.assertIn('if low is not None and f and p >= low:', src)
        self.assertIn('res["guess"] = True', src)
        self.assertIn('if req.get("guess_shade", True): res["unsure"] = out', src)
        self.assertIn('run_mode.update(gatecore.ghost_words(req))', src)
        self.assertIn('min_words=run.get("min_words")', (ROOT / "engine/model.py").read_text())


class Early(unittest.TestCase):
    """Step 6: one notch lower, lower still right after a space; nothing changes with the switch off or guesses off."""
    def test_bar(self):
        pass
        self.assertEqual(g.early_bar(0.3, "see you", True), 0.25)
        self.assertEqual(g.early_bar(0.3, "see you ", True), 0.2)
        self.assertEqual(g.early_bar(0.3, "see you\n", True), 0.2)
        self.assertEqual(g.early_bar(0.3, "see you ", False), 0.3)
        self.assertIsNone(g.early_bar(None, "see you ", True))
        self.assertEqual(g.early_bar(0.1, "see you ", True), 0.1)      # a lower bar from the env stays lower

    def test_wired(self):
        src = (ROOT / "engine/server.py").read_text()
        self.assertIn('low = gatecore.early_bar(low, before, bool(req.get("early_start")))', src)
        self.assertLess(src.index("low = gatecore.guess_bar("), src.index("low = gatecore.early_bar("))


class Keep(unittest.TestCase):
    def test_keeps_when_he_typed_a_few_letters_on(self):
        self.assertTrue(g.keeps("see you to", "see you tom"))
        self.assertTrue(g.keeps("see you ", "see you tomo"))
        self.assertFalse(g.keeps("see you ", "see you tomorr"))       # more than 4: a new ask
        self.assertFalse(g.keeps("see you to", "see you ta"))         # not the same text
        self.assertFalse(g.keeps("see you", "see you"))               # nothing typed
        self.assertFalse(g.keeps("see you", "see you\nok"))           # a new line
        self.assertFalse(g.keeps("", "a"))

    def test_keeps_when_he_types_the_answer_through(self):
        """Short-ghost round (2026-11-18): past 4 letters it still runs on when what he typed is what it wrote."""
        self.assertTrue(g.keeps("see you ", "see you tomorr", written="tomorrow at noon"))
        self.assertTrue(g.keeps("see you", "see you tomorrow ", written=" tomorrow at noon"))
        self.assertTrue(g.keeps("see you ", "see you tomorrow at", written=" tomorrow  at noon"))   # spaces as clean()
        self.assertFalse(g.keeps("see you ", "see you tomorx", written="tomorrow at noon"))         # he left it
        self.assertFalse(g.keeps("see you ", "see you tomorrow at noon too", written="tomorrow at noon"))
        self.assertFalse(g.keeps("see you ", "see you tomorr", written=""))                         # nothing written yet
        self.assertFalse(g.keeps("see you ", "see you tom\nx", written="tom\nx"))                   # a new line

    def test_server_records_what_the_stream_wrote(self):
        src = (ROOT / "engine/server.py").read_text()
        self.assertIn('if WRITTEN["seq"] == seq: WRITTEN["text"] = raw.replace("\\ufffd", "")', src)
        self.assertIn('gatecore.keeps(r[1], normal_space(req.get("before") or "")[-4000:], written=written)', src)
        self.assertIn('WRITTEN.update(seq=seq, text="")', src)

    def test_server_wiring(self):
        src = (ROOT / "engine/server.py").read_text()
        self.assertIn("gone = box.get(\"cancel\") or (lambda: stale(seq) and seq not in KEPT)", src)
        self.assertIn("keep_running(req)    # earlier round", src)
        self.assertLess(src.index("keep_running(req)    # earlier round"), src.index("seq = request_seq()  # cancel before"))
        self.assertIn('if req.get("keep_on") and not low else {}', src)


def server_parts(names):
    """The named top-level functions and assignments of engine/server.py, run in a fresh namespace (no model)."""
    return lift(*names, gatecore=g, normal_space=lambda t: t)


class KeepWorker(unittest.TestCase):
    def run_case(self, newer_before, keep_on=True, newer=None, swap_model=False, written=None):
        import threading, time
        ns = server_parts({"jobs", "JOB_ORDER", "latest", "LATEST_LOCK", "request_seq", "stale", "RUNNING", "KEPT", "WRITTEN",
                           "keep_running", "keep_ident", "worker", "run"})
        ns["model"] = types.SimpleNamespace(repo="made-up/model", adapter=None, strength=1.0)
        threading.Thread(target=ns["worker"], daemon=True).start()
        seen = {}

        def job(cancelled):
            for _ in range(40):
                time.sleep(0.005)
                if cancelled(): return {"text": "", "stopped": True}
            return {"text": "morrow"}
        out = {}
        seq = ns["request_seq"]()
        asked = {"before": "see you to", "after": "", "field": 3, "keep_on": keep_on}
        t = threading.Thread(target=lambda: out.update(ns["run"](job, seq=seq, before="see you to" if keep_on else None,
                                                                 ident=ns["keep_ident"](asked))))
        t.start(); time.sleep(0.03)
        if written is not None: ns["WRITTEN"]["text"] = written      # what the stream's parts wrote so far
        if swap_model: ns["model"] = types.SimpleNamespace(repo="made-up/model", adapter="made-up/adapter", strength=1.0)
        ns["keep_running"](dict(asked, before=newer_before, **(newer or {}))); ns["request_seq"]()
        t.join(2)
        return out

    def test_runs_on_when_he_typed_its_start(self):
        self.assertEqual(self.run_case("see you tom").get("text"), "morrow")

    def test_runs_on_when_he_types_its_whole_first_word(self):
        """Short-ghost round: past 4 letters, still the answer's own words."""
        self.assertEqual(self.run_case("see you tomorrow ", written="morrow at noon").get("text"), "morrow")
        self.assertTrue(self.run_case("see you tomorrow ", written="").get("stopped"))
        self.assertTrue(self.run_case("see you tomatoes", written="morrow at noon").get("stopped"))

    def test_stops_for_other_text(self):
        self.assertTrue(self.run_case("see you la").get("stopped"))

    def test_stops_when_the_text_after_the_caret_changed(self):
        self.assertTrue(self.run_case("see you tom", newer={"after": " at noon"}).get("stopped"))

    def test_stops_in_another_field(self):
        self.assertTrue(self.run_case("see you tom", newer={"field": 4}).get("stopped"))

    def test_stops_when_the_model_changed(self):
        self.assertTrue(self.run_case("see you tom", swap_model=True).get("stopped"))

    def test_stops_when_the_switch_is_off(self):
        self.assertTrue(self.run_case("see you tom", keep_on=False).get("stopped"))


class Idle(unittest.TestCase):
    """Step 7, the idle ghost: where it may start, its bar, and that it stays local. Made-up lines only."""
    def test_spot(self):
        for b in ["", "  ", "Thanks. ", "Done!  ", "Він сказав «так.» ", "hi\n"]: self.assertTrue(g.idle_spot(b), repr(b))
        for b in ["see you", "ok.", "so, ", "мені треба"]: self.assertFalse(g.idle_spot(b), repr(b))

    def test_bar(self):
        self.assertEqual(g.idle_bar(None), g.IDLE_BAR)
        self.assertEqual(g.idle_bar(0.3), min(0.3, g.IDLE_BAR))
        self.assertEqual(g.idle_bar(0.3, 0.0), 0.0)
        self.assertEqual(g.idle_bar(0.3, "x"), min(0.3, g.IDLE_BAR))

    def test_wired(self):
        src = (ROOT / "engine/server.py").read_text()
        i = src.index("def _complete(")
        head = src[i:i + 1300]
        self.assertIn('idle = bool(req.get("idle"))', head)
        self.assertIn("not gatecore.idle_spot(before)", head)
        self.assertIn('if idle: low = gatecore.idle_bar(low, req.get("idle_bar"))', src)
        self.assertIn("blk = who.block(app, context)", head)

    def test_no_cloud_from_an_idle_request(self):
        # the Claude early lane and pause are gone (2026-11-17): /complete starts no Claude helper at all
        src = (ROOT / "engine/server.py").read_text()
        for gone in ("ask_early", "early_off_path", "claude_type.early", "claude_type.answer"):
            self.assertNotIn(gone, src)


class IdlePrompt(unittest.TestCase):
    """Step 7b: the empty box gets a reply-shaped prompt (engine/idle_prompt.py). Made-up lines only."""
    def setUp(self):
        import idle_prompt as idle
        self.i = idle

    def test_named_lines_are_theirs(self):
        ts = self.i.chat_turns("Ліна: Привіт!\nЛіна: Ти завтра вільна?")
        self.assertEqual(ts, [("them", "Ліна", "Привіт!"), ("them", "Ліна", "Ти завтра вільна?")])

    def test_app_marks(self):
        ts = self.i.chat_turns("Вони: lunch tomorrow?\nЯ: maybe\nВони: noon works\nat the cafe")
        self.assertEqual(ts, [("them", "Вони", "lunch tomorrow?"), ("me", "Я", "maybe"), ("them", "Вони", "noon works at the cafe")])

    def test_last_turns_only(self):
        ctx = "\n".join(f"Вони: line {k}" for k in range(20))
        ts = self.i.chat_turns(ctx)
        self.assertEqual(len(ts), self.i.TURNS)
        self.assertEqual(ts[-1][2], "line 19")

    def test_turns_tail_ends_on_his_turn(self):
        t = self.i.turns_tail("Ліна: Ти завтра вільна?", "Telegram", who="Ліна, a made-up colleague", mine="ок")
        self.assertTrue(t.startswith("[Telegram]\n"))
        self.assertIn("Хто це: Ліна, a made-up colleague", t)
        self.assertIn("Чат:\nЛіна: Ти завтра вільна?\n", t)
        self.assertTrue(t.endswith("\nЯ: "))

    def test_chat_messages(self):
        m = self.i.chat_messages("Вони: lunch tomorrow?", "Slack", name="Sam")
        self.assertEqual([x["role"] for x in m], ["user"])
        self.assertIn("Write Sam's next message", m[0]["content"])
        self.assertIn("Вони: lunch tomorrow?", m[0]["content"])

    def test_form(self):
        self.assertEqual(self.i.form_for({}), self.i.FORM)
        self.assertEqual(self.i.form_for({"idle_form": "chat"}), "chat")
        self.assertEqual(self.i.form_for({"idle_form": "x"}), self.i.FORM)

    def test_wired(self):
        src = (ROOT / "engine/server.py").read_text()
        self.assertIn('idle_form = idle_mod.form_for(req) if not before.strip() else "screen"', src)
        self.assertIn('if idle_form in ("turns", "chat"): ids, heal, stable = idle_ids(idle_form, b, app, context, blk)', src)


class Bench(unittest.TestCase):
    def test_policy_shades(self):
        import earlier
        row = {"_key": (0, 3), "toks": toks([" we", " can", " go", " home", ".", " "], [.9] * 6), "max_tokens": 24}
        P = {(0, 3): 0.35}
        self.assertEqual(earlier.Policy(P)(row, "So ", "claude")[0], "")
        pol = earlier.Policy(P, guess=0.3, mode="words", min_words=3, max_words=5)
        text, _ = pol(row, "So ", "claude")
        self.assertEqual((text, pol.info["shade"]), ("we can go home.", "guess"))


if __name__ == "__main__":
    unittest.main()

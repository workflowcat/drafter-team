"""Round three (2026-11-13): the user's writing as one dated corpus (bench/corpus.py) and weighted training lines from it
(bench/make_train.py --corpus). Made-up lines only; no model, no personal records.

    .venv/bin/python -B tests/test_corpus.py
"""
import json, sys, tempfile, unittest
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "bench")); sys.path.insert(0, str(ROOT / "engine"))
import corpus as C


def reader(rows):
    return lambda: iter(rows)


class Filters(unittest.TestCase):
    def test_pastes_and_dumps_are_not_his_lines(self):
        self.assertTrue(C.paste_like("x " * 400))
        self.assertTrue(C.paste_like("look at this ```code here``` please"))
        self.assertTrue(C.paste_like("Traceback (most recent call last):\n  File \"a.py\", line 1"))
        self.assertTrue(C.paste_like("\n".join(f"line number {i} of a long dump" for i in range(9))))
        self.assertTrue(C.paste_like("3f9a2c1d-0x7ff 1234-5678 99.12 = 4096/77"))
        self.assertFalse(C.paste_like("can you check why the panel opens twice"))
        self.assertFalse(C.paste_like("ok let's ship it\nthen tell me what changed"))

    def test_a_copied_text_is_a_paste(self):
        clip = frozenset({C.key("a long sentence someone else wrote that sits in the clipboard history")})
        self.assertTrue(C.paste_like("A long sentence someone else wrote that sits in the clipboard history", clip))
        self.assertFalse(C.paste_like("my own line about the clipboard", clip))


class Build(unittest.TestCase):
    def build(self, **sources):
        with tempfile.TemporaryDirectory() as d:
            out, counts = Path(d) / "c.jsonl", Path(d) / "n.json"
            rows, n = C.build(readers={k: reader(v) for k, v in sources.items()}, clip=frozenset(), out=out, counts_out=counts)
            on_disk = [json.loads(l) for l in out.read_text().splitlines()]
            self.assertEqual(rows, on_disk)
            self.assertEqual(json.loads(counts.read_text())["sources"], n)
            return rows, n

    def test_wrappers_commands_and_short_lines_are_dropped(self):
        rows, n = self.build(cc=[(1, "Claude Code", "<task-notification>done</task-notification>"),
                                 (2, "Claude Code", "/compact now please"),
                                 (3, "Claude Code", "[Request interrupted by user]"),
                                 (4, "Claude Code", "ok go"),
                                 (5, "Claude Code", "please make the button smaller and blue")])
        self.assertEqual([r["text"] for r in rows], ["please make the button smaller and blue"])
        self.assertEqual(n["cc"]["wrapper"], 3); self.assertEqual(n["cc"]["short"], 1)

    def test_a_line_counts_once_and_the_first_source_wins(self):
        same = "let's move the settings into one place"
        rows, n = self.build(typed=[(10, "Claude", same)], take=[(11, "Claude", same + ".")],
                             cc=[(12, "Claude Code", "Let's move the settings into one place")])
        self.assertEqual([r["src"] for r in rows], ["typed", "take"])   # the take differs by a dot: kept, the prompt not
        self.assertEqual(n["cc"]["same as typed"], 1)

    def test_a_prompt_that_matches_a_take_is_marked_dictated(self):
        take = "so the idea is that the panel should open where the caret is and not jump around"
        rows, _ = self.build(take=[(1, "Claude", take)],
                             cc=[(2, "Claude Code", take + " at all"), (3, "Claude Code", "type this one myself please now")])
        by = {r["text"]: r for r in rows}
        self.assertTrue(by[take]["dictated"])
        self.assertTrue(by[take + " at all"]["dictated"])
        self.assertFalse(by["type this one myself please now"]["dictated"])

    def test_load_cuts_by_date_and_source(self):
        rows, _ = self.build(typed=[(100, "Claude", "an older line he typed here"), (200, "Claude", "a newer line he typed here")],
                             cc=[(150, "Claude Code", "a prompt in the middle of it all")])
        with tempfile.TemporaryDirectory() as d:
            p = Path(d) / "c.jsonl"; p.write_text("".join(json.dumps(r) + "\n" for r in rows))
            self.assertEqual([r["t"] for r in C.load(p, before=200)], [100, 150])
            self.assertEqual([r["src"] for r in C.load(p, srcs={"cc"})], ["cc"])


class Weights(unittest.TestCase):
    def test_weights_repeat_and_sample(self):
        import make_train
        rows = [{"src": "typed", "text": f"t{i}"} for i in range(100)] + [{"src": "take", "text": f"v{i}"} for i in range(100)]
        out = make_train.weighted(rows, {"typed": 2, "take": 0.5})
        self.assertEqual(sum(r["src"] == "typed" for r in out), 200)
        self.assertTrue(30 < sum(r["src"] == "take" for r in out) < 70)
        self.assertEqual(make_train.weighted(rows, {"typed": 1}), rows[:100])

    def test_training_lines_leave_out_late_and_held_lines(self):
        import make_train
        with tempfile.TemporaryDirectory() as d:
            p, out = Path(d) / "c.jsonl", Path(d) / "train"
            rows = [{"src": "typed", "t": 10 + i, "app": "Claude", "text": f"an early line number {i} he typed", "dictated": False} for i in range(80)]
            rows += [{"src": "cc", "t": 500, "app": "Claude Code", "text": "a late prompt after the cut line", "dictated": False},
                     {"src": "typed", "t": 20, "app": "Claude", "text": "the held line from the test set", "dictated": False}]
            p.write_text("".join(json.dumps(r) + "\n" for r in rows))
            real = make_train.Held
            with mock.patch.object(make_train, "Held", lambda: real(["the held line from the test set"])):
                n = make_train.from_corpus(p, {"typed": 1, "cc": 1}, before=100, out=out)
            self.assertEqual(n, {"typed": 80})
            text = (out / "train.jsonl").read_text() + (out / "valid.jsonl").read_text()
            self.assertNotIn("late prompt", text); self.assertNotIn("held line", text)
            self.assertIn("[Claude]\\nan early line", text)

    def test_settings_file_overrides_default_weights(self):
        with tempfile.TemporaryDirectory() as d, mock.patch.object(C, "DATA", Path(d)):
            self.assertEqual(C.weights(), C.WEIGHTS)
            (Path(d) / "corpus-weights.json").write_text('{"beeper": 1}')
            self.assertEqual(C.weights()["beeper"], 1)
            self.assertEqual(C.weights()["typed"], C.WEIGHTS["typed"])


class NightlyMix(unittest.TestCase):
    def test_chats_do_not_drown_prompts(self):
        """Round three: the nightly mix samples chats at 0.1 and leaves takes out, as the weights round trains."""
        import sys
        sys.path.insert(0, str(Path(C.__file__).parent / "weights"))
        from train_sweep import MIX
        self.assertEqual(C.WEIGHTS["beeper"], 0.1)
        self.assertEqual(C.WEIGHTS["take"], 0)
        self.assertEqual({k: v for k, v in C.WEIGHTS.items() if v}, MIX)
        # the source sizes of 14 November: 60,265 chats against 2,911 typed and 3,771 prompts
        sizes = {"typed": 2911, "take": 1385, "cc": 3771, "codex": 33, "beeper": 60265, "vault": 69, "fb": 2263}
        lines = {k: n * C.WEIGHTS[k] for k, n in sizes.items()}
        self.assertLess(lines["beeper"] / sum(lines.values()), 0.4)
        self.assertGreater(lines["typed"] + lines["cc"], lines["beeper"])

    def test_zero_weight_source_is_left_out(self):
        import make_train
        rows = [{"src": "take", "text": "made up take line", "t": 1}] * 5 + [{"src": "typed", "text": "made up typed line", "t": 1}]
        out = make_train.weighted(rows, C.WEIGHTS)
        self.assertNotIn("take", {r["src"] for r in out})


class Vault(unittest.TestCase):
    def test_only_his_own_notes_outside_skipped_scopes(self):
        with tempfile.TemporaryDirectory() as d:
            v = Path(d)
            def note(rel, origin, body):
                p = v / rel; p.parent.mkdir(parents=True, exist_ok=True)
                p.write_text(f"---\ntype: artifact\ncreated: 2026-01-02\norigin: {origin}\n---\n{body}")
            note("Artifacts/Writing/mine.md", "me", "# Title\n\nA paragraph I wrote about [[Some Page|the plan]] here.\n\n![[pic.png]]")
            note("Artifacts/Notes/agent.md", "claude", "An agent wrote this paragraph for me.")
            note("Stories/Private/case.md", "me", "A private matter note I wrote myself.")
            note("Entities/Private/person.md", "me", "Notes about a person kept private.")
            note("System/old/log.md", "me", "An old log line of mine from before.")
            note(".claude/worktrees/x/copy.md", "me", "A copy inside an agent worktree.")
            with mock.patch.object(C, "VAULT", v), mock.patch.object(C, "ORIGIN", "me"):
                got = [t for _, _, t in C.vault()]
        self.assertEqual(sorted(got), ["A paragraph I wrote about the plan here.", "A private matter note I wrote myself."])

    def test_long_paragraphs_are_cut_at_sentence_ends(self):
        para = " ".join(f"Sentence number {i} is here." for i in range(60))
        pieces = list(C.paragraphs(para + "\n\nShort one."))
        self.assertTrue(all(len(p) <= C.MAX_CHARS for p in pieces))
        self.assertEqual(" ".join(pieces[:-1]), para)
        self.assertEqual(pieces[-1], "Short one.")


class Vote(unittest.TestCase):
    def test_matches_vote_by_next_word(self):
        import memory
        from collections import Counter
        conts = Counter({"deployment today": 1, "deployment after lunch": 1, "deployment once approved": 1, "release now": 1})
        text, hits, share = memory.vote(conts)
        self.assertEqual((text, hits, share), ("deployment", 3, 0.75))
        conts = Counter({"deployment today please": 2, "deployment today now": 1})
        self.assertEqual(memory.vote(conts)[0], "deployment today")


class EngineReaders(unittest.TestCase):
    def test_imported_writing_comes_from_the_import_folder_and_config_folders(self):
        import json as _j
        with tempfile.TemporaryDirectory() as t:
            d = Path(t); (d / "import").mkdir(); notes = d / "notes"; notes.mkdir()
            (d / "import" / "chat.jsonl").write_text(_j.dumps({"text": "a made up line from an exported chat", "t": 5}) + "\n" + _j.dumps({"x": 1}) + "\n")
            (d / "import" / "letter.txt").write_text("First made up paragraph of a letter.\n\nSecond made up paragraph here.")
            (notes / "n.md").write_text("---\ntitle: x\n---\n# Heading\n\nA made up note paragraph to keep.")
            (notes / ".hidden").mkdir(); (notes / ".hidden" / "h.md").write_text("never read this made up line")
            cfg = C.local._merge(C.local.DEFAULTS, {"corpus": {"folders": [str(notes)]}})
            with mock.patch.object(C, "SRC", d), mock.patch.object(C.local, "config", lambda: cfg):
                got = [x for _, _, x in C.imported()]
                self.assertIn("import", C.sources())
        self.assertIn("a made up line from an exported chat", got)
        self.assertIn("Second made up paragraph here.", got)
        self.assertIn("A made up note paragraph to keep.", got)
        self.assertFalse(any("Heading" in x or "never read" in x or "title:" in x for x in got))

    def test_memory_and_finisher_read_the_corpus_sources(self):
        import memory, words
        with tempfile.TemporaryDirectory() as d:
            d = Path(d)
            rows = [{"src": "typed", "t": 1, "text": "please check the build before lunch today"},
                    {"src": "take", "t": 2, "text": "so like the spoken take goes here somehow"},
                    {"src": "cc", "t": 3, "text": "take a look at the failing panel test"}]
            (d / "corpus.jsonl").write_text("".join(json.dumps(r) + "\n" for r in rows))
            (d / "typed.jsonl").write_text(json.dumps({"t": 0, "text": "an old typed line already in the corpus"}) + "\n"
                                           + json.dumps({"t": 4e9, "text": "a line sent after the corpus was built"}) + "\n")
            with mock.patch.object(memory, "DATA", d), mock.patch.object(memory, "CORPUS", d / "corpus.jsonl"):
                got = memory.from_corpus(memory.Memory.SOURCES)
            self.assertIn("take a look at the failing panel test", got)
            self.assertNotIn("so like the spoken take goes here somehow", got)   # takes stay out of the memory
            self.assertIn("a line sent after the corpus was built", got)
            self.assertNotIn("an old typed line already in the corpus", got)
            with mock.patch.object(memory, "CORPUS", d / "none.jsonl"):
                self.assertIsNone(memory.from_corpus(memory.Memory.SOURCES))
            (d / "drafts.jsonl").write_text("")
            with mock.patch.object(words, "DATA", d), mock.patch.object(words, "ROOT", d):
                w = words.Words(); w.load()
                self.assertIn("spoken", w.uni)      # the finisher takes every source
                self.assertIn("failing", w.uni)
                self.assertIn("built", w.uni)         # sent after the corpus was built, as the memory reads it
                self.assertNotIn("already", w.uni)     # older typed lines come through the corpus only


if __name__ == "__main__":
    unittest.main()

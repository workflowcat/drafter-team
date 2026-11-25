"""Big-model round benches (bench/big/): the context training rows and the scorer's word runs. Made-up text only.

    .venv/bin/python -B tests/test_big_bench.py
"""
import sys, types, unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
for p in (ROOT / "bench/big", ROOT / "bench", ROOT / "engine"):
    sys.path.insert(0, str(p))
import ctx_train, score
import prompt as P


class Tok:
    """One id per character, "\\n\\n" one id; eos 0."""
    eos_token_id = 0

    def encode(self, s):
        out, i = [], 0
        while i < len(s):
            if s[i:i + 2] == "\n\n": out.append(1); i += 2
            else: out.append(ord(s[i])); i += 1
        return out


class TrainRows(unittest.TestCase):
    def test_line_is_the_only_target_and_ends_with_eos(self):
        prompt = P.tail("", "Beeper", "", "They asked about the meeting time.")
        ids, off = ctx_train.plain_process(Tok(), prompt, "Tomorrow at ten works for me", True)
        self.assertEqual(ids[-1], 0)
        self.assertEqual(ids[:off], Tok().encode(prompt))
        self.assertEqual(Tok().encode("Tomorrow at ten works for me") + [0], ids[off:])

    def test_joined_token_stays_in_the_target(self):
        ids, off = ctx_train.plain_process(Tok(), "[Claude]\n", "\nnew paragraph", True)
        self.assertEqual(off, len("[Claude]"))          # the "\n\n" token belongs to both: kept as target
        self.assertEqual(ids[:-1], Tok().encode("[Claude]\n\nnew paragraph"))

    def test_no_mask(self):
        self.assertEqual(ctx_train.plain_process(Tok(), "[A]\n", "hi there", False)[1], 0)

    def test_engine_cut_is_the_server_window(self):
        cut = ctx_train.engine_cut()
        short = "a short screen text"
        self.assertEqual(cut(short), short)
        long = "\n".join(f"line {i} of a made-up chat with some words in it" for i in range(80))
        got = cut(long)
        self.assertLessEqual(len(got), 1000)
        self.assertTrue(long.endswith(got))
        self.assertTrue(got.startswith("line "))          # starts at a line, as the engine's window does
        self.assertEqual(cut("  two\u00a0spaces here  "), "two spaces here")


class Runs(unittest.TestCase):
    def row(self, text, n=24):
        return {"toks": [[text, 0.9, 0.05, 10.0, "x"]], "max_tokens": n}

    def test_words_right_in_a_row(self):
        truth = "please check the build and then the tests"
        pos = len("please ")
        self.assertEqual(score.run_len(self.row("check the build or"), truth, pos), 3)
        self.assertEqual(score.run_len(self.row("check a build"), truth, pos), 1)
        self.assertEqual(score.run_len(self.row("chop"), truth, pos), 0)

    def test_first_word(self):
        truth = "please check the build"
        self.assertTrue(score.first_ok(self.row("check it"), truth, len("please ")))
        self.assertFalse(score.first_ok(self.row("checks it"), truth, len("please ")))
        self.assertTrue(score.first_ok(self.row("eck the"), truth, len("please ch")))


if __name__ == "__main__":
    unittest.main()

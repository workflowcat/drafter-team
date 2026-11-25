"""Parity round (2026-11-15): clipboard context and writing instructions in the prompt (engine/prompt.py), and the
layer strength in the head key (engine/model.py). Empty extras leave the prompt byte-identical to before; a sensitive
copy never reaches it; both sit after the cached head. Made-up text only.
.venv/bin/python -B tests/test_prompt_parity.py"""
import hashlib, sys, types, unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "engine"))
import prompt
from server_src import lift


class Tok:
    """A stand-in tokenizer: one id per character, so prefixes behave like a real one's for these tests."""
    def encode(self, t): return [ord(c) for c in t]
    def bos(self): return []


class FakeModel:
    def __init__(self): self.t = Tok()
    def encode(self, t): return self.t.encode(t)
    def bos(self): return []


def builder():
    b = prompt.Builder.__new__(prompt.Builder)
    b.m, b.fmt = FakeModel(), "raw"
    b.head = "HEAD\n###\n"; b.head_ids = b.m.encode(b.head)
    return b


class Safe(unittest.TestCase):
    def test_plain_text_is_safe(self):
        self.assertTrue(prompt.clip_safe("the zebra meeting moved to Thursday at 3"))
        self.assertTrue(prompt.clip_safe("https://example.com/plans/zebra-q4"))
        self.assertTrue(prompt.clip_safe("Зустріч перенесли на четвер"))

    def test_keys_and_tokens(self):
        for t in ("sk-ant-api03-abcdefghijklmnopqrstuvwx", "ghp_abcdefghijklmnopqrstuvwxyz0123456789",
                  "AKIAABCDEFGHIJKLMNOP", "password: hunter2hunter2", "token=abcdef123456",
                  "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.abcdefghijklmnop",
                  "-----BEGIN RSA PRIVATE KEY-----", "x9Fq2LmZ8pR4tW7yB1nC5vK3hJ6dS0aG"):
            self.assertFalse(prompt.clip_safe(t), t)

    def test_card_iban_code(self):
        self.assertFalse(prompt.clip_safe("4111 1111 1111 1111"))          # a test card number (Luhn)
        self.assertFalse(prompt.clip_safe("UA21 3223 1300 0002 6007 2335 6600 1"))
        self.assertFalse(prompt.clip_safe("GB82WEST12345698765432"))
        self.assertFalse(prompt.clip_safe("482913"))
        self.assertTrue(prompt.clip_safe("order 1234 5678 is late"))       # short numbers stay

    def test_clip_text_caps_and_dedupes(self):
        long = "word " * 200
        out = prompt.clip_text(long, "", 50)
        self.assertLessEqual(len(out), 51); self.assertTrue(out.endswith("…"))
        self.assertEqual(prompt.clip_text("the zebra plan for Q4", "here it is: the zebra plan for Q4"), "")
        self.assertEqual(prompt.clip_text("482913", ""), "")
        self.assertEqual(prompt.clip_text("two\n\nlines", ""), "two lines")


class Tail(unittest.TestCase):
    def test_empty_extras_are_byte_identical(self):
        for args in [("hello wor", "Beeper", "Olena", "Вони: hi\nЯ: hey", ""), ("Please write", "Claude", "", "", ""), ("x", "", "", "", "")]:
            self.assertEqual(prompt.tail(*args), prompt.tail(*args, clip="", notes=""))
        b = builder()
        self.assertEqual(b.ids_stable("hello wor", "Beeper", "Olena", "ctx"), b.ids_stable("hello wor", "Beeper", "Olena", "ctx", "", "", ""))

    def test_clip_sits_above_the_screen_after_the_head(self):
        t = prompt.tail("so the", "Beeper", "Olena", "Вони: when?", clip="Thursday 3 pm, room B")
        self.assertIn(prompt.CLIP_LABEL + " Thursday 3 pm, room B\n", t)
        self.assertLess(t.index(prompt.CLIP_LABEL), t.index("На екрані перед цим:"))
        self.assertTrue(t.endswith("so the"))
        b = builder()
        ids, heal, stable = b.ids_stable("so the", "Beeper", "Olena", "Вони: when?", clip="Thursday 3 pm")
        self.assertEqual(ids[:len(b.head_ids)], b.head_ids)       # the cached head is untouched
        self.assertGreater(stable, len(b.head_ids) + 20)         # the copy is in the part that stays put

    def test_sensitive_clip_left_out(self):
        self.assertEqual(prompt.tail("a", "Mail", "", "", clip="4111 1111 1111 1111"), prompt.tail("a", "Mail", "", ""))

    def test_notes_paren_and_line(self):
        t = prompt.tail("Hi", "Beeper", "Olena", "", notes="write in English")
        self.assertTrue(t.startswith("[Beeper · Olena] (коротко, розмовно, як у чаті; write in English)\n"))
        t = prompt.tail("Hi", "Zebrapad", "", "", notes="short,\n no greetings")
        self.assertTrue(t.startswith("[Zebrapad] (short, no greetings)\n"))
        old = prompt.NOTES_FORM
        try:
            prompt.NOTES_FORM = "line"
            t = prompt.tail("Hi", "Beeper", "", "", notes="write in English")
            self.assertTrue(t.startswith("Нотатка: write in English\n[Beeper] (коротко"))
        finally:
            prompt.NOTES_FORM = old
        self.assertLessEqual(len(prompt.notes_text("x" * 900)), prompt.NOTES_CHARS)

    def test_notes_keep_the_head(self):
        b = builder()
        ids, _, stable = b.ids_stable("Hi", "Mail", "", "", notes="short")
        self.assertEqual(ids[:len(b.head_ids)], b.head_ids)
        self.assertGreater(stable, len(b.head_ids))


class Strength(unittest.TestCase):
    def test_head_key_keeps_todays_key_at_full_strength(self):
        # This method only hashes metadata. Extract it without importing MLX or touching a GPU.
        ns = lift("head_key", path=ROOT / "engine/model.py", cls="Model", hashlib=hashlib, Path=Path, FUSE=True, TWEAKS="")
        m = types.SimpleNamespace(repo="made/up-model", adapter=None, cache=None)
        m.head_key = types.MethodType(ns["head_key"], m)
        m.strength = 1.0; full = m.head_key([1, 2, 3])
        del m.strength; self.assertEqual(m.head_key([1, 2, 3]), full)       # an object without the field: the same key
        m.strength = 0.5; half = m.head_key([1, 2, 3])
        m.strength = 0.0; zero = m.head_key([1, 2, 3])
        self.assertEqual(len({full, half, zero}), 3)

    def test_server_reads_the_setting(self):
        src = (ROOT / "engine/server.py").read_text()
        self.assertIn('Model(REPO, ADAPTER, strength=strength_setting())', src)
        self.assertIn('"/strength"', src)


if __name__ == "__main__":
    unittest.main()

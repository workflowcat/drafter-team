"""Parity round (2026-11-15): his writing instructions reach the Claude helper prompts (rework on Claude and on the
local model; the pause, early lane and next message went on 2026-11-17), and an empty instruction leaves each prompt
byte-identical. The calls go through the existing claude_on / cloud.py checks (unchanged). Made-up text, no model.
.venv/bin/python -B tests/test_helper_notes.py"""
import sys, types, unittest
from pathlib import Path
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "engine"))
import rework as rw
import prompt as prompt_mod
from writing_notes import normalize as normalize_notes
from chat_template import encode as chat_ids
from server_src import lift

NOTE = "zebra-tone: short, no greetings"


def server_fns(*names, **ns):
    ns.setdefault("who", types.SimpleNamespace(hint=lambda req, task="type": ""))   # engine/whom.py
    ns.setdefault("normalize_notes", normalize_notes)
    ns.setdefault("chat_ids", chat_ids)
    return lift(*names, **ns)


class FakeWorker:
    def __init__(self): self.users = []; self.turns = 1
    def ask(self, user, cancelled=lambda: False, **kw): self.users.append(user); return ("rest of it", 1, 2)
    def alive(self): return True


class Normalization(unittest.TestCase):
    def test_whitespace_and_exact_cap(self):
        cases = [(None, ""), (False, ""), (0, ""), ("", ""), (" \t\r\n\u00a0", ""),
                 ("  zebra\n\t tone\u00a0short\u2028lines ", "zebra tone short lines"),
                 ("x" * 299 + " \n tail", "x" * 299 + " "),
                 ("x" * 301, "x" * 300), ("\u00e9" * 301, "\u00e9" * 300)]
        for raw, expected in cases:
            with self.subTest(raw=raw):
                self.assertEqual(prompt_mod.notes_text(raw), expected)
                self.assertEqual(rw.notes_text(raw), expected)

    def test_local_prompt_keeps_its_own_budget(self):
        with patch.object(prompt_mod, "NOTES_CHARS", 4):
            self.assertEqual(prompt_mod.notes_text(" zebra tone "), "zebr")
            self.assertEqual(rw.notes_text(" zebra tone "), "zebra tone")


class Rework(unittest.TestCase):
    def setUp(self):
        self.w = FakeWorker(); self.local = []
        self.saved = rw._worker, rw.ct.CLI
        rw._worker = lambda model: self.w
        rw.ct.CLI = sys.executable
        rw._cache.clear()

    def tearDown(self): rw._worker, rw.ct.CLI = self.saved

    def test_claude_path(self):
        rw.rework("the zebra plan is late again", "clearer", app="Mail", notes=NOTE)
        self.assertIn("His writing instructions (follow them unless the task says otherwise): " + NOTE, self.w.users[-1])
        rw._cache.clear()
        rw.rework("the zebra plan is late again", "clearer", app="Mail")
        plain = self.w.users[-1]
        rw._cache.clear()
        rw.rework("the zebra plan is late again", "clearer", app="Mail", notes="")
        self.assertEqual(plain, self.w.users[-1])
        self.assertNotIn("instructions", plain)

    def test_note_changes_only_its_prompt_line(self):
        text = "the zebra plan is late again"
        rw.rework(text, "clearer", app="Mail")
        plain = self.w.users[-1]
        for raw, normalized in ((" \tzebra\n tone ", "zebra tone"), ("x" * 301, "x" * 300)):
            rw._cache.clear()
            rw.rework(text, "clearer", app="Mail", notes=raw)
            line = f"His writing instructions (follow them unless the task says otherwise): {normalized}\n\n"
            self.assertEqual(self.w.users[-1], plain.replace("Task: ", line + "Task: ", 1))

    def test_local_path(self):
        calls = []
        local = lambda *a: calls.append(a) or ""
        rw.rework("the zebra plan is late again", "clearer", online=False, local=local, notes=NOTE)
        rw.rework("the zebra plan is late again", "clearer", online=False, local=local)
        self.assertEqual(calls[0][2], NOTE)
        self.assertEqual(len(calls[1]), 2)          # no note: the old two-argument call

    def test_local_prompt(self):
        seen = []
        tok = types.SimpleNamespace(apply_chat_template=lambda m, **kw: seen.append(m[0]["content"]) or "S", chat_template="",
                                    encode=lambda s, **kw: [1, 2])
        ns = server_fns("local_rewrite", model=types.SimpleNamespace(tok=tok, oneshot=lambda *a, **kw: ""), REPO="x", latest=[0],
                        threading=__import__("threading"), run=lambda fn, **kw: fn(lambda: False))
        ns["local_rewrite"]("zebra text", "clearer", NOTE)
        ns["local_rewrite"]("zebra text", "clearer")
        ns["local_rewrite"]("zebra text", "clearer", "")
        self.assertIn(NOTE, seen[0])
        self.assertEqual(seen[1], seen[2]); self.assertNotIn("his writing instructions", seen[1])

    def test_server_passes_notes_only_when_set(self):
        got = []
        fake = types.SimpleNamespace(rework=lambda *a, **kw: got.append(kw) or {}, warm=lambda m: None)
        sys.modules["rework"] = fake
        try:
            ns = server_fns("rework", settings_load=lambda: {"rework": True}, cloud=types.SimpleNamespace(allowed=lambda f, st: True),
                            claude_on=lambda f, st=None: True, local_rewrite=None, DATA=Path("/nonexistent"))
            ns["rework"]({"text": "t", "cmd": "fix", "notes": NOTE}); ns["rework"]({"text": "t", "cmd": "fix"})
        finally:
            sys.modules["rework"] = rw
        self.assertEqual(got[0]["notes"], NOTE); self.assertNotIn("notes", got[1])


if __name__ == "__main__":
    unittest.main()

"""Exact local-helper tokens and call policies from a fake tokenizer; no server or model starts.
Run: .venv/bin/python -B tests/test_chat_template.py
"""
import ast
import hashlib
import json
from pathlib import Path
import re
import sys
import threading
import types
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "engine"))
import idle_prompt
from chat_template import encode as chat_ids

FIXTURE = ROOT / "tests/fixtures/local_chat_tokens.json"
SOURCE = ROOT / "engine/server.py"
CASES = ("ask", "rewrite", "outline", "local_rewrite", "idle_ids")
SUFFIX = "<think>\n\n</think>\n\n"


class Tokenizer:
    """Stable IDs for words, whitespace and markers; default encoding adds its own start token."""
    def __init__(self, template):
        self.chat_template = template
        self.messages, self.encodings = [], []

    def apply_chat_template(self, messages, *, tokenize, add_generation_prompt):
        assert tokenize is False and add_generation_prompt is True
        self.messages.append(messages)
        return "<bos>" + "".join(f"<{m['role']}>{m['content']}</{m['role']}>" for m in messages) + "<assistant>"

    def encode(self, text, add_special_tokens=True):
        self.encodings.append((text, add_special_tokens))
        pieces = re.findall(r"<[^>]*>|\s+|\w+|[^\w\s]", text)
        ids = [int.from_bytes(hashlib.sha256(p.encode()).digest()[:4], "big") for p in pieces]
        return ([7] if add_special_tokens else []) + ids


def run_case(name, template="plain", repo="made-up/model", source=None, **extra):
    tok, calls = Tokenizer(template), []
    def oneshot(ids, **kwargs):
        calls.append((ids, kwargs))
        return '{"title":"Zebra plan","points":["Check the boat"],"todos":[]}' if name == "outline" else "  zebra result  "
    cancelled = lambda: False
    ns = dict(model=types.SimpleNamespace(tok=tok, repo=repo, oneshot=oneshot, encode=tok.encode),
              re=re, json=json, threading=threading, latest=[4], DATA=Path("/nonexistent"),
              time=types.SimpleNamespace(perf_counter=lambda: 10.0), claude_on=lambda *a: False,
              run=lambda fn, **kw: fn(cancelled), idle_mod=idle_prompt,
              earlier=lambda *a, **kw: "I can bring the paper boat.",
              local=types.SimpleNamespace(short_name=lambda: "the user"), chat_ids=chat_ids, **extra)
    tree = ast.parse(source if source is not None else SOURCE.read_text())
    functions = [n for n in tree.body if isinstance(n, ast.FunctionDef) and n.name in CASES]
    exec(compile(ast.Module(body=functions, type_ignores=[]), "server.py", "exec"), ns)
    if name == "ask":
        result = ns[name]("Return the zebra color as JSON.", max_tokens=17, cancelled=cancelled)
    elif name == "rewrite":
        result = ns[name]({"text": "the paper boat is ready", "instruction": "make it shorter"})
    elif name == "outline":
        result = ns[name]({"text": "We discussed the paper boat and agreed to check the zebra drawing before lunch today.", "call": True})
    elif name == "local_rewrite":
        result = ns[name]("the paper boat is ready", "make it shorter", "use short lines")
    else:
        result = ns[name]("chat", None, "Zebra", "They: Is the paper boat ready?", "Chat with: River\n")
    ids = result[0] if name == "idle_ids" else calls[0][0]
    return dict(ids=ids, messages=tok.messages, tok=tok, calls=calls, result=result, cancelled=cancelled, ns=ns)


class ChatTokens(unittest.TestCase):
    def test_exact_tokens_for_every_local_caller(self):
        fixtures = json.loads(FIXTURE.read_text())
        for name in CASES:
            for template, repo, suffix in ((None, "made-up/model", ""), ("", "made-up/model", ""),
                                           ("plain", "made-up/model", ""), ("with <think>", "made-up/model", SUFFIX),
                                           ("with <think>", "made-up/Instruct-2507", "")):
                with self.subTest(name=name, template=template, repo=repo):
                    got = run_case(name, template, repo)
                    fixture = fixtures[name]
                    self.assertEqual(got["messages"], fixture["messages"])
                    self.assertEqual(got["ids"], fixture["thinking_ids"] if suffix else fixture["ids"])
                    self.assertIs(got["tok"].encodings[0][1], False)

    def test_task_caps_stopping_and_results(self):
        ask = run_case("ask")
        kwargs = ask["calls"][0][1]
        self.assertEqual(kwargs["max_tokens"], 17)
        self.assertEqual(kwargs["stop"].pattern, r"\}\s*$")
        self.assertIs(kwargs["cancelled"], ask["cancelled"])
        self.assertEqual(ask["result"], "  zebra result  ")
        for name, cap in (("rewrite", 600), ("local_rewrite", 900)):
            got = run_case(name)
            self.assertEqual(got["calls"][0][1]["max_tokens"], min(cap, 2 * len(got["tok"].encode("the paper boat is ready")) + 40))
            if name == "rewrite":
                self.assertEqual(got["result"], {"text": "zebra result", "ms": 0, "by": "local"})
                self.assertNotIn("cancelled", got["calls"][0][1])
            else:
                self.assertEqual(got["result"], "zebra result")
                self.assertTrue(got["calls"][0][1]["cancelled"]())   # request marks itself gone on return
        outline = run_case("outline")
        self.assertEqual(outline["calls"][0][1], {"max_tokens": 320})
        self.assertEqual(outline["result"], {"title": "Zebra plan", "points": ["Check the boat"], "todos": [], "ms": 0, "by": "local"})
        idle = run_case("idle_ids")
        self.assertEqual(idle["result"][1:], ("", max(0, len(idle["ids"]) - 1)))


if __name__ == "__main__":
    unittest.main()

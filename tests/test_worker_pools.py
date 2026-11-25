"""The rework helper pool with fake workers (proofread, translate and facts went on 2026-11-17): lock ownership, rotation, prompts, caps and failure contracts.
Extract functions and constants without importing the server, cloud transport, local configuration or models.
Run: .venv/bin/python -B tests/test_worker_pools.py
"""
import ast
from collections import Counter
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timedelta
import difflib
import hashlib
import json
from pathlib import Path
import re
import sys
import threading
import time
import types
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "engine"))
from worker_pool import get_or_create
FIXTURE = ROOT / "tests/fixtures/worker_pool_prompts.json"
FEATURES = {"rework": 3000}
WORDS = [f"zebra{i}" for i in range(160)]


def feature(name, **extra):
    events, created = [], []
    ns = dict(Counter=Counter, datetime=datetime, timedelta=timedelta, difflib=difflib, hashlib=hashlib, json=json,
              Path=Path, re=re, threading=threading, time=time, local=types.SimpleNamespace(name=lambda: "the user"),
              tr=types.SimpleNamespace(TOKENS=re.compile(r"https?://\S+"), NAMES={"en": "English", "uk": "Ukrainian"}),
              notes_text=lambda text: text, get_or_create=get_or_create, **extra)

    def record(event):
        if not ns["_lock"].locked(): raise AssertionError("pool bookkeeping escaped the feature lock")
        events.append(event)

    class Worker:
        MAX_TURNS = 40
        fail_create = False

        def __init__(self, model, system, max_tokens=None):
            record("create")
            if self.fail_create: raise ValueError("made-up creation failure")
            self.model, self.system, self.max_tokens = model, system, max_tokens
            self.turns, self.dead, self._used = 0, False, 0
            self.ask_calls = []
            created.append(self)

        def alive(self):
            record("alive")
            return not self.dead

        def stop(self):
            record("stop")
            self.dead = True

        @property
        def used(self): return self._used

        @used.setter
        def used(self, value):
            record("used")
            self._used = value

        def ask(self, user, cancelled, **kwargs):
            if ns["_lock"].locked(): raise AssertionError("asking while holding the pool lock")
            self.ask_calls.append((user, cancelled, kwargs))
            return None

    def words():
        record("words")
        return WORDS

    ns.update(ct=types.SimpleNamespace(Worker=Worker, CLI=sys.executable, RUSSIAN=re.compile(r"[ыэъёЫЭЪЁ]")),
              prompt_mod=types.SimpleNamespace(words=words))
    source = ast.parse((ROOT / "engine" / (name + ".py")).read_text())
    nodes = [n for n in source.body if isinstance(n, (ast.Assign, ast.FunctionDef))]
    exec(compile(ast.Module(body=nodes, type_ignores=[]), name + ".py", "exec"), ns)
    original_system = ns["system"]
    def system():
        record("system")
        return original_system()
    ns["system"] = system
    return types.SimpleNamespace(ns=ns, events=events, created=created, Worker=Worker)


class Pools(unittest.TestCase):
    def test_creation_prompts_caps_and_reuse(self):
        fixtures = json.loads(FIXTURE.read_text())
        for name, cap in FEATURES.items():
            with self.subTest(name=name):
                f = feature(name)
                with patch.object(time, "time", return_value=123.0):
                    first = f.ns["_worker"]("sonnet")
                self.assertEqual(first.system, fixtures[name])
                self.assertEqual(first.max_tokens, cap)
                self.assertEqual(first.used, 123.0)
                self.assertIs(f.ns["_workers"]["sonnet"], first)
                self.assertEqual(f.events, (["words"] if name != "rework" else []) + ["system", "create", "used"])
                f.events.clear()
                first.turns = 39
                with patch.object(time, "time", return_value=456.0):
                    again = f.ns["_worker"]("sonnet")
                self.assertIs(again, first)
                self.assertEqual(again.used, 456.0)
                self.assertEqual(f.events, ["alive", "used"])   # no prompt or names refresh on reuse
                self.assertFalse(f.ns["_lock"].locked())

    def test_dead_and_turn_limit_stop_before_replacing(self):
        for name in FEATURES:
            for reason in ("dead", "turns"):
                with self.subTest(name=name, reason=reason):
                    f = feature(name)
                    old = f.ns["_worker"]("sonnet")
                    other = f.ns["_worker"]("haiku")
                    old.dead, old.turns = reason == "dead", 40 if reason == "turns" else 0
                    f.events.clear()
                    new = f.ns["_worker"]("sonnet")
                    self.assertIsNot(new, old)
                    self.assertTrue(old.dead)
                    self.assertIs(f.ns["_workers"]["haiku"], other)
                    expected = ["alive", "stop"] + (["words"] if name != "rework" else []) + ["system", "create", "used"]
                    self.assertEqual(f.events, expected)
                    self.assertEqual(new.system, old.system)
                    self.assertEqual(new.max_tokens, old.max_tokens)

    def test_failed_replacement_leaves_the_old_entry_and_releases_the_lock(self):
        for name in FEATURES:
            with self.subTest(name=name):
                f = feature(name)
                old = f.ns["_worker"]("sonnet")
                old.turns = 40
                previous_used = old.used
                f.Worker.fail_create = True
                f.events.clear()
                with self.assertRaisesRegex(ValueError, "made-up creation failure"):
                    f.ns["_worker"]("sonnet")
                self.assertIs(f.ns["_workers"]["sonnet"], old)
                self.assertTrue(old.dead)
                self.assertEqual(old.used, previous_used)
                self.assertNotIn("used", f.events)
                self.assertFalse(f.ns["_lock"].locked())
                f.Worker.fail_create = False
                self.assertIsNot(f.ns["_worker"]("sonnet"), old)

    def test_concurrent_acquisitions_share_one_worker(self):
        for name in FEATURES:
            with self.subTest(name=name):
                f = feature(name)
                ready = threading.Barrier(4)
                def acquire(_):
                    ready.wait(timeout=3)
                    return f.ns["_worker"]("sonnet")
                with ThreadPoolExecutor(max_workers=4) as pool:
                    workers = list(pool.map(acquire, range(4)))
                self.assertEqual(len(f.created), 1)
                self.assertTrue(all(w is workers[0] for w in workers))

    def test_features_keep_distinct_pools_and_locks(self):
        features = [feature(name) for name in FEATURES]
        n = len(FEATURES)
        self.assertEqual(len({id(f.ns["_lock"]) for f in features}), n)
        self.assertEqual(len({id(f.ns["_workers"]) for f in features}), n)
        workers = [f.ns["_worker"]("sonnet") for f in features]
        self.assertEqual(len({id(w) for w in workers}), n)

    def test_failed_asks_keep_each_feature_result_and_deadline(self):
        cancelled = lambda: False
        for name in FEATURES:
            with self.subTest(name=name):
                f = feature(name)
                f.ns["kept"] = lambda *a: False
                result = f.ns["rework"]("the zebra boat is ready", "clearer", cancelled=cancelled)
                expected, deadline = {}, 20.0
                self.assertEqual(result, expected)
                self.assertEqual(f.created[0].ask_calls[0][1:], (cancelled, {"wait": 1.0, "deadline": deadline, "whole": True}))


if __name__ == "__main__":
    unittest.main()

"""Model catalog (2026-11-15): Model.unload / load_as on the real class with a stand-in loader (no weights load).
One model at a time: load_as refuses while a model is in; a failed load leaves nothing loaded; the head key differs
per model, so each model keeps its own head file.

    .venv/bin/python -B tests/test_model_swap.py
"""
import sys, threading, unittest
from collections import OrderedDict
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "engine"))
import model as M


class Tok:
    def __init__(self, name): self.name = name


def stand_in():
    m = M.Model.__new__(M.Model)
    m.model, m.tok, m.cache, m.ids, m.fused = object(), Tok("old"), [1], [1, 2], []
    m.snapshot, m.marks, m.screen, m.parked, m.dist = None, OrderedDict(), None, OrderedDict(), None
    m.tw, m.head_file, m.repo, m.adapter, m.src, m.strength = None, None, "org/old", None, None, 1.0
    m.lock, m.loading, m.wake_at, m.retrain_sleep, m.head_ids = threading.Lock(), False, 0.0, False, [5]
    m._by_first, m.sleeps = {"a": []}, 0
    return m


class Swap(unittest.TestCase):
    def setUp(self):
        self.calls, self.old = [], M.load
        def fake_load(where, adapter_path=None):
            self.calls.append((where, adapter_path))
            if "broken" in where: raise ValueError("stand-in")
            return object(), Tok(where)
        M.load = fake_load

    def tearDown(self): M.load = self.old

    def test_unload_then_load_from_the_snapshot(self):
        m = stand_in()
        with self.assertRaises(RuntimeError): m.load_as("org/new")        # never two models
        self.assertEqual(self.calls, [])
        m.unload()
        self.assertTrue(m.asleep)
        self.assertIsNone(m._by_first)                                     # pieces of the old tokenizer go
        m.load_as("org/new", adapter="/no/such/layer", src="/snap/new")
        self.assertEqual(self.calls, [("/snap/new", None)])                # a missing layer folder: no layer
        self.assertEqual((m.repo, m.src, m.tok.name, m.head_ids, m.loading), ("org/new", "/snap/new", "/snap/new", [], False))

    def test_a_failed_load_leaves_nothing(self):
        m = stand_in(); m.unload()
        with self.assertRaises(ValueError): m.load_as("org/broken")
        self.assertTrue(m.asleep); self.assertFalse(m.loading)

    def test_head_key_differs_per_model(self):
        m = stand_in(); m.cache = []
        a = m.head_key([1, 2, 3]); m.repo = "org/other"
        self.assertNotEqual(a, m.head_key([1, 2, 3]))

    def test_wake_after_a_switch_loads_the_new_model(self):
        m = stand_in(); m.unload(); m.load_as("org/new", src="/snap/new")
        m.sleep(0); self.calls.clear()
        m._warm = lambda ids: None
        m.wake()
        self.assertEqual(self.calls, [("/snap/new", None)])


class KV(unittest.TestCase):
    def test_kv_gb_counts_each_kind(self):
        import mlx.core as mx
        mx.set_cache_limit(0)
        class C:
            def __init__(self, n): self.keys = mx.zeros((1, 2, n, 64), mx.float16); self.values = mx.zeros((1, 2, n, 64), mx.float16)
        gb = lambda n: round(2 * 2 * n * 64 * 2 * 2 / 2**30, 3)      # keys + values, 2 layers, float16
        m = stand_in()
        m.cache = [C(1024), C(1024)]
        m.parked = OrderedDict(a=([1], [C(512), C(512)]), b=([2], [C(256), C(256)]))
        m.marks = OrderedDict(a=([C(256), C(256)], [1]))
        kv = m.kv_gb()
        self.assertEqual((kv["active"], kv["parked"], kv["marks"], kv["head_copy"], kv["screens"]),
                         (gb(1024), round(2 * 2 * 768 * 64 * 2 * 2 / 2**30, 3), gb(256), 0, 3))
        m.cache = None; m.parked.clear(); m.marks.clear()
        self.assertEqual(m.kv_gb()["active"], 0)


if __name__ == "__main__":
    unittest.main()

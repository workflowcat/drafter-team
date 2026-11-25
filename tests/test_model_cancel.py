"""Cancellation at the real generation boundaries, without importing MLX or loading a model."""
import math
from pathlib import Path
import re
import sys
import threading
import time
import types
import unittest
from unittest.mock import Mock
import numpy as np

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'engine'))
from server_src import lift


def model():
    class Cancelled(Exception): pass
    ns = lift('complete', 'complete_gated', path=ROOT / 'engine/model.py', cls='Model', DIST=False, time=time, math=math, END=re.compile(r'[.!?\n]'),
              mx=types.SimpleNamespace(array=np.array, exp=np.exp, topk=lambda a, k: np.sort(a)[-k:]),
              Model=types.SimpleNamespace(Cancelled=Cancelled))
    m = types.SimpleNamespace(lock=threading.Lock(), model=object(), _switch=Mock(), _feed=Mock(return_value=[0]),
                              cache=[], sampler=None, ids=[], BARS=(0, 0, 0), healer=Mock(),
                              snapshot=None, marks={}, screen=None, rebuilds=0,   # _feed's fields (big-model round)
                              bos=lambda: [], encode=lambda _: [0],
                              tok=types.SimpleNamespace(eos_token_id=9, decode=lambda ids: 'a' * len(ids)))
    return ns, m, Cancelled


class Cancellation(unittest.TestCase):
    def run_method(self, ns, m, method, cancelled):
        if method == 'complete':
            return ns[method](m, None, raw_ids=[0], heal='aaaaaa', cancelled=cancelled)
        return ns[method](m, [0], 'aaaaaa', Mock(return_value=.8), cancelled=cancelled)

    def test_cancelled_before_prefill_does_not_touch_cache_or_generate(self):
        for method in ('complete', 'complete_gated'):
            ns, m, error = model()
            ns['generate_step'] = Mock()
            with self.assertRaises(error): self.run_method(ns, m, method, lambda: True)
            m._switch.assert_not_called(); m._feed.assert_not_called()
            ns['generate_step'].assert_not_called()

    def test_cancellation_arriving_during_setup_stops_before_generation(self):
        for method in ('complete', 'complete_gated'):
            ns, m, error = model()
            cancelled = [False]
            m._feed.side_effect = lambda ids: cancelled.__setitem__(0, True) or [0]
            ns['generate_step'] = Mock()
            with self.assertRaises(error): self.run_method(ns, m, method, lambda: cancelled[0])
            ns['generate_step'].assert_not_called()

    def test_cancel_after_feed_keeps_ids_equal_to_actual_cache_then_recovers(self):
        for method in ('complete', 'complete_gated'):
            ns, m, error = model()
            lift('_feed', path=ROOT / 'engine/model.py', cls='Model', into=ns, can_trim_prompt_cache=lambda c: True,
                 trim_prompt_cache=lambda c, n: (c.__delitem__(slice(len(c)-n, None)) or n))
            m.ids, m.cache = [8, 9], [8, 9]
            m._feed = lambda ids, stable=None: ns['_feed'](m, ids, stable)
            calls = [0]
            def cancelled():
                calls[0] += 1
                return calls[0] == 3  # after _feed, before the first generation step
            ns['generate_step'] = Mock()
            with self.assertRaises(error): self.run_method(ns, m, method, cancelled)
            self.assertEqual(m.ids, m.cache)
            ns['generate_step'].assert_not_called()
            tail = m._feed([0, 2])
            self.assertEqual(m.cache + tail, [0, 2])
            self.assertEqual(tail, [0, 2])

    def test_every_healing_token_checks_cancellation_before_the_next_token(self):
        for method in ('complete', 'complete_gated'):
            ns, m, error = model()
            cancelled, yielded = [False], []
            def generate(*args, **kw):
                for i in range(6):
                    yielded.append(i)
                    cancelled[0] = i == 1
                    yield 1, np.zeros(10)
            ns['generate_step'] = generate
            with self.assertRaises(error): self.run_method(ns, m, method, lambda: cancelled[0])
            self.assertEqual(yielded, [0, 1])
            self.assertEqual(m.ids, [0, 1, 1])  # cache tracking still includes the yielded token

    def test_cancellation_during_heal_decode_stops_before_next_generation(self):
        for method in ('complete', 'complete_gated'):
            ns, m, error = model()
            cancelled, yielded = [False], []
            def decode(ids):
                cancelled[0] = True
                return 'a'
            m.tok.decode = decode
            def generate(*args, **kw):
                for i in range(6):
                    yielded.append(i)
                    yield 1, np.zeros(10)
            ns['generate_step'] = generate
            with self.assertRaises(error): self.run_method(ns, m, method, lambda: cancelled[0])
            self.assertEqual(yielded, [0])


if __name__ == '__main__': unittest.main()

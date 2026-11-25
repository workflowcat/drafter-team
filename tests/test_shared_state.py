"""Concurrency around look-ahead's non-model state, using synthetic records only."""
from concurrent.futures import ThreadPoolExecutor
import json
from pathlib import Path
import sys
import threading
import types
import unittest
from unittest.mock import Mock, patch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'engine'))
import memory
import snippets
from server_src import lift


def functions(*names, **namespace):
    return lift(*names, **namespace)


class SharedState(unittest.TestCase):
    def test_concurrent_builder_and_gate_loads_publish_once(self):
        builder = Mock(side_effect=lambda *a: object())
        gate = Mock(return_value={'boost': .3})
        path = Mock()
        path.stat.return_value = types.SimpleNamespace(st_mtime=123)
        ns = functions('builder_for', 'gate', 'gate_file', 'fitted', DEFAULTS=None, Builder=builder, model=object(), builders={},
                       BUILDERS_LOCK=threading.Lock(), GATE_LOCK=threading.Lock(), GATE={'mtime': 0},
                       gatecore=types.SimpleNamespace(load=gate))
        class Folder:
            def __truediv__(self, other): return path
        ns['DATA'] = Folder()
        with ThreadPoolExecutor(max_workers=8) as pool:
            built = list(pool.map(ns['builder_for'], ['raw'] * 100))
            loaded = list(pool.map(lambda i: ns['gate'](), range(100)))
        builder.assert_called_once(); gate.assert_called_once_with(path)
        self.assertTrue(all(b is built[0] for b in built))
        self.assertTrue(all(g is loaded[0] for g in loaded))

    def test_snippet_cache_reads_one_consistent_version(self):
        file = Mock()
        file.stat.return_value = types.SimpleNamespace(st_mtime=12)
        file.read_text.return_value = json.dumps({';test': 'synthetic'})
        with patch.object(snippets, 'FILE', file), patch.object(snippets, '_cache', {'mtime': None, 'data': {}}):
            with ThreadPoolExecutor(max_workers=8) as pool:
                values = list(pool.map(lambda i: snippets.load(), range(100)))
            file.read_text.assert_called_once()
            self.assertTrue(all(v == {';test': 'synthetic'} for v in values))

    def test_phrase_learning_and_lookahead_share_consistent_strings(self):
        # No constructor: it reads personal files. These are synthetic in-memory strings.
        m = memory.Memory.__new__(memory.Memory)
        m.lock, m.text, m.low, m.n = threading.Lock(), '\n', '\n', 0
        def add(i):
            m.add('We can review the synthetic draft tomorrow')
            m.suggest('We can review the synthetic draft ')
        with ThreadPoolExecutor(max_workers=8) as pool:
            list(pool.map(add, range(300)))
        self.assertEqual(m.n, 300)
        self.assertEqual(m.low, m.text.lower())
        self.assertEqual(m.suggest('We can review the synthetic draft ')[0], 'tomorrow')

    def test_ahead_stats_are_a_snapshot(self):
        original = {'made': 2, 'hit': 1}
        ns = functions('ahead_stats', AHEAD_LOCK=threading.Lock(), AHEAD_STATS=original)
        result = ns['ahead_stats']()
        result['made'] = 100
        self.assertEqual(original['made'], 2)


if __name__ == '__main__':
    unittest.main()

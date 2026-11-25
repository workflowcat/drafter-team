"""Speculative cache reuse: exercise _feed without importing MLX or a model."""
import copy
from pathlib import Path
import types
import unittest
from unittest.mock import Mock
from server_src import lift


class Cache(unittest.TestCase):
    def test_unaccepted_tokens_are_trimmed_before_different_prompt(self):
        path = Path(__file__).resolve().parents[1] / 'engine/model.py'
        for trimmable in (True, False):
            trim = Mock(side_effect=lambda cache, n: n)
            rebuild = Mock(return_value=['new cache'])
            ns = lift('_feed', path=path, cls='Model', copy=copy, can_trim_prompt_cache=lambda c: trimmable,
                      trim_prompt_cache=trim, make_prompt_cache=rebuild)
            m = types.SimpleNamespace(cache=['speculation'], ids=[1, 2, 3, 8, 9], snapshot=None, rebuilds=0, model=object(),
                                      marks={}, screen=None)   # _feed's fields (big-model round)
            tail = ns['_feed'](m, [1, 2, 4, 5])
            self.assertEqual(m.ids + tail, [1, 2, 4, 5])
            if trimmable:
                trim.assert_called_once_with(['speculation'], 3)
                self.assertEqual(tail, [4, 5])
            else:
                self.assertEqual(m.cache, ['new cache'])
                self.assertEqual(m.rebuilds, 1)


if __name__ == '__main__':
    unittest.main()

"""Voice dependency adapters. No MLX imports, model loads, or personal data."""
import ast
import importlib.util
from pathlib import Path
import sys
import unittest
from unittest.mock import patch

import numpy as np

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'engine'))
import stand_ins

PACKAGES = ('librosa', 'numba', 'scipy')


class Adapters(unittest.TestCase):
    def test_missing_packages_and_repeat_install(self):
        with patch.dict(sys.modules):
            for key in list(sys.modules):
                if key.split('.')[0] in PACKAGES:
                    del sys.modules[key]
            with patch.object(stand_ins.importlib.util, 'find_spec', return_value=None):
                self.assertEqual(stand_ins.install(), list(PACKAGES))
                self.assertEqual(stand_ins.install(), [])
            from librosa.filters import mel
            from numba import jit
            from scipy import signal
            self.assertIs(mel, stand_ins.mel)
            def plus(x): return x + 1
            self.assertIs(jit(plus), plus)
            self.assertIs(jit(nopython=True, parallel=True)(plus), plus)
            with self.assertRaisesRegex(RuntimeError, 'word timestamps require real scipy'):
                signal.medfilt(np.zeros(10), kernel_size=3)

    def test_module_spec_cannot_be_hidden_by_clearing_it(self):
        # find_spec returns an already-loaded module's spec. None raises rather than
        # reporting "optional dependency absent"; do not apply that tempting workaround.
        module = stand_ins._module('drafter_synthetic_optional')
        with patch.dict(sys.modules, {'drafter_synthetic_optional': module}):
            self.assertIs(importlib.util.find_spec(module.__name__), module.__spec__)
            module.__spec__ = None
            with self.assertRaises(ValueError): importlib.util.find_spec(module.__name__)

    def test_discoverable_packages_are_not_replaced_or_imported(self):
        with patch.dict(sys.modules):
            for key in PACKAGES:
                sys.modules.pop(key, None)
            with patch.object(stand_ins.importlib.util, 'find_spec', return_value=object()):
                self.assertEqual(stand_ins.install(), [])
            for key in PACKAGES:
                self.assertNotIn(key, sys.modules)

    def test_loaded_packages_are_preserved(self):
        originals = {key: object() for key in PACKAGES}
        with patch.dict(sys.modules, originals):
            self.assertEqual(stand_ins.install(), [])
            for key, original in originals.items():
                self.assertIs(sys.modules[key], original)

    def test_only_supported_mel_modes(self):
        for extra in ({'htk': True}, {'norm': None}):
            with self.assertRaises(ValueError):
                stand_ins.mel(sr=16000, n_fft=512, **extra)

    def test_voice_explicitly_disables_word_alignment(self):
        tree = ast.parse((ROOT / 'engine/voice.py').read_text())
        calls = [n for n in ast.walk(tree) if isinstance(n, ast.Call)
                 and isinstance(n.func, ast.Attribute) and n.func.attr == 'transcribe'
                 and isinstance(n.func.value, ast.Name) and n.func.value.id == 'mlx_whisper']
        self.assertEqual(len(calls), 2)
        for call in calls:
            self.assertIs(ast.literal_eval(next(k.value for k in call.keywords
                                               if k.arg == 'word_timestamps')), False)


@unittest.skipUnless(all(importlib.util.find_spec(p) is not None for p in PACKAGES),
                     'run with the old .venv for real librosa parity')
class RealPackages(unittest.TestCase):
    def test_real_packages_win_and_mel_matches(self):
        # Test the real on-disk packages, first unimported and then imported.
        self.assertEqual(stand_ins.install(), [])
        import librosa
        import numba
        import scipy.signal
        modules = {p: sys.modules[p] for p in PACKAGES}
        self.assertEqual(stand_ins.install(), [])
        for p, module in modules.items():
            self.assertIs(sys.modules[p], module)
            self.assertFalse(getattr(module, '__drafter_stand_in__', False))
        # Cached Parakeet v3 config: 16 kHz, FFT 512, 128 features. Also cover
        # librosa defaults and another common bank without importing Parakeet/MLX.
        for args in (dict(sr=16000, n_fft=512, n_mels=128, fmin=0, fmax=8000, norm='slaney'),
                     dict(sr=16000, n_fft=512), dict(sr=16000, n_fft=400, n_mels=80)):
            actual, expected = stand_ins.mel(**args), librosa.filters.mel(**args)
            delta = float(np.max(np.abs(actual - expected)))
            print(f'mel parity {args}: max abs difference {delta:.10g}', flush=True)
            self.assertEqual(actual.dtype, expected.dtype)
            self.assertEqual(actual.shape, expected.shape)
            self.assertLess(delta, 1e-6)


if __name__ == '__main__':
    unittest.main()

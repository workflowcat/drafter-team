"""Exercise the manual smoke's orchestration with fake readers; never load MLX."""
import contextlib
import importlib.util
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import types
import unittest
from unittest.mock import Mock, patch
import wave

import numpy as np

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('smoke_voice', ROOT / 'scripts/smoke_voice.py')
smoke = importlib.util.module_from_spec(spec)
spec.loader.exec_module(smoke)


class Smoke(unittest.TestCase):
    def check_worker(self, reader):
        mx = types.ModuleType('mlx.core')
        mx.set_memory_limit = Mock()
        mx.set_cache_limit = Mock()
        mx.synchronize = Mock()
        mx.get_peak_memory = lambda: 123_000_000
        mlx = types.ModuleType('mlx')
        mlx.core = mx
        guard = types.SimpleNamespace(start=Mock(), footprint_gb=lambda: 0.1)
        readers = types.SimpleNamespace(warm=Mock(return_value='fake model'),
                                        careful=Mock(return_value='Whisper text'), drop=Mock())
        voice = types.SimpleNamespace(Readers=lambda: readers,
                                      load_pcm16=Mock(return_value=np.zeros(16000, dtype=np.int16)),
                                      read=Mock(return_value='Parakeet text'))
        output = io.StringIO()
        with tempfile.TemporaryDirectory() as folder, patch.dict(os.environ), \
             patch.object(sys, 'path', list(sys.path)), \
             patch.dict(sys.modules, {'mlx': mlx, 'mlx.core': mx, 'guard': guard, 'voice': voice}), \
             contextlib.redirect_stdout(output):
            smoke.worker(reader, Path(folder) / 'speech.wav')
            self.assertEqual(os.environ['HF_HUB_OFFLINE'], '1')
            self.assertEqual(os.environ['DRAFTER_WORDS'], str(Path(folder) / 'words.json'))
            self.assertEqual(os.environ['DRAFTER_VOICE_SETTINGS'], str(Path(folder) / 'settings.json'))
            # Missing-cache errors are propagated, never retried online.
            load = Mock(side_effect=FileNotFoundError('synthetic missing cache'))
            with self.assertRaises(FileNotFoundError):
                voice.online(load)
            load.assert_called_once()
        guard.start.assert_called_once_with(3_000_000_000 / 2**30, every=0.1, hold=1, spike=0)
        self.assertTrue(all(c.args == (3_000_000_000,) for c in mx.set_memory_limit.call_args_list))
        mx.set_cache_limit.assert_called_once_with(64 * 2**20)
        readers.drop.assert_called_once_with('smoke done')
        result = json.loads(output.getvalue())
        self.assertEqual(result['reader'], reader)
        self.assertEqual(result['peak_mlx_GB'], 0.123)
        if reader == 'parakeet':
            voice.read.assert_called_once()
            readers.warm.assert_called_once()
            readers.careful.assert_not_called()
        else:
            readers.careful.assert_called_once()
            readers.warm.assert_not_called()
            voice.read.assert_not_called()

    def test_parakeet_uses_voice_functions_under_cap(self):
        self.check_worker('parakeet')

    def test_whisper_uses_voice_functions_under_cap(self):
        self.check_worker('whisper')

    def test_parent_tries_both_readers_and_fails_if_one_fails(self):
        commands, folders = [], []
        def run(command, **kwargs):
            commands.append(command)
            if command[0] == 'afconvert':
                path = Path(command[-1])
                folders.append(path.parent)
                with wave.open(str(path), 'wb') as stream:
                    stream.setnchannels(1)
                    stream.setsampwidth(2)
                    stream.setframerate(16000)
                    stream.writeframes(b'\0\0' * 16000)
            if '--worker' in command:
                self.assertEqual(kwargs['timeout'], 180)
                if 'parakeet' in command:
                    raise subprocess.CalledProcessError(137, command)
            return subprocess.CompletedProcess(command, 0)
        with patch.object(sys, 'argv', ['smoke_voice.py']), patch.object(sys, 'platform', 'darwin'), \
             patch.object(smoke.subprocess, 'run', side_effect=run), \
             contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
            with self.assertRaises(SystemExit) as result:
                smoke.main()
        self.assertEqual(result.exception.code, 1)
        workers = [c[c.index('--worker') + 1] for c in commands if '--worker' in c]
        self.assertEqual(workers, ['parakeet', 'whisper'])
        self.assertTrue(all(not p.exists() for p in folders))


if __name__ == '__main__':
    unittest.main()

"""Round eight: synthetic files and fake readers only. No models, data/ or servers."""
import contextlib
import ast
import importlib.util
import io
import json
import os
from pathlib import Path
import struct
import subprocess
import sys
import tempfile
import types
import unittest
from unittest.mock import Mock, patch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'engine'))
from voice_settings import FAST, CAREFUL, load_models, model_names


def module(name, path):
    spec = importlib.util.spec_from_file_location(name, ROOT / path)
    result = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(result)
    return result


converter = module('convert_parakeet', 'scripts/convert_parakeet.py')
bench = module('voice_models', 'bench/voice_models.py')


class Settings(unittest.TestCase):
    def test_settings_route_preserves_and_updates_model_keys_without_server(self):
        tree = ast.parse((ROOT / 'engine/server.py').read_text())
        post = next(n for n in ast.walk(tree) if isinstance(n, ast.FunctionDef) and n.name == 'do_POST')
        branch = next(n for n in ast.walk(post) if isinstance(n, ast.If)
                      and ast.unparse(n.test) == "self.path == '/settings'")
        function = ast.FunctionDef(name='save', args=ast.arguments(posonlyargs=[], args=[],
                                  kwonlyargs=[], kw_defaults=[], defaults=[]), body=branch.body, decorator_list=[])
        with tempfile.TemporaryDirectory() as folder:
            namespace = dict(DATA=Path(folder), json=json, settings_load=lambda: {'voice': True, 'model': 'text'},
                             req={'voiceFast': 'fast', 'voiceCareful': 'careful'}, self=types.SimpleNamespace(send=lambda x: x))
            exec(compile(ast.fix_missing_locations(ast.Module(body=[function], type_ignores=[])), '<settings-route>', 'exec'), namespace)
            self.assertEqual(namespace['save'](), {'ok': True})
            self.assertEqual(json.loads((Path(folder) / 'settings.json').read_text()),
                             {'voice': True, 'model': 'text', 'voiceFast': 'fast', 'voiceCareful': 'careful'})
            get = next(n for n in ast.walk(tree) if isinstance(n, ast.FunctionDef) and n.name == 'do_GET')
            branch = next(n for n in ast.walk(get) if isinstance(n, ast.If)
                          and ast.unparse(n.test) == "self.path == '/settings'")
            function.body = branch.body
            namespace.update(settings_load=lambda: json.loads((Path(folder) / 'settings.json').read_text()),
                             actions=types.SimpleNamespace(ALL=[]), dictionary=types.SimpleNamespace(load=lambda: {'words': []}))
            exec(compile(ast.fix_missing_locations(ast.Module(body=[function], type_ignores=[])), '<settings-route>', 'exec'), namespace)
            self.assertEqual(namespace['save']()['voiceFast'], 'fast')
            self.assertEqual(namespace['save']()['voiceCareful'], 'careful')

    def test_defaults_and_bad_values(self):
        for settings in ({}, None, [], 'bad', {'voiceFast': False, 'voiceCareful': []},
                         {'voiceFast': '  ', 'voiceCareful': None}):
            self.assertEqual(model_names(settings), (FAST, CAREFUL))
        self.assertEqual(model_names({'voiceFast': ' custom/fast '}), ('custom/fast', CAREFUL))
        self.assertEqual(model_names({'voiceCareful': ' custom/careful '}), (FAST, 'custom/careful'))
        self.assertEqual(model_names({'voiceFast': '~/test'})[0], os.path.expanduser('~/test'))

    def test_loading_only_explicit_fixture(self):
        with tempfile.TemporaryDirectory() as folder:
            p = Path(folder) / 'settings.json'
            self.assertEqual(load_models(p), (FAST, CAREFUL))
            for text in ('{', 'null', '[]', '42'):
                p.write_text(text)
                self.assertEqual(load_models(p), (FAST, CAREFUL))
            p.write_text('{"voiceCareful":"local/whisper"}')
            with patch.dict(os.environ, DRAFTER_VOICE_SETTINGS=str(p)):
                self.assertEqual(load_models(), (FAST, 'local/whisper'))

    def test_voice_import_uses_selection_without_loading_models(self):
        # Execute real module wiring with inert MLX/Parakeet/guard imports and a
        # temporary settings + glossary. serve() never runs.
        mx = types.ModuleType('mlx.core')
        mx.set_cache_limit = Mock()
        mlx = types.ModuleType('mlx')
        mlx.core = mx
        loader = Mock(side_effect=AssertionError('No model loads'))
        fake = {'mlx': mlx, 'mlx.core': mx,
                'stand_ins': types.SimpleNamespace(install=Mock()),
                'parakeet_mlx': types.SimpleNamespace(from_pretrained=loader),
                'parakeet_mlx.audio': types.SimpleNamespace(get_logmel=Mock()),
                'guard': types.SimpleNamespace(start=Mock())}
        with tempfile.TemporaryDirectory() as folder:
            p = Path(folder)
            (p / 'settings.json').write_text('{"voiceFast":"test/fast","voiceCareful":"test/careful"}')
            (p / 'words.json').write_text('{"terms":[]}')
            with patch.dict(os.environ, DRAFTER_VOICE_SETTINGS=str(p / 'settings.json'),
                            DRAFTER_WORDS=str(p / 'words.json')), patch.dict(sys.modules, fake):
                voice = module('voice_wiring_test', 'engine/voice.py')
            self.assertEqual((voice.MODEL, voice.CAREFUL), ('test/fast', 'test/careful'))
            loader.assert_not_called()


class Conversion(unittest.TestCase):
    def fixture(self, directory):
        directory.mkdir()
        header = {'__metadata__': {'format': 'mlx'},
                  'encoder.weight': dict(dtype='F32', shape=[2], data_offsets=[0, 8]),
                  'encoding._pe': dict(dtype='F32', shape=[1], data_offsets=[8, 12]),
                  'counter': dict(dtype='I32', shape=[], data_offsets=[12, 16])}
        data = struct.pack('<fffi', 1.0, -2.0, 3.0, 7)
        encoded = json.dumps(header).encode()
        (directory / 'config.json').write_text('{"vocabulary":["a","б"]}')
        (directory / 'model.safetensors').write_bytes(struct.pack('<Q', len(encoded)) + encoded + data)
        return header, data

    @staticmethod
    def cast(block, dtype):
        assert dtype == 'F32'
        return b''.join(block[i + 2:i + 4] for i in range(0, len(block), 4))

    def test_streaming_layout_preserves_config_metadata_and_fp32_buffers(self):
        with tempfile.TemporaryDirectory() as folder:
            source, dest = Path(folder) / 'source', Path(folder) / 'out'
            _, original = self.fixture(source)
            before = (source / 'model.safetensors').read_bytes()
            with patch.object(converter, 'BLOCK', 4), contextlib.redirect_stdout(io.StringIO()):
                converter.convert(source, dest, self.cast)
            self.assertEqual((source / 'model.safetensors').read_bytes(), before)
            self.assertEqual((dest / 'config.json').read_bytes(), (source / 'config.json').read_bytes())
            header, offset = converter.read_header(dest / 'model.safetensors')
            self.assertEqual(offset % 8, 0)
            self.assertEqual(header['__metadata__'], {'format': 'mlx'})
            self.assertEqual(header['encoder.weight'], dict(dtype='BF16', shape=[2], data_offsets=[0, 4]))
            self.assertEqual(header['encoding._pe']['dtype'], 'F32')
            self.assertEqual((dest / 'model.safetensors').read_bytes()[offset:],
                             self.cast(original[:8], 'F32') + original[8:])
            # Independent reader validates the serialized format without GPU imports.
            from safetensors import safe_open
            with safe_open(dest / 'model.safetensors', framework='numpy') as f:
                self.assertEqual(f.get_slice('encoder.weight').get_dtype(), 'BF16')
                self.assertEqual(f.get_tensor('counter').item(), 7)
            with self.assertRaises(FileExistsError):
                converter.convert(source, dest, self.cast)

    def test_bad_offsets_and_size_rejected(self):
        for tensor, size in [(dict(dtype='F32', shape=[2], data_offsets=[1, 9]), 9),
                             (dict(dtype='F32', shape=[2], data_offsets=[0, 4]), 4),
                             (dict(dtype='F32', shape=[-1], data_offsets=[0, 4]), 4),
                             (dict(dtype='F32', shape=[1], data_offsets=[0, 4]), 8)]:
            with self.assertRaises(ValueError):
                converter.plan({'x': tensor}, size)

    def test_dtype_policy(self):
        self.assertEqual(converter.target_dtype('norm.weight', 'F32'), 'BF16')
        self.assertEqual(converter.target_dtype('x', 'F16'), 'BF16')
        for dtype in ('I64', 'BF16', 'BOOL'):
            self.assertEqual(converter.target_dtype('x', dtype), dtype)
        self.assertEqual(converter.target_dtype('preprocessor._filterbanks', 'F32'), 'F32')

    def test_failed_conversion_has_no_partial_destination(self):
        with tempfile.TemporaryDirectory() as folder:
            source, dest = Path(folder) / 'source', Path(folder) / 'out'
            self.fixture(source)
            with self.assertRaises(ValueError):
                converter.convert(source, dest, lambda *_: b'')
            self.assertFalse(dest.exists())
            self.assertEqual(sorted(p.name for p in Path(folder).iterdir()), ['source'])
            with self.assertRaises(ValueError):
                converter.convert(source, ROOT / 'forbidden-model', self.cast)


class Comparison(unittest.TestCase):
    def test_english_and_ukrainian_normalization(self):
        for left, right in [("It's Friday!", "IT’S friday"),
                            ('П’ятниця, сімʼя і ґанок.', "п'ятниця сім'я і ҐАНОК"),
                            ('Їжак', 'І\u0308жак')]:
            self.assertEqual(bench.difference(left, right)['rate'], 0)
        self.assertGreater(bench.difference('ї ґ є і', 'и г е ы')['rate'], 0)

    def test_edit_distance_and_empty_reference(self):
        for hyp in ('one cat three', 'one three', 'one two extra three'):
            self.assertEqual(bench.difference('one two three', hyp),
                             dict(edits=1, reference_words=3, rate=1 / 3))
        self.assertEqual(bench.difference('one', 'a b c')['rate'], 3)
        self.assertEqual(bench.difference('one two', '')['rate'], 1)
        self.assertEqual(bench.difference('', '')['rate'], 0)
        self.assertIsNone(bench.difference('', 'invented words')['rate'])

    def test_compare_matches_take_and_reader_and_missing_baseline(self):
        rows = [dict(pair='current', take='a', reader='fast', status='ok', text='hello'),
                dict(pair='current', take='a', reader='careful', status='error'),
                dict(pair='smaller', take='a', reader='fast', status='ok', text='hello there'),
                dict(pair='smaller', take='a', reader='careful', status='ok', text='hello'),
                dict(pair='smaller', take='b', reader='fast', status='ok', text='hello')]
        bench.compare(rows)
        self.assertEqual(rows[2]['difference']['rate'], 1)
        self.assertNotIn('difference', rows[3])
        self.assertNotIn('difference', rows[4])

    def test_voice_locale_parser_including_names_with_spaces(self):
        self.assertEqual(bench.say_voices('Bad News en_US # hi\nSamantha en_US # hi\nLesya uk_UA # Привіт'),
                         {'en': 'Samantha', 'uk': 'Lesya'})
        self.assertNotIn('uk', bench.say_voices('Milena ru_RU # hi'))

    def test_synthetic_generates_both_languages_without_substituting_russian(self):
        commands = []
        def run(command, **kwargs):
            commands.append(command)
            return subprocess.CompletedProcess(command, 0, stdout='Samantha en_US # hi\nLesya uk_UA # hi\n')
        with tempfile.TemporaryDirectory() as folder, patch.object(bench.subprocess, 'run', side_effect=run), \
             contextlib.redirect_stdout(io.StringIO()):
            clips = bench.synthetic(Path(folder))
        self.assertEqual([p.name for p in clips], ['en.wav', 'uk.wav'])
        self.assertEqual([c[2] for c in commands if c[0] == 'say' and '-o' in c], ['Samantha', 'Lesya'])

    def test_parent_default_pairs_report_and_synthetic_empty_failure(self):
        pairs = []
        def run_pair(name, fast, careful, wav, mode, folder):
            pairs.append((name, fast, careful))
            return [dict(pair=name, take=str(wav), reader=r, status='ok', text='', mode=mode)
                    for r in ('fast', 'careful')]
        with tempfile.TemporaryDirectory() as folder:
            report = Path(folder) / 'report.json'
            with patch.object(sys, 'argv', ['voice_models.py', '--synthetic', '--json', str(report)]), \
                 patch.object(sys, 'platform', 'darwin'), patch.object(bench, 'run_pair', side_effect=run_pair), \
                 patch.object(bench, 'synthetic', side_effect=lambda p: [p / 'en.wav']), \
                 contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(bench.main(), 1)
            self.assertEqual([p[0] for p in pairs], ['current', 'smaller'])
            rows = json.loads(report.read_text())['rows']
            self.assertTrue(all(r['status'] == 'error' and 'difference' not in r for r in rows))

    def test_timeout_retains_completed_reader_and_marks_pair_failed(self):
        def run(command, **kwargs):
            self.assertEqual(kwargs['timeout'], 180)
            kwargs['stdout'].write(json.dumps(dict(event='result', reader='fast', status='ok', text='kept')) + '\n')
            kwargs['stderr'].write('synthetic failure')
            raise subprocess.TimeoutExpired(command, 180)
        with tempfile.TemporaryDirectory() as folder, patch.object(bench.subprocess, 'run', side_effect=run), \
             contextlib.redirect_stderr(io.StringIO()):
            rows = bench.run_pair('test', 'fast', 'careful', Path(folder) / 'take.wav', 'take', Path(folder))
        self.assertEqual(rows[0]['text'], 'kept')
        self.assertIn('process_error', rows[0])
        self.assertEqual(rows[1]['status'], 'error')
        self.assertIn('timeout', rows[1]['error'])

    def test_worker_keeps_models_sequential_and_uses_strict_cap(self):
        mx = types.ModuleType('mlx.core')
        for name in ('set_memory_limit', 'set_cache_limit', 'reset_peak_memory', 'synchronize'):
            setattr(mx, name, Mock())
        mx.get_peak_memory = lambda: 100_000_000
        mlx = types.ModuleType('mlx'); mlx.core = mx
        guard = types.SimpleNamespace(start=Mock(), footprint_gb=lambda: 0.1)
        events = []
        readers = types.SimpleNamespace(
            read_file_fast=lambda p: events.append('fast') or [{'text': 'fast text'}],
            read_file_whisper=lambda p, fast_text=None, fast_segments=None: events.append('careful') or [{'text': 'careful text'}],
            drop=lambda why: events.append('drop'))
        voice = types.SimpleNamespace(Readers=lambda: readers, whisper_segments=lambda s: s,
                                      whisper_rejection=lambda s: None)
        with tempfile.TemporaryDirectory() as folder, patch.dict(os.environ), \
             patch.dict(sys.modules, {'mlx': mlx, 'mlx.core': mx, 'guard': guard, 'voice': voice}), \
             contextlib.redirect_stdout(io.StringIO()) as output:
            self.assertEqual(bench.worker('f', 'c', Path(folder) / 'fake.wav', 'file', Path(folder)), 0)
            settings = json.loads(Path(os.environ['DRAFTER_VOICE_SETTINGS']).read_text())
            self.assertEqual(settings, {'voiceFast': 'f', 'voiceCareful': 'c'})
            self.assertEqual(os.environ['HF_HUB_OFFLINE'], '1')
            self.assertEqual(float(os.environ['DRAFTER_FILE_CAP_GB']), 3_000_000_000 / 2**30)
            load = Mock(side_effect=FileNotFoundError())
            with self.assertRaises(FileNotFoundError):
                voice.online(load)
            load.assert_called_once()
        self.assertEqual(events, ['fast', 'drop', 'careful', 'drop'])
        guard.start.assert_called_once_with(3_000_000_000 / 2**30, every=0.1, hold=1, spike=0)
        self.assertEqual(mx.reset_peak_memory.call_count, 2)
        self.assertEqual(len(output.getvalue().splitlines()), 2)


if __name__ == '__main__':
    unittest.main()

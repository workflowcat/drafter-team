"""Fifth-pass regressions: temporary synthetic corpora, fake processes, no model or live data."""
import importlib.util
import json
from pathlib import Path
import re
import tempfile
import time
import types
import unittest
from unittest.mock import patch

import test_retrain
from test_round7_third import ROOT, extract

retrain = test_retrain.retrain


class PhraseStaging(unittest.TestCase):
    setUp = test_retrain.Lifecycle.setUp

    def run_attempt(self, *, training=0, comparison=(False, 'recording'), preparation=None):
        live = self.root / 'data/phrases.jsonl'
        staged = self.root / 'data/phrases-next.jsonl'
        before = live.read_bytes() if live.exists() else None
        events = []
        fresh = json.dumps({'src': 'beeper', 'text': 'this weeks synthetic writing'}) + '\n'

        def unchanged():
            self.assertEqual(live.read_bytes() if live.exists() else None, before)
            self.assertEqual(self.stamp.read_text(), '123')

        def step(script, *args, **kw):
            unchanged()
            events.append(script)
            if script == preparation: return 1, 'synthetic preparation failure'
            if script == 'engine/memory.py':
                self.assertEqual(args, ('build', '--output', str(staged)))
                staged.write_text(fresh)
            elif script == 'bench/make_train.py':
                self.assertEqual(args, ('--corpus', str(self.root / 'data/corpus.jsonl')))   # trained from the corpus
                self.assertEqual(staged.read_text(), fresh)
            return 0, 'synthetic'

        def run(command, **kw):
            unchanged()
            self.assertEqual(Path(command[1]).name, 'train.py')
            self.assertEqual(staged.read_text(), fresh)
            events.append('train')
            if isinstance(training, Exception): raise training
            adapter = self.root / 'data/adapters-new/adapters.safetensors'
            adapter.parent.mkdir(exist_ok=True)
            adapter.write_text('synthetic adapter')
            return types.SimpleNamespace(returncode=training, stderr='synthetic failure')

        def compare(*args):
            unchanged()  # both recordings are still on the pre-cutoff corpus
            events.append('compare')
            return comparison

        with patch.object(retrain, 'fresh_set', return_value=50), \
             patch.object(retrain, 'step', side_effect=step), \
             patch.object(retrain.subprocess, 'run', side_effect=run), \
             patch.object(retrain, '_compare', side_effect=compare):
            retrain.main()
        if preparation or training or comparison[1] is None:
            unchanged()
        else:
            self.assertEqual(live.read_text(), fresh)
            self.assertFalse(staged.exists())
            self.assertNotEqual(self.stamp.read_text(), '123')
        return events

    def test_training_failure_and_incomplete_comparison_leave_retry_corpus_untouched(self):
        live = self.root / 'data/phrases.jsonl'
        live.write_text('{"src":"typed","text":"old synthetic vocabulary"}\n')
        for training, comparison in ((1, (False, 'recording')),
                                     (OSError('synthetic training failure'), (False, 'recording')),
                                     (0, (False, None))):
            with self.subTest(training=training, comparison=comparison):
                events = self.run_attempt(training=training, comparison=comparison)
                self.assertEqual(events, ['bench/people_fresh.py', 'engine/memory.py', 'bench/corpus.py',
                                         'bench/make_train.py', 'train'] + (['compare'] if training == 0 else []))
        # A leftover staging file is rebuilt, not consumed by either the retry's training or benches.
        (self.root / 'data/phrases-next.jsonl').write_text('stale staging')
        self.assertEqual(self.run_attempt(), ['bench/people_fresh.py', 'engine/memory.py', 'bench/corpus.py',
                                              'bench/make_train.py', 'train', 'compare'])

    def test_missing_live_phrases_still_trains_on_staged_file(self):
        self.run_attempt()

    def test_preparation_failure_never_trains_or_publishes_stale_staging(self):
        (self.root / 'data/phrases-next.jsonl').write_text('stale staging')
        for script in ('engine/memory.py', 'bench/corpus.py', 'bench/make_train.py'):
            with self.subTest(script=script):
                events = self.run_attempt(preparation=script)
                self.assertNotIn('train', events)
                self.assertNotIn('compare', events)
        retrain.engine_post.assert_not_called()


class PhraseInputs(unittest.TestCase):
    def test_build_alternate_output_preserves_live_default_and_uses_all_sources(self):
        with tempfile.TemporaryDirectory() as folder:
            live = Path(folder) / 'phrases.jsonl'
            staged = Path(folder) / 'phrases-next.jsonl'
            live.write_text('old live corpus')
            sources = {name: (lambda name=name: [f'synthetic {name} source phrase'])
                       for name in ('beeper', 'voice_notes', 'claude_prompts', 'typed')}
            ns = extract('engine/memory.py', {'build'},
                         dict(Path=Path, time=time, json=json, OUT=live,
                              WORD=re.compile(r'\w+'), **sources))
            ns['build'](staged)
            self.assertEqual(live.read_text(), 'old live corpus')
            self.assertEqual({json.loads(line)['src'] for line in staged.read_text().splitlines()},
                             {'beeper', 'voice', 'claude', 'typed'})
            ns['build']()
            self.assertEqual(live.read_bytes(), staged.read_bytes())

    def test_make_train_uses_explicit_phrases_and_retains_default_and_holdout(self):
        spec = importlib.util.spec_from_file_location('make_train_tested', ROOT / 'bench/make_train.py')
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)  # import has no personal-data reads
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            (root / 'data').mkdir()
            live = root / 'data/phrases.jsonl'
            staged = root / 'data/phrases-next.jsonl'
            live.write_text(json.dumps({'src': 'typed', 'text': 'old synthetic vocabulary'}) + '\n')
            rows = [{'src': 'beeper', 'text': 'new synthetic vocabulary'},
                    {'src': 'voice', 'text': 'held synthetic sentence'}]
            staged.write_text(''.join(json.dumps(row) + '\n' for row in rows))
            from held import Held
            with patch.object(module, 'ROOT', root), \
                 patch.object(module, 'Held', side_effect=lambda: Held(['held synthetic sentence'])):
                for args, expected in ((['--phrases', str(staged)], '[Beeper]\nnew synthetic vocabulary'),
                                       ([], '[Claude]\nold synthetic vocabulary')):
                    module.main(args)
                    output = [json.loads(line)['text'] for name in ('train', 'valid')
                              for line in (root / f'data/train/{name}.jsonl').read_text().splitlines() if line]
                    self.assertEqual(output, [expected])


class ContextCompletion(unittest.TestCase):
    def test_both_reads_check_old_conversation_before_remembering(self):
        # Existing Keys tests use source contracts; this does not exercise live Accessibility.
        source = (ROOT / 'app/Keys.swift').read_text()
        for name in ('contextFor', 'warmField'):
            body = source.split(f'    func {name}(', 1)[1].split('\n    func ', 1)[0]
            self.assertIn('self.rememberContext(key, t, el: el)', body)
            self.assertNotIn('self.remember(key, t)', body)
            self.assertLess(body.index('DispatchQueue.main.async {'), body.index('self.rememberContext('))
        helper = source.split('    func rememberContext(', 1)[1].split('\n    func ', 1)[0]
        for condition in ('let was = screens[key]', '!was.isEmpty',
                          '!text.contains(String(was.suffix(160)))', 'Ghost.shared.visible',
                          'Ghost.shared.action == nil', 'spot.map({ CFEqual($0.el, el) }) == true'):
            self.assertIn(condition, helper)
        self.assertLess(helper.index('Ghost.shared.hide("context")'), helper.index('remember(key, text)'))
        self.assertIn('context: another conversation under the same title, suggestion dropped', helper)


if __name__ == '__main__':
    unittest.main()

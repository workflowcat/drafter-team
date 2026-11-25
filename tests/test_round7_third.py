"""Third-pass regressions: synthetic files, extracted methods, no engines or model imports."""
import datetime
import errno
import json
import os
from pathlib import Path
import tempfile
import threading
import time
import types
import unittest
from unittest.mock import Mock, patch
from urllib.error import URLError

from test_ahead import load as ahead_load
import test_retrain
retrain = test_retrain.retrain
from retrain_state import last_retrain
import people
from server_src import lift

ROOT = Path(__file__).resolve().parents[1]


def extract(path, names, ns, cls=None):
    return lift(*names, path=ROOT / path, cls=cls, into=ns)


class Sticky(unittest.TestCase):
    def test_real_keys_and_ahead_hits_track_chat_but_cached_screen_and_speculation_do_not(self):
        with tempfile.TemporaryDirectory() as folder:
            p = people.People(Path(folder) / 'people.json')
            contexts = {}
            for chat in ('old', 'new'):
                lines = [f'{chat} synthetic message {i}' for i in range(4)]
                p.chats[chat] = {'mine': lines}
                for line in lines: p._mark(people.mark(line), chat)
                contexts[chat] = '\n'.join(lines[:2])
            ns = ahead_load(lambda *a, **kw: {'text': ''}, [0])
            extract('engine/server.py', {'earlier'}, ns)
            ns['people_mem'] = p
            def req(chat, **kw):
                return dict(app='Beeper', context=contexts[chat], before='hello', **kw)
            ns['complete'](req('old'))
            self.assertEqual(p.last, 'old')
            self.assertEqual(p.chat_for(contexts['old'].splitlines()[0]), 'old')
            # A fast ahead hit still represents a real key in the new chat.
            r = req('new')
            ns['AHEAD'][ns['ahead_key'](r)] = (time.time(), {'text': ''})
            self.assertTrue(ns['complete'](r)['ahead'])
            self.assertEqual(p.last, 'new')
            ns['complete'](req('old', context_fresh=False))
            ns['complete'](req('old'), low=True, seq=ns['latest'][0])
            self.assertEqual(p.last, 'new')
            self.assertEqual(p.chat_for(contexts['new'].splitlines()[0]), 'new')
            self.assertEqual(p.add(contexts['old'], 'a freshly sent message'), 'old')
            self.assertEqual(p.last, 'old')


class Sleep(unittest.TestCase):
    def test_oneshot_during_retrain_never_loads_but_expired_lease_and_wake_can(self):
        load = Mock(return_value=('model', None))
        ns = extract('engine/model.py', {'sleep', 'wake', '_ensure', 'oneshot'},
                     dict(time=time, load=load), cls='Model')
        m = types.SimpleNamespace(lock=threading.Lock(), model=None, wake_at=0, retrain_sleep=False,
                                  repo='fake', adapter=None, head_ids=[], parked={}, marks={}, _warm=Mock(), lora=Mock(),
                                  _oneshot=Mock(return_value='answer'), tw=None, _tweak=lambda tw: None)
        m._ensure = lambda force=False: ns['_ensure'](m, force)
        self.assertFalse(ns['sleep'](m, 3600, retrain=True))
        deadline = m.wake_at
        ns['sleep'](m, 10)  # a voice sleep must not shorten the retrain lease
        self.assertTrue(m.retrain_sleep)
        self.assertEqual(m.wake_at, deadline)
        self.assertEqual(ns['oneshot'](m, [1]), '')
        load.assert_not_called(); m._oneshot.assert_not_called(); m.lora.assert_not_called()
        m.wake_at = time.time() - 1
        self.assertEqual(ns['oneshot'](m, [1]), 'answer')
        load.assert_called_once()
        m.model = None; m.wake_at = time.time() + 3600
        self.assertTrue(ns['wake'](m))
        self.assertEqual(load.call_count, 2)

    def test_chip_checks_sleep_before_queue_and_again_inside_worker(self):
        m = types.SimpleNamespace(asleep=True, loading=False)
        actions = types.SimpleNamespace(detect=Mock(return_value='action'), cached=Mock())
        run = Mock(side_effect=lambda fn: fn(lambda: False))
        ns = extract('engine/server.py', {'chip'}, dict(model=m, actions=actions, run=run, time=time))
        self.assertEqual(ns['chip']({'before': 'do a thing'}), {})
        run.assert_not_called(); actions.cached.assert_not_called()
        m.asleep = False
        run.side_effect = lambda fn: (setattr(m, 'asleep', True) or fn(lambda: False))
        self.assertEqual(ns['chip']({'before': 'do a thing'}), {})
        actions.cached.assert_not_called()


class RetrainEdges(unittest.TestCase):
    setUp = test_retrain.Lifecycle.setUp
    run_night = test_retrain.Lifecycle.run_night

    def test_engine_down_does_not_block_comparison_or_try_wake(self):
        retrain.engine_post.side_effect = URLError(ConnectionRefusedError(errno.ECONNREFUSED, 'offline'))
        with patch.object(retrain, '_compare', return_value=(True, 'new')) as compare:
            self.assertEqual(retrain.compare('a', 'b', []), (True, 'new'))
        compare.assert_called_once()
        retrain.engine_post.assert_called_once_with('sleep', secs=3600, retrain=True)

    def test_other_sleep_failures_still_abort_comparison(self):
        retrain.engine_post.side_effect = URLError(TimeoutError('no acknowledgement'))
        with patch.object(retrain, '_compare') as compare:
            self.assertEqual(retrain.compare('a', 'b', []), (False, None))
        compare.assert_not_called()

    def test_failed_wake_preserves_successful_decision(self):
        retrain.engine_post.side_effect = [{}, RuntimeError('wake failed')]
        report = []
        with patch.object(retrain, '_compare', return_value=(True, 'new')):
            self.assertEqual(retrain.compare('a', 'b', report), (True, 'new'))
        self.assertIn('decision retained', report[-1])

    def test_failed_wake_still_applies_decided_switch_in_main(self):
        retrain.engine_post.side_effect = [{}, RuntimeError('wake failed')]
        current = self.root / 'data/adapters'
        current.mkdir(); (current / 'adapters.safetensors').write_text('old')
        self.run_night(0, (True, 'new-recording'))
        self.assertEqual((current / 'adapters.safetensors').read_text(), 'fake')
        self.assertEqual((self.root / 'data/adapters-prev/adapters.safetensors').read_text(), 'old')
        self.assertNotEqual(self.stamp.read_text(), '123')

    def test_first_switch_keeps_original_cutoff_through_gate_refit(self):
        self.stamp.unlink()
        adapter = self.root / 'data/adapters/adapters.safetensors'
        adapter.parent.mkdir(); adapter.write_text('old')
        os.utime(adapter, (1000, 1000))
        def run(*a, **kw):
            new = self.root / 'data/adapters-new/adapters.safetensors'
            if 'launchctl' != a[0][0]:
                new.parent.mkdir(exist_ok=True); new.write_text('new')
            return types.SimpleNamespace(returncode=0, stderr='')
        def step(*args, **kw):
            if args[0] == 'bench/gate.py': self.assertEqual(last_retrain(self.root), 1000)
            return test_retrain.synthetic_step(*args, **kw)
        with patch.object(retrain, 'fresh_set', return_value=50), \
             patch.object(retrain, 'step', side_effect=step), \
             patch.object(retrain.subprocess, 'run', side_effect=run), \
             patch.object(retrain, '_compare', return_value=(True, 'new-recording')):
            retrain.main()
        self.assertGreater(last_retrain(self.root), 1000)

    def test_first_draw_uses_layer_mtime_and_no_unknown_cutoff_draw(self):
        self.stamp.unlink()
        adapter = self.root / 'data/adapters/adapters.safetensors'
        adapter.parent.mkdir(); adapter.write_text('synthetic')
        os.utime(adapter, (1000, 1000))
        ns = extract('bench/make_fresh.py', {'since'},
                     dict(ROOT=self.root, last_retrain=last_retrain, datetime=datetime))
        self.assertEqual(ns['since']().timestamp(), 1000)
        self.stamp.write_text('2000')
        self.assertEqual(ns['since']().timestamp(), 2000)
        self.stamp.unlink(); adapter.unlink()
        with self.assertRaisesRegex(RuntimeError, 'No training cutoff'): ns['since']()

    def test_corpus_filters_held_from_all_sources_including_zero_cut(self):
        import held
        line = 'held synthetic sentence with enough words to detect near copies'
        (self.root / 'data/replay-fresh.json').write_text(json.dumps([{'text': line}]))
        def rows(name, src=None):
            out = [{'text': line, 't': 1}, {'text': line + ' continuation', 't': 2},
                   {'text': 'safe old ' + name, 't': 3}, {'text': 'safe recent ' + name, 't': 200}]
            return [dict(r, src=src) for r in out] if src else out
        corpus_rows = rows('typed', 'typed') + [{'text': 'other source line', 't': 3, 'src': 'other'}]
        (self.root / 'data/corpus.jsonl').write_text('\n'.join(map(json.dumps, corpus_rows)))
        (self.root / 'data/drafts.jsonl').write_text('\n'.join(map(json.dumps, rows('drafts'))))
        live = types.SimpleNamespace(SOURCES=('typed',))
        ns = extract('bench/ngram.py', {'corpus', 'corpus_from'}, dict(ROOT=self.root, json=json, LiveWords=live))
        with patch.object(held, 'ROOT', self.root):
            for cut in (0, 100, 300):
                lines = ns['corpus'](cut)
                self.assertFalse(any(line in text for text in lines))
                self.assertNotIn('other source line', lines)          # only the live finisher's sources
                for name in ('typed', 'drafts'):
                    self.assertIn('safe old ' + name, lines)
                    self.assertEqual('safe recent ' + name in lines, cut != 100)

if __name__ == '__main__': unittest.main()

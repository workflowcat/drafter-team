"""Fourth-pass regressions: fake model/clock/routes and temporary synthetic records only."""
import threading
import types
import unittest
from unittest.mock import Mock, patch

from test_ahead import load as ahead_load, settle
from test_round7_third import ROOT, extract
import test_server_routes
import test_retrain


class Sleep(unittest.TestCase):
    def setUp(self):
        self.clock = types.SimpleNamespace(time=Mock(return_value=1000.0))
        self.load = Mock(return_value=('fake model', None))
        ns = extract('engine/model.py', {'sleep', 'wake', '_ensure', 'oneshot', '_drop'},
                     dict(time=self.clock, load=self.load, gc=types.SimpleNamespace(collect=Mock()),
                          mx=types.SimpleNamespace(clear_cache=Mock())), cls='Model')
        self.m = types.SimpleNamespace(lock=threading.Lock(), model=None, wake_at=0,
                                       retrain_sleep=False, repo='fake', adapter=None,
                                       head_ids=[], parked={}, marks={}, sleeps=0, _warm=Mock(),   # marks: big-model round
                                       lora=Mock(), _oneshot=Mock(return_value='answer'),
                                       memory_gb=lambda: (0, 0), asleep=False, _tweak=lambda tw: tw, tw=None)
        for name, fn in ns.items():
            if name in {'sleep', 'wake', '_ensure', 'oneshot', '_drop'}:
                setattr(self.m, name, types.MethodType(fn, self.m))

    def test_wake_then_short_voice_sleep_auto_wakes_through_real_routes(self):
        routes = test_server_routes.ServerRoutes()
        routes.setUp()
        routes.ns['model'] = self.m
        routes.post('/sleep', {'secs': 3600, 'retrain': True})
        self.clock.time.return_value = 1900.0
        routes.post('/wake', {})
        self.assertEqual((self.m.wake_at, self.m.retrain_sleep), (0, False))
        routes.post('/sleep', {'secs': 10})
        self.assertEqual((self.m.wake_at, self.m.retrain_sleep), (1910, False))
        delay, callback = routes.timer.call_args.args
        self.assertEqual(delay, 11)
        self.clock.time.return_value = 1911.0
        callback()  # no timer thread or waiting
        self.assertIsNotNone(self.m.model)
        self.assertEqual((self.m.wake_at, self.m.retrain_sleep), (0, False))
        self.assertEqual(self.load.call_count, 2)

    def test_retrain_blocks_oneshot_and_timer_but_ordinary_sleep_does_not_block_oneshot(self):
        self.m.sleep(3600, retrain=True)
        self.m.sleep(10)
        self.assertEqual(self.m.oneshot([1]), '')
        self.assertFalse(self.m.wake(force=False))
        self.load.assert_not_called()
        self.clock.time.return_value = 4601.0
        self.assertEqual(self.m.oneshot([1]), 'answer')
        self.assertEqual((self.m.wake_at, self.m.retrain_sleep), (0, False))
        self.m.sleep(10)
        self.assertEqual(self.m.oneshot([1]), 'answer')
        self.assertEqual((self.m.wake_at, self.m.retrain_sleep), (0, False))

    def test_ensure_clears_lease_even_when_already_loaded(self):
        self.m.model = 'fake model'
        self.m.wake_at, self.m.retrain_sleep = 4600, True
        self.assertTrue(self.m.wake())
        self.assertEqual((self.m.wake_at, self.m.retrain_sleep), (0, False))
        self.load.assert_not_called()


class Ahead(unittest.TestCase):
    def test_finished_context_read_keeps_ahead_hit_but_changed_text_or_settings_do_not(self):
        complete = Mock(return_value={'text': ''})
        ns = ahead_load(complete, [0])
        req = dict(before='let me kn', context='same synthetic chat', app='Beeper',
                   context_fresh=False, max_tokens=8, chips=False)
        ns['look_ahead'](req, 'ow')
        settle()
        taken = dict(req, before='let me know', context_fresh=True, early=True, after='x', field=2)
        key = ns['ahead_key'](taken)
        for change in ({'context': 'another chat'}, {'max_tokens': 4}, {'chips': True}, {'fix': True}):
            self.assertNotEqual(key, ns['ahead_key']({**taken, **change}))
        self.assertTrue(ns['complete'](taken)['ahead'])
        complete.assert_called_once()  # only the speculative call
        self.assertTrue(ns['earlier'].call_args.kwargs['remember'])


class ContextReads(unittest.TestCase):
    def test_both_swift_read_paths_hold_busy_until_main_queue_publishes_context(self):
        # Source contract only: Swift execution is forbidden in this pass.
        source = (ROOT / 'app/Keys.swift').read_text()
        self.assertIn('var contextReads = 0', source)
        self.assertIn('var contextBusy: Bool { contextReads > 0 }', source)
        self.assertEqual(source.count('contextReads += 1'), 2)
        self.assertEqual(source.count('contextReads -= 1'), 2)
        for name in ('contextFor', 'warmField'):
            body = source.split(f'    func {name}(', 1)[1].split('\n    func ', 1)[0]
            ordered = ['contextReads += 1', 'contextQueue.async {', 'Keys.readContext(',
                       'DispatchQueue.main.async {', 'self.context = (el, t, Date())',
                       'self.contextReads -= 1']
            positions = [body.index(s) for s in ordered]
            self.assertEqual(positions, sorted(positions))
        self.assertIn('"context_fresh": !contextBusy && (context.map { CFEqual($0.el, s.el) } ?? false)', source)


class PhraseRebuild(unittest.TestCase):
    setUp = test_retrain.Lifecycle.setUp

    def test_compare_and_gate_see_old_phrases_before_publish(self):
        retrain = test_retrain.retrain
        phrases = self.root / 'data/phrases.jsonl'
        old = '{"src":"typed","text":"old synthetic vocabulary"}\n'
        newer = '{"src":"typed","text":"new post cutoff vocabulary"}\n'
        current = self.root / 'data/adapters'
        current.mkdir(); (current / 'adapters.safetensors').write_text('old')
        for switch, recording in ((True, 'new-recording'), (False, 'new-recording'), (False, None)):
            with self.subTest(switch=switch, recording=recording):
                phrases.write_text(old)
                events = []
                def step(script, *args, **kw):
                    if script == 'engine/memory.py':
                        self.assertNotIn('compare', events)
                        test_retrain.Path(args[args.index('--output') + 1]).write_text(old + newer)
                        events.append('stage')
                    elif script == 'bench/make_train.py':
                        # training reads the dated corpus (bench/corpus.py), rebuilt after the staged phrases
                        self.assertEqual(args, ('--corpus', str(self.root / 'data/corpus.jsonl')))
                        self.assertEqual((self.root / 'data/phrases-next.jsonl').read_text(), old + newer)
                        self.assertEqual(phrases.read_text(), old)
                        events.append('make_train')
                    elif script == 'bench/gate.py':
                        self.assertEqual(phrases.read_text(), old)
                        events.append('gate')
                    return 0, 'synthetic'
                def compare(*args):
                    self.assertEqual(phrases.read_text(), old)
                    events.append('compare')
                    return switch, recording
                def run(*args, **kw):
                    adapter = self.root / 'data/adapters-new/adapters.safetensors'
                    adapter.parent.mkdir(exist_ok=True); adapter.write_text('new')
                    return types.SimpleNamespace(returncode=0, stderr='')
                with patch.object(retrain, 'fresh_set', return_value=50), \
                     patch.object(retrain, 'step', side_effect=step), \
                     patch.object(retrain, '_compare', side_effect=compare), \
                     patch.object(retrain.subprocess, 'run', side_effect=run):
                    retrain.main()
                self.assertEqual(events, ['stage', 'make_train', 'compare'] + (['gate'] if switch else []))
                self.assertEqual(phrases.read_text(), old + newer if recording else old)


if __name__ == '__main__':
    unittest.main()

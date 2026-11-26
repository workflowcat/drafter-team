"""The retrain's rule (bench/retrain.py decide): the new layer only when it saves more letters over the apps by more
than the margin and no app's share of right first words falls too far."""
import ast, unittest
from pathlib import Path
from server_src import lift


def decide():
    return lift("decide", path=Path(__file__).resolve().parents[1] / "bench/retrain.py", MARGIN=0.5, RIGHT_DROP=2.0)["decide"]


class Decide(unittest.TestCase):
    def test_rule(self):
        d = decide()
        cur = {"beeper": {"saved": 12.0, "right": 53.0}, "claude": {"saved": 31.0, "right": 61.0}}
        self.assertEqual(d(cur, {"beeper": {"saved": 12.6, "right": 52.0}, "claude": {"saved": 31.2, "right": 61.5}}), (True, 0.8, []))
        self.assertFalse(d(cur, {"beeper": {"saved": 12.2, "right": 53.0}, "claude": {"saved": 31.2, "right": 61.0}})[0])    # within noise
        self.assertEqual(d(cur, {"beeper": {"saved": 14.0, "right": 50.0}, "claude": {"saved": 31.0, "right": 61.0}})[2], ["beeper"])
        self.assertFalse(d(cur, {})[0])



# Importing retrain is now inert: only main() runs the nightly job.
import importlib.util, json, subprocess, tempfile, types
from unittest.mock import Mock, patch
SOURCE = Path(__file__).resolve().parents[1] / 'bench/retrain.py'
spec = importlib.util.spec_from_file_location('retrain_tested', SOURCE)
retrain = importlib.util.module_from_spec(spec)
spec.loader.exec_module(retrain)


def synthetic_step(script, *args, **kw):
    if script == 'engine/memory.py':
        Path(args[args.index('--output') + 1]).write_text('{"src":"typed","text":"synthetic staged phrase"}\n')
    return 0, 'ok'


class Lifecycle(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        (self.root / 'data/review').mkdir(parents=True)
        self.stamp = self.root / 'data/review/last-retrain'
        self.stamp.write_text('123')
        self.items = [{'text': 'abc', 'app': 'Beeper'}, {'text': 'def', 'app': 'Claude'}]
        (self.root / 'data/replay-fresh.json').write_text(json.dumps(self.items))
        for name, value in [('ROOT', self.root), ('STAMP', self.stamp), ('force', True), ('engine_post', Mock(return_value={}))]:
            p = patch.object(retrain, name, value); p.start(); self.addCleanup(p.stop)

    def test_fresh_set_is_published_only_if_large_enough(self):
        target = self.root / 'data/replay-fresh.json'
        old = target.read_bytes()
        for count, code in [(2, 0), (50, 1), (50, 0)]:
            def step(*args, **kw):
                self.assertEqual(args[1], '--output')
                self.assertEqual(args[-1], '0')
                Path(args[2]).write_text(json.dumps([{'text': 'synthetic', 'src': 'beeper' if i % 2 else 'claude'} for i in range(count)]))
                return code, 'synthetic'
            with patch.object(retrain, 'step', side_effect=step):
                self.assertEqual(retrain.fresh_set([]), count if code == 0 else 0)
            if count < 50 or code: self.assertEqual(target.read_bytes(), old)
            else: self.assertEqual(len(json.loads(target.read_text())), count)

    def test_fresh_set_without_ai_app_lines_is_not_a_test(self):
        """Chat lines alone (60 chat lines, 0 AI-app lines) are not a fair test of the layers."""
        target = self.root / 'data/replay-fresh.json'
        old = target.read_bytes()
        def step(*args, **kw):
            Path(args[2]).write_text(json.dumps([{'text': 'synthetic', 'src': 'beeper'}] * 60))
            return 0, 'synthetic'
        report = []
        with patch.object(retrain, 'step', side_effect=step):
            self.assertEqual(retrain.fresh_set(report), 0)
        self.assertEqual(target.read_bytes(), old)
        self.assertIn('no claude lines', report[-1])

    def test_comparison_refuses_a_set_without_ai_app_lines(self):
        """A set of 60 chat lines and 0 AI-app lines: no recording, layer kept."""
        (self.root / 'data/replay-fresh.json').write_text(json.dumps([{'text': 'made up', 'src': 'beeper', 'app': 'Slack'}] * 60))
        report = []
        with patch.object(retrain, 'record', side_effect=AssertionError('recorded')):
            self.assertEqual(retrain.compare('old', 'new', report), (False, None))
        self.assertIn('no claude lines', report[-1])

    def test_missing_kinds_by_src_or_app(self):
        self.assertEqual(retrain.missing_kinds([{'src': 'beeper'}, {'src': 'claude'}]), [])
        self.assertEqual(retrain.missing_kinds([{'app': 'Beeper'}, {'app': 'ChatGPT'}]), [])
        self.assertEqual(retrain.missing_kinds([{'src': 'claude', 'app': 'Claude'}]), [])
        self.assertEqual(retrain.missing_kinds([{'src': 'beeper', 'app': 'Slack'}]), ['claude'])
        self.assertEqual(retrain.missing_kinds([]), ['claude'])

    def test_comparison_rejects_equal_truncation_missing_positions_and_wrong_set(self):
        rows = {(0, 2): {}, (1, 2): {}}
        summary = Mock(return_value={'Beeper': {'saved': 10, 'right': 80}})
        for covered, positions in [(self.items[:1], {(0, 2): {}}), (self.items, {(1, 2): {}}),
                                   ([{'text': 'xyz'}, self.items[1]], rows), (self.items, rows)]:
            score = types.SimpleNamespace(load=Mock(return_value=(covered, positions)))
            with patch.dict('sys.modules', gate=types.SimpleNamespace(summary=summary), typescore=score), \
                 patch.object(retrain, 'record', side_effect=[('cur', 'ok'), ('new', 'ok')]):
                result = retrain.compare('old', 'new', [])
            self.assertEqual(result[1], 'new' if covered == self.items and positions == rows else None)

    def run_night(self, training, comparison=(False, 'new-recording')):
        adapter = self.root / 'data/adapters-new/adapters.safetensors'
        def run(*args, **kw):
            if isinstance(training, Exception): raise training
            adapter.parent.mkdir(exist_ok=True)
            adapter.write_text('fake')
            return subprocess.CompletedProcess([], training, stderr='failed')
        with patch.object(retrain, 'fresh_set', return_value=50), \
             patch.object(retrain, 'step', side_effect=synthetic_step), \
             patch.object(retrain.subprocess, 'run', side_effect=run), \
             patch.object(retrain, '_compare', return_value=comparison) as compare:
            retrain.main()
        self.assertEqual([c.args[0] for c in retrain.engine_post.call_args_list][-2:], ['sleep', 'wake'])
        return compare

    def test_timeout_and_failed_training_resume_and_retry(self):
        for failure in [subprocess.TimeoutExpired('train', 3600), OSError('synthetic failure'), 1]:
            with self.subTest(failure=failure):
                self.run_night(failure).assert_not_called()
                self.assertEqual(self.stamp.read_text(), '123')

    def test_incomplete_comparison_keeps_weekly_stamp_and_reports_cut_short(self):
        self.run_night(0, (False, None))
        self.assertEqual(self.stamp.read_text(), '123')
        self.assertTrue(self.stamp.with_name('last-retrain-attempt').exists())
        report = next((self.root / 'data/review').glob('retrain-*.md')).read_text()
        self.assertIn('test cut short', report)
        self.run_night(0)
        self.assertNotEqual(self.stamp.read_text(), '123')

    def test_interrupt_still_resumes(self):
        with patch.object(retrain, 'fresh_set', return_value=50), patch.object(retrain, 'step', side_effect=synthetic_step), \
             patch.object(retrain.subprocess, 'run', side_effect=KeyboardInterrupt):
            with self.assertRaises(KeyboardInterrupt): retrain.main()
        self.assertEqual(retrain.engine_post.call_args.args, ('wake',))
        self.assertEqual(self.stamp.read_text(), '123')

    def test_small_fresh_draw_writes_report_with_real_count(self):
        original = (self.root / 'data/replay-fresh.json').read_bytes()
        def draw(script, *args, **kw):
            self.assertEqual(script, 'bench/make_fresh.py')
            self.assertEqual(args[-1], '0')
            Path(args[1]).write_text(json.dumps([{'text': 'small synthetic draw', 'src': 'beeper' if i % 2 else 'claude'} for i in range(17)]))
            return 0, '17 items'
        with patch.object(retrain, 'step', side_effect=draw):
            retrain.main()
        retrain.engine_post.assert_not_called()
        self.assertEqual((self.root / 'data/replay-fresh.json').read_bytes(), original)
        report = next((self.root / 'data/review').glob('retrain-*.md')).read_text()
        self.assertIn('17 fresh lines', report)
        self.assertEqual(self.stamp.read_text(), '123')

    def test_missing_stamp_is_long_ago_for_every_bench_reader(self):
        self.stamp.unlink()
        from retrain_state import last_retrain
        self.assertEqual(last_retrain(self.root), 0)
        self.run_night(0)
        self.assertGreater(last_retrain(self.root), 0)
        # No top-level bench execution (which would read private files/load models).
        for name in ('make_fresh', 'typebench', 'gate', 'ngram'):
            tree = ast.parse(SOURCE.with_name(name + '.py').read_text())
            calls = [n for n in ast.walk(tree) if isinstance(n, ast.Call) and
                     isinstance(n.func, ast.Name) and n.func.id == 'last_retrain']
            self.assertTrue(calls, name)
            self.assertNotIn('data/review/last-retrain', [n.value for n in ast.walk(tree) if isinstance(n, ast.Constant)])

    def test_comparison_sleeps_before_recording_and_wakes_even_on_error(self):
        events = []
        def post(route, **kw): events.append(route); return {}
        def record(*args):
            events.append('record')
            raise RuntimeError('test cut short')
        with patch.object(retrain, 'engine_post', side_effect=post), \
             patch.object(retrain, 'record', side_effect=record), \
             patch.dict('sys.modules', gate=types.SimpleNamespace(), typescore=types.SimpleNamespace()):
            report = []
            self.assertEqual(retrain.compare('old', 'new', report), (False, None))
        self.assertEqual(events, ['sleep', 'record', 'wake'])

    def test_sleep_spans_both_recordings_and_scoring(self):
        events = []
        rows = {(0, 2): {}, (1, 2): {}}
        def record(adapter, label): events.append(label); return label, 'ok'
        def summary(path): events.append('score'); return {'Beeper': {'saved': 10, 'right': 80}}
        def post(route, **kw): events.append(route); return {}
        with patch.object(retrain, 'engine_post', side_effect=post), \
             patch.object(retrain, 'record', side_effect=record), \
             patch.dict('sys.modules', gate=types.SimpleNamespace(summary=summary),
                        typescore=types.SimpleNamespace(load=lambda _: (self.items, rows))):
            self.assertEqual(retrain.compare('old', 'new', []), (False, 'retrain-new'))
        self.assertEqual(events, ['sleep', 'retrain-cur', 'retrain-new', 'score', 'score', 'wake'])

    def test_cut_short_training_is_not_due_the_next_night(self):
        self.run_night(0, (False, None))
        with patch.object(retrain, 'force', False), patch.object(retrain, 'on_power') as power:
            with self.assertRaises(SystemExit) as result: retrain.main()
        self.assertEqual(result.exception.code, 0)
        power.assert_not_called()

    def test_sleep_lease_renews_and_interrupt_still_wakes(self):
        stopped = Mock()
        stopped.wait.side_effect = [False, True]
        worker = Mock()
        worker.start.side_effect = lambda: holder['target']()
        holder = {}
        def thread(**kw): holder.update(kw); return worker
        with patch.object(retrain.threading, 'Event', return_value=stopped), \
             patch.object(retrain.threading, 'Thread', side_effect=thread):
            with self.assertRaises(KeyboardInterrupt):
                with retrain.sleeping_engine(): raise KeyboardInterrupt
        self.assertEqual([c.args[0] for c in retrain.engine_post.call_args_list], ['sleep', 'sleep', 'wake'])
        stopped.set.assert_called_once(); worker.join.assert_called_once()

    def test_make_fresh_stages_and_preserves_small_draws_itself(self):
        ns = lift('publish', path=SOURCE.with_name('make_fresh.py'), tempfile=tempfile, Path=Path, json=json)
        target = self.root / 'data/replay-fresh.json'
        old = target.read_bytes()
        self.assertFalse(ns['publish']([{'text': 'short draw'}], target, 50))
        self.assertEqual(target.read_bytes(), old)
        full = [{'text': 'enough synthetic lines'}] * 50
        self.assertTrue(ns['publish'](full, target, 50))
        self.assertEqual(json.loads(target.read_text()), full)

    def test_failed_recording_does_not_reuse_an_old_file(self):
        with patch.dict('sys.modules', gate=types.SimpleNamespace(summary=Mock()), typescore=types.SimpleNamespace(load=Mock())),              patch.object(retrain, 'record', side_effect=RuntimeError('bench failed')):
            report = []
            self.assertEqual(retrain.compare('old', 'new', report), (False, None))
            self.assertIn('bench failed', report[-1])



class GateSaveKeepsThreshold(unittest.TestCase):
    """Argon 25: bench/gate.py --save (run by the retrain when a new layer wins) wrote th 0.4 over the one in use."""
    def saved_th(self):
        import ast as _ast
        source = Path(__file__).resolve().parents[1] / "bench/gate.py"
        fn = [n for n in _ast.parse(source.read_text()).body if isinstance(n, _ast.FunctionDef) and n.name == "saved_th"]
        ns = {"json": json, "Path": Path}
        exec(compile(_ast.Module(body=fn, type_ignores=[]), str(source), "exec"), ns)
        return ns["saved_th"]

    def test_keeps_and_defaults(self):
        f = self.saved_th()
        with tempfile.TemporaryDirectory() as d:
            p = Path(d) / "gate.json"
            self.assertEqual(f(p), {"ai": 0.4, "chat": 0.4})
            p.write_text(json.dumps({"th": {"ai": 0.45, "chat": 0.5}}))
            self.assertEqual(f(p), {"ai": 0.45, "chat": 0.5})
            p.write_text(json.dumps({"th": {"ai": "x"}}))
            self.assertEqual(f(p), {"ai": 0.4, "chat": 0.4})

    def test_save_uses_it(self):
        src = (Path(__file__).resolve().parents[1] / "bench/gate.py").read_text()
        self.assertNotIn('"th": {"ai": 0.4, "chat": 0.4}', src)
        self.assertIn('th = saved_th(ROOT / "data/gate.json")', src)


if __name__ == "__main__":
    unittest.main()

"""Exercise the real HTTP handler without loading models, personal records or providers."""
import io
from email.message import Message
import json
from pathlib import Path
import types
import threading
import time
import unittest
from http.server import BaseHTTPRequestHandler
from unittest.mock import Mock, patch
from server_src import lift

TOKEN = 'synthetic-token-for-tests'


class ServerRoutes(unittest.TestCase):
    def setUp(self):
        self.ask = Mock(return_value='synthetic answer')
        self.model = types.SimpleNamespace(prefill=Mock(return_value=3), warm=Mock(), sleep=Mock(return_value=True),
                                           wake=Mock(return_value=True), memory_gb=Mock(return_value=(0.1, 2.0)), asleep=False)
        self.claude = types.SimpleNamespace(reap=Mock(return_value=2))
        self.timer = Mock()
        self.builder = types.SimpleNamespace(ids=Mock(return_value=([1, 2, 3], '')), refresh=Mock(), head_ids=[],
                                             ids_stable=Mock(return_value=([1, 2, 3], '', 2)))
        self.actions = types.SimpleNamespace(queue_app=Mock(return_value={'slots': []}))
        self.notes = types.SimpleNamespace(make=Mock(side_effect=lambda text, ask, *args, **kw: {'title': ask(text)}))
        self.runner = Mock(side_effect=lambda fn, **kwargs: fn(lambda: False))
        self.order = []
        self.complete = Mock(side_effect=lambda req, **kw: self.order.append("complete") or {"text": ""})
        namespace = dict(BaseHTTPRequestHandler=BaseHTTPRequestHandler, json=json, time=time, LOCAL_HOSTS={'127.0.0.1'},
                         run=self.runner, ask=self.ask, model=self.model, builder=self.builder,
                         request_seq=lambda: self.order.append("cancel") or 7,
                         complete=self.complete,
                         actions=self.actions, notes=self.notes, claude_on=Mock(return_value=False), TYPED=[0], promise_typed=Mock(), claude_type=self.claude,
                         threading=types.SimpleNamespace(Timer=self.timer),
                         parts=lambda r: (r.get('before') or '', r.get('app', ''), r.get('title', ''), r.get('context') or '', ' · '),
                         dictionary=types.SimpleNamespace(add=Mock(return_value={'text': 'Synthetic'})),
                         fast_drop=lambda cancelled=None: {'fast': False}, WANT=[''], ahead_key=lambda req, pack=None: req.get('before', ''),
                         keep_running=Mock(), extras=lambda r: ('', ''))
        lift('H', into=namespace)
        self.ns = namespace
        self.handler = namespace['H']
        self.handler.token = TOKEN

    def post(self, route, body, **headers):
        # Call the real handler with in-memory streams; no sockets or server startup.
        h = self.handler.__new__(self.handler)
        h.path, h.client_address = route, ('127.0.0.1', 12345)
        payload = json.dumps(body).encode()
        h.headers = Message()
        for key, value in {'Host': '127.0.0.1', 'Content-Type': 'application/json',
                           'Content-Length': str(len(payload)), 'X-Drafter-Token': TOKEN, **headers}.items():
            if value is not None: h.headers[key] = value
        h.rfile = io.BytesIO(payload)
        h.send = Mock()
        h.do_POST()
        args = h.send.call_args.args
        return (args[1] if len(args) > 1 else 200), args[0]

    def test_typed_export_runs_outside_gate_lock_and_is_reserved_once(self):
        import io
        lock = threading.Lock()
        def export(path):
            self.assertTrue(lock.acquire(blocking=False))
            lock.release()
        finisher = types.SimpleNamespace(add=Mock(), export=Mock(side_effect=export))
        self.ns.update(DATA=Path('/synthetic'), time=time, GATE_LOCK=lock, GATE={},
                       phrases=types.SimpleNamespace(add=Mock()), finisher=finisher,
                       edits=types.SimpleNamespace(sent=Mock()), open=Mock(side_effect=lambda *a: io.StringIO()))
        for _ in range(2):
            self.assertEqual(self.post('/typed', {'text': 'three synthetic words'}), (200, {'ok': True}))
        finisher.export.assert_called_once()

    def test_prefill_uses_model_worker(self):
        self.assertEqual(self.post('/prefill', {'before': 'Synthetic text'}), (200, {'fed': 3}))
        self.model.prefill.assert_called_once_with([1, 2, 3], screen=' · ', stable=2)
        self.assertFalse(self.runner.call_args.kwargs['newest'])

    def test_idle_sleep_has_no_wake_timer(self):
        # the app's idle sleep (textIdleMin): only its /wake ends it, so no timer and no 1 h cap
        status, body = self.post('/sleep', {'idle': True})
        self.assertEqual(status, 200)
        self.model.sleep.assert_called_once_with(86400.0, retrain=False)
        self.timer.assert_not_called()

    def test_sleep_frees_model_and_helpers_then_wake(self):
        status, body = self.post('/sleep', {'secs': 5})
        self.assertEqual((status, body['slept'], body['claude_stopped']), (200, True, 2))
        self.model.sleep.assert_called_once_with(10.0, retrain=False)          # at least 10 s
        self.claude.reap.assert_called_once_with(0)
        self.assertEqual(self.timer.call_args.args[0], 11.0)    # wakes by itself after the sleep
        self.assertEqual(self.post('/wake', {})[1]['woke'], True)
        self.model.wake.assert_called_once_with()

    def test_note_uses_model_worker_and_callable_ask(self):
        self.assertEqual(self.post('/note', {'text': 'Synthetic note', 'dry': True}), (200, {'title': 'synthetic answer'}))
        self.ask.assert_called_once_with('Synthetic note', 60)

    def test_note_passes_calendar_event_through(self):
        event = {'title': 'Weekly sync', 'people': ['Mila']}
        self.post('/note', {'text': 'Synthetic note', 'dry': True, 'call': True, 'event': event})
        self.assertEqual(self.notes.make.call_args.args[5], event)
        self.post('/note', {'text': 'Synthetic note', 'dry': True, 'event': 'not a dict'})
        self.assertIsNone(self.notes.make.call_args.args[5])

    def test_note_call_summary_follows_call_notes(self):
        self.post('/note', {'text': 'Synthetic note', 'dry': True, 'call': True})
        self.assertIs(self.notes.make.call_args.kwargs['cloud'], False)
        self.ns['claude_on'].assert_called_once_with('call_notes')
        self.ns['claude_on'].return_value = True
        self.post('/note', {'text': 'Synthetic note', 'dry': True, 'call': True})
        self.assertIs(self.notes.make.call_args.kwargs['cloud'], True)
        self.post('/note', {'text': 'Synthetic note', 'dry': True})          # a long note: no summary, no ask
        self.assertIs(self.notes.make.call_args.kwargs['cloud'], False)

    def test_dictionary_refresh_uses_model_worker(self):
        self.assertEqual(self.post('/words', {'text': 'Synthetic'})[0], 200)
        self.builder.refresh.assert_called_once()
        self.model.warm.assert_called_once()

    def test_command_callback_is_model_ask_not_notes_module(self):
        command = types.SimpleNamespace(plan=lambda text, ask: {'answer': ask(text)})
        with patch.dict('sys.modules', command=command):
            self.assertEqual(self.post('/command', {'text': 'Synthetic command'}), (200, {'answer': 'synthetic answer'}))
        self.ask.assert_called_once_with('Synthetic command', 90)

    def test_notes_question_and_free_slots_remain_separate(self):
        with patch.dict('sys.modules', ask=types.SimpleNamespace(answer=lambda text: {'answer': text})):
            self.assertEqual(self.post('/ask', {'text': 'Synthetic question'}), (200, {'answer': 'Synthetic question'}))
        self.assertEqual(self.post('/free', {'minutes': 30}), (200, {'slots': []}))
        self.actions.queue_app.assert_called_once_with({'kind': 'eventkit.free', 'minutes': 30})

    def test_browser_requests_still_blocked(self):
        self.assertEqual(self.post('/prefill', {}, Origin='https://example.com')[0], 403)
        self.runner.assert_not_called()

    def test_post_without_or_with_wrong_token_is_refused(self):
        self.assertEqual(self.post('/prefill', {}, **{'X-Drafter-Token': None}), (403, {'error': 'forbidden'}))
        self.assertEqual(self.post('/prefill', {}, **{'X-Drafter-Token': 'wrong'}), (403, {'error': 'forbidden'}))
        self.runner.assert_not_called()

    def test_complete_cancels_then_completes(self):
        self.assertEqual(self.post('/complete', {'before': 'test'}), (200, {'text': ''}))
        self.assertEqual(self.order, ['cancel', 'complete'])   # no Claude early lane since 2026-11-17
        self.assertEqual(self.complete.call_args.kwargs, {'seq': 7})


if __name__ == '__main__':
    unittest.main()

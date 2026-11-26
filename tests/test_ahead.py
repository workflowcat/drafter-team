"""Look-ahead (engine/server.py): the suggestion for when the user takes the current one is worked out behind newer keys,
kept by the exact request, and dropped when the user typed something else meanwhile."""
import json, queue, re, threading, time, types, unittest
import sys
from unittest.mock import Mock
from collections import OrderedDict
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "engine"))

import words as words_mod
import know
from server_src import lift

NAMES = {"ahead_key", "ahead_count", "look_ahead", "complete", "normal_space", "request_seq", "stale", "run", "worker"}


def load(fake_complete, latest):
    return lift(*NAMES, words_mod=words_mod, knowledge=know.Pack(), earlier=Mock(return_value=""), json=json, time=time, threading=threading, OrderedDict=OrderedDict, latest=latest, _complete=fake_complete,
              LATEST_LOCK=threading.Lock(), jobs=queue.Queue(), RUNNING=[None], KEPT=set(), BRANCHES=0, re=__import__("re"), selector=lambda: None, word_first=lambda *a: "", JOB_ORDER=iter(range(1 << 30)),
              AHEAD=OrderedDict(), AHEAD_LOCK=threading.Lock(), AHEAD_TTL=30.0, AHEAD_STATS={"made": 0, "hit": 0}, AHEAD_KIND={},
              AHEAD_DAYS_FILE=Path(__import__("tempfile").mkdtemp()) / "ahead-days.json", _ahead_days=None, _ahead_saved=[0.0],
              model=types.SimpleNamespace(asleep=False, loading=False),
              # long round: futures and the in-flight join (engine/server.py); stand-ins keep the old behaviour
              note_gap=lambda: None, futures_k=lambda cap=None: 0, INFLIGHT={}, WANT=[""], FUT_INDEX=OrderedDict(), COSTS=[], GAPS=[])


def settle():
    for t in [t for t in threading.enumerate() if t.name == "ahead"]: t.join(2)


class Ahead(unittest.TestCase):
    def test_taking_the_text_finds_the_next_one_ready(self):
        calls = []
        def fake(req, low=False, seq=None, pack=None, **kw):
            calls.append((req["before"], low))
            return {"text": " next" if req["before"].endswith("know") else "", "src": "gate", "ms": 60}
        ns = load(fake, [5])
        req = {"before": "let me kn", "app": "Claude", "context": "", "early": True, "field": 3}
        first = {"text": "ow", "src": "gate", "ms": 60}
        ns["_complete"] = lambda r, low=False, seq=None, pack=None, **kw: first if r["before"] == "let me kn" else fake(r, low)
        self.assertEqual(ns["complete"](req)["text"], "ow")
        settle()
        self.assertEqual(calls, [("let me know", True)])                   # worked out at low priority
        hit = ns["complete"](dict(req, before="let me know", early=False, after="x", field=3))
        self.assertTrue(hit["ahead"]); self.assertEqual((hit["text"], hit["ms"]), (" next", 0))
        settle()
        self.assertEqual(calls[-1], ("let me know next", True))              # and the one after it
        self.assertEqual(ns["AHEAD_STATS"], {"made": 2, "hit": 1})
        # the day counts (accounting only): two started and kept, the first one taken, both "next"
        day = ns["_ahead_days"][time.strftime("%Y-%m-%d")]
        self.assertEqual(day, {"asked": 2, "started": 2, "made": 2, "next_made": 2, "used": 1, "next_used": 1})
        self.assertTrue(ns["AHEAD_DAYS_FILE"].exists())   # first count saves at once, then at most once a minute

    def test_a_newer_key_meanwhile_still_keeps_the_finished_answer(self):
        # long round (2026-11-14): an answer that ends a moment after the user's next key is the exact answer for its text,
        # so it is kept (before, it was thrown away: one cause of the low live hit rate); the futures after it stop
        latest = [5]
        def fake(req, low=False, seq=None, pack=None, **kw):
            if low: latest[0] += 1                                            # the user typed while it ran
            return {"text": "ow" if not low else " next", "src": "gate"}
        ns = load(fake, latest)
        ns["complete"]({"before": "let me kn", "app": "Claude"})
        settle()
        self.assertEqual(len(ns["AHEAD"]), 1)

    def test_actions_fixes_and_empty_answers_start_nothing(self):
        for res in ({"text": "", "src": "gate"}, {"text": "x", "action": {"id": "a"}}, {"text": "word", "replace": "wrod"}):
            ns = load(lambda req, low=False, seq=None, pack=None, res=res, **kw: res, [1])
            ns["complete"]({"before": "abc", "app": "Claude"})
            settle()
            self.assertEqual(ns["AHEAD_STATS"]["made"], 0, res)

    def test_a_different_screen_is_a_different_request(self):
        ns = load(lambda req, low=False, seq=None, pack=None, **kw: {"text": "x"}, [1])
        a = ns["ahead_key"]({"before": "hi", "app": "Telegram", "context": "one"})
        self.assertNotEqual(a, ns["ahead_key"]({"before": "hi", "app": "Telegram", "context": "two"}))
        self.assertEqual(a, ns["ahead_key"]({"before": "hi", "app": "Telegram", "context": "one", "after": "z", "early": True}))
        self.assertEqual(a, ns["ahead_key"]({"before": "hi", "app": "Telegram", "context": "one", "gap_ms": 84, "stream": True}))
        self.assertEqual(
            ns["ahead_key"]({"before": "hi", "app": "Telegram", "context": "one", "combo": True, "gap_ms": 84, "stream": True}),
            ns["ahead_key"]({"before": "hi", "app": "Telegram", "context": "one", "combo": True, "gap_ms": 210}),
        )

    def test_gap_ms_and_stream_still_hit_look_ahead_and_futures(self):
        seen = []
        def fake(req, low=False, seq=None, pack=None, **kw):
            seen.append((req["before"], req.get("gap_ms"), low))
            if req["before"] == "let me kn":
                return {"text": "ow", "src": "gate", "ms": 40, "next": "ow", "alts": ["e"]}
            if req["before"] == "let me know":
                return {"text": " soon", "src": "gate", "ms": 40}
            if req["before"] == "let me kne":
                return {"text": "w that", "src": "gate", "ms": 40}
            return {"text": "", "src": "gate", "ms": 40}
        ns = load(fake, [5])
        ns["futures_k"] = lambda cap=None: 1
        ns["branch_letters"] = lambda before, raw, ghost, n=2, alts=(): list(alts)[:n]
        lift("futures", into=ns)
        req = {"before": "let me kn", "app": "Claude", "context": "", "combo": True, "gap_ms": 82, "stream": True}
        self.assertEqual(ns["complete"](req)["text"], "ow")
        settle()
        # every look-ahead drops gap_ms (big model): ahead_key ignores gap_ms, so a fast-model answer must not reach a slow key
        spec = [(b, g) for b, g, low in seen if low]
        self.assertEqual(spec, [("let me know", None), ("let me kne", None)])
        # /futures is posted without stream and possibly a different gap_ms, yet finds the prepared branch
        fut = ns["futures"]({"before": "let me kn", "app": "Claude", "context": "", "combo": True, "gap_ms": 145})
        self.assertEqual(fut["futures"], [{"letter": "e", "text": "w that", "unsure": ""}])
        # Next keystroke with a different gap_ms hits AHEAD at 0 ms
        hit = ns["complete"]({"before": "let me kne", "app": "Claude", "context": "", "combo": True, "gap_ms": 97, "stream": True})
        self.assertTrue(hit["ahead"])
        self.assertEqual((hit["text"], hit["ms"]), ("w that", 0))



class Cancellation(unittest.TestCase):
    def test_every_real_early_return_advances_generation(self):
        for branch in ('snippet', 'memory', 'fix', 'words', 'asleep', 'ahead'):
            with self.subTest(branch=branch):
                ns = load(None, [0])
                ns.update(re=re, FMT='raw', AI_APPS=(), short=lambda req, text: False,
                          parts=lambda r, **kw: ('test', '', '', '', ''), builder_for=lambda f: None,
                          snippets=types.SimpleNamespace(offer=lambda b: {'id': 's'} if branch == 'snippet' else None),
                          phrases=types.SimpleNamespace(suggest=lambda b: ('rest', 2) if branch == 'memory' else ('', 0)),
                          actions=types.SimpleNamespace(detect=lambda b: None), clean=lambda b, t: t,
                          gate=lambda: {'words_first': branch == 'words'},
                          finisher=types.SimpleNamespace(lock=threading.Lock(), own_folded={}, own_prefix={},
                                                        fix=lambda b: {'new': 'text', 'old': 'test', 'kind': 'typo'} if branch == 'fix' else None,
                                                        finish=lambda *a: 'rest' if branch == 'words' else ''),
                          model=types.SimpleNamespace(asleep=branch == 'asleep', loading=False))
                lift('_complete', into=ns)
                req = {'before': 'test', 'ahead': branch == 'ahead', 'fix': True}
                if branch == 'ahead': ns['AHEAD'][ns['ahead_key'](req)] = (time.time(), {'text': ''})
                # A token callback captured at startup must become stale even when no job is queued.
                self.assertFalse(ns['stale'](0))
                ns['complete'](req)
                self.assertTrue(ns['stale'](0))
                self.assertEqual(ns['latest'][0], 1)

    def test_running_zero_generation_job_sees_new_completion(self):
        ns = load(lambda r, **kw: {'text': ''}, [0])
        seen = []
        def job(cancelled):
            seen.append(cancelled())
            ns['complete']({'ahead': False})
            seen.append(cancelled())
            return {'text': ''}
        box = {'done': threading.Event()}
        ns['jobs'] = Mock()
        ns['jobs'].get.side_effect = [(0, 0, 0, job, box), StopIteration]
        with self.assertRaises(StopIteration): ns['worker']()
        self.assertEqual(seen, [False, True])
        self.assertTrue(box['done'].is_set())

    def test_already_queued_zero_job_is_skipped_but_uncancellable_job_runs(self):
        ns = load(None, [1])
        old, durable = Mock(), Mock(return_value={'text': 'done'})
        boxes = [{'done': threading.Event()} for _ in range(2)]
        ns['jobs'] = Mock()
        ns['jobs'].get.side_effect = [(0, 0, 0, old, boxes[0]), (0, 1, None, durable, boxes[1]), StopIteration]
        with self.assertRaises(StopIteration): ns['worker']()
        old.assert_not_called(); durable.assert_called_once()
        self.assertTrue(boxes[0]['out']['stale'])

    def test_delayed_ahead_thread_cannot_adopt_newer_generation(self):
        ns = load(Mock(return_value={'text': ''}), [0])
        pending = []
        ns['threading'] = types.SimpleNamespace(Thread=lambda **kw: types.SimpleNamespace(start=lambda: pending.append(kw['target'])))
        ns['look_ahead']({'before': 'a'}, 'b')
        ns['request_seq']()
        pending.pop()()
        ns['_complete'].assert_not_called()
        self.assertEqual(ns['AHEAD_STATS']['made'], 0)

    def test_request_keeps_its_generation_when_queued_late(self):
        ns = load(None, [0])
        old = ns['request_seq']()
        ns['request_seq']()
        ns['run'](lambda c: {}, seq=old, timeout=0)
        _, _, seq, _, _ = ns['jobs'].get_nowait()
        self.assertEqual(seq, old)
        self.assertTrue(ns['stale'](seq))

    def test_typing_goes_before_waiting_look_ahead_work(self):
        ns = load(None, [0])
        ns['jobs'] = queue.PriorityQueue()
        ns['run'](lambda c: {}, low=True, seq=0, timeout=0)
        ns['run'](lambda c: {}, seq=0, timeout=0)
        self.assertEqual([ns['jobs'].get_nowait()[0] for _ in range(2)], [0, 1])

    def test_nbsp_and_plain_space_share_key_and_prompt(self):
        ns = load(None, [0])
        a = {'before': 'hello ', 'context': 'one two'}
        b = {'before': 'hello\u00a0', 'context': 'one\u00a0two'}
        self.assertEqual(ns['ahead_key'](a), ns['ahead_key'](b))
        lift('parts', into=ns, window=lambda k, t, s, **kw: t, BEFORE_CHARS=800, CTX_CHARS=1000)
        self.assertEqual(ns['parts'](a), ns['parts'](b))


if __name__ == "__main__":
    unittest.main()

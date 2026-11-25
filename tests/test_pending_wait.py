"""/pending?wait=N: an idle app holds one request until a job comes, instead of asking every second.
.venv/bin/python -B tests/test_pending_wait.py"""
import sys, threading, time, unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "engine"))
import actions  # noqa: E402


class PendingWait(unittest.TestCase):
    def setUp(self):
        actions.PENDING.clear()

    def test_no_wait_answers_at_once(self):
        t = time.time()
        self.assertEqual(actions.take_pending(), [])
        self.assertLess(time.time() - t, 0.05)

    def test_wait_times_out_empty(self):
        t = time.time()
        self.assertEqual(actions.take_pending(0.3), [])
        self.assertGreaterEqual(time.time() - t, 0.28)

    def test_job_wakes_the_waiting_request(self):
        got = {}
        th = threading.Thread(target=lambda: got.update(jobs=actions.take_pending(5), at=time.time()))
        th.start(); time.sleep(0.2)
        t = time.time()
        # queue_app is what Aleph's free-slots ask goes through; nobody reports back, so it times out after 0.5 s
        r = actions.queue_app({"kind": "eventkit.free"}, wait=0.5)
        th.join(2)
        self.assertEqual([j["run"]["kind"] for j in got["jobs"]], ["eventkit.free"])
        self.assertLess(got["at"] - t, 0.1)   # handed over at once, not after the 5 s wait
        self.assertIn("error", r)

    def test_job_already_waiting_is_taken_without_waiting(self):
        threading.Thread(target=lambda: actions.queue_app({"kind": "eventkit.free"}, wait=0.3)).start()
        time.sleep(0.05)
        t = time.time()
        self.assertEqual(len(actions.take_pending(5)), 1)
        self.assertLess(time.time() - t, 0.05)


if __name__ == "__main__":
    unittest.main()

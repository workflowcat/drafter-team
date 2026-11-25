"""Background jobs (bench/jobs.py): the queue, waiting while the server is away, clean-up on the server in a finally,
what comes back, and what the nightly queues. A fake runner stands in for ssh/rsync; made-up audio and lines only,
in a temporary data folder (DRAFTER_DATA).

    .venv/bin/python -B tests/test_jobs.py
"""
import json, os, struct, sys, tempfile, time, unittest, wave
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "bench"))


def silent_wav(p, secs):
    with wave.open(str(p), "wb") as w:
        w.setnchannels(1); w.setsampwidth(2); w.setframerate(16000); w.writeframes(b"\0\0" * int(secs * 16000))


class FakeServer:
    """Records every argv; 'run' writes the kind's result files into the back folder when 'back' is asked for."""
    def __init__(self, down=False, fail_at=None, results=None):
        self.calls, self.down, self.fail_at, self.results = [], down, fail_at, results or {}

    def __call__(self, argv, timeout):
        self.calls.append(argv)
        joined = " ".join(argv)
        if self.down and argv[0] == "ssh": raise RuntimeError("ssh: connect timed out")
        if self.fail_at and self.fail_at in joined and "docker rm" not in joined: raise RuntimeError(f"{self.fail_at} failed")
        if argv[0] == "rsync" and argv[-1].endswith("/back/"):
            for name, body in self.results.items():
                p = Path(argv[-1]) / name
                p.write_bytes(body) if isinstance(body, bytes) else p.write_text(body)

    def cleaned(self):
        return any("rm -rf drafter-jobs/job-" in " ".join(a) for a in self.calls)


class JobsTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.data = Path(self.tmp.name)
        os.environ["DRAFTER_DATA"] = str(self.data)
        import jobs; self.J = jobs

    def tearDown(self):
        os.environ.pop("DRAFTER_DATA", None); self.tmp.cleanup()

    def call(self, name="c1", secs=200, careful=False):
        d = self.data / "calls" / name; d.mkdir(parents=True)
        silent_wav(d / "me.wav", secs); silent_wav(d / "them.wav", secs)
        (d / "meta.json").write_text(json.dumps({"call": True, "started": 1.7e9, "event": {"people": ["Made Up"]}}))
        (d / "transcript.txt").write_text("Я: made-up words for a test")
        if careful: (d / "careful.json").write_text("{}")
        return d

    def careful_results(self):
        meta = {"kind": "careful", "model": "large-v3", "min_per_audio_min": 0.4}
        return {"me.json": json.dumps([{"start": 0, "end": 1, "text": "made-up"}]), "them.json": "[]", "meta.json": json.dumps(meta)}

    def test_add_once(self):
        d = self.call()
        a = self.J.add("careful", {"dir": str(d)}); b = self.J.add("careful", {"dir": str(d)})
        self.assertEqual(a["id"], b["id"])
        self.assertEqual(len(list((self.data / "jobs/queue").glob("*.json"))), 1)

    def test_server_away_waits_and_backs_off(self):
        self.J.add("careful", {"dir": str(self.call())})
        srv = FakeServer(down=True)
        self.J.run_due(srv, say=lambda *_: None)
        j = json.loads(next((self.data / "jobs/queue").glob("*.json")).read_text())
        self.assertEqual(j["tries"], 1)
        self.assertGreater(j["next_at"], time.time() + 800)
        self.assertEqual(len(srv.calls), 1, "only the reachability check ran")
        self.assertEqual(self.J.due(), [], "not due again before its time")
        self.assertEqual([self.J.backoff(n) for n in (1, 2, 3, 10)], [900, 1800, 3600, 6 * 3600])

    def test_gives_up_after_max_tries(self):
        job = self.J.add("index")
        job["tries"] = self.J.MAX_TRIES - 1; self.J.save(job)
        self.J.retry(job, "still away", lambda *_: None)
        self.assertEqual(list((self.data / "jobs/queue").glob("*.json")), [])
        self.assertEqual(len(list((self.data / "jobs/failed").glob("*.json"))), 1)

    def test_careful_round_trip_and_cleanup(self):
        d = self.call()
        self.J.add("careful", {"dir": str(d)})
        srv = FakeServer(results=self.careful_results())
        res = self.J.run_due(srv, say=lambda *_: None)
        self.assertEqual(res[0]["model"], "large-v3")
        c = json.loads((d / "careful.json").read_text())
        self.assertEqual(c["me"][0]["text"], "made-up"); self.assertEqual(c["them"], [])
        self.assertTrue(srv.cleaned())
        run = [a for a in srv.calls if "docker run" in " ".join(a)][0][-1]
        for cap in ("--cpus 10", "--memory 16g", "nice -n 19", ":/work/in:ro"): self.assertIn(cap, run)
        self.assertEqual(len(list((self.data / "jobs/done").glob("*.json"))), 1)

    def test_failed_run_still_cleans_the_server(self):
        self.J.add("careful", {"dir": str(self.call())})
        srv = FakeServer(fail_at="docker run")
        self.J.run_due(srv, say=lambda *_: None)
        self.assertTrue(srv.cleaned(), "the job folder goes in the finally")
        j = json.loads(next((self.data / "jobs/queue").glob("*.json")).read_text())
        self.assertIn("docker run failed", j["error"])

    def test_missing_result_is_a_failure(self):
        self.J.add("careful", {"dir": str(self.call())})
        r = self.careful_results(); r.pop("them.json")
        self.J.run_due(FakeServer(results=r), say=lambda *_: None)
        j = json.loads(next((self.data / "jobs/queue").glob("*.json")).read_text())
        self.assertIn("not back", j["error"])

    def test_pruned_audio_is_skipped(self):
        d = self.call(); (d / "me.wav").unlink(); (d / "them.wav").unlink()
        self.J.add("careful", {"dir": str(d)})
        srv = FakeServer()
        res = self.J.run_due(srv, say=lambda *_: None)
        self.assertEqual(res, [{"skipped": "inputs gone"}])
        self.assertFalse(any(a[0] == "rsync" for a in srv.calls), "nothing sent")

    def test_dry_run_sends_nothing(self):
        srv = FakeServer()
        job = {"id": "t1", "kind": "careful", "inputs": {"dir": str(self.call())}}
        lines = []
        self.assertEqual(self.J.run_job(job, srv, dry_run=True, say=lines.append), {})
        self.assertEqual(srv.calls, [])
        self.assertTrue(any(l.startswith("[clean]") for l in lines))

    def test_nightly_queues_long_unread_carefully(self):
        self.call("long", 200); self.call("short", 30); self.call("done", 200, careful=True)
        live = self.call("live", 200); (live / "me.pcm").write_bytes(b"")
        self.assertEqual(self.J.nightly_queue(), 1)
        kinds = sorted(json.loads(f.read_text())["kind"] for f in (self.data / "jobs/queue").glob("*.json"))
        self.assertEqual(kinds, ["careful", "index"])

    def test_journal_items_leave_out_test_rows_and_copies(self):
        (self.data / "takes.jsonl").write_text(json.dumps({"id": "a", "t": 1, "text": "made-up voice take here"}) + "\n"
                                                + json.dumps({"id": "b", "t": 2, "text": "⟦drafter-test⟧ never learned"}) + "\n")
        (self.data / "clipboard.jsonl").write_text(json.dumps({"t": 3, "text": "a copied secret token"}) + "\n")
        (self.data / "typed.jsonl").write_text(json.dumps({"t": 4, "text": "a made-up sent line"}) + "\n")
        self.call()
        ids = [r["id"] for r in self.J.journal_items(self.data)]
        self.assertEqual(ids[0], "v:a"); self.assertEqual(len(ids), 3)
        self.assertTrue(ids[-1].startswith("d:"))

    def test_index_finish_swaps_in_whole(self):
        import numpy as np, io
        rows = self.J.smoke_rows(10)
        buf = io.BytesIO(); np.save(buf, np.ones((10, 384), np.float16))
        res = {"vectors.npy": buf.getvalue(), "items.json": json.dumps([{"id": r["id"], "tags": ["t"]} for r in rows]),
               "tags.json": json.dumps([{"tag": "t", "items": 10}]), "meta.json": json.dumps({"kind": "index", "items": 10})}
        self.J.add("index", {"rows": rows})
        out = self.J.run_due(FakeServer(results=res), say=lambda *_: None)
        idx = self.data / "jobs/journal-index"
        items = json.loads((idx / "items.json").read_text())
        self.assertEqual(items[0]["kind"], "said"); self.assertEqual(items[0]["tags"], ["t"])
        self.assertGreater(out[0]["bytes"], 7000)
        self.assertFalse((idx.with_name("journal-index.new")).exists())


if __name__ == "__main__":
    unittest.main(verbosity=1)

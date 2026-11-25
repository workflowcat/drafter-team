"""bench/weights/common.py plumbing on a temporary data folder: no model, no real data/.

    .venv/bin/python -B tests/test_weights_common.py
"""
import os, subprocess, sys, tempfile, unittest
from pathlib import Path
TMP = tempfile.mkdtemp()
os.environ["DRAFTER_DATA"] = TMP
sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "bench/weights"))
import common as C


class Guarded(unittest.TestCase):
    def test_work_folder_exists_before_the_worker_runs(self):
        seen = {}
        def fake_run(cmd, **kw):
            seen["work"] = C.WORK.is_dir()
            return subprocess.CompletedProcess(cmd, 0, "ok\n", "")
        real_run, real_free = C.subprocess.run, C.free_pct
        C.subprocess.run, C.free_pct = fake_run, lambda: 90
        try:
            code, lines = C.guarded("x.py", ["--worker"], 1.0)
        finally:
            C.subprocess.run, C.free_pct = real_run, real_free
        self.assertEqual((code, lines), (0, ["ok"]))
        self.assertTrue(seen["work"])
        self.assertEqual(C.WORK, Path(TMP) / "bench/weights/work")

    def test_refuses_under_free_memory(self):
        real = C.free_pct
        C.free_pct = lambda: 10
        try:
            with self.assertRaises(SystemExit): C.guarded("x.py", [], 1.0)
        finally:
            C.free_pct = real


class HeldSet(unittest.TestCase):
    def test_default_set_without_chat_lines_is_refused(self):
        import json
        p = Path(TMP) / "replay-fresh.json"
        p.write_text(json.dumps([{"text": "made up", "src": "claude", "app": "Claude"}] * 60))
        with self.assertRaises(SystemExit): C.held_set()
        p.write_text(json.dumps([{"text": "made up", "src": "claude"}, {"text": "made up", "src": "beeper"}]))
        self.assertEqual(C.held_set(), p)

    def test_named_set_is_taken_as_given(self):
        self.assertEqual(C.held_set("/x/held.json"), Path("/x/held.json"))


class TrainingOutput(unittest.TestCase):
    def test_old_and_new_mlx_lm_lines(self):
        new = ["\x1b[1m  iter   train_loss\x1b[0m", "     1    val 5.524    3.43s", "    10    4.290 \u25bc      361      1.3k",
               "  1500    val 2.627    3.03s", "Peak mem 4.812 GB (guarded step)"]
        r = C.peak_and_loss(new)
        self.assertEqual((r["val_loss_first"], r["val_loss"], r["peak_gb"]), (5.524, 2.627, 4.812))
        old = ["Iter 1: Val loss 3.100, Val took 2s", "Iter 10: Train loss 2.9, It/sec 1.5, Peak mem 4.10 GB",
               "Iter 20: Val loss 2.800, Val took 2s"]
        r = C.peak_and_loss(old)
        self.assertEqual((r["val_loss_first"], r["val_loss"], r["peak_gb"], r["it_per_s"]), (3.1, 2.8, 4.1, 1.5))


class SweepRecording(unittest.TestCase):
    def test_dora_is_recorded_fused_lora_with_its_adapter(self):
        import train_sweep as T
        repo, adapter = T.record_target("dora", T.recipe("dora"))
        self.assertTrue(repo.endswith("dora-fused")); self.assertIsNone(adapter)
        repo, adapter = T.record_target("ref", T.recipe("ref"))
        self.assertEqual(repo, C.BASE); self.assertEqual(str(adapter), "bench/out/weights/ref")


class Table(unittest.TestCase):
    def test_decode_ms_and_verdict(self):
        import table
        rows = {(0, 1): {"toks": [["a", 0, 0, 100.0], ["ab", 0, 0, 106.0], ["abc", 0, 0, 113.0]]},
                (0, 2): {"toks": [["x", 0, 0, 90.0], ["xy", 0, 0, 98.0]]}}
        self.assertEqual(table.decode_ms(rows), 7.0)
        self.assertEqual(table.decode_ms({}), None)
        self.assertEqual([table.verdict(*iv) for iv in ((0.2, 1.0), (-1.0, -0.1), (-0.3, 0.4))], ["win", "lose", "noise"])


class Speed(unittest.TestCase):
    def test_per_token_counts_tokens_made(self):
        import importlib.util
        spec = importlib.util.spec_from_file_location("weights_speed", Path(C.__file__).parent / "speed.py")
        speed = importlib.util.module_from_spec(spec); spec.loader.exec_module(speed)
        # 4 tokens made of 32 asked: 3 decode steps after the first, not 31
        self.assertAlmostEqual(speed.per_token_ms(70.0, 40.0, 4), 10.0)
        self.assertAlmostEqual(speed.per_token_ms(40.0, 40.0, 1), 0.0)


if __name__ == "__main__":
    unittest.main()

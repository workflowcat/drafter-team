"""bench/take_rate.py on made-up rows in a throwaway folder (never the live data/)."""
import gzip, json, sys, tempfile, time, unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "bench"))
import take_rate  # noqa: E402


class TakeRate(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(); self.d = Path(self.tmp.name)
        self.t = time.mktime((2026, 11, 10, 12, 0, 0, 0, 0, -1))
        day = take_rate.day_of(self.t)
        def jl(name, rs): (self.d / name).write_text("".join(json.dumps(r) + "\n" for r in rs))
        jl("accepted.jsonl", [{"t": self.t, "app": "x", "before": "I will send the ", "text": "report today", "ghost_len": 12}])
        jl("typed.jsonl", [{"t": self.t + 30, "app": "x", "text": "I will send the report tomorrow"}])
        (self.d / "logs").mkdir()
        with gzip.open(self.d / "logs" / "app-old.log.gz", "wt") as f:
            f.write(f"{day}T10:00:00Z shown x 80ms engine 60ms len 5\n")
        (self.d / "app.log").write_text(
            f"{day}T11:00:00Z shown x 120ms engine 90ms len 5\n"
            f"{day}T11:00:01Z shown x 40ms engine 30ms part len 2\n"
            f"{day}T11:00:01Z shown x 55ms engine 45ms part len 4\n"
            f"{day}T11:00:01Z shown x 70ms engine 60ms len 6\n"
            f"{day}T11:00:02Z shown x 200ms engine 150ms len 7 «made up» \n"
            f"{day}T11:00:03Z quiet x: mid-line\n"
            f"{day}T11:00:04Z shown x 900ms engine 800ms gate ctx idle part len 9\n")
        self.day = day

    def tearDown(self): self.tmp.cleanup()

    def test_day(self):
        [r] = take_rate.measure(self.d, days=3, now=self.t + 3600)
        self.assertEqual(r["day"], self.day)
        self.assertEqual(r["takes"], 1)
        self.assertEqual(r["kept"], 8)                     # "report to" still matches, "day" not
        self.assertEqual(r["typed"], 26)
        self.assertEqual(r["kept_per_1k"], round(1000 * 8 / 26, 1))
        self.assertEqual(r["shown"], 4)                    # 80, 120, the streamed 40 (its parts and final once), 200
        self.assertEqual(r["p50"], 120)
        self.assertEqual(r["p90"], 200)
        self.assertEqual(r["idle"], 1)                     # the idle ghost is not key-to-ghost time

    def test_keyed_only_from_the_idle_ghost(self):
        t = time.mktime((2026, 11, 16, 12, 0, 0, 0, 0, -1)); day = take_rate.day_of(t)
        (self.d / "logs" / "app-old.log.gz").unlink()
        (self.d / "app.log").write_text(
            f"{day}T11:00:00Z shown x 50ms engine 40ms gate ctx key 50ms len 5\n"
            f"{day}T11:00:05Z shown x 600ms engine 590ms gate ctx part len 9\n"      # no key: a rest (the idle ghost)
            f"{day}T11:00:05Z shown x 650ms engine 640ms gate ctx len 12\n"
            f"{day}T11:00:09Z shown x 70ms engine 60ms gate ctx predicted key 70ms len 5\n")
        [r] = [x for x in take_rate.measure(self.d, days=3, now=t + 3600) if x["day"] == day]
        self.assertEqual((r["shown"], r["idle"], r["p90"]), (2, 1, 70))

    def test_no_text_in_table(self):
        out = "\n".join(take_rate.table(take_rate.measure(self.d, days=3, now=self.t + 3600)))
        for s in ("report", "made up", "tomorrow"): self.assertNotIn(s, out)

    def test_empty_folder(self):
        self.assertEqual(take_rate.measure(Path(self.tmp.name) / "none", days=3, now=self.t), [])


if __name__ == "__main__":
    unittest.main()

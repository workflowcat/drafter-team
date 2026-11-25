"""Recency weighting of training lines (bench/weights/recency.py) on made-up rows: no model, no data/.

    .venv/bin/python -B tests/test_weights_recency.py
"""
import sys, unittest
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "bench/weights"))
import recency as R

DAY = 86400


class Recency(unittest.TestCase):
    def test_newer_lines_weigh_more_and_mean_is_one(self):
        now = 1000 * DAY
        ts = [now - d * DAY for d in (0, 30, 60, 120, 400)]
        m = R.multipliers(ts, now, half_life_days=30, floor=0.0)
        self.assertEqual(m, sorted(m, reverse=True))
        self.assertAlmostEqual(sum(m) / len(m), 1.0)
        self.assertAlmostEqual(m[0] / m[1], 2.0)          # one half-life apart

    def test_floor_and_undated(self):
        now = 1000 * DAY
        m = R.multipliers([now, now - 900 * DAY, 0], now, half_life_days=10, floor=0.25)
        self.assertAlmostEqual(m[2], 1.0)                 # no date: the mean
        self.assertAlmostEqual(m[0] / m[1], 4.0)          # 1 against the floor 0.25

    def test_off(self):
        self.assertEqual(R.multipliers([1, 2, 0], 10, None), [1.0, 1.0, 1.0])

    def test_sample_keeps_size_on_average_and_is_repeatable(self):
        rows = list(range(2000))
        w = [0.5] * 1000 + [1.5] * 1000
        a, b = R.sample(rows, w, seed=3), R.sample(rows, w, seed=3)
        self.assertEqual(a, b)
        self.assertAlmostEqual(len(a) / 2000, 1.0, delta=0.05)
        self.assertGreater(sum(1 for r in a if r >= 1000), 2.5 * sum(1 for r in a if r < 1000))


if __name__ == "__main__":
    unittest.main()

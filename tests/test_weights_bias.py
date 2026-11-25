"""bench/weights/bias.py `fit` on a made-up collect file (the arrays collect.py writes): no model, no data/.

    .venv/bin/python -B tests/test_weights_bias.py
"""
import json, sys, tempfile, unittest
from pathlib import Path
import numpy as np
sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "bench/weights"))
import bias


def fake_npz(n, seed=0):
    rng = np.random.default_rng(seed)
    cand = np.array([3, 5, 7, 11], np.int64)
    logits = rng.normal(size=(n, 4)) - 2.0
    cand_lp = logits - np.log(np.exp(logits).sum(1, keepdims=True) + 1.0)   # the rest of the vocabulary holds the remainder
    y = rng.choice(np.append(cand, 13), size=n, p=[0.4, 0.1, 0.1, 0.1, 0.3])
    y_lp = np.where(y == 13, np.log(0.3), cand_lp[np.arange(n), np.minimum(np.searchsorted(cand, y), 3)])
    kind = np.array(["ai", "chat"] * (n // 2))
    p = Path(tempfile.mkdtemp()) / "x.npz"
    np.savez(p, cand=cand, cand_lp=cand_lp, y=y, y_lp=y_lp, kind=kind, vocab=np.array(20), meta=json.dumps({}))
    return p


class Fit(unittest.TestCase):
    def test_small_run_fits_with_a_low_threshold(self):
        p = fake_npz(300)
        self.assertEqual(bias.fit(p, ("all", "ai", "chat"))[0], {})          # the old fixed 500: nothing to save
        out, report = bias.fit(p, ("all", "ai", "chat"), min_positions=20)
        self.assertEqual(set(out), {"all", "ai", "chat"})
        self.assertEqual(out["all"].shape, (20,))
        self.assertEqual(report["all"]["positions"], 300)
        self.assertTrue(np.all(out["all"][[0, 1, 2, 4, 13]] == 0))             # non-candidates keep 0


if __name__ == "__main__":
    unittest.main()

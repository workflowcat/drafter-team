"""The logit-bias fit (bench/weights/biasfit.py) on made-up distributions: no model, no data/.

    .venv/bin/python -B tests/test_weights_biasfit.py
"""
import sys, unittest
from pathlib import Path
import numpy as np
sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "bench/weights"))
import biasfit as B

VOCAB = 80


def fake(n=6000, seed=0, shift=None):
    """A 'model' with random logits and a writer whose choices carry an extra bias on 8 tokens, stored like collect.py."""
    rng = np.random.default_rng(seed)
    z = rng.normal(0, 2.0, (n, VOCAB))
    true = np.zeros(VOCAB)
    true[:8] = shift if shift is not None else [1.5, -1.5, 1.0, -1.0, 2.0, 0.5, -0.5, 1.2]
    lp = z - np.log(np.exp(z).sum(1, keepdims=True))
    pw = np.exp(z + true); pw /= pw.sum(1, keepdims=True)
    y = (pw.cumsum(1) > rng.random(n)[:, None]).argmax(1)
    cand = B.candidates([y.tolist()], min_count=5)
    return B.pack(cand, lp[:, cand], y, lp[np.arange(n), y]), true


class BiasFit(unittest.TestCase):
    def test_candidates(self):
        c = B.candidates([[1, 2, 2, 3], [2, 3, 3, 9]], min_count=2)
        self.assertEqual(c.tolist(), [2, 3])
        self.assertEqual(B.candidates([[1, 1, 2, 2, 2]], min_count=2, most=1).tolist(), [2])

    def test_gradient_matches_numbers(self):
        d, _ = fake(n=500, seed=1)
        b = np.random.default_rng(2).normal(0, 0.3, len(d["cand"]))
        _, g = B.loss_grad(b, d, 1e-3)
        for t in (0, 3, len(b) - 1):
            e = np.zeros(len(b)); e[t] = 1e-3      # the probabilities are float32: a wider step
            num = (B.loss_grad(b + e, d, 1e-3)[0] - B.loss_grad(b - e, d, 1e-3)[0]) / 2e-3
            self.assertAlmostEqual(num, g[t], delta=1e-4)

    def test_recovers_the_writers_bias(self):
        d, true = fake()
        b, hist = B.fit(d, lam=1e-6, steps=200)
        self.assertLess(hist[-1], hist[0])
        full = B.dense(b, d["cand"], VOCAB)
        # tokens outside the candidates stay at 0, so the bias is defined up to that: compare the 8 shifted tokens
        self.assertGreater(np.corrcoef(full[:8], true[:8])[0, 1], 0.97)
        self.assertLess(np.abs(full[:8] - true[:8]).max(), 0.35)

    def test_held_out_positions_get_better(self):
        d, _ = fake(seed=3)
        out = B.choose(d)
        before, after = out["valid"][out["lam"]]
        self.assertLess(after, before - 0.05)

    def test_no_bias_when_the_writer_is_the_model(self):
        d, _ = fake(seed=4, shift=np.zeros(8))
        out = B.choose(d)
        before, after = out["valid"][out["lam"]]
        self.assertLess(before - after, 0.01)
        w = np.bincount(d["ycol"][d["ycol"] >= 0], minlength=len(out["b"]))
        self.assertLess(float((np.abs(out["b"]) * w).sum() / w.sum()), 0.1)

    def test_cap_and_untouched_tokens(self):
        d, _ = fake(seed=5)
        b, _ = B.fit(d, lam=0.0, steps=50, cap=0.25)
        self.assertLessEqual(np.abs(b).max(), 0.25 + 1e-9)
        full = B.dense(b, d["cand"], VOCAB + 20)
        self.assertTrue((full[VOCAB:] == 0).all())


if __name__ == "__main__":
    unittest.main()

"""Steering vectors (bench/weights/steervec.py) and the default-off hook that applies them and the logit bias
(engine/tweaks.py), on made-up arrays and a tiny made-up model: no real model, no data/.

    .venv/bin/python -B tests/test_weights_steer.py
"""
import os, sys, tempfile, unittest
from pathlib import Path
import numpy as np
ROOT = Path(__file__).resolve().parent.parent
sys.path[:0] = [str(ROOT / "bench/weights"), str(ROOT / "engine")]
import steervec as S


class Vectors(unittest.TestCase):
    def setUp(self):
        rng = np.random.default_rng(0)
        self.shift = np.zeros(16); self.shift[3] = 2.0
        self.a = rng.normal(0, 1, (400, 16)) + self.shift
        self.b = rng.normal(0, 1, (300, 16))

    def test_difference_of_means_finds_the_shift(self):
        v = S.vector(self.a, self.b)
        self.assertGreater(S.cosine(v, self.shift), 0.95)
        self.assertAlmostEqual(float(np.linalg.norm(v)), 2.0, delta=0.3)

    def test_kind_vectors_weigh_kinds_the_same_and_add_to_zero(self):
        rng = np.random.default_rng(1)
        groups = {"ai": rng.normal(0, 1, (1000, 8)) + 1.0, "chat": rng.normal(0, 1, (50, 8)) - 1.0}
        v = S.kind_vectors(groups)
        self.assertTrue(np.allclose(v["ai"] + v["chat"], 0))
        self.assertAlmostEqual(float(v["ai"].mean()), 1.0, delta=0.2)   # the big group does not pull the centre

    def test_scale(self):
        v = S.scale_to(np.array([3.0, 4.0]), token_norm=10.0, rel=0.5)
        self.assertAlmostEqual(float(np.linalg.norm(v)), 5.0)
        self.assertTrue((S.scale_to(np.zeros(3), 10.0, 1.0) == 0).all())

    def test_holdout_accuracy(self):
        self.assertGreater(S.holdout_accuracy(self.a, self.b), 0.75)
        rng = np.random.default_rng(2)
        same = S.holdout_accuracy(rng.normal(0, 1, (400, 16)), rng.normal(0, 1, (400, 16)))
        self.assertLess(abs(same - 0.5), 0.12)


class Hook(unittest.TestCase):
    """engine/tweaks.py on a made-up model shaped like mlx_lm's: Model(inputs, cache) -> logits, model.layers[i](x, mask, cache)."""

    def setUp(self):
        import mlx.core as mx, mlx.nn as nn
        import tweaks
        self.mx, self.tweaks = mx, tweaks

        class Cache:
            def __init__(self): self.offset = 0

        class Block(nn.Module):
            def __call__(self, x, mask=None, cache=None):
                if cache is not None: cache.offset += x.shape[1]   # attention moves the offset, as in mlx_lm
                return x

        class Tiny(nn.Module):
            def __init__(self):
                super().__init__()
                self.blocks = [Block(), Block()]
            @property
            def layers(self): return self.blocks
            def __call__(self, inputs, cache=None):
                h = mx.zeros((1, inputs.shape[0], 4)) + inputs[None, :, None].astype(mx.float32)
                for blk, c in zip(self.layers, cache or [None] * 2): h = blk(h, None, c)
                return h[..., :3]   # "logits" over a vocabulary of 3

        self.Cache, self.Tiny = Cache, Tiny

    def test_off_by_default(self):
        import importlib, model as engine_model   # noqa: F401  (imports with DRAFTER_TWEAKS unset)
        self.assertEqual(os.environ.get("DRAFTER_TWEAKS", ""), "")
        self.assertEqual(engine_model.TWEAKS, "")

    def test_bias_by_kind_and_off_switch(self):
        mx, T = self.mx, self.tweaks
        m = self.Tiny()
        tw = T.attach(m, T.Tweaks(bias={"all": [0, 0, 1.0], "chat": [5.0, 0, 0]}))
        x = mx.array([1, 2])
        self.assertEqual(m(x).tolist()[0][0], [1.0, 1.0, 2.0])
        tw.kind = "chat"; self.assertEqual(m(x).tolist()[0][1], [7.0, 2.0, 2.0])
        tw.kind = "ai"; self.assertEqual(m(x).tolist()[0][1], [2.0, 2.0, 3.0])     # no "ai" entry: "all"
        tw.on = False; self.assertEqual(m(x).tolist()[0][1], [2.0, 2.0, 2.0])

    def test_steering_skips_the_head_and_scales(self):
        mx, T = self.mx, self.tweaks
        m = self.Tiny()
        tw = T.attach(m, T.Tweaks(steer={"all": [1.0, 1.0, 1.0, 1.0]}, layer=1, strength=2.0))
        tw.start = 2                                   # two head tokens
        c = [self.Cache(), self.Cache()]
        out = m(mx.array([0, 0, 0]), c).tolist()[0]    # head + one token in one call
        self.assertEqual([r[0] for r in out], [0.0, 0.0, 2.0])
        out = m(mx.array([0]), c).tolist()[0]          # a later token, fed alone
        self.assertEqual(out[0][0], 2.0)
        tw.strength = 0.0
        self.assertEqual(m(mx.array([0]), c).tolist()[0][0][0], 0.0)

    def test_load_from_file_and_kind_of(self):
        T = self.tweaks
        with tempfile.TemporaryDirectory() as d:
            p = os.path.join(d, "t.npz")
            np.savez(p, bias_all=np.zeros(3, np.float32), steer_chat=np.ones(4, np.float32), meta='{"layer": 1, "strength": 0.5}')
            tw = T.Tweaks.load(p, kind="chat")
            self.assertEqual((tw.layer, tw.strength, tw.kind), (1, 0.5, "chat"))
            self.assertEqual(sorted(tw.bias), ["all"]); self.assertEqual(sorted(tw.steer), ["chat"])
        self.assertEqual([T.kind_of(a) for a in ("Beeper", "Claude", "TextEdit", "ChatGPT")], ["chat", "ai", "all", "ai"])


if __name__ == "__main__":
    unittest.main()

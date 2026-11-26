"""Engine memory round (2026-11-17): the user's layer merged without keeping the plain layers beside the merged ones.
A tiny made-up Qwen3 (random weights, 4-bit, a LoRA on its last 2 layers) built in memory, no weights from disk:
- typing (layer on) gives the same logits, bit for bit, as the old way that kept the plain layers
- the plain copies are gone: active MLX memory drops by their size
- layer off (chips, rewrites) is the base model within one 4-bit re-rounding: its distance to the base is smaller than
  the base model's own distance to its float weights

    .venv/bin/python -B tests/test_lora_merged_only.py
"""
import gc, sys, threading, unittest
from collections import OrderedDict
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "engine"))
import mlx.core as mx
import mlx.nn as nn
from mlx.utils import tree_flatten
from mlx_lm.models import qwen3
from mlx_lm.tuner.utils import linear_to_lora_layers
import model as M

ARGS = dict(model_type="qwen3", hidden_size=512, num_hidden_layers=4, intermediate_size=2048, num_attention_heads=8,
            num_key_value_heads=4, head_dim=64, rms_norm_eps=1e-6, vocab_size=512, max_position_embeddings=512,
            rope_theta=10000.0, tie_word_embeddings=True)
IDS = mx.array([[3, 17, 99, 250, 7, 41, 300, 12, 5, 77, 190, 2, 64, 128, 33, 401]])


def tiny():
    mx.random.seed(0)
    net = qwen3.Model(qwen3.ModelArgs(**ARGS))
    net.eval()
    fp = net(IDS); mx.eval(fp)
    nn.quantize(net, group_size=64, bits=4)
    base = net(IDS)
    linear_to_lora_layers(net, 2, {"rank": 8, "scale": 20.0, "dropout": 0.0})
    for _, m in net.named_modules():
        if type(m).__name__ == "LoRALinear": m.lora_b = mx.random.normal(m.lora_b.shape) * 0.01
    mx.eval(net.parameters(), base)
    m = M.Model.__new__(M.Model)
    m.model, m.strength, m.adapter, m.tw, m.dist, m.lock = net, 1.0, "/layer", None, None, threading.Lock()
    m.fp = fp
    return m, base


def plain_bytes(m):
    return sum(v.nbytes for k, v in tree_flatten(m.model.parameters()) if ".linear." in k)


class MergedOnly(unittest.TestCase):
    def build(self, keep):
        M.KEEP_PLAIN = keep
        m, base = tiny()
        plain = plain_bytes(m)
        gc.collect(); mx.clear_cache()
        a0 = mx.get_active_memory()
        n = m.fuse_lora()
        gc.collect(); mx.clear_cache()
        mem = mx.get_active_memory() - a0                         # what merging added
        on = m.model(IDS); mx.eval(on)
        m.lora(False); off = m.model(IDS); mx.eval(off); m.lora(True)
        again = m.model(IDS); mx.eval(again)
        return m, base, n, plain, on, off, again, mem

    def test_typing_same_memory_less_off_close(self):
        old = self.build(True)
        old_mem, old_on, old_n = old[7], old[4], old[2]
        del old; gc.collect(); mx.clear_cache()
        m, base, n, plain, on, off, again, mem = self.build(False)
        self.assertEqual(n, old_n)
        self.assertEqual(n, 14)                                   # 2 layers x 7 projections
        self.assertTrue(mx.array_equal(on, old_on).item())        # typing: the same merged layers, bit for bit
        self.assertTrue(mx.array_equal(on, again).item())         # layer back on after a chip: the same again
        print(f"\ntiny model, memory added by merging: plain kept {old_mem / 2**20:.2f} MB, merged only {mem / 2**20:.2f} MB (plain copies {plain / 2**20:.2f} MB)")
        self.assertGreaterEqual(old_mem, 0.95 * plain)            # the old way: a second copy of every touched layer
        self.assertLessEqual(mem, 0.05 * plain)                   # merged only: nothing added
        err = lambda a, b: (mx.abs(a - b).mean() / mx.abs(b).mean()).item()
        off_err, quant_err = err(off, base), err(base, m.fp)
        print(f"logit error: layer off vs base {off_err:.3f}, base 4-bit vs float {quant_err:.3f}, layer on vs base {err(on, base):.3f}")
        self.assertLess(off_err, 0.6 * quant_err)                 # within the rounding the base model already has

    def test_new_strength_loads_the_plain_weights_again(self):
        M.KEEP_PLAIN = False
        loads = []
        def fake_load(where, adapter_path=None):
            loads.append(where)
            return tiny()[0].model, None
        old_load, M.load = M.load, fake_load
        try:
            m, _ = tiny()
            m.fuse_lora()
            m.src, m.repo, m.loading, m.wake_at, m.retrain_sleep, m.head_ids = None, "org/tiny", False, 0.0, False, []
            m.cache, m.ids, m.snapshot, m.marks, m.parked, m.screen = None, [], None, OrderedDict(), OrderedDict(), None
            m.set_strength(0.5)
            self.assertEqual(loads, ["org/tiny"])               # the weights again, merged at the new strength
            self.assertEqual(len(m.fused), 14)
            want, _ = tiny(); want.strength = 0.5; want.fuse_lora()
            got = m.model(IDS); ref = want.model(IDS); mx.eval(got, ref)
            self.assertTrue(mx.array_equal(got, ref).item())    # same as a fresh load at 0.5: no drift from a re-merge
        finally:
            M.load = old_load

    def tearDown(self): M.KEEP_PLAIN = False


if __name__ == "__main__":
    unittest.main()

"""Ghost p90 round (2026-11-17): a job a key may stop (the idle ghost, look-ahead) reads its prompt in small chunks and
stops between them. A tiny made-up Qwen3 (random weights, built in memory, nothing from disk):
- a cancel after 2 chunks stops the read there, and self.ids holds exactly the tokens in the cache
- reading on from that point gives the same tokens as one uninterrupted read (the cache is not broken)
- without `cancelled` the read is the old one: same tokens, self.ids untouched until the first token

    .venv/bin/python -B tests/test_prefill_yield.py
"""
import sys, threading, unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "engine"))
import mlx.core as mx
from mlx_lm.models import qwen3
from mlx_lm.models.cache import make_prompt_cache
import model as M

ARGS = dict(model_type="qwen3", hidden_size=128, num_hidden_layers=2, intermediate_size=256, num_attention_heads=4,
            num_key_value_heads=2, head_dim=32, rms_norm_eps=1e-6, vocab_size=256, max_position_embeddings=512,
            rope_theta=10000.0, tie_word_embeddings=True)
PROMPT = [(7 * i + 3) % 256 for i in range(40)]


def tiny():
    mx.random.seed(1)
    net = qwen3.Model(qwen3.ModelArgs(**ARGS)); net.eval(); mx.eval(net.parameters())
    m = M.Model.__new__(M.Model)
    m.model, m.dist, m.lock, m.ids = net, None, threading.Lock(), []
    m.cache = make_prompt_cache(net)
    m.sampler = lambda lp: mx.argmax(lp, axis=-1)
    return m


def run(m, raw, n=4, **kw):
    fed = raw[len(m.ids):]
    return [t for t, _ in m._steps(raw, fed, [], n, **kw)]


class PrefillYield(unittest.TestCase):
    def test_stops_between_chunks_and_stays_whole(self):
        ref = run(tiny(), PROMPT)                     # one read, the old way
        m, calls = tiny(), [0]

        def cancelled():
            calls[0] += 1
            return calls[0] >= 2
        with self.assertRaises(M.Model.Cancelled):
            run(m, PROMPT, prefill_step=8, cancelled=cancelled)
        self.assertEqual(len(m.ids), 16)              # 2 chunks of 8
        self.assertEqual(m.ids, PROMPT[:16])
        self.assertEqual(m.cache[0].offset, 16)       # the cache holds the same tokens
        self.assertEqual(run(m, PROMPT), ref)         # reading on gives the same tokens

    def test_no_cancel_is_the_old_read(self):
        a, b = tiny(), tiny()
        self.assertEqual(run(a, PROMPT, prefill_step=8, cancelled=lambda: False), run(b, PROMPT))
        c = tiny()
        list(c._steps(PROMPT, PROMPT, [], 0, prefill_step=8))   # no `cancelled`: self.ids is not touched
        self.assertEqual(c.ids, [])


if __name__ == "__main__":
    unittest.main()

"""Model decode syncs (engine/model.py): single eval per token in complete_gated and argpartition in _alts.

No model weights loaded. Run: .venv/bin/python -B tests/test_model_sync.py
"""
import math
from pathlib import Path
import re
import sys
import threading
import time
import types
import unittest
from unittest.mock import Mock
import numpy as np

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "engine"))
from server_src import lift


class DecodeSyncs(unittest.TestCase):
    def test_complete_gated_batches_per_token_eval_without_gpu_exp(self):
        evals = []
        exp_calls = []

        def fake_eval(*args):
            evals.append(len(args))

        def fake_exp(x):
            exp_calls.append(x)
            return np.exp(x)

        class Cancelled(Exception):
            pass

        mx = types.SimpleNamespace(
            array=np.array,
            exp=fake_exp,
            eval=fake_eval,
            topk=lambda a, k: np.sort(a)[-k:],
        )
        ns = lift(
            "complete_gated",
            path=ROOT / "engine/model.py",
            cls="Model",
            DIST=False,
            SETTLE=True,
            time=time,
            math=math,
            END=re.compile(r"[.!?…)\n]"),
            mx=mx,
            Model=types.SimpleNamespace(Cancelled=Cancelled),
        )
        pieces = ["<eos>", " to", " the", " park", "."]
        script = [(1, {1: 0.85, 2: 0.10, 3: 0.02}), (2, {2: 0.75, 1: 0.15, 3: 0.04}), (3, {3: 0.70, 1: 0.10})]

        def gen(*a, **k):
            for tok, ps in script:
                lp = np.full(len(pieces), -30.0)
                for t, p in ps.items():
                    lp[t] = math.log(p)
                yield tok, lp

        seen_toks = []

        def decide(toks):
            seen_toks.extend(toks)
            return 0.9

        m = types.SimpleNamespace(
            lock=threading.Lock(),
            model=object(),
            _switch=Mock(),
            _feed=Mock(return_value=[0]),
            cache=[],
            sampler=None,
            ids=[],
            healer=Mock(),
            russian_mask=lambda s: 0,
            tok=types.SimpleNamespace(eos_token_id=0, decode=lambda ids: "".join(pieces[i] for i in ids)),
        )
        ns["generate_step"] = gen
        text, g, _, _ = ns["complete_gated"](
            m, [7], "", decide, max_tokens=10, mid={"rest": 3, "text": " park.", "stop": 0.3}
        )
        self.assertEqual(text, " to the")
        self.assertEqual(g, 0.9)
        self.assertEqual(len(exp_calls), 9)       # exp stays lazy in the model's dtype (top, p, rest), inside the one eval
        self.assertEqual(evals, [3, 3, 3])        # one batched eval (top, p_lp, r_lp) per token
        self.assertEqual(seen_toks[0][1:], [0.85, 0.1])
        self.assertEqual([round(x, 4) for x in m.last_rests], [0.02, 0.04, 0.7])

    def test_alts_uses_argpartition_and_single_eval_matching_argsort(self):
        evals = []
        calls = {"argpartition": 0, "argsort": 0, "exp": 0, "array": 0}

        def fake_argpartition(a, k):
            calls["argpartition"] += 1
            return np.argpartition(a, k)

        def fake_argsort(a):
            calls["argsort"] += 1
            return np.argsort(a)

        def fake_eval(*args):
            evals.append(len(args))

        mx = types.SimpleNamespace(
            argpartition=fake_argpartition,
            argsort=fake_argsort,
            eval=fake_eval,
            exp=lambda x: calls.__setitem__("exp", calls["exp"] + 1) or np.exp(x),
            array=lambda x: calls.__setitem__("array", calls["array"] + 1) or np.array(x),
        )
        ns = lift("_alts", path=ROOT / "engine/model.py", cls="Model", math=math, mx=mx)
        vocab = [f" {chr(ord('a') + (i % 26))}{i}" for i in range(200)]
        rng = np.random.default_rng(7)
        lp = rng.normal(-8.0, 2.0, size=len(vocab))
        lp[5] = -0.5   # " f5"
        lp[31] = -0.6  # " f31" -> 'f' gets summed mass
        lp[2] = -0.4   # " c2"
        lp[10] = -0.7  # " k10"
        m = types.SimpleNamespace(tok=types.SimpleNamespace(decode=lambda ids: vocab[ids[0]]))

        got = ns["_alts"](m, lp, "", 3)
        self.assertEqual(got, ["f", "c", "k"])
        self.assertEqual(calls["argpartition"], 1)
        self.assertEqual(calls["argsort"], 0)
        self.assertEqual(calls["exp"], 0)
        self.assertEqual(calls["array"], 0)
        self.assertEqual(evals, [2])

        # Small vocab (<= 48): falls back to argsort cleanly without raising
        small_lp = lp[:12]
        got_small = ns["_alts"](m, small_lp, "", 2)
        self.assertEqual(got_small, ["c", "f"])
        self.assertEqual(calls["argsort"], 1)

    def test_alts_matches_real_mlx_argsort(self):
        import mlx.core as mx
        ns = lift("_alts", path=ROOT / "engine/model.py", cls="Model", math=math, mx=mx)
        vocab = [f" {chr(ord('a') + (i % 26))}{i}" for i in range(500)]
        m = types.SimpleNamespace(tok=types.SimpleNamespace(decode=lambda ids: vocab[ids[0]]))
        lp = mx.array(np.random.default_rng(42).normal(-5.0, 1.5, size=len(vocab)).astype(np.float32))
        mx.eval(lp)
        got = ns["_alts"](m, lp, "", 4)
        # Reference via full argsort
        top = mx.argsort(-lp)[:48].tolist()
        ps = mx.exp(lp[mx.array(top)]).tolist()
        score = {}
        for t, p in zip(top, ps):
            ch = vocab[t].lstrip(" ")[:1]
            score[ch] = score.get(ch, 0.0) + p
        ref = [c for c, _ in sorted(score.items(), key=lambda x: -x[1])[:4]]
        self.assertEqual(got, ref)


if __name__ == "__main__":
    unittest.main()

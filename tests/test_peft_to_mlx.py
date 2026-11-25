"""PEFT -> MLX layer converter (bench/remote/peft_to_mlx.py) on a tiny random adapter: key for key the converted
weights are the PEFT ones transposed, mlx_lm's own loader takes them on a tiny made-up model, and a LoRA layer then
gives the same output as the PEFT formula. No real model loads here.

    .venv/bin/python -B tests/test_peft_to_mlx.py
"""
import json, sys, tempfile, unittest
from pathlib import Path

import numpy as np
from safetensors.numpy import load_file, save_file

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "bench/remote"))
import peft_to_mlx as P

R, ALPHA, TOTAL, LAST = 4, 80.0, 4, 2          # rank 4, scale 20, the last 2 of 4 layers
SHAPES = {"self_attn.q_proj": (16, 16), "self_attn.k_proj": (16, 8), "mlp.down_proj": (32, 16)}   # (in, out)


def peft_adapter(folder, rng, layers=range(TOTAL - LAST, TOTAL), drop=None, extra=None):
    w = {}
    for n in layers:
        for key, (i, o) in SHAPES.items():
            base = f"base_model.model.model.layers.{n}.{key}"
            w[f"{base}.lora_A.weight"] = rng.standard_normal((R, i)).astype(np.float32)
            w[f"{base}.lora_B.weight"] = rng.standard_normal((o, R)).astype(np.float32)
    if drop: w.pop(drop)
    if extra: w.update(extra)
    folder.mkdir(parents=True, exist_ok=True)
    save_file(w, str(folder / "adapter_model.safetensors"))
    (folder / "adapter_config.json").write_text(json.dumps({
        "peft_type": "LORA", "r": R, "lora_alpha": ALPHA, "lora_dropout": 0.0, "bias": "none", "use_dora": False,
        "use_rslora": False, "target_modules": [k.split(".")[1] for k in SHAPES], "base_model_name_or_path": "made/up"}))
    return w


class Convert(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(); self.dir = Path(self.tmp.name)
        self.rng = np.random.default_rng(7)

    def tearDown(self): self.tmp.cleanup()

    def test_key_for_key(self):
        src = peft_adapter(self.dir / "peft", self.rng)
        info = P.convert(self.dir / "peft", self.dir / "mlx", total_layers=TOTAL, model="org/tiny")
        got = load_file(str(self.dir / "mlx/adapters.safetensors"))
        want = {}
        for k, w in src.items():
            mod = k[len("base_model.model."):].rsplit(".lora_", 1)[0]
            want[mod + (".lora_a" if ".lora_A." in k else ".lora_b")] = w.T
        self.assertEqual(set(got), set(want))
        for k in want:
            self.assertEqual(got[k].shape, want[k].shape, k)
            np.testing.assert_array_equal(got[k], want[k], err_msg=k)
        self.assertEqual(info["tensors"], LAST * len(SHAPES) * 2)
        cfg = json.loads((self.dir / "mlx/adapter_config.json").read_text())
        self.assertEqual(cfg["fine_tune_type"], "lora")
        self.assertEqual(cfg["num_layers"], LAST)
        self.assertEqual(cfg["lora_parameters"], {"rank": R, "scale": ALPHA / R, "dropout": 0.0, "keys": sorted(SHAPES)})
        self.assertEqual(cfg["model"], "org/tiny")

    def test_refuses_what_mlx_would_read_differently(self):
        cases = {"half": dict(drop="base_model.model.model.layers.3.mlp.down_proj.lora_B.weight"),
                 "gap": dict(layers=[1, 3]),
                 "not last": dict(layers=[1, 2]),
                 "stray": dict(extra={"base_model.model.lm_head.weight": np.zeros((2, 2), np.float32)})}
        for name, kw in cases.items():
            with self.subTest(name):
                peft_adapter(self.dir / name, self.rng, **kw)
                with self.assertRaises(ValueError):
                    P.convert(self.dir / name, self.dir / (name + "-mlx"), total_layers=TOTAL)

    def test_mlx_loader_takes_it_and_output_matches_peft(self):
        try:
            import mlx.core as mx, mlx.nn as nn
            from mlx_lm.tuner.utils import load_adapters
        except ImportError:
            self.skipTest("mlx not installed")
        src = peft_adapter(self.dir / "peft", self.rng)
        P.convert(self.dir / "peft", self.dir / "mlx", total_layers=TOTAL)

        class Attn(nn.Module):
            def __init__(s):
                super().__init__(); s.q_proj = nn.Linear(16, 16, bias=False); s.k_proj = nn.Linear(16, 8, bias=False)

        class MLP(nn.Module):
            def __init__(s):
                super().__init__(); s.down_proj = nn.Linear(32, 16, bias=False)

        class Block(nn.Module):
            def __init__(s):
                super().__init__(); s.self_attn = Attn(); s.mlp = MLP()

        class Inner(nn.Module):
            def __init__(s):
                super().__init__(); s.layers = [Block() for _ in range(TOTAL)]

        class Tiny(nn.Module):
            def __init__(s):
                super().__init__(); s.model = Inner()

            @property
            def layers(s): return s.model.layers

        model = load_adapters(Tiny(), str(self.dir / "mlx"))      # mlx_lm checks every name and shape itself
        lora = model.model.layers[3].mlp.down_proj
        self.assertEqual(type(lora).__name__, "LoRALinear")
        self.assertEqual(type(model.model.layers[1].mlp.down_proj).__name__, "Linear")   # only the last LAST layers
        x = self.rng.standard_normal((3, 32)).astype(np.float32)
        base = np.array(lora.linear(mx.array(x)))
        a = src["base_model.model.model.layers.3.mlp.down_proj.lora_A.weight"]
        b = src["base_model.model.model.layers.3.mlp.down_proj.lora_B.weight"]
        peft_out = base + (ALPHA / R) * (x @ a.T @ b.T)            # PEFT: base(x) + scaling * B(A(x))
        np.testing.assert_allclose(np.array(lora(mx.array(x))), peft_out, rtol=1e-4, atol=1e-3)


if __name__ == "__main__":
    unittest.main()

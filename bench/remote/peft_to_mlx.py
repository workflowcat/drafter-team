"""A PEFT LoRA adapter (bench/remote/train_lora.py on the team server) -> the MLX layer the engine loads.

    .venv/bin/python -B bench/remote/peft_to_mlx.py <peft folder> <mlx folder> [--total-layers N] [--model REPO]

PEFT keeps `base_model.model.model.layers.N.self_attn.q_proj.lora_A.weight` (r, in) and `...lora_B.weight` (out, r),
scale = lora_alpha / r. MLX (mlx_lm.tuner.lora.LoRALinear) keeps `model.layers.N.self_attn.q_proj.lora_a` (in, r) and
`...lora_b` (r, out), output = linear(x) + scale * (x @ lora_a) @ lora_b. So lora_a = A.T, lora_b = B.T, and
adapter_config.json carries num_layers (the last N layers), rank, scale and the keys, as mlx_lm load_adapters and
DRAFTER_LORA_FUSE read them. Numpy and safetensors only: no torch, no model."""
import argparse, json, re, sys
from pathlib import Path

import numpy as np
from safetensors.numpy import load_file, save_file

PEFT_KEY = re.compile(r"^(?:base_model\.model\.)?(?P<mod>.+)\.lora_(?P<ab>[AB])(?:\.default)?\.weight$")
LAYER = re.compile(r"^model\.layers\.(?P<n>\d+)\.(?P<key>.+)$")


def convert(src, dst, total_layers=None, model=None):
    """Write dst/adapters.safetensors and dst/adapter_config.json from the PEFT folder `src`. -> summary dict.
    Raises ValueError for anything the MLX loader would read differently (DoRA, rsLoRA, bias, gaps in the layers)."""
    src, dst = Path(src), Path(dst)
    cfg = json.loads((src / "adapter_config.json").read_text())
    if cfg.get("use_dora"): raise ValueError("DoRA adapter: not a plain LoRA")
    if cfg.get("bias", "none") != "none": raise ValueError(f"LoRA bias {cfg.get('bias')!r}: MLX layers have none")
    r, alpha = int(cfg["r"]), float(cfg["lora_alpha"])
    scale = alpha / (r ** 0.5) if cfg.get("use_rslora") else alpha / r
    weights = load_file(str(src / "adapter_model.safetensors"))
    out, parts = {}, {}
    for k, w in weights.items():
        m = PEFT_KEY.match(k)
        if not m: raise ValueError(f"not a LoRA weight: {k}")
        mod, ab = m["mod"], m["ab"]
        if not LAYER.match(mod): raise ValueError(f"LoRA outside model.layers.N: {k}")
        if w.ndim != 2: raise ValueError(f"{k}: {w.ndim}-d, expected 2-d")
        if (ab == "A" and w.shape[0] != r) or (ab == "B" and w.shape[1] != r):
            raise ValueError(f"{k}: shape {w.shape} does not hold rank {r}")
        out[f"{mod}.lora_{ab.lower()}"] = np.ascontiguousarray(w.T.astype(np.float32))
        parts.setdefault(mod, set()).add(ab)
    if not out: raise ValueError("no LoRA weights")
    half = [m for m, s in parts.items() if s != {"A", "B"}]
    if half: raise ValueError(f"A without B (or B without A): {sorted(half)[:3]}")
    layers = sorted({int(LAYER.match(m)["n"]) for m in parts})
    keys = sorted({LAYER.match(m)["key"] for m in parts})
    if layers != list(range(layers[0], layers[-1] + 1)): raise ValueError(f"layers not contiguous: {layers}")
    if total_layers is not None and layers[-1] != total_layers - 1:
        raise ValueError(f"layers {layers[0]}..{layers[-1]} are not the last of {total_layers}: MLX applies the last N")
    missing = [f"model.layers.{n}.{k}" for n in layers for k in keys if f"model.layers.{n}.{k}" not in parts]
    if missing: raise ValueError(f"every layer must carry the same keys; missing {missing[:3]}")
    dst.mkdir(parents=True, exist_ok=True)
    save_file(out, str(dst / "adapters.safetensors"), metadata={"format": "mlx"})
    config = {"fine_tune_type": "lora", "num_layers": len(layers),
              "lora_parameters": {"rank": r, "scale": scale, "dropout": float(cfg.get("lora_dropout") or 0.0), "keys": keys},
              "model": model, "source": "peft", "peft_base": cfg.get("base_model_name_or_path")}
    (dst / "adapter_config.json").write_text(json.dumps(config, indent=4) + "\n")
    return {"tensors": len(out), "layers": [layers[0], layers[-1]], "keys": keys, "rank": r, "scale": scale}


def main(argv=None):
    p = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    p.add_argument("src"); p.add_argument("dst")
    p.add_argument("--total-layers", type=int); p.add_argument("--model")
    a = p.parse_args(argv)
    print(json.dumps(convert(a.src, a.dst, a.total_layers, a.model)))


if __name__ == "__main__":
    sys.exit(main())

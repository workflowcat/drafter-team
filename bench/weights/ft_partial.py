"""Item B1: partial full fine-tune. The last N transformer blocks (and, with --head, the tied input/output embedding)
of the unquantized Qwen3 1.7B are trained on his lines, then the model is quantized back (4-bit everywhere, or the
trained blocks at 8-bit) into one model folder that loads with no adapter and no merge step.

Why the unquantized base: on the 4-bit base mlx-lm's `--fine-tune-type full` unfreezes the packed 4-bit integers, which
cannot take gradients; only norms would learn. Base: mlx-community/Qwen3-1.7B-bf16 at REVISION (3.44 GB, one file).

    .venv/bin/python -B bench/weights/ft_partial.py --download            # once: fetch the base (3.44 GB), nothing else
    .venv/bin/python -B bench/weights/ft_partial.py --smoke               # 10 steps, 3 held lines
    .venv/bin/python -B bench/weights/ft_partial.py --only last4          # one variant
Variants (VARIANTS): last4, last8, last4-live (starts from the live layer merged into the base), last2-head.
Each variant writes bench/out/weights/ft-<variant>-q4 and -q8 (trained blocks at 8 bits), records and scores both,
and reports how much of the trained change survives quantization (cosine and size of the quantized change against the
trained change, per trained matrix). Output: data/bench/weights/ft-<variant>.json.
Internals: --worker train|quant run in their own guarded process; never call them by hand without guarded.py."""
import argparse, json, os, sys, time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import common as C

REPO = "mlx-community/Qwen3-1.7B-bf16"
REVISION = "9cd6692855d3e06772228e9a962b2606359b2d24"    # model.safetensors 3,441 MB (Hugging Face, 2026-11-14)
VARIANTS = {   # blocks from the end, head (tied embedding) trained too, start from the live layer, lr, iters, cap GB
    "last4": {"blocks": 4, "head": False, "from_live": False, "lr": 1e-5, "iters": 1500, "cap": 9.0},
    "last8": {"blocks": 8, "head": False, "from_live": False, "lr": 1e-5, "iters": 1500, "cap": 11.0},
    "last4-live": {"blocks": 4, "head": False, "from_live": True, "lr": 1e-5, "iters": 1000, "cap": 9.0},
    "last2-head": {"blocks": 2, "head": True, "from_live": False, "lr": 5e-6, "iters": 1500, "cap": 13.0},
}


def base_path(download=False):
    from huggingface_hub import snapshot_download
    if download:
        os.environ["HF_HUB_OFFLINE"] = "0"
        return snapshot_download(REPO, revision=REVISION, allow_patterns=["*.json", "*.safetensors", "*.txt", "*.jinja"])
    try: return snapshot_download(REPO, revision=REVISION, local_files_only=True)
    except Exception:
        raise SystemExit(f"{REPO} is not downloaded: .venv/bin/python -B bench/weights/ft_partial.py --download (3.44 GB)")


# ---- worker steps (one model, this process) ----

def load_base(path, from_live):
    """The bf16 base; with from_live, his live LoRA merged into it in bf16 (the layer was trained on the 4-bit base,
    so this start is close to, not equal to, the live model)."""
    from mlx_lm import load
    from mlx.utils import tree_unflatten
    model, tok, config = load(path, adapter_path=str(C.ROOT / C.LIVE) if from_live else None, return_config=True)
    if from_live:
        fused = [(n, m.fuse(dequantize=True)) for n, m in model.named_modules() if hasattr(m, "fuse")]
        model.update_modules(tree_unflatten(fused))
    return model, tok, config


def trained_keys(model, blocks, head):
    from mlx.utils import tree_flatten
    n = len(model.layers)
    pre = tuple(f"model.layers.{i}." for i in range(n - blocks, n)) + (("model.embed_tokens.",) if head else ())
    return [k for k, _ in tree_flatten(model.parameters()) if k.startswith(pre) and "norm" not in k]


def worker_train(a, v):
    import mlx.core as mx, mlx.optimizers as optim
    from types import SimpleNamespace
    from mlx.utils import tree_flatten
    from mlx_lm.tuner.trainer import train, TrainingArgs
    from mlx_lm.tuner.datasets import load_dataset, CacheDataset
    model, tok, _ = load_base(base_path(), v["from_live"])
    model.freeze()
    parts = list(model.layers[-v["blocks"]:]) + ([model.model.embed_tokens] if v["head"] else [])
    for p in parts:
        p.set_dtype(mx.float32)    # bf16 weights cannot take steps of 1e-5 (one bf16 step near 0.02 is ~8e-5)
        p.unfreeze()
    args = SimpleNamespace(data=str(a.data), train=True, test=False, mask_prompt=False, hf_dataset=False)
    train_set, valid_set, _ = load_dataset(args, tok)
    out = Path(a.out); out.mkdir(parents=True, exist_ok=True)
    n_train = sum(x.size for _, x in tree_flatten(model.trainable_parameters()))
    print(f"trainable {n_train / 1e6:.1f}M parameters", flush=True)
    iters = 10 if a.smoke else v["iters"]
    train(model=model, optimizer=optim.AdamW(learning_rate=v["lr"], weight_decay=0.0),
          train_dataset=CacheDataset(train_set), val_dataset=CacheDataset(valid_set),
          args=TrainingArgs(batch_size=4, iters=iters, val_batches=20, steps_per_report=10,
                            steps_per_eval=5 if a.smoke else 250, steps_per_save=iters + 1, max_seq_length=256,
                            adapter_file=str(out / "trained.safetensors"), grad_checkpoint=False))
    print(f"saved {out / 'trained.safetensors'}; peak {mx.get_peak_memory() / 2**30:.2f} GB", flush=True)


def worker_quant(a, v):
    """Base (+ live) with the trained weights in, quantized: 4-bit, the trained blocks at a.bits. Then how much of the
    trained change is left after quantization, per trained matrix."""
    import mlx.core as mx, numpy as np
    from mlx.utils import tree_flatten
    from mlx_lm.utils import quantize_model, save
    path = base_path()
    model, tok, config = load_base(path, v["from_live"])
    keys = trained_keys(model, v["blocks"], v["head"])
    before = {k: x for k, x in tree_flatten(model.parameters()) if k in keys and x.ndim == 2}
    trained = mx.load(str(Path(a.out) / "trained.safetensors"))
    model.load_weights([(k, x.astype(mx.bfloat16)) for k, x in trained.items()], strict=False)
    after = {k: x for k, x in tree_flatten(model.parameters()) if k in before}
    survive = []
    q = lambda x: mx.dequantize(*mx.quantize(x, group_size=64, bits=a.bits), group_size=64, bits=a.bits)
    for k in before:
        d_true = (after[k].astype(mx.float32) - before[k].astype(mx.float32))
        d_q = q(after[k]).astype(mx.float32) - q(before[k]).astype(mx.float32)
        nt, nq = float(mx.linalg.norm(d_true.reshape(-1)).item()), float(mx.linalg.norm(d_q.reshape(-1)).item())
        cos = float((d_true * d_q).sum().item()) / max(nt * nq, 1e-12)
        rel = nt / max(float(mx.linalg.norm(before[k].astype(mx.float32).reshape(-1)).item()), 1e-12)
        survive.append((k, round(nq / max(nt, 1e-12), 3), round(cos, 3), round(rel, 6)))
        mx.clear_cache()
    n = len(model.layers)
    touched = tuple(f"model.layers.{i}." for i in range(n - v["blocks"], n)) + (("model.embed_tokens",) if v["head"] else ())
    pred = lambda p, m: ({"group_size": 64, "bits": a.bits} if p.startswith(touched) else True) if hasattr(m, "to_quantized") else False
    model, config = quantize_model(model, config, 64, 4, quant_predicate=pred)
    dst = Path(a.out + f"-q{a.bits}")
    save(dst, path, model, tok, config)
    size = sum(f.stat().st_size for f in dst.glob("*.safetensors"))
    (Path(a.out) / f"survive-q{a.bits}.json").write_text(json.dumps({
        "matrices": len(survive), "size_ratio_median": float(np.median([s[1] for s in survive])) if survive else None,
        "cosine_median": float(np.median([s[2] for s in survive])) if survive else None,
        "change_rel_median": float(np.median([s[3] for s in survive])) if survive else None,
        "folder_gb": round(size / 1e9, 3)}))
    print(f"quantized to {dst} ({size / 1e9:.2f} GB), peak {mx.get_peak_memory() / 2**30:.2f} GB", flush=True)


# ---- orchestrator ----

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--smoke", action="store_true")
    ap.add_argument("--only", default=None)
    ap.add_argument("--set", default=None)
    ap.add_argument("--bits", default="4,8")
    ap.add_argument("--download", action="store_true")
    ap.add_argument("--sleep-engine", action="store_true")
    ap.add_argument("--worker", choices=["train", "quant"])
    ap.add_argument("--variant"); ap.add_argument("--data"); ap.add_argument("--out"); ap.add_argument("--bit", type=int)
    a = ap.parse_args()
    if a.worker:
        a.bits = a.bit
        return (worker_train if a.worker == "train" else worker_quant)(a, VARIANTS[a.variant])
    if a.download:
        print(f"downloaded to {base_path(download=True)}"); return
    C.need_data(); base_path()
    import recency
    from train_sweep import MIX
    names = a.only.split(",") if a.only else (["last4"] if a.smoke else list(VARIANTS))
    set_path = C.held_set(a.set)
    tag = "-smoke" if a.smoke else ""
    from train_sweep import data_key
    data_dir = C.WORK / f"train-{data_key(set_path, MIX)}-flat"
    if not (data_dir / "train.jsonl").exists() or a.smoke:
        info = recency.build(data_dir, MIX, C.cut_time(), C.held_lines(set_path))
        (data_dir / "info.json").write_text(json.dumps(info))
    from contextlib import nullcontext
    from retrain import sleeping_engine
    me = Path(__file__)
    with (sleeping_engine() if a.sleep_engine else nullcontext()):
        live = C.baseline(a.set, a.smoke)
        for name in names:
            v, out = VARIANTS[name], C.OUT / f"ft-{name}{tag}"
            t = time.time()
            common = ["--variant", name, "--data", data_dir, "--out", out] + (["--smoke"] if a.smoke else [])
            code, lines = C.guarded(me, ["--worker", "train", *common], v["cap"], timeout=6 * 3600,
                                    log=C.RESULTS / "logs" / f"ft-{name}{tag}-train.log")
            if code: raise SystemExit(f"{name}: training failed ({code}): {lines[-1:]}")
            res = {"variant": name, "recipe": v, "base": f"{REPO}@{REVISION[:8]}", "mix": MIX,
                   "train": {"seconds": round(time.time() - t), **C.peak_and_loss(lines)}, "live": live, "smoke": a.smoke}
            for bits in [int(b) for b in a.bits.split(",")]:
                code, lines = C.guarded(me, ["--worker", "quant", "--bit", bits, *common], 8.0,
                                        log=C.RESULTS / "logs" / f"ft-{name}{tag}-q{bits}.log")
                if code: raise SystemExit(f"{name}: quantizing failed ({code}): {lines[-1:]}")
                rec = C.record(f"weights-ft-{name}-q{bits}{tag}", repo=str(Path(f"{out}-q{bits}")), set_path=set_path, smoke=a.smoke)
                s = C.score(rec, set_path, a.smoke)
                res[f"q{bits}"] = {"survive": json.loads((out / f"survive-q{bits}.json").read_text()), "score": s,
                                   "vs_live": C.versus(s, live)}
                print(f"{name} q{bits}: {s} vs live {res[f'q{bits}']['vs_live']}", flush=True)
            C.write(f"ft-{name}{tag}", res)


if __name__ == "__main__":
    main()

"""Big-model round (2026-11-15): the guarded model steps, one at a time. Loads no model itself.

    .venv/bin/python -B bench/big/run.py rec <candidate> [--adapter bench/out/big/<name>] [--label L] [--smoke] [--no-stable]
    .venv/bin/python -B bench/big/run.py train <candidate> --data data/bench/big/work/ctx-flat --name <name> [--smoke] [--sleep-engine]
    .venv/bin/python -B bench/big/run.py train <candidate> --plain --data data/train --name <name> [--smoke]

rec: the held set (data/bench/weights/held-137.json) as Drafter types it, 24 tokens a key (bench/typebench.py through
bench/models/record.py), with the copy after the screen text for caches that cannot be cut back.
-> data/bench/big-<label>.jsonl. train: his layer with the live recipe (LoRA rank 8, scale 20, 16 layers, lr 1e-4,
1,500 steps) on prompt/completion rows (bench/big/ctx_train.py), the prompt masked, 1,024 tokens a row.
-> bench/out/big/<name>/ (never data/adapters*). Each step: on mains power only, 25 % or more memory free, under the
memory guard."""
import argparse, json, subprocess, sys, time
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent.parent
sys.path.insert(0, str(ROOT / "bench/models"))
import shared as S

OUT = ROOT / "bench/out/big"
LOGS = S.W.DATA / "bench/big/logs"


def on_power():
    s = subprocess.run(["pmset", "-g", "batt"], capture_output=True, text=True).stdout
    return "AC Power" in s.splitlines()[0] if s else True


def checks():
    if not on_power(): raise SystemExit("on battery: not starting a model step")
    free = S.W.free_pct()
    if free < 25: raise SystemExit(f"free memory {free}% (under 25%): not starting")


def rec(a):
    checks()
    label = "big-" + (a.label or (a.candidate + ("-" + Path(a.adapter).name if a.adapter else "-base")))
    if a.smoke: label += "-smoke"
    extra = ["--tokens", "24"] + (["--no-stable"] if a.no_stable else []) + (["--strength", str(a.strength)] if a.strength != 1.0 else [])
    t = time.time()
    p, lines = S.record(label, a.candidate, adapter=a.adapter, set_path=a.set, smoke=a.smoke, extra=extra)
    (LOGS).mkdir(parents=True, exist_ok=True)
    info = {"label": label, "candidate": a.candidate, "adapter": a.adapter, "seconds": round(time.time() - t),
            "peak_gb": S.peak_gb(lines), "load": " ".join(l for l in lines if "loaded in" in l)[:200],
            "last": lines[-1][:200] if lines else "", "uptime": subprocess.run(["uptime"], capture_output=True, text=True).stdout.strip()}
    (LOGS / f"{label}.json").write_text(json.dumps(info, indent=1))
    print(json.dumps(info, indent=1))


def no_held(data, set_path=S.SET):
    """Refuse a {"text"} training folder that holds a held-set line or a near-copy (bench/held.py). -> rows checked."""
    from held import Held
    is_held = Held([x["text"] for x in json.loads((ROOT / set_path).read_text())])
    n = 0
    for f in ("train.jsonl", "valid.jsonl"):
        for l in (ROOT / data / f).read_text().splitlines():
            t = json.loads(l)["text"].split("\n", 1)[-1]
            n += 1
            if is_held(t): raise SystemExit(f"{data}/{f} holds a held-set line: not training")
    return n


def train(a):
    checks()
    if a.plain: print(f"held check: {no_held(a.data)} rows, none held")
    c = S.candidate(a.candidate)
    out = OUT / (a.name + ("-smoke" if a.smoke else ""))
    out.mkdir(parents=True, exist_ok=True)
    keys = ""
    if a.attn_only:   # LoRA only on full-attention layers' attention (Qwen3.5: 6 of 24 layers have self_attn)
        keys = "  keys: [" + ", ".join(f'"self_attn.{k}_proj"' for k in "qkvo") + "]\n"
    (out / "recipe.yaml").write_text(f"lora_parameters:\n  rank: 8\n  scale: {a.scale}\n  dropout: 0.0\n{keys}")
    iters = 20 if a.smoke else a.iters
    model = c["repo"]
    if c.get("rev"):
        from huggingface_hub import snapshot_download
        model = snapshot_download(c["repo"], revision=c["rev"], local_files_only=True)
    args = ["--model", model, "--train", "--data", str(ROOT / a.data), "--adapter-path", str(out),
            "-c", str(out / "recipe.yaml"), "--fine-tune-type", "lora", "--num-layers", str(a.layers), "--learning-rate", str(a.lr),
            "--iters", str(iters), "--batch-size", str(min(4, c["batch"]) if a.batch is None else a.batch),
            "--grad-checkpoint", "--grad-accumulation-steps", str(a.accum), "--steps-per-report", "10", "--val-batches", "20", "--save-every", str(min(iters, 400)), "--seed", "7"]
    if a.plain:
        # the live layer's own recipe (bench/train.py): {"text"} rows from bench/make_train.py, 256 tokens, no mask
        script, args = "-m", ["mlx_lm.lora", *args, "--max-seq-length", "256", "--steps-per-eval", "10" if a.smoke else "200"]
    else:
        script, args = HERE / "ctx_train.py", ["train", *args, "--max-seq-length", "1024", "--mask-prompt",
                                               "--steps-per-eval", "10" if a.smoke else "250"]
    cap = a.cap or c["train_cap"]
    from contextlib import nullcontext
    from retrain import sleeping_engine
    t = time.time()
    with (sleeping_engine() if a.sleep_engine else nullcontext()):
        env = {"DRAFTER_MLX_CACHE_GB": str(a.mlx_cache)} if a.mlx_cache else None
        code, lines = S.W.guarded(script, args, cap, timeout=6 * 3600, env=env, log=LOGS / f"train-{out.name}.log")
    info = {"name": out.name, "candidate": a.candidate, "data": a.data, "seconds": round(time.time() - t), "cap_gb": cap,
            "plain": a.plain, "batch": a.batch, "accum": a.accum, "lr": a.lr, "scale": a.scale, "layers": a.layers, "attn_only": a.attn_only, "iters": iters, "exit": code, **S.W.peak_and_loss(lines), "adapter": str(out.relative_to(ROOT))}
    (out / "train-info.json").write_text(json.dumps(info, indent=1))
    print(json.dumps(info, indent=1))
    if code or not (out / "adapters.safetensors").exists(): raise SystemExit(f"training failed: {lines[-3:]}")


def main():
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("rec"); p.add_argument("candidate"); p.add_argument("--adapter"); p.add_argument("--label")
    p.add_argument("--smoke", action="store_true"); p.add_argument("--no-stable", action="store_true")
    p.add_argument("--strength", type=float, default=1.0, help="his layer's merge scale 0..1 (engine strength)")
    p.add_argument("--set", default=None, help="another held set, e.g. data/bench/big/held-slice.json (bench/big/slice.py)")
    p = sub.add_parser("train"); p.add_argument("candidate"); p.add_argument("--data", required=True); p.add_argument("--name", required=True)
    p.add_argument("--smoke", action="store_true"); p.add_argument("--sleep-engine", action="store_true")
    p.add_argument("--plain", action="store_true", help="live recipe on {text} rows (data/train), as bench/train.py")
    p.add_argument("--accum", type=int, default=1, help="gradient accumulation (batch 2 x 2 = the live batch 4)")
    p.add_argument("--iters", type=int, default=1500); p.add_argument("--batch", type=int, default=None); p.add_argument("--cap", type=float, default=None)
    p.add_argument("--mlx-cache", type=float, default=None, help="MLX buffer cache limit in GB (footprint under the cap)")
    p.add_argument("--lr", type=float, default=1e-4); p.add_argument("--scale", type=float, default=20.0)
    p.add_argument("--layers", type=int, default=16, help="last N layers get LoRA (Qwen3.5 has 24)")
    p.add_argument("--attn-only", action="store_true", help="LoRA keys = self_attn q/k/v/o only (Qwen3.5: the 6 full-attention layers with --layers 24)")
    a = ap.parse_args()
    {"rec": rec, "train": train}[a.cmd](a)


if __name__ == "__main__":
    main()

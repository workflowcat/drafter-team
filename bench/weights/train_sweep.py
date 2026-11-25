"""Item A: training variants of his layer through the installed mlx-lm (0.32.2): LoRA vs DoRA, rank, number of layers,
learning rate and schedule, iterations, recency weighting. Each variant is trained, recorded on the held-out set and
scored like the weekly retrain, against the live layer.

    .venv/bin/python -B bench/weights/train_sweep.py --smoke                 # 20 steps, 3 lines: checks the plumbing
    .venv/bin/python -B bench/weights/train_sweep.py --only ref,dora        # the named variants, in that order
    .venv/bin/python -B bench/weights/train_sweep.py --list                  # the variants and what each changes
Options: --set <held set json> (default data/replay-fresh.json), --weights '<json per source>' (default MIX below),
--sleep-engine (unload the running Drafter model while this runs, like the retrain).

Every variant trains on the same lines (same mix, same held-out cut, same valid split); only the recipe moves, and
`recency-*` moves the mix toward newer lines. `ref` is the live recipe on these lines, so `ref` vs live says what new
lines alone do, and each variant vs `ref` says what the recipe does. One model per process, one process at a time.
Output: data/bench/weights/train-<variant>.json; the layer in bench/out/weights/<variant>/ (promote by hand only)."""
import argparse, json, sys, time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import common as C
import recency

# the 14 November every-source mix (docs/rounds/2026-11-13-typing.md, round three): chats sampled at 0.1 so 60,000
# Beeper lines do not drown his prompts; takes left out (they add fillers). corpus.WEIGHTS (the nightly) is the
# same mix since 14 November (tests/test_corpus.py checks it).
MIX = {"typed": 2, "cc": 1, "codex": 1, "vnotes": 0.5, "fb": 0.5, "vault": 0.5, "beeper": 0.1, "import": 1}
LIVE = {"fine_tune_type": "lora", "rank": 8, "scale": 20.0, "num_layers": 16, "lr": 1e-4, "iters": 1500, "batch": 4}

VARIANTS = {   # name: what changes from the live recipe (bench/train.py), in the recommended order
    "ref": {},
    "dora": {"fine_tune_type": "dora"},
    "recency-60": {"half_life": 60},
    "recency-21": {"half_life": 21},
    "r16": {"rank": 16, "scale": 10.0},          # scale x rank kept the same: the update size stays comparable
    "r4": {"rank": 4, "scale": 40.0},
    "layers-28": {"num_layers": -1},
    "layers-8": {"num_layers": 8},
    "lr-5e-5": {"lr": 5e-5},
    "lr-2e-4": {"lr": 2e-4},
    "cosine": {"schedule": {"name": "cosine_decay", "warmup": 100, "warmup_init": 1e-6}},
    "iters-3000": {"iters": 3000},
    "iters-750": {"iters": 750},
}


def data_key(set_path, weights):
    """Training files are reused only for the same held set, mix and corpus."""
    import hashlib, typescore
    corpus = C.DATA / "corpus.jsonl"
    return hashlib.sha1(f"{typescore.set_sha(set_path)}{json.dumps(weights, sort_keys=True)}{corpus.stat().st_mtime}".encode()).hexdigest()[:10]


def recipe(name):
    return {**LIVE, **VARIANTS[name]}


def config_yaml(r, path):
    """The parts mlx_lm.lora takes only from a config file: LoRA rank/scale and the learning-rate schedule."""
    lines = ["lora_parameters:", f"  rank: {r['rank']}", f"  scale: {r['scale']}", "  dropout: 0.0"]
    if r.get("schedule"):
        s = r["schedule"]
        lines += ["lr_schedule:", f"  name: {s['name']}", f"  arguments: [{r['lr']}, {r['iters']}, 0.0]",
                  f"  warmup: {s.get('warmup', 0)}", f"  warmup_init: {s.get('warmup_init', 0.0)}"]
    Path(path).write_text("\n".join(lines) + "\n")


def train(name, r, data_dir, smoke):
    out = C.OUT / name
    out.mkdir(parents=True, exist_ok=True)
    cfg = out / "recipe.yaml"
    config_yaml(r, cfg)
    iters = 20 if smoke else r["iters"]
    args = [iters, "--adapter-path", out, "--data", data_dir, "-c", cfg, "--fine-tune-type", r["fine_tune_type"],
            "--num-layers", r["num_layers"], "--learning-rate", r["lr"], "--batch-size", r["batch"],
            "--save-every", max(iters, 1), "--steps-per-eval", 10 if smoke else 250]
    cap = 7.0 if r["num_layers"] == -1 or r["fine_tune_type"] == "dora" else 6.0
    t = time.time()
    # bench/train.py starts its own guard from DRAFTER_TRAIN_CAP_GB, which replaces the outer cap: keep them equal
    code, lines = C.guarded(C.ROOT / "bench/train.py", args, cap, timeout=4 * 3600, env={"DRAFTER_TRAIN_CAP_GB": str(cap)},
                            log=C.RESULTS / "logs" / f"train-{name}.log")
    if code or not (out / "adapters.safetensors").exists():
        raise RuntimeError(f"{name}: training failed ({code}): {lines[-1:]}")
    return {"seconds": round(time.time() - t), "cap_gb": cap, **C.peak_and_loss(lines), "adapter": str(out.relative_to(C.ROOT))}


def record_target(name, r):
    """(model folder or repo, adapter) to record a trained variant with. The engine's in-memory merge
    (Model.fuse_lora) knows only LoRA layers: a DoRA layer would run unmerged, about 3x slower a token (the 14 November
    run reached 17 % of the set in 85 min). So DoRA is fused on disk first (mlx_lm fuse) and recorded with no adapter."""
    if r["fine_tune_type"] == "dora":
        return str(C.OUT / f"{name}-fused"), None
    return C.BASE, C.OUT.relative_to(C.ROOT) / name


def fuse(name):
    dst = C.OUT / f"{name}-fused"
    if (dst / "config.json").exists(): return
    code, lines = C.guarded("-m", ["mlx_lm", "fuse", "--model", C.BASE, "--adapter-path", C.OUT / name, "--save-path", dst],
                            4.0, log=C.RESULTS / "logs" / f"fuse-{name}.log")
    if code or not (dst / "config.json").exists(): raise RuntimeError(f"{name}: fuse failed ({code}): {lines[-1:]}")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--smoke", action="store_true")
    ap.add_argument("--only", default=None)
    ap.add_argument("--list", action="store_true")
    ap.add_argument("--set", default=None)
    ap.add_argument("--weights", default=None)
    ap.add_argument("--sleep-engine", action="store_true")
    ap.add_argument("--reuse", action="store_true", help="a variant already trained in bench/out/weights: record it only")
    a = ap.parse_args()
    if a.list:
        for n in VARIANTS: print(f"{n:12} {VARIANTS[n] or 'the live recipe'}")
        return
    C.need_data()
    names = a.only.split(",") if a.only else (["ref"] if a.smoke else list(VARIANTS))
    unknown = [n for n in names if n not in VARIANTS]
    if unknown: raise SystemExit(f"unknown variants {unknown}; --list shows them")
    weights = json.loads(a.weights) if a.weights else MIX
    set_path = C.held_set(a.set)
    is_held, cut = C.held_lines(set_path), C.cut_time()
    from contextlib import nullcontext
    from retrain import sleeping_engine
    with (sleeping_engine() if a.sleep_engine else nullcontext()):
        live = C.baseline(a.set, a.smoke)
        print(f"live layer: {live}", flush=True)
        for name in names:
            r = recipe(name)
            data_dir = C.WORK / f"train-{data_key(set_path, weights)}-{r.get('half_life') or 'flat'}"
            if not (data_dir / "train.jsonl").exists() or a.smoke:
                info = recency.build(data_dir, weights, cut, is_held, r.get("half_life"))
                (data_dir / "info.json").write_text(json.dumps(info))
            info = json.loads((data_dir / "info.json").read_text())
            if a.reuse and (C.OUT / name / "adapters.safetensors").exists():
                tr = {"reused": True, "adapter": str((C.OUT / name).relative_to(C.ROOT)),
                      **C.peak_and_loss((C.RESULTS / "logs" / f"train-{name}.log").read_text().splitlines())}
            else:
                tr = train(name, r, data_dir, a.smoke)
            if r["fine_tune_type"] == "dora": fuse(name)
            label = f"weights-{name}" + ("-smoke" if a.smoke else "")
            repo, adapter = record_target(name, r)
            rec = C.record(label, repo=repo, adapter=adapter, set_path=set_path, smoke=a.smoke)
            s = C.score(rec, set_path, a.smoke)
            res = {"variant": name, "recipe": r, "mix": weights, "data": {k: v for k, v in info.items() if k != "per_source"},
                   "lines_per_source": info.get("per_source"), "train": tr, "score": s, "live": live, "vs_live": C.versus(s, live),
                   "smoke": a.smoke}
            p = C.write(f"train-{name}" + ("-smoke" if a.smoke else ""), res)
            print(f"{name}: {s} vs live {res['vs_live']} -> {p.relative_to(C.ROOT)}", flush=True)


if __name__ == "__main__":
    main()

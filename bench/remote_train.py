"""Your layer trained on your own Linux server (integrations.server in data/drafter.local.json: an ssh alias with
Docker) instead of the Mac: CPU only, in a container. Off unless that integration is on.

    .venv/bin/python -B bench/remote_train.py --out data/adapters-new [--model REPO|4b|1.7b]   # what retrain.py --remote runs
    .venv/bin/python -B bench/remote_train.py --smoke [--model 4b]      # 50 made-up lines, a few steps: no data/ read
    .venv/bin/python -B bench/remote_train.py --dry-run [--smoke]       # prints every remote command, runs none

What goes to the server: the training lines retrain.py already selected (data/train/train.jsonl and valid.jsonl, the
"text" field only, copied to a temp folder first), bench/remote/Dockerfile and bench/remote/train_lora.py. They go to
~/drafter-train/run-<timestamp>/; the container (`nice -n 19`, --cpus 10, --memory 24g) trains there with the Hugging
Face base from the volume drafter-hf-cache. Back comes only the PEFT adapter, meta.json and train.log; the Mac turns
the adapter into the MLX layer (bench/remote/peft_to_mlx.py). The run folder and the container are removed in a
finally, on success and on failure. Promotion stays with retrain.py's compare and gate on the Mac."""
import argparse, json, shlex, shutil, subprocess, sys, tempfile, time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "bench")); sys.path.insert(0, str(ROOT / "bench/remote"))
from lora_recipe import RECIPE, HF_BASE, SHORT

sys.path.insert(0, str(ROOT / "engine"))
import local as _local
HOST = str(_local.setting("server", "host") or "").strip()   # the ssh alias (team round, 25 November 2026)


def server_on():
    return _local.enabled("server") and bool(HOST)


IMAGE = "drafter-train"
CACHE = "drafter-hf-cache"
BACK = ("adapter_model.safetensors", "adapter_config.json", "meta.json", "train.log")
SMOKE_ITERS = 5


def hf_base(model):
    repo = SHORT.get(model, model)
    if repo not in HF_BASE: raise SystemExit(f"no Hugging Face base known for {model!r}: one of {sorted(HF_BASE)} or {sorted(SHORT)}")
    return repo, HF_BASE[repo]


def export_lines(train_dir, dest):
    """data/train/{train,valid}.jsonl -> dest, the "text" field only. -> (train rows, valid rows)."""
    dest.mkdir(parents=True, exist_ok=True)
    counts = []
    for name in ("train.jsonl", "valid.jsonl"):
        rows = [json.loads(l)["text"] for l in (Path(train_dir) / name).read_text(encoding="utf-8").splitlines() if l.strip()]
        (dest / name).write_text("".join(json.dumps({"text": t}, ensure_ascii=False) + "\n" for t in rows), encoding="utf-8")
        counts.append(len(rows))
    return tuple(counts)


def smoke_lines(dest, n=50):
    """50 made-up lines in the "[App]\\ntext" shape make_train.py writes: 45 train, 5 valid."""
    apps = ["Beeper", "Claude", "Codex"]
    words = ["meeting", "draft", "tomorrow", "invoice", "the plan", "a quick call", "the deck", "Friday", "notes", "budget"]
    rows = [f"[{apps[i % 3]}]\nmade-up line {i}: send {words[i % 10]} and {words[(i * 3 + 1) % 10]} before {words[(i + 7) % 10]}"
            for i in range(n)]
    dest.mkdir(parents=True, exist_ok=True)
    for name, part in (("train.jsonl", rows[:n - 5]), ("valid.jsonl", rows[n - 5:])):
        (dest / name).write_text("".join(json.dumps({"text": t}) + "\n" for t in part))
    return n - 5, 5


def plan(stamp, base, iters, cpus, memory, grad_checkpoint=False):
    """The remote commands of one run, in order: (name, argv). Paths relative to the server home (ssh and rsync start
    there); docker -v needs absolute ones, so those use $HOME inside the remote shell."""
    run = f"drafter-train/run-{stamp}"
    name = f"drafter-train-{stamp}"
    r = RECIPE
    train = ["nice", "-n", "19", "python", "/app/train_lora.py", "--base", base, "--data", "/work/data", "--out", "/work/out",
             "--iters", str(iters), "--batch", str(r["batch"]), "--lr", str(r["lr"]), "--rank", str(r["rank"]),
             "--scale", str(r["scale"]), "--layers", str(r["layers"]), "--max-seq", str(r["max_seq"]), "--seed", str(r["seed"]),
             "--steps-per-eval", str(r["steps_per_eval"]), "--val-batches", str(r["val_batches"]), "--threads", str(cpus)]
    if grad_checkpoint: train.append("--grad-checkpoint")
    docker = ["docker", "run", "--rm", "--name", name, "--cpus", str(cpus), "--memory", memory, "--memory-swap", memory,
              "-e", f"OMP_NUM_THREADS={cpus}", "-v", f"{CACHE}:/cache",
              "-v", f"$HOME/{run}/data:/work/data:ro", "-v", f"$HOME/{run}/out:/work/out", IMAGE, *train]
    q = lambda argv: " ".join(a if a.startswith("$HOME/") else shlex.quote(a) for a in argv)
    return run, name, [
        ("mkdir", ["ssh", HOST, f"mkdir -p drafter-train/image {run}/data {run}/out"]),
        ("image files", ["rsync", "-a", str(ROOT / "bench/remote/Dockerfile"), str(ROOT / "bench/remote/train_lora.py"), f"{HOST}:drafter-train/image/"]),
        ("build", ["ssh", HOST, f"docker build -q -t {IMAGE} drafter-train/image"]),
        ("lines up", ["rsync", "-a", "{lines}/", f"{HOST}:{run}/data/"]),
        ("train", ["ssh", HOST, q(docker)]),
        ("back", ["rsync", "-a", *[f"--include={f}" for f in BACK], "--exclude=*", f"{HOST}:{run}/out/", "{back}/"]),
    ]


def cleanup_cmd(run, name):
    return ["ssh", HOST, f"docker rm -f {name} >/dev/null 2>&1; rm -rf {run}; test ! -e {run}"]


def train_remote(out=None, model="4b", train_dir=ROOT / "data/train", smoke=False, dry_run=False, iters=None,
                 cpus=10, memory="24g", timeout_h=14.0, grad_checkpoint=False, runner=None, say=print):
    """One remote run. -> meta dict (empty on a dry run). Raises on any failed step; the server folder goes anyway."""
    runner = runner or (lambda argv, timeout: subprocess.run(argv, check=True, timeout=timeout, stdin=subprocess.DEVNULL))
    repo, base = hf_base(model)
    iters = iters or (SMOKE_ITERS if smoke else RECIPE["iters"])
    stamp = time.strftime("%Y%m%d-%H%M%S")
    run, name, steps = plan(stamp, base, iters, cpus, memory, grad_checkpoint)
    t0, meta = time.time(), {}
    with tempfile.TemporaryDirectory(prefix="drafter-remote-") as tmp:
        lines, back = Path(tmp) / "lines", Path(tmp) / "back"
        n = smoke_lines(lines) if smoke else export_lines(train_dir, lines)
        say(f"remote training of {repo} ({base}) on {HOST}: {n[0]} train + {n[1]} valid lines, {iters} steps")
        back.mkdir()
        try:
            for label, argv in steps:
                argv = [a.replace("{lines}", str(lines)).replace("{back}", str(back)) for a in argv]
                say(f"[{label}] {shlex.join(argv)}")
                if not dry_run: runner(argv, timeout_h * 3600 if label == "train" else 1800)
        finally:
            argv = cleanup_cmd(run, name)
            say(f"[clean] {shlex.join(argv)}")
            if not dry_run:
                try: runner(argv, 300)
                except Exception as e:
                    say(f"WARNING: the run folder may still be on {HOST}: {run} ({e}); delete it: ssh {HOST} 'rm -rf {run}'")
                    raise
        if dry_run:
            say("dry run: nothing ran"); return {}
        missing = [f for f in BACK if not (back / f).exists()]
        if missing: raise RuntimeError(f"not back from {HOST}: {missing}")
        meta = json.loads((back / "meta.json").read_text())
        dest = Path(out) if out else ROOT / "bench/out/remote" / f"{'smoke' if smoke else 'run'}-{stamp}"
        from peft_to_mlx import convert
        info = convert(back, dest, total_layers=meta.get("num_hidden_layers"), model=repo)
        shutil.copy(back / "train.log", dest / "remote-train.log")
        (dest / "remote-meta.json").write_text(json.dumps(meta, indent=1))
        wall = time.time() - t0
        say(f"layer: {dest} ({info['tensors']} tensors, layers {info['layers'][0]}-{info['layers'][1]})")
        say(f"time: {wall / 60:.1f} min wall, training {meta['seconds'] / 3600:.2f} h ({meta['sec_per_step']} s/step); "
            f"peak memory {meta.get('peak_gb_cgroup')} GB (container), {meta.get('peak_gb_rss')} GB (trainer)")
        if smoke:
            say(f"a full run of {RECIPE['iters']} steps at this pace: about {meta['sec_per_step'] * RECIPE['iters'] / 3600:.1f} h "
                f"(made-up lines are short; his rows run longer)")
        meta["wall_seconds"] = round(wall)
    return meta


def main(argv=None):
    p = argparse.ArgumentParser(description="your layer trained on your server (integrations.server)")
    p.add_argument("--out", help="MLX layer folder (default bench/out/remote/<run>)")
    p.add_argument("--model", default="4b", help="engine repo or 4b / 1.7b")
    p.add_argument("--train-dir", default=str(ROOT / "data/train"))
    p.add_argument("--smoke", action="store_true"); p.add_argument("--dry-run", action="store_true")
    p.add_argument("--iters", type=int); p.add_argument("--cpus", type=int, default=10); p.add_argument("--memory", default="24g")
    p.add_argument("--timeout-h", type=float, default=14.0); p.add_argument("--grad-checkpoint", action="store_true")
    a = p.parse_args(argv)
    if not server_on() and not a.dry_run:
        print("remote training is off: turn on integrations.server with its ssh host in data/drafter.local.json", file=sys.stderr)
        return 2
    train_remote(a.out, a.model, a.train_dir, a.smoke, a.dry_run, a.iters, a.cpus, a.memory, a.timeout_h, a.grad_checkpoint)


if __name__ == "__main__":
    sys.exit(main())

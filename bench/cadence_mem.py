"""Cadence round, memory trial: the live 1.7B (+ data/adapters) and the 4B (+ data/layers/qwen3-4b) loaded in ONE
process, typing replayed with both (keys alternate by a made-up cadence, plus 4B extensions after 1.7B answers),
then the process's physical footprint (Metal included, engine/guard.py) and MLX peak read once. Model.memory_gb is
process-wide, so it is read once, never summed per model. Prints numbers only.

    DRAFTER_CAP_GB=7.5 .venv/bin/python -B bench/weights/guarded.py 7.5 bench/cadence_mem.py [--lines 10] [--spare 2]
"""
import argparse, json, os, re, subprocess, sys, time
from collections import defaultdict
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
ap = argparse.ArgumentParser()
ap.add_argument("--lines", type=int, default=10)
ap.add_argument("--tokens", type=int, default=12)
ap.add_argument("--set", default="data/bench/weights/held-137.json")
ap.add_argument("--min-free", type=int, default=20, help="stop when system free memory falls under this %%")
a = ap.parse_args()
os.environ.setdefault("DRAFTER_CAP_GB", "7.5")
os.environ.setdefault("HF_HUB_OFFLINE", "1")
sys.path.insert(0, str(ROOT / "engine"))
import guard, catalog
import mlx.core as mx
from mlx_lm.generate import generate_step
from model import Model
from prompt import Builder


def free_pct():
    try:
        s = subprocess.run(["memory_pressure"], capture_output=True, text=True, timeout=10).stdout
        return int(re.search(r"free percentage: (\d+)%", s).group(1))
    except Exception: return 100


def swap():
    return subprocess.run(["sysctl", "-n", "vm.swapusage"], capture_output=True, text=True).stdout.strip()


def snap(tag):
    print(f"{tag}: footprint {guard.footprint_gb():.2f} GB, mlx active {mx.get_active_memory() / 2**30:.2f} GB, "
          f"mlx peak {mx.get_peak_memory() / 2**30:.2f} GB, free {free_pct()}%", flush=True)


print("swap before:", swap(), flush=True)
snap("start")
cat = catalog.load()
big_e = catalog.entry(cat, "qwen3-4b-mine")
t = time.time()
fast = Model("mlx-community/Qwen3-1.7B-4bit", str(ROOT / "data/adapters"))
fb = Builder(fast); fast.warm(fb.head_ids)
snap(f"1.7B loaded ({time.time() - t:.1f} s)")
t = time.time()
big = Model(big_e["repo"], catalog.adapter_for(big_e, str(ROOT / "data/adapters"), ROOT / "data"),
            src=str(catalog.local_path(big_e)) if catalog.local_path(big_e) else None)
bb = Builder(big); big.warm(bb.head_ids)
snap(f"4B loaded too ({time.time() - t:.1f} s)")


def answer(m, b, before, it):
    ids, heal, stable = b.ids_stable(before, it.get("app", ""), it.get("title", ""), it.get("context", ""), "", it.get("clip", ""))
    t0 = time.perf_counter()
    tail = m._feed(ids, stable); m.ids = list(ids)
    first = None
    for tok, _ in generate_step(mx.array(tail), m.model, max_tokens=a.tokens, sampler=m.sampler, prompt_cache=m.cache,
                                prefill_step_size=512):
        m.ids.append(int(tok))
        if first is None: first = (time.perf_counter() - t0) * 1000
    return first or 0.0, (time.perf_counter() - t0) * 1000


items = json.loads((ROOT / a.set).read_text())[: a.lines]
keys = {"fast": 0, "big": 0, "ext": 0}
ms = defaultdict(list)    # model -> [(first token ms, all tokens ms)]
t = time.time()
for i, it in enumerate(items):
    if free_pct() < a.min_free:
        print(f"stopped at line {i}: free memory under {a.min_free}%", flush=True); break
    text = it["text"]
    for pos in range(2, len(text)):
        before = text[:pos]
        if (pos // 4) % 2 == 0:           # a made-up cadence: 4 quick keys to the 1.7B, then 4 slower ones to the 4B
            ms["1.7B"].append(answer(fast, fb, before, it)); keys["fast"] += 1
            if pos % 4 == 3: ms["4B"].append(answer(big, bb, before, it)); keys["ext"] += 1   # an extension in the time left
        else:
            ms["4B"].append(answer(big, bb, before, it)); keys["big"] += 1
    mx.clear_cache()
def q(xs, p): xs = sorted(xs); return xs[min(len(xs) - 1, int(len(xs) * p))] if xs else 0
for k, v in ms.items():
    f = [x[0] for x in v]; w = [x[1] for x in v]
    print(f"{k}: {len(v)} answers, first token p50/p95 {q(f, .5):.0f}/{q(f, .95):.0f} ms, {a.tokens} tokens p50/p95 {q(w, .5):.0f}/{q(w, .95):.0f} ms", flush=True)
snap(f"after typing {sum(keys.values())} answers {keys} in {time.time() - t:.0f} s")
print("swap after:", swap(), flush=True)

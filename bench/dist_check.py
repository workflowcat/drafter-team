"""The kept next-token distribution (round four, 2026-11-14; engine/model.py DIST): same choices as before, less time.

Types the lines of a fresh set key by key, twice on one loaded model: once the way the engine does now (Model._reuse
and Model._steps: inside a half word the first token comes from the kept distribution, no forward pass), once the old
way (Model._feed + mlx_lm generate_step, as bench/typebench.py records). Prints how many keys reused the distribution,
how many answers differ (token by token) and the largest difference in a chosen token's probability, and the time to
the first token both ways.

    .venv/bin/python bench/dist_check.py --adapter-path <layer> [--n 20] [--app Claude] [--tokens 8]
"""
import argparse, json, os, statistics, sys, time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
ap = argparse.ArgumentParser()
ap.add_argument("--repo", default="mlx-community/Qwen3-1.7B-4bit")
ap.add_argument("--adapter-path", default=None)
ap.add_argument("--set", default="data/replay-fresh.json")
ap.add_argument("--n", type=int, default=20)
ap.add_argument("--app", default=None)
ap.add_argument("--tokens", type=int, default=8)
ap.add_argument("--cap", type=float, default=3.0)
a = ap.parse_args()
os.environ["DRAFTER_CAP_GB"] = str(a.cap)
os.environ["DRAFTER_DIST"] = "1"
os.environ.setdefault("HF_HUB_OFFLINE", "1")
sys.path.insert(0, str(ROOT / "engine"))

import mlx.core as mx
from mlx_lm.generate import generate_step
from model import Model
from prompt import Builder

items = [it for it in json.loads((ROOT / a.set).read_text()) if not a.app or it["app"] == a.app][: a.n]
m = Model(a.repo, a.adapter_path)
b = Builder(m, "raw")
m.warm(b.head_ids)
eos = set(getattr(m.tok, "eos_token_ids", None) or [m.tok.eos_token_id])
ru = lambda toks, logits: logits + m.russian_mask(logits.shape)


def spots():
    for it in items:
        for pos in range(1, len(it["text"])):
            before = it["text"][:pos]
            if len(before.strip()) >= 2: yield before, it["app"], it.get("context", "")[-1000:], it.get("title", "")


def new_way(ids, heal):
    t0 = time.perf_counter()
    raw0 = m._reuse(ids)
    fed = list(ids[-1:]) if raw0 is not None else m._feed(ids)
    procs = ([m.healer(heal, len(fed))] if heal else []) + [ru]
    return collect(m._steps(ids, fed, procs, a.tokens + (6 if heal else 0), raw0), t0, ids), raw0 is not None


def old_way(ids, heal):
    t0 = time.perf_counter()
    fed = m._feed(ids)
    procs = ([m.healer(heal, len(fed))] if heal else []) + [ru]
    return collect(generate_step(mx.array(fed), m.model, max_tokens=a.tokens + (6 if heal else 0), sampler=m.sampler,
                                 prompt_cache=m.cache, prefill_step_size=512, logits_processors=procs), t0, ids), False


def collect(gen, t0, ids):
    out, first = [], None
    for tok, lp in gen:
        tok = int(tok)
        if first is None: m.ids = list(ids); first = (time.perf_counter() - t0) * 1000
        m.ids.append(tok)
        out.append((tok, float(mx.exp(lp[tok]))))
        if tok in eos or len(out) >= a.tokens: break
    return out, first or 0.0


def run(way):
    m._warm(b.head_ids)
    res = []
    for before, app, ctx, title in spots():
        ids, heal = b.ids(before, app, title, ctx, "")
        (out, first), reused = way(ids, heal)
        res.append((out, first, reused))
    return res


t = time.time()
new = run(new_way)
old = run(old_way)
diff = sum(1 for x, y in zip(new, old) if [t for t, _ in x[0]] != [t for t, _ in y[0]])
dp = max((abs(p - q) for x, y in zip(new, old) for (t1, p), (t2, q) in zip(x[0], y[0]) if t1 == t2), default=0.0)
reused = [x for x in new if x[2]]
print(f"{len(new)} keys on {len(items)} lines, {time.time() - t:.0f}s, peak {mx.get_peak_memory() / 2**30:.2f} GB")
print(f"distribution reused at {len(reused)} keys ({100 * len(reused) / max(1, len(new)):.0f}%)")
print(f"answers that differ token by token: {diff}; largest gap in a chosen token's p: {dp:.4f}")
med = lambda xs: statistics.median(xs) if xs else 0
print(f"first token ms, p50: new {med([x[1] for x in new]):.1f} / old {med([y[1] for y in old]):.1f}; "
      f"at the reused keys new {med([x[1] for x in reused]):.1f} / old {med([y[1] for x, y in zip(new, old) if x[2]]):.1f}")

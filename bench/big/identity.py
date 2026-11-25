"""Big-model round (2026-11-15): proof that the engine change keeps the ghosts. One engine folder, one model, a typing
session over held lines key by key through Model.complete_gated (sentence mode, the gate always says yes, so the
ghost is the model's own text up to the run's end); every ghost, the tokens read at the key and the time are kept.
Run it once with the old engine folder and once (twice: the head file made, then read) with the new one, then compare.

    .venv/bin/python -B bench/big/identity.py run --engine <engine dir> --label old --model live [--every 3]
    .venv/bin/python -B bench/big/identity.py compare old new-made new-read

Run `run` under the guard (bench/weights/guarded.py), one at a time. Output: data/bench/big/identity-<label>.jsonl
(his text stays under data/); `compare` prints counts only."""
import argparse, json, os, statistics, sys, time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent.parent
OUT = ROOT / "data/bench/big"
MODELS = {"live": ("mlx-community/Qwen3-1.7B-4bit", "data/adapters"),
          "gemma4-e2b": ("mlx-community/gemma-4-e2b-4bit", None),
          "gemma4-e4b": ("mlx-community/gemma-4-e4b-4bit", None),
          "qwen35-2b": ("Muesli-HQ/qwen35-2b-base-cotypist-mlx-4bit", None),
          "qwen3-4b": ("mlx-community/Qwen3-4B-Instruct-2507-4bit", None)}


def run(a):
    os.environ.setdefault("HF_HUB_OFFLINE", "1")
    os.environ["DRAFTER_CAP_GB"] = str(a.cap)
    os.environ["DRAFTER_HEAD_CACHE"] = str(OUT / "headcache")
    sys.path.insert(0, str(Path(a.engine).resolve()))
    import mlx.core as mx
    from model import Model
    from prompt import Builder
    repo, adapter = MODELS[a.model]
    items = json.loads((ROOT / a.set).read_text())
    # a fixed spread over the set: every k-th line (its index in the set kept), chats and AI apps both
    items = [(i, it) for i, it in enumerate(items) if i % a.every == 0][: a.n]
    t = time.time()
    m = Model(repo, str(ROOT / adapter) if adapter else None)
    b = Builder(m, "raw")
    t1 = time.perf_counter(); m.warm(b.head_ids); warm_ms = (time.perf_counter() - t1) * 1000
    stable_ok = hasattr(b, "ids_stable") and not a.no_stable
    OUT.mkdir(parents=True, exist_ok=True)
    out = OUT / f"identity-{a.label}.jsonl"
    yes = lambda toks: 1.0
    with out.open("w") as f:
        f.write(json.dumps({"meta": True, "repo": repo, "engine": str(a.engine), "warm_ms": round(warm_ms, 1), "stable": stable_ok,
                            "head_file": getattr(m, "head_file", None), "load_s": round(time.time() - t, 2)}) + "\n")
        for i, it in items:
            text = it["text"]
            screen = f"{it['app']} · line {i}"
            for pos in range(1, len(text)):
                before = text[:pos]
                if len(before.strip()) < 2: continue
                if stable_ok:
                    ids, heal, stable = b.ids_stable(before, it["app"], "", it.get("context", ""), "")
                    kw = {"stable": stable}
                else:
                    ids, heal = b.ids(before, it["app"], "", it.get("context", ""), "")
                    kw = {}
                t0 = time.perf_counter()
                ghost, g, first, total = m.complete_gated(ids, heal, yes, max_tokens=24, screen=screen,
                                                          run={"mode": "sentence", "floor": 0.1}, **kw)
                f.write(json.dumps({"i": i, "pos": pos, "ghost": ghost, "first": round(first, 1), "total": round(total, 1),
                                    "fed": (getattr(m, "timing", {}) or {}).get("fed")}, ensure_ascii=False) + "\n")
    print(f"{a.label}: {len(items)} lines in {time.time() - t:.0f}s, warm {warm_ms:.0f} ms, head file {getattr(m, 'head_file', None)}, "
          f"rebuilds {m.rebuilds}, copies used {getattr(m, 'mark_hits', 0)}, peak {mx.get_peak_memory() / 2**30:.2f} GB", flush=True)


def load(label):
    rows = [json.loads(l) for l in (OUT / f"identity-{label}.jsonl").read_text().splitlines() if l.strip()]
    return rows[0], {(r["i"], r["pos"]): r for r in rows[1:]}


def q(xs, p):
    return sorted(xs)[min(len(xs) - 1, int(len(xs) * p))] if xs else None


def compare(a):
    base_meta, base = load(a.labels[0])
    for lab in a.labels:
        meta, rows = load(lab)
        same = sum(1 for k, r in rows.items() if k in base and base[k]["ghost"] == r["ghost"])
        firsts = [r["first"] for r in rows.values()]
        fed = [r["fed"] for r in rows.values() if r.get("fed") is not None]
        print(f"{lab:14s} keys {len(rows)} same ghost as {a.labels[0]}: {same} ({100 * same / max(1, len(rows)):.2f}%) | "
              f"first token ms p50 {q(firsts, .5)} p90 {q(firsts, .9)} | tokens read per key p50 {q(fed, .5)} p90 {q(fed, .9)} | "
              f"warm {meta.get('warm_ms')} ms, head file {meta.get('head_file')}, stable {meta.get('stable')}")


def main():
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("run")
    p.add_argument("--engine", required=True); p.add_argument("--label", required=True)
    p.add_argument("--model", default="live", choices=list(MODELS)); p.add_argument("--n", type=int, default=1000); p.add_argument("--every", type=int, default=3)
    p.add_argument("--set", default="data/bench/weights/held-137.json"); p.add_argument("--cap", type=float, default=3.0)
    p.add_argument("--no-stable", action="store_true")
    p = sub.add_parser("compare"); p.add_argument("labels", nargs="+")
    a = ap.parse_args()
    {"run": run, "compare": compare}[a.cmd](a)


if __name__ == "__main__":
    main()

"""Shared parts of the models round (docs/rounds/2026-11-14-models.md): the candidates, the guarded recording, the
score, timing and memory from a recording, the best recipe of the weights round.

Every script here orchestrates and loads no model itself. Each model step (training, recording) runs in its own process
under engine/guard.py (bench/weights/guarded.py), one at a time, after a free-memory check (bench/weights/common.py).
Scores are the weekly retrain's own test, so numbers compare with the weights round and the live layer:
bench/typebench.py records data/bench/weights/held-137.json as Drafter types it, bench/gate.py `summary` scores it
with a gate refit on held-out folds, `retrain.decide` says whether it beats the live layer. On top, the one replay
(bench/measure.py) gives right %, wrong per 1,000 letters and ms with the same refit gate.

Run from the main checkout (it has data/). Results: data/bench/models/<name>.json (numbers only). Layers:
bench/out/models/<name>/ (git ignores it). Nothing here writes data/adapters*, gate.json or selector.json."""
import json, re, statistics, sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent.parent
for p in (ROOT / "bench/weights", ROOT / "bench", ROOT / "engine"):
    if str(p) not in sys.path: sys.path.insert(0, str(p))
import importlib.util
_spec = importlib.util.spec_from_file_location("weights_common", ROOT / "bench/weights/common.py")
W = importlib.util.module_from_spec(_spec); _spec.loader.exec_module(W)   # guarded(), held_set(), baseline(), versus()

RESULTS = W.DATA / "bench/models"
OUT = ROOT / "bench/out/models"
SET = "data/bench/weights/held-137.json"

# name: repo, pinned revision (None = cached copy), LoRA training cap and batch, recording cap (MLX limit) and guard,
# measured or estimated 4-bit size and ms per token. Caps from docs/rounds/2026-11-13-typing.md (measured peaks:
# 1.7B 2.65 GB merged, 4B 3.92 GB merged, Gemma 4 E2B 3.12 GB) plus 1 GB.
CANDIDATES = {
    "live": {"repo": "mlx-community/Qwen3-1.7B-4bit", "rev": None, "train_cap": 6.0, "batch": 4, "ckpt": False,
             "cap": 3.0, "guard": 4.0, "disk_gb": 0.98, "note": "Qwen3 1.7B, the live base"},
    "qwen35-2b": {"repo": "Muesli-HQ/qwen35-2b-base-cotypist-mlx-4bit", "rev": "2434da7449586e5e676ce03f5f34008e5df85ba8",
                  "train_cap": 7.0, "batch": 4, "ckpt": True, "cap": 3.5, "guard": 4.5, "disk_gb": 1.06,
                  "note": "Qwen3.5 2B Base, text weights only; hybrid cache (snapshot path)"},
    "gemma4-e2b": {"repo": "mlx-community/gemma-4-e2b-4bit", "rev": None, "train_cap": 9.0, "batch": 2, "ckpt": True,
                   "cap": 4.0, "guard": 5.0, "disk_gb": 3.61, "note": "Gemma 4 E2B base, cached since 31 October; sliding window 512"},
    "gemma4-e4b": {"repo": "mlx-community/gemma-4-e4b-4bit", "rev": "1560521ede4c3196854c19b6a77fcc2db8d4e289", "train_cap": 12.0,
                   "batch": 2, "ckpt": True, "cap": 7.0, "guard": 8.0, "disk_gb": 5.25,
                   "note": "Gemma 4 E4B base (the size Cotypist runs), downloaded 15 November; sliding window 512"},
    "qwen3-4b": {"repo": "mlx-community/Qwen3-4B-Instruct-2507-4bit", "rev": None, "train_cap": 9.0, "batch": 2, "ckpt": True,
                 "cap": 4.5, "guard": 5.5, "disk_gb": 2.28, "note": "Qwen3 4B Instruct 2507, cached; same tokenizer as live"},
    "qwen3-4b-hy": {"repo": "mlx-community/Qwen3-4B-4bit", "rev": "4dcb3d101c2a062e5c1d4bb173588c54ea6c4d25", "train_cap": 9.0, "batch": 2,
                    "ckpt": True, "cap": 4.5, "guard": 5.5, "disk_gb": 2.26,
                    "note": "Qwen3 4B (the hybrid build, same kind as live's Qwen3 1.7B; no mlx-community 4-bit Base exists), downloaded 16 November"},
    "qwen3-0.6b": {"repo": "mlx-community/Qwen3-0.6B-4bit", "rev": None, "train_cap": 5.0, "batch": 4, "ckpt": False,
                   "cap": 2.0, "guard": 3.0, "disk_gb": 0.34, "note": "Qwen3 0.6B, cached; the small side of two-tier"},
}


def candidate(name):
    if name not in CANDIDATES: raise SystemExit(f"unknown candidate {name}; one of {', '.join(CANDIDATES)}")
    return CANDIDATES[name]


def cached(repo, rev=None):
    """True when the model folder is in the Hugging Face cache (no download, no load)."""
    from huggingface_hub import snapshot_download
    try:
        p = Path(snapshot_download(repo, revision=rev, local_files_only=True))
        return any(p.glob("*.safetensors"))
    except Exception:
        return False


def record(label, cand, adapter=None, set_path=None, smoke=False, extra=(), env=None):
    """The held set recorded as Drafter types it (bench/typebench.py through bench/models/record.py, which adds the
    prompt knobs in `extra`). Same arguments as bench/weights/common.record. -> recording path."""
    c = candidate(cand)
    sp = W.held_set(set_path or SET)
    args = [c["repo"], "--set", str(sp), "--boost", str(W.gate_boost()), "--label", label,
            "--cap", str(c["cap"]), "--n", "3" if smoke else "100000", *map(str, extra)]
    if adapter: args += ["--adapter", str(adapter)]
    e = dict(env or {})
    if c.get("rev"): e.setdefault("DRAFTER_MODEL_REVISION", c["rev"])
    code, lines = W.guarded(HERE / "record.py", args, c["guard"], timeout=4 * 3600, env=e,
                            log=RESULTS / "logs" / f"{label}.log")
    if code: raise RuntimeError(f"{label}: recording failed ({code}): {lines[-1:] or ''}")
    return W.DATA / "bench" / f"{label}.jsonl", lines


def peak_gb(lines):
    """Peak MLX memory from typebench's own output ("peak 2.65 GB")."""
    xs = [float(m.group(1)) for l in lines for m in [re.search(r"peak ([\d.]+) GB", l)] if m]
    return max(xs) if xs else None


def q(xs, p):
    return sorted(xs)[min(len(xs) - 1, int(len(xs) * p))] if xs else None


def timing(rows):
    """From recorded rows {"toks": [[text, p, p2, ms, piece], ...], "prefill_ms"}: ms to the first token (p50/p90) and
    ms per further token (p50). The first token's ms includes reading the new part of the prompt."""
    first, per = [], []
    for r in rows:
        t = r.get("toks") or []
        if not t: continue
        first.append(t[0][3])
        per += [b[3] - a[3] for a, b in zip(t, t[1:])]
    return {"first_ms_p50": round(statistics.median(first), 1) if first else None,
            "first_ms_p90": round(q(first, .9), 1) if first else None,
            "token_ms_p50": round(statistics.median(per), 2) if per else None}


def gate_policy(rec, th=0.4, more=0.5, max_words=3):
    """(policy, items, rows) for a recording, with a gate refit on it by held-out folds (as gate.summary does), so each
    model is judged with a gate made for it. rows carry "_key" = (line, letters typed)."""
    import gate, ngram, typescore as ts
    from retrain_state import last_retrain
    items, rows = ts.load(rec)
    for k, r in rows.items(): r["_key"] = k
    Wd = ngram.Words(ngram.corpus(last_retrain(ROOT)))
    X, y, keys = gate.dataset(items, rows, Wd)
    P = gate.held_out(items, X, y, keys)
    pol = gate.policy_from(P, items, rows, Wd, th, more, max_words,
                           knowledge=ts.knowledge_for(rec, ts.meta(rec).get("know", "none")))
    pol.P = P
    return pol, items, rows


def line_start_ms(items, rows):
    """ms to the first token at the first recorded key of each line: the cost of reading the screen text and the head's
    tail anew (later keys reuse the cache). p50 / p90."""
    first = {}
    for (i, pos), r in rows.items():
        if r.get("toks") and (i not in first or pos < first[i][0]): first[i] = (pos, r["toks"][0][3])
    xs = [ms for _, ms in first.values()]
    return {"line_start_ms_p50": round(statistics.median(xs), 1) if xs else None, "line_start_ms_p90": round(q(xs, .9), 1) if xs else None}


def scored(rec, th=0.4):
    """Right %, wrong/1k, saved %, ms per app kind (claude = AI apps, beeper = chats) through the one replay
    (bench/measure.py) with a gate refit on this recording, plus first-token and per-token ms."""
    import measure
    pol, items, rows = gate_policy(rec, th)
    res, _ = measure.replay(items, rows, pol)
    keep = ("shown", "right", "wrong_1k", "saved", "taken", "ms_p50", "ms_p90")
    out = {k: {m: v[m] for m in keep} for k, v in res.items()}
    by_src = {}
    for (i, pos), r in rows.items(): by_src.setdefault(items[i]["src"], {})[(i, pos)] = r
    for src, rs in by_src.items():
        out.setdefault(src, {}).update(timing(rs.values()))
        out[src].update(line_start_ms(items, rs))
    return out


def score(rec, smoke=False):
    """(retrain score {app: saved, right, shown}, replay detail). A smoke recording (3 lines) may be too small for the
    gate's folds: then both carry the error and the run only checks the plumbing."""
    try:
        return W.score(rec, W.held_set(SET), smoke), scored(rec)
    except Exception as e:
        if not smoke: raise
        err = {"smoke_error": f"{type(e).__name__}: {e}"[:200]}
        return err, err


def best_recipe(results_dir=None):
    """The best training recipe of the weights round (data/bench/weights/train-*.json, full runs only): the variant with
    the largest letters-saved gain over live, if it beats `ref`. -> (name, recipe dict) or (None, None)."""
    d = Path(results_dir or W.RESULTS)
    runs = {}
    for p in d.glob("train-*.json"):
        if p.stem.endswith("-smoke"): continue
        try: r = json.loads(p.read_text())
        except ValueError: continue
        g = (r.get("vs_live") or {}).get("gain_points")
        if r.get("smoke") or g is None: continue
        runs[r.get("variant") or p.stem[len("train-"):]] = (g, r.get("recipe") or {})
    if not runs: return None, None
    name, (g, rec) = max(runs.items(), key=lambda kv: kv[1][0])
    ref = runs.get("ref", (None,))[0]
    if name == "ref" or (ref is not None and g <= ref): return None, None
    return name, rec


def write(name, result):
    import time
    RESULTS.mkdir(parents=True, exist_ok=True)
    p = RESULTS / f"{name}.json"
    p.write_text(json.dumps({**result, "made": time.strftime("%Y-%m-%d %H:%M")}, indent=1, ensure_ascii=False))
    return p

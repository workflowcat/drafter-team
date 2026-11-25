"""Training lines with recency weighting: his newer lines are sampled more often (weights round, item A).

The base is bench/make_train.py `from_corpus`: per-source weights, nothing dated at or after the held-out cut, no held
line, the same valid split (seed 3, a twentieth, at least 60). On top, each line's weight is multiplied by
    m = max(floor, 0.5 ** (age_days / half_life))
normalised so the mean multiplier over dated lines is 1 (a line without a date gets 1). `build` then rescales so the
expected number of training lines is the same as without recency: only the mix moves toward new lines. Pure helpers
first; `build` reads the corpus."""
import json, random
from pathlib import Path

DAY = 86400.0


def multipliers(ts, now, half_life_days, floor=0.25):
    """Recency multipliers for unix times `ts` (0 or None = no date), mean 1 over the dated ones."""
    if not half_life_days: return [1.0] * len(ts)
    raw = [None if not t else max(floor, 0.5 ** (max(0.0, now - t) / DAY / half_life_days)) for t in ts]
    dated = [x for x in raw if x is not None]
    mean = sum(dated) / len(dated) if dated else 1.0
    return [1.0 if x is None else x / mean for x in raw]


def sample(rows, weights, seed=3):
    """Each row kept round-down(weight) times, plus once more with the leftover share (make_train.weighted, per row)."""
    rnd, out = random.Random(seed), []
    for r, w in zip(rows, weights):
        out += [r] * (int(w) + (rnd.random() < w - int(w)))
    return out


def build(out_dir, src_weights, before, is_held, half_life_days=None, floor=0.25, corpus=None, seed=3):
    """Write train.jsonl / valid.jsonl like make_train.from_corpus, with recency multipliers on the training side.
    -> {"train": n, "valid": n, "per_source": {...}, "mean_age_days": weighted mean age of the training lines}"""
    import corpus as C
    from held import norm
    from make_train import APP_TAG
    rows = []
    for r in C.load(corpus or C.OUT, before=before):
        t = norm(r["text"])
        if is_held(t) or len(t) < 8 or not src_weights.get(r["src"]): continue
        app = APP_TAG.get(r["src"]) or r.get("app") or "Claude"
        rows.append({"src": r["src"], "t": r.get("t") or 0, "text": f"[{app}]\n{t}"})
    random.Random(seed).shuffle(rows)
    k = max(60, len(rows) // 20)
    valid, rest = rows[:k], rows[k:]
    now = before or max((r["t"] for r in rows), default=0)
    mult = multipliers([r["t"] for r in rest], now, half_life_days, floor)
    flat = [float(src_weights[r["src"]]) for r in rest]
    w = [f * m for f, m in zip(flat, mult)]
    keep = sum(flat) / max(sum(w), 1e-9)          # same expected size as the flat mix
    train = sample(rest, [x * keep for x in w], seed)
    random.Random(seed + 1).shuffle(train)
    out = Path(out_dir); out.mkdir(parents=True, exist_ok=True)
    (out / "valid.jsonl").write_text("".join(json.dumps({"text": r["text"]}, ensure_ascii=False) + "\n" for r in valid))
    (out / "train.jsonl").write_text("".join(json.dumps({"text": r["text"]}, ensure_ascii=False) + "\n" for r in train))
    per = {}
    for r in train: per[r["src"]] = per.get(r["src"], 0) + 1
    ages = [(now - r["t"]) / DAY for r in train if r["t"]]
    return {"train": len(train), "valid": len(valid), "per_source": per,
            "mean_age_days": round(sum(ages) / len(ages), 1) if ages else None}

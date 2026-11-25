"""The weights round's results table: each recording scored through one replay (bench/measure.py) with the running
policy (gate refit on held-out folds, as bench/gate.py `summary` does), split by chat (beeper) and AI apps (claude),
with paired 95% intervals against the live layer's recording on the same set. No model; numbers only.

    .venv/bin/python -B bench/weights/table.py data/bench/weights-live-<sha>.jsonl data/bench/weights-ref.jsonl ...
The first recording is the live layer. Output: one JSON object per recording on stdout."""
import json, statistics, sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent.parent
sys.path[:0] = [str(ROOT / "bench"), str(ROOT / "engine")]


def decode_ms(rows):
    """Median ms between two tokens of one answer (the recording's own clock): speed per token."""
    gaps = [b[3] - a[3] for r in rows.values() for a, b in zip(r["toks"], r["toks"][1:]) if b[3] >= a[3]]
    return round(statistics.median(gaps), 2) if gaps else None


def per_line(path):
    import gate, measure, ngram, typescore as ts
    from retrain_state import last_retrain
    items, rows = ts.load(path)
    for k, r in rows.items(): r["_key"] = k
    W = ngram.Words(ngram.corpus(last_retrain(ROOT)))
    X, y, keys = gate.dataset(items, rows, W)
    know = ts.knowledge_for(path, ts.meta(path).get("know", "none"))
    pol = gate.policy_from(gate.held_out(items, X, y, keys), items, rows, W, 0.4, knowledge=know)
    res, per = measure.replay(items, rows, pol)
    return res, per, decode_ms(rows)


def verdict(lo, hi):
    """win / lose only when the paired 95% interval of letters saved leaves 0 on that side, else noise."""
    return "win" if lo > 0 else ("lose" if hi < 0 else "noise")


def main(paths):
    import measure
    base = None
    for p in paths:
        res, per, ms = per_line(p)
        row = {"recording": Path(p).name, "ms_per_token": ms}
        for k in ("claude", "beeper"):
            if k in res:
                r = res[k]
                row[k] = {"right": r["right"], "saved": r["saved"], "wrong_1k": r["wrong_1k"], "shown": r["shown"]}
        allr = measure.total(per)
        row["all"] = {"right": allr["right"], "saved": allr["saved"], "wrong_1k": allr["wrong_1k"]}
        if base is None:
            base = per
        else:
            for k in ("claude", "beeper"):
                if k not in row: continue
                lo, hi = measure.paired(base, per, k, "saved")
                row[k]["saved_vs_live"] = [lo, hi]
                row[k]["verdict"] = verdict(lo, hi)
        print(json.dumps(row), flush=True)


if __name__ == "__main__":
    main(sys.argv[1:])

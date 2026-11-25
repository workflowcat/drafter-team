"""Compare models on Andrii's held-out messages: how much of each suggestion he would keep, and how fast.

    .venv/bin/python bench/bench.py <hf-repo> [raw|chat] [n]
One model per process. Prints one JSON line and appends it to data/bench.jsonl.
"""
import json, os, statistics, sys, time
from pathlib import Path
ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "engine"))
import guard
guard.start(float(os.environ.get("DRAFTER_CAP_GB", "3.5")))
from model import Model
from prompt import Builder

repo, fmt = sys.argv[1], (sys.argv[2] if len(sys.argv) > 2 else "raw")
n = int(sys.argv[3]) if len(sys.argv) > 3 else 30
MIN_P = float(sys.argv[4]) if len(sys.argv) > 4 else 0.0
MAXW = int(sys.argv[5]) if len(sys.argv) > 5 else 0
MAXT = int(sys.argv[6]) if len(sys.argv) > 6 else 12
cases = json.loads((ROOT / "data" / "cases.json").read_text())[:n]
m = Model(repo); b = Builder(m, fmt)
m.warm(b.head_ids); m.pieces()


def kept(s, t):
    k = 0
    for a, c in zip(s, t):
        if a != c: break
        k += 1
    return k


rows, first, total, inc = [], [], [], []
for c in cases:
    ids, heal = b.ids(c["before"], c["app"])
    s, f, tt = m.complete(None, raw_ids=ids, heal=heal, min_p=MIN_P, max_words=MAXW, max_tokens=MAXT)
    first.append(f); total.append(tt)
    # next keystroke: one more character typed, cache should make this cheap
    if c["truth"]:
        ids, heal = b.ids(c["before"] + c["truth"][0], c["app"])
        _, f2, _ = m.complete(None, raw_ids=ids, heal=heal)
        inc.append(f2)
    tw, sw = c["truth"].split(), s.split()
    rows.append({"before": c["before"][-40:], "truth": c["truth"][:40], "got": s,
                 "kept": kept(s, c["truth"]), "word": bool(tw and sw and (c["before"][-1:].isspace() or c["truth"][:1].isspace()) == (c["before"][-1:].isspace() or s[:1].isspace()) and sw[0] == tw[0])})
act, peak = m.memory_gb()
res = {"repo": repo, "fmt": fmt, "min_p": MIN_P, "max_words": MAXW, "n": len(rows),
       "shown": sum(bool(r["got"].strip()) for r in rows), "wrong": sum(bool(r["got"].strip()) and r["kept"] == 0 for r in rows), "load_s": round(m.load_s, 1),
       "kept_chars": round(statistics.mean(r["kept"] for r in rows), 2),
       "useful": sum(r["kept"] >= 3 for r in rows), "first_word": sum(r["word"] for r in rows),
       "first_ms_p50": round(statistics.median(first)), "first_ms_p90": round(sorted(first)[int(len(first) * .9) - 1]),
       "keystroke_ms_p50": round(statistics.median(inc)), "total_ms_p50": round(statistics.median(total)),
       "head_tokens": len(b.head_ids), "rebuilds": m.rebuilds, "mlx_peak_gb": round(peak, 2), "rss_gb": round(guard.rss_gb(), 2)}
print(json.dumps(res, ensure_ascii=False))
with open(ROOT / "data" / "bench.jsonl", "a") as f: f.write(json.dumps({**res, "rows": rows}, ensure_ascii=False) + "\n")

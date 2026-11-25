"""Tables for bench/typo_bench.swift (2026-11-15), written to an out folder (never data/): his word counts and bigrams
from lines written before a cutoff, so the held typed lines after it are new to both correctors; and the log events.

    .venv/bin/python -B bench/typo_prep.py OUT [--data data] [--held 0.25]
"""
import argparse, json, re, sys
from collections import Counter
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "engine")); sys.path.insert(0, str(ROOT / "bench"))
import typos, typo_log


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("out"); ap.add_argument("--data", default=str(ROOT / "data")); ap.add_argument("--held", type=float, default=0.25)
    a = ap.parse_args()
    data, out = Path(a.data), Path(a.out); out.mkdir(parents=True, exist_ok=True)
    typed = [json.loads(l) for l in (data / "typed.jsonl").read_text().splitlines() if l.strip()]
    ts = sorted(r["t"] for r in typed)
    cutoff = ts[int(len(ts) * (1 - a.held))]
    early = []
    for l in (data / "corpus.jsonl").read_text().splitlines():
        try: r = json.loads(l)
        except ValueError: continue
        if r.get("src") in typos.SOURCES and (r.get("t") or 0) < cutoff and "⟦drafter-test⟧" not in (r.get("text") or ""): early.append(r["text"])
    uni = Counter()
    for line in early:
        for sent in re.split(r"[\n.!?]+", line):
            if typos.RUSSIAN.search(sent): continue
            uni.update(w.lower() for w in typos.WORD.findall(sent))
    counts = {w: n for w, n in uni.items() if n >= 3 and len(w) >= 2}
    (out / "counts-held.json").write_text(json.dumps(counts, ensure_ascii=False))
    typos.write_bigrams(typos.bigrams(early), out / "bigrams-held.tsv")
    typos.write_bigrams(typos.bigrams(typos.lines_of(data)), out / "bigrams-all.tsv")
    autos, offers, _ = typo_log.events(sorted((data / "logs").glob("app-*.log.gz")) + [data / "app.log"])
    (out / "events.json").write_text(json.dumps({"autos": autos, "cutoff": cutoff}))
    print(f"prep: cutoff {cutoff:.0f}, {len(early)} early lines, {len(counts)} words, {len(autos)} fix events")


if __name__ == "__main__":
    main()

"""Round five (2026-11-14): the lighter tail's bar (Keys.length "tail") with the live selector and the settled stop.

    .venv/bin/python -B bench/tailbar.py data/bench/<recording>.jsonl
"""
import json, sys
from collections import defaultdict
from pathlib import Path
ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "bench")); sys.path.insert(0, str(ROOT / "engine"))
import lengths, measure, ngram, settle, typescore as ts, words, memory as mem
from retrain_state import last_retrain
path = sys.argv[1]
items, rows = ts.load(path)
cut = last_retrain(ROOT)
W = ngram.Words(ngram.corpus_from(cut, words.Words.SOURCES))
M = lengths.memory_from(ngram.corpus_from(cut, mem.Memory.SOURCES))
gate = json.loads((ROOT / "data/gate.json").read_text()); sel = json.loads((ROOT / "data/selector.json").read_text())
base = None
for tail in (0.2, 0.3, 0.4, 0.5):
    knobs = dict(settle.KNOBS, settle=True, tail=tail)
    r, per = measure.replay(items, rows, settle.live(W, M, gate, sel, knobs))
    if base is None: base = per
    for k in sorted(k for k in r if "/" not in k):
        by, run = defaultdict(lambda: [0, 0, 0]), defaultdict(lambda: [0, 0, 0, 0, 0])
        for l in per:
            if l["src"] != k: continue
            for b, v in l["by"].items(): by[b] = [x + y for x, y in zip(by[b], v)]
            for b, v in l["run"].items(): run[b] = [x + y for x, y in zip(run[b], v)]
        long_shown = sum(by[b][0] for b in ("10-14", "15-19", "20+")); long_whole = sum(by[b][2] for b in ("10-14", "15-19", "20+"))
        words_all = sum(v[1] for v in run.values()); words_bad = sum(v[4] for v in run.values())
        v = r[k]
        print(f"tail {tail} {k:7s} shown {v['shown']} right {v['right']}% saved {v['saved']}% wrong/1k {v['wrong_1k']} | 10+ letters shown {long_shown}, wholly right {long_whole} | grey words {words_all}, after the first wrong {words_bad} | saved vs 0.2 {measure.paired(base, per, k, 'saved')}")

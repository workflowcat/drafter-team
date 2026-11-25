"""Round five (2026-11-14): stop the model once the ghost can no longer change (gatecore.settled, model.py SETTLE).

The live policy as the engine runs it today (the selector from data/selector.json at its bar, his word, phrase memory,
the gated model with the picked length rule and the AI-app tail) replayed on a recording, without and with the stop.
The ghost texts must be the same key for key; what changes is when the answer ends (`new ms`, from the recorded
per-token times), and with it how often the next answer is ready in his gap (the look-ahead and the two word branches
of bench/branches.py fit in the time left).

    .venv/bin/python -B bench/settle.py data/bench/<recording>.jsonl [--gap 150] [--selector data/selector.json]
"""
import argparse, json, statistics, sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "bench")); sys.path.insert(0, str(ROOT / "engine"))
import measure

KNOBS = {"min_letters": 5, "grow": 0.05, "tail": 0.2, "tail_words": 8}   # the app's request before round five (tail 0.3 after)


def live(W, M, gate, sel, knobs):
    """The engine's order with the selector on (server._complete): his word and memory when they clear the bar, else
    the model's ghost when its first word clears it."""
    import selector as S
    src = S.Sources(W, M, gate, sel["wordgate"], knobs)
    return S.Selector(src, sel["w"], sel["th"])


class Recorder:
    """Wraps a policy: keeps each key's ghost, so two runs can be compared key for key."""
    def __init__(self, pol): self.pol, self.out = pol, {}

    def __setattr__(self, k, v):
        if k == "text" and "pol" in self.__dict__ and hasattr(self.pol, "text"): self.pol.text = v
        object.__setattr__(self, k, v)

    def __call__(self, row, before, src):
        g, ms = self.pol(row, before, src)
        self.out[(src, before)] = g
        return g, ms


def ms_of(per, k):
    return [m for l in per if l["src"] == k for m in l["ms"]]


def q(xs, p):
    return round(sorted(xs)[min(len(xs) - 1, int(len(xs) * p))]) if xs else None


if __name__ == "__main__":
    import branches, lengths, ngram, typescore as ts, words, memory as mem
    from retrain_state import last_retrain
    ap = argparse.ArgumentParser()
    ap.add_argument("path")
    ap.add_argument("--gap", type=float, default=150)
    ap.add_argument("--gate", default="data/gate.json")
    ap.add_argument("--selector", default="data/selector.json")
    ap.add_argument("--lines", type=int, default=0, help="only the first N lines (a short run first)")
    a = ap.parse_args()
    items, rows = ts.load(a.path)
    if a.lines:
        keep = set(range(min(a.lines, len(items))))
        items = items[: len(keep)]; rows = {k: v for k, v in rows.items() if k[0] in keep}
    cut = last_retrain(ROOT)
    W = ngram.Words(ngram.corpus_from(cut, words.Words.SOURCES))
    M = lengths.memory_from(ngram.corpus_from(cut, mem.Memory.SOURCES))
    gate = json.loads((ROOT / a.gate).read_text())
    sel = json.loads((ROOT / a.selector).read_text())
    res = {}
    for name, settle in (("live", False), ("settle", True)):
        rec = Recorder(live(W, M, gate, sel, dict(KNOBS, settle=settle)))
        r, per = measure.replay(items, rows, rec)
        b = branches.Branches(live(W, M, gate, sel, dict(KNOBS, settle=settle)), W, rows, a.gap, 2)
        rb, pb = measure.replay(items, rows, b, gap_ms=a.gap)
        res[name] = (rec.out, r, per, rb, pb)
        measure.show(f"{name}", r)
        measure.show(f"{name}, 2 branches, gap {a.gap:.0f}", rb)
        for k in sorted(k for k in r if "/" not in k):
            ms, msb = ms_of(per, k), ms_of(pb, k)
            ready = sum(1 for m in msb if m <= 1)
            print(f"  {k}: answer ends p50 {q(ms, .5)} p90 {q(ms, .9)} ms · in the gap: ready {ready} of {len(msb)} "
                  f"({100 * ready / max(1, len(msb)):.0f}%), new ghost p50 {q(msb, .5)} p90 {q(msb, .9)} ms")
    a0, a1 = res["live"][0], res["settle"][0]
    diff = sum(1 for k in a0 if a0[k] != a1.get(k))
    print(f"keys asked {len(a0)}; ghosts that differ with the stop: {diff}")
    for k in sorted(k for k in res["live"][1] if "/" not in k):
        print(f"  {k} (gap {a.gap:.0f}, branches): saved {measure.paired(res['live'][4], res['settle'][4], k, 'saved')} "
              f"right {measure.paired(res['live'][4], res['settle'][4], k, 'right')}")

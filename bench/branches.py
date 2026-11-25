"""Two prepared word branches in typing gaps (round four, 2026-11-14; Codex design review), on the one replay.

After each answer the engine already works out the next one for when he takes the ghost (server.look_ahead). Here,
in the gap before his next key, it also works out the answers for the next letter of two word branches: the model's
own next word (what it wrote, gated or not) and his own most likely next word (engine/words.py Words.dist). When his
key is one of those letters the answer is ready (a cache hit, ~1 ms) instead of a fresh model run. Answers are the
same either way (the engine keeps them by the exact request), so only time changes: a ghost is ready when the work
before it fits in the gap (the look-ahead for the shown ghost first, then branch one, then branch two, each costing
what a fresh answer cost at that key).

    .venv/bin/python bench/branches.py data/bench/<recording>.jsonl [--gap 150] [--branches 2]
"""
import argparse, statistics, sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "bench")); sys.path.insert(0, str(ROOT / "engine"))
import measure


def letters_next(row, before, W, n):
    """The next letter of each branch word, best first, at most n different ones."""
    out = []
    if row and row.get("toks"):
        t = row["toks"][-1][0]
        if before.endswith((" ", "\n")): t = t.lstrip(" ")
        if t[:1].strip(): out.append(t[0])
    for rest, _ in W.dist(before, 3):
        if rest[:1] and rest[0] not in out: out.append(rest[0])
    return out[:n]


class Branches:
    """Replay policy: the live answers, with ms 1 at keys a branch prepared in time."""
    def __init__(self, pol, W, rows_of, gap, n=2, order=None):
        """order (round five): None = the round-four model (the gap less one answer when a ghost shows); "next" = the
        engine as it was (the answer itself, then the look-ahead for the shown ghost, then the branches, each costing
        what this key's answer cost); "branches" = the branches before the look-ahead for the shown ghost."""
        self.pol, self.W, self.rows_of, self.gap, self.n, self.order = pol, W, rows_of, gap, n, order
        self.ready, self.last, self.taken = set(), None, None
        self.asked = self.hit = 0

    def __setattr__(self, k, v):
        if k == "text" and hasattr(self.__dict__.get("pol"), "text"): self.pol.text = v
        object.__setattr__(self, k, v)

    def __call__(self, row, before, src):
        g, ms = self.pol(row, before, src)
        ready = before in self.ready or before == self.taken
        self.taken = before + g if g else None             # server.look_ahead: the answer for when he takes it all
        self.asked += 1; self.hit += ready
        # what this gap prepares: the look-ahead for the shown ghost (it already runs), then the branch letters
        budget = (self.gap or 10**9) - (ms if g else 0)
        if self.order is not None:
            budget = (self.gap or 10**9) - (0 if ready else ms) - (ms if g and self.order == "next" else 0)
        self.ready = set()
        for ch in letters_next(row, before, self.W, self.n):
            if g and g.startswith(ch): continue           # typed through the shown ghost: no new ask
            budget -= ms
            if budget < 0: break
            self.ready.add(before + ch)
        return g, (1 if ready else ms)


if __name__ == "__main__":
    import ngram, typescore as ts, words
    from retrain_state import last_retrain
    ap = argparse.ArgumentParser()
    ap.add_argument("path")
    ap.add_argument("--gap", type=float, default=150)
    ap.add_argument("--branches", type=int, default=2)
    ap.add_argument("--gate", default="data/gate.json")
    a = ap.parse_args()
    items, rows = ts.load(a.path)
    W = ngram.Words(ngram.corpus_from(last_retrain(ROOT), words.Words.SOURCES))
    r0, p0 = measure.replay(items, rows, measure.live_policy(a.path, a.gate), gap_ms=a.gap)
    measure.show(f"live, gap {a.gap:.0f} ms", r0)
    for n in range(0, a.branches + 1):
        b = Branches(measure.live_policy(a.path, a.gate), W, rows, a.gap, n)
        r1, p1 = measure.replay(items, rows, b, gap_ms=a.gap)
        measure.show(f"{n} branch{'es' if n != 1 else ''}" + (" (look-ahead only, as live)" if not n else ""), r1)
        for k in sorted(k for k in r0 if "/" not in k):
            ms = [m for l in p1 if l["src"] == k for m in l["ms"]]
            fast = sum(1 for m in ms if m <= 1)
            print(f"  {k}: new ghosts ready {fast} of {len(ms)} ({100 * fast / max(1, len(ms)):.0f}%), new ms p50 "
                  f"{statistics.median(ms) if ms else 0:.0f}; saved change {measure.paired(p0, p1, k, 'saved')} right "
                  f"{measure.paired(p0, p1, k, 'right')}")

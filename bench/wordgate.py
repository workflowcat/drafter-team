"""The word gate (round four, 2026-11-14; Codex design review, "personal word path first"): his own finish of the word
being typed (engine/words.py Words.candidate) answers before the model when a small logistic model over its counts
says it is right often enough. Fit on the earlier half of the held-out lines by date (bench/measure.py split), the
bar picked there for a precision target, then scored on the later half, with word lists from before the cut.

    .venv/bin/python bench/wordgate.py data/bench/<recording>.jsonl [--target 0.8] [--save bench/out/gate-word.json]

The recording is only used for its lines and, in the replay, for the model's own answer after the word.
"""
import argparse, json, sys
from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "bench")); sys.path.insert(0, str(ROOT / "engine"))
import gatecore, measure
from gate import fit


def examples(items, idx, W):
    """Every key inside a word of the given lines: (features, right, (i, pos))."""
    out = []
    for i in idx:
        it = items[i]; text = it["text"]
        for pos in range(1, len(text)):
            before = text[:pos]
            if not measure.WORDCH.match(before[-1]): continue
            c = W.candidate(before)
            f = gatecore.word_features(c, before, it["src"] == "claude")
            if f is None: continue
            out.append((f, measure.first_right(c["rest"], text[pos:]), (i, pos)))
    return out


def pick(p, y, target):
    """The lowest bar whose approved words are right at least `target` of the time (and 20+ of them)."""
    order = np.argsort(-p)
    right = np.cumsum(y[order]); n = np.arange(1, len(y) + 1)
    ok = [(p[order][k]) for k in range(len(y)) if n[k] >= 20 and right[k] / n[k] >= target]
    return float(min(ok)) if ok else 1.0


def fit_gate(items, W, cal, target):
    ex = examples(items, cal, W)
    X = np.array([e[0] for e in ex]); y = np.array([float(e[1]) for e in ex])
    w = fit(X, y)
    th = pick(1 / (1 + np.exp(-X @ w)), y, target)
    return {"names": gatecore.WORD_NAMES, "min_letters": 3, "w": [round(float(v), 4) for v in w], "th": round(th, 4), "target": target,
            "fit_on": len(ex)}


def report(items, W, idx, g, label):
    ex = examples(items, idx, W)
    X = np.array([e[0] for e in ex]); y = np.array([float(e[1]) for e in ex])
    p = 1 / (1 + np.exp(-X @ np.array(g["w"])))
    ok = p >= g["th"]
    print(f"{label}: {len(ex)} keys inside a word, approved {int(ok.sum())} ({100 * ok.mean():.1f}%), right "
          f"{100 * y[ok].mean() if ok.any() else 0:.1f}% (all candidates right {100 * y.mean():.1f}%)")


class WordsFirst:
    """Replay policy: the live policy, with his own word first where the word gate approves. The word shows at once
    (about 1 ms); the model's ghost is kept only when it starts with that whole word (a later part may only extend
    what is shown), else the word stands alone."""
    def __init__(self, pol, W, g, min_letters=3):
        self.pol, self.W, self.g, self.min = pol, W, g, min_letters
        self.used = self.kept = 0

    def __setattr__(self, k, v):
        if k == "text" and hasattr(self.__dict__.get("pol"), "text"): self.pol.text = v
        object.__setattr__(self, k, v)

    def __call__(self, row, before, src):
        text, ms = self.pol(row, before, src)
        if not measure.WORDCH.match(before[-1:] or " "): return text, ms
        c = self.W.candidate(before)
        f = gatecore.word_features(c, before, src == "claude")
        if f is None or gatecore.score(self.g["w"], f) < self.g["th"] or gatecore.letters(c["rest"]) < self.min:
            return text, ms
        w = c["rest"]; self.used += 1
        if gatecore.extends(text, w):
            self.kept += 1; return text, 1
        return w, 1


def subset(items, rows, idx):
    m = {i: j for j, i in enumerate(idx)}
    return [items[i] for i in idx], {(m[i], p): r for (i, p), r in rows.items() if i in m}


if __name__ == "__main__":
    import ngram, typescore as ts
    from retrain_state import last_retrain
    import words
    ap = argparse.ArgumentParser()
    ap.add_argument("path")
    ap.add_argument("--target", type=float, default=0.8)
    ap.add_argument("--save", default=None)
    ap.add_argument("--replay", action="store_true", help="before/after through the live policy on the later half")
    ap.add_argument("--gate", default="data/gate.json")
    ap.add_argument("--min-letters", type=int, default=3)
    ap.add_argument("--gap", type=float, default=None, help="ms between his keys (a slower ghost is late)")
    a = ap.parse_args()
    items, rows = ts.load(a.path)
    W = ngram.Words(ngram.corpus_from(last_retrain(ROOT), words.Words.SOURCES))
    cal, test = measure.split(items)
    g = fit_gate(items, W, cal, a.target)
    print(f"bar {g['th']} for {a.target:.0%} on the earlier half ({g['fit_on']} keys)")
    report(items, W, cal, g, "calibration")
    report(items, W, test, g, "test")
    if a.save: Path(a.save).write_text(json.dumps(g, indent=1))
    if a.replay:
        ti, tr = subset(items, rows, test)
        base, _ = None, None
        r0, p0 = measure.replay(ti, tr, measure.live_policy(a.path, a.gate), gap_ms=a.gap)
        wf = WordsFirst(measure.live_policy(a.path, a.gate), W, g, a.min_letters)
        r1, p1 = measure.replay(ti, tr, wf, gap_ms=a.gap)
        print(f"later half, {len(ti)} lines: word first at {wf.used} new ghosts, model extended it at {wf.kept}")
        measure.show("live", r0); measure.show("words first", r1)
        for k in sorted(k for k in r0 if "/" not in k):
            print(f"  {k}: change right {measure.paired(p0, p1, k, 'right')} saved {measure.paired(p0, p1, k, 'saved')} "
                  f"wrong/1k {measure.paired(p0, p1, k, 'wrong_1k')}")

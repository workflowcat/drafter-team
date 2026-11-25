"""One calibrated selector over phrase memory, his own word and the model (round four, 2026-11-14; Codex design
review). At each key every source offers its ghost: the phrase memory (his own line said before), the word finisher
(engine/words.py Words.candidate) and the model's gated text whatever the gate says. One small logistic model reads
which source it is and how sure that source is, and gives the chance that the first word is exactly his. The best
candidate shows when that chance clears one bar.

Fit on the earlier half of the held-out lines by date (bench/measure.py split), scored on the later half through the
one replay, against the live policy on the same lines. The target (Codex): 75% of first words right while keeping at
least 90% of the letters saved.

    .venv/bin/python bench/selector.py data/bench/<recording>.jsonl [--gap 120] [--save bench/out/selector.json]

Default historical-selector keeps the old tail/grow presets. --policy-mode current-2026-11-16 uses
the shared request flags, including the model-guess fallback. This still fits a research selector;
it does not load the shipped selector. Static replay does not simulate keep-in-flight.
"""
import argparse, json, math, sys
from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "bench")); sys.path.insert(0, str(ROOT / "engine"))
import gatecore, measure, request_policy

NAMES = gatecore.SEL_NAMES
MIN = {"model": 5, "memory": 5, "words": 3}


def model_p(row, before, src, W, gate):
    """The model gate's chance for the recorded tokens (server._complete decide), or None before a whole word."""
    consumed = []
    for tok in row["toks"]:
        consumed.append(tok)
        if tok[0] and (gatecore.word_done(tok[0]) or measure.re.search(r"[.!?…)\n]", tok[0])): break
    if not consumed or not consumed[-1][0]: return None
    f, _ = gatecore.features(consumed, before, src == "claude", W.finish(before, 2, 0.5, 1))
    return gatecore.score(gate["w"], f) if f else None


class Sources:
    def __init__(self, W, M, gate, wordgate, knobs=None, policy_mode=request_policy.SELECTOR):
        import lengths, typescore as ts
        self.request_policy = request_policy.build(policy_mode)
        self.minimum = dict(MIN)
        open_gate = dict(gate, th={"ai": 0.0, "chat": 0.0})
        if policy_mode == request_policy.CURRENT:
            if knobs is not None: raise ValueError("current request mode does not accept historical length knobs")
            from earlier import ghost
            self.minimum = dict.fromkeys(MIN, self.request_policy.request["min_letters"])

            def model(row, before, src):
                # Static scorer keeps full recorded time; only earlier normalises cold prefill.
                text, _, full = ghost(dict(row, prefill_ms=0), before, **self.request_policy.run_kwargs())
                return text, full
            self.model = model
        else:
            self.model = lengths.policy(W, None, open_gate, **(self.request_policy.request if knobs is None else knobs))
        self.W, self.M, self.gate, self.wg = W, M, gate, wordgate

    def offers(self, row, before, src):
        """-> [(source, ghost, ms, features)]"""
        mid = bool(measure.WORDCH.match(before[-1:] or " "))
        out = []

        def add(kind, text, ms, **f):
            if not text or gatecore.letters(text) < self.minimum[kind]: return
            out.append((kind, text, ms, gatecore.sel_features(kind, text, before, src == "claude", **f)))
        if self.M is not None:
            said, hits = self.M.suggest(before)
            said = measure.clean(before, said) if said else ""
            add("memory", said, 1, mem_hits=math.log1p(hits or 1))
        if mid:
            c = self.W.candidate(before)
            f = gatecore.word_features(c, before, src == "claude")
            if f: add("words", c["rest"], 1, word_p=gatecore.score(self.wg["w"], f))
        if row is not None:
            text, ms = self.model(row, before, src)
            p = model_p(row, before, src, self.W, self.gate)
            if p is not None: add("model", text, ms, model_p=p, model_low=float(p < self.gate["th"]["ai" if src == "claude" else "chat"]))
        return out

    def guess(self, row, before, src):
        bar = self.request_policy.guess_bar
        if bar is not None and row is not None:
            p = model_p(row, before, src, self.W, self.gate)
            if p is not None and p >= bar: return self.model(row, before, src)
        return "", 0


def examples(items, rows, idx, S):
    X, y = [], []
    for i in idx:
        text = items[i]["text"]
        for pos in range(1, len(text)):
            for kind, g, ms, v in S.offers(rows.get((i, pos)), text[:pos], items[i]["src"]):
                X.append(v); y.append(float(measure.first_right(g, text[pos:])))
    return np.array(X), np.array(y)


class Selector:
    """fast: the engine's order (phrase memory and his word are read first and answer at once when they clear the bar;
    the model is asked only when they do not), instead of the best of all three."""
    def __init__(self, S, w, th, fast=True):
        self.S, self.w, self.th, self.fast = S, np.array(w), th, fast

    def __call__(self, row, before, src):
        best = None
        if self.fast:
            for kind, g, ms, v in self.S.offers(None, before, src):
                p = 1 / (1 + math.exp(-float(np.dot(self.w, v))))
                if p >= self.th and (best is None or p > best[0]): best = (p, g, ms)
            if best: return best[1], best[2]
        for kind, g, ms, v in self.S.offers(row, before, src):
            p = 1 / (1 + math.exp(-float(np.dot(self.w, v))))
            if p >= self.th and (best is None or p > best[0]): best = (p, g, ms)
        return (best[1], best[2]) if best else self.S.guess(row, before, src)


if __name__ == "__main__":
    import lengths, ngram, typescore as ts, wordgate as wgmod
    from gate import fit
    from retrain_state import last_retrain
    import memory as mem, words
    ap = argparse.ArgumentParser()
    ap.add_argument("path")
    ap.add_argument("--gap", type=float, default=None)
    ap.add_argument("--gate", default="data/gate.json")
    ap.add_argument("--save", default=None)
    request_policy.add_argument(ap, request_policy.SELECTOR)
    a = ap.parse_args()
    items, rows = ts.load(a.path)
    cut = last_retrain(ROOT)
    W = ngram.Words(ngram.corpus_from(cut, words.Words.SOURCES))
    M = lengths.memory_from(ngram.corpus_from(cut, mem.Memory.SOURCES))
    gate = json.loads((ROOT / a.gate).read_text())
    cal, test = measure.split(items)
    wg = wgmod.fit_gate(items, W, cal, 0.85)
    S = Sources(W, M, gate, wg, policy_mode=a.policy_mode)
    X, y = examples(items, rows, cal, S)
    w = fit(X, y)
    print(f"selector fit on {len(y)} offers from {len(cal)} earlier lines ({100 * y.mean():.1f}% right)")
    ti, tr = wgmod.subset(items, rows, test)
    r0, p0 = measure.replay(ti, tr, measure.live_policy(a.path, a.gate), gap_ms=a.gap)
    measure.show("live" if a.policy_mode == request_policy.SELECTOR else "historical live baseline", r0)
    # the bar from the earlier half: the lowest one whose shown ghosts are 75% right there
    ci, cr = wgmod.subset(items, rows, cal)
    bars = {}
    for th in (0.55, 0.6, 0.65, 0.7, 0.75):
        rc, _ = measure.replay(ci, cr, Selector(S, w, th), gap_ms=a.gap)
        bars[th] = rc
    keys = sorted(k for k in r0 if "/" not in k)
    for th, rc in bars.items():
        r1, p1 = measure.replay(ti, tr, Selector(S, w, th), gap_ms=a.gap)
        print(f"bar {th}: earlier half " + "  ".join(f"{k} right {rc[k]['right']}% saved {rc[k]['saved']}%" for k in keys if k in rc))
        measure.show(f"  later half, bar {th}", r1)
        for k in keys:
            print(f"    {k}: right {measure.paired(p0, p1, k, 'right')} saved {measure.paired(p0, p1, k, 'saved')} "
                  f"wrong/1k {measure.paired(p0, p1, k, 'wrong_1k')}  (saved kept {100 * r1[k]['saved'] / max(0.1, r0[k]['saved']):.0f}%)")
    if a.save:
        Path(a.save).write_text(json.dumps({"names": NAMES, "w": [round(float(v), 4) for v in w], "wordgate": wg, "min": S.minimum}, indent=1))

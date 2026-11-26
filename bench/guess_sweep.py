"""More-bold round (2026-11-17, the user: "a bit less sureness in the guesses and suggest more"). Offline, loads no model.
The live order on a recording: the shipped selector (data/selector.json: phrase memory, the user's own word, the model; bar
`th`) first; when nothing clears it, the model's guess at the lower gate, with the live earlyStart notch
(gatecore.early_bar: at most EARLY_GUESS, EARLY_SPACE after a space). The sweep moves both bars by the setting's
rule (gatecore.bolder_sel): the guess bar to `g`, the selector bar down by SEL_STEP of its distance from SEL_REF.
Numbers only.

    .venv/bin/python -B bench/guess_sweep.py data/bench/big-q4b-lr5-s10.jsonl --bars 0.3,0.2,0.15,0.12,0.1 [--step 0.5] [--half later]

Columns: shown % (ghosts / keys where one could be asked), kept /1k (letters Tab put in that are the user's, less one key a
Tab, per 1,000 typed letters), wrong /1k (shown ghosts whose first word is not the user's, per 1,000 typed letters).
"""
import argparse, json, math, sys
from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parent.parent
for p in (ROOT / "bench", ROOT / "bench/big", ROOT / "engine"):
    if str(p) not in sys.path: sys.path.insert(0, str(p))
import gatecore, measure, request_policy
from selector import Sources, model_p


class Live:
    """The engine's order at one key (server._complete): instant offers, then the model under the selector, then the
    model's guess at the lower (early) bar."""
    def __init__(self, S, sel, g, step=gatecore.SEL_STEP):
        self.S, self.w, self.g, self.info = S, np.array(sel["w"]), g, None
        self.th = gatecore.bolder_sel(sel["th"], g, step)

    def __call__(self, row, before, src):
        self.info = None
        best = None
        for fast in (True, False):
            for kind, text, ms, v in self.S.offers(None if fast else row, before, src):
                p = 1 / (1 + math.exp(-float(np.dot(self.w, v))))
                if p >= self.th and (best is None or p > best[0]): best = (p, text, ms)
            if best: return best[1], best[2]
        if row is None: return "", 0
        bar = gatecore.early_bar(self.g, before, True)
        p = model_p(row, before, src, self.S.W, self.S.gate)
        if p is not None and p >= bar: return self.S.model(row, before, src)
        return "", 0


def stats(items, rows, pol):
    res, per = measure.replay(items, rows, pol)
    letters = sum(l["letters"] for l in per); keys = sum(l["keys"] for l in per)
    gs = [g for l in per for g in l.get("ghosts", [])]
    return {"shown_pct": round(100 * len(gs) / max(1, keys), 1),
            "kept_1k": round(1000 * sum(l["saved"] for l in per) / letters, 1),
            "wrong_1k": round(1000 * sum(1 for g in gs if g[0] == 0) / letters, 1)}


if __name__ == "__main__":
    import lengths, ngram, typescore as ts, wordgate as wgmod
    from retrain_state import last_retrain
    import memory as mem, words
    ap = argparse.ArgumentParser()
    ap.add_argument("path")
    ap.add_argument("--bars", default="0.3,0.25,0.2,0.15,0.1")
    ap.add_argument("--gate", default="data/gate.json")
    ap.add_argument("--selector", default="data/selector.json")
    ap.add_argument("--step", type=float, default=gatecore.SEL_STEP, help="selector bar step per guess-bar step (0 = fixed)")
    ap.add_argument("--half", choices=("all", "later"), default="later",
                    help="later: only the later half by date (the shipped selector was fit on the earlier one)")
    ap.add_argument("--out", default=None)
    a = ap.parse_args()
    items, rows = ts.load(a.path)
    if a.half == "later": items, rows = wgmod.subset(items, rows, measure.split(items)[1])
    # no lines from after the held ones: the word and memory corpus ends at the first held line
    cut = min(last_retrain(ROOT) or float("inf"), min(w for w in measure.dates(items)[0] if w))
    W = ngram.Words(ngram.corpus_from(cut, words.Words.SOURCES))
    M = lengths.memory_from(ngram.corpus_from(cut, mem.Memory.SOURCES))
    gate = json.loads((ROOT / a.gate).read_text())
    sel = json.loads((ROOT / a.selector).read_text())
    S = Sources(W, M, gate, sel["wordgate"], policy_mode=request_policy.CURRENT)
    S.minimum = dict(sel.get("min", S.minimum))
    table, base = {}, None
    for g in [float(x) for x in a.bars.split(",") if x]:
        s = stats(items, rows, Live(S, sel, g, a.step))
        base = base or s
        table[g] = s
        print(f"bar {g:.2f} sel {gatecore.bolder_sel(sel['th'], g, a.step):.3f}  shown {s['shown_pct']:5.1f}% "
              f"({s['shown_pct'] / max(0.1, base['shown_pct']):.2f}x)  kept {s['kept_1k']:6.1f}  "
              f"wrong {s['wrong_1k']:5.1f} ({s['wrong_1k'] / max(0.1, base['wrong_1k']):.2f}x)", flush=True)
    if a.out: Path(a.out).write_text(json.dumps(table, indent=1))

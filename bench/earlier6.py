"""Earlier round step 6: one more notch down the gate, an earlier start after a space, longer runs. The same replay as
`bench/earlier.py length` (recorded tokens, each model's gate refit out of fold); ghosts of 3+ letters as live.
A lower bar at a caret place is the same as a refit with a place intercept: the logistic gate moves by a constant there.

    .venv/bin/python -B bench/earlier6.py data/bench/big-q4b-lr5-s10.jsonl data/bench/big-live.jsonl --out bench/out/earlier6.json
"""
import argparse, json, sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "bench"))
sys.path.insert(0, str(ROOT / "bench/big"))
import earlier as E

W = lambda mx, **k: dict(mode="words", min_words=3, max_words=mx, min_letters=3, **k)
VARIANTS = {
    "original (sentence, th 0.4, 5 letters)": (None, None, dict()),
    "live (words 3-5, guess 0.3, 3 letters)": (0.3, None, W(5)),
    "guess 0.25": (0.25, None, W(5)),
    "guess 0.2": (0.2, None, W(5)),
    "max 6": (0.3, None, W(6)),
    "max 8": (0.3, None, W(8)),
    "guess 0.25 + max 6": (0.25, None, W(6)),
    "guess 0.25 + max 8": (0.25, None, W(8)),
    "guess 0.25 + space 0.2": (0.25, {"space": 0.2}, W(5)),
    "guess 0.25 + space 0.15": (0.25, {"space": 0.15}, W(5)),
    "guess 0.25 + space 0.2 + max 6": (0.25, {"space": 0.2}, W(6)),
    "guess 0.25 + space 0.2 + max 8": (0.25, {"space": 0.2}, W(8)),
    "guess 0.2 + space 0.15 + max 6": (0.2, {"space": 0.15}, W(6)),
    # longer runs: the running chance floor (0.1) ends most runs before 5 words; a lower floor lets them go on
    "guess 0.25 + space 0.2 + max 8 + floor 0.05": (0.25, {"space": 0.2}, W(8, floor=0.05)),
    "guess 0.25 + space 0.2 + max 8 + floor 0.03": (0.25, {"space": 0.2}, W(8, floor=0.03)),
    "guess 0.25 + space 0.2 + max 6 + floor 0.05": (0.25, {"space": 0.2}, W(6, floor=0.05)),
}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("recs", nargs="+")
    ap.add_argument("--out", default=None)
    ap.add_argument("--only", default=None, help="variant names holding this text")
    a = ap.parse_args()
    import score as big
    table = {}
    for rec in a.recs:
        items, rows, P = big.oof(rec)
        p50 = E.q([r.get("prefill_ms", 0) for r in rows.values()], .5)
        for r in rows.values(): r["_prefill50"] = p50
        name = Path(rec).stem
        table[name] = {}
        for vname, (g, places, run) in VARIANTS.items():
            if a.only and a.only not in vname: continue
            pol = E.Policy(P, guess=g, places=places, **run)
            s, _ = E.score(items, rows, pol)
            table[name][vname] = s
            al = s["all"]
            print(f"{name:24s} {vname:40s} shown {al['shown_pct']:5.1f}% row {al['row_shown']:.2f}/{al['row_all']:.3f} "
                  f"kept {al['kept_1k']:6.1f} wrong {al['wrong_1k']:5.1f} grey {al['grey_1k']:6.1f} words {al['words_mean']:.2f} "
                  f"first {al['first_ms']}", flush=True)
    if a.out: Path(a.out).write_text(json.dumps(table, indent=1))


if __name__ == "__main__":
    main()

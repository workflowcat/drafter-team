"""Base-model comparison (round three, 2026-11-14; Andrii open to something other than Qwen). Reads typebench
recordings of the same held-out lines and prints one row per model, per kind of line (claude = English prompts to AI
apps, beeper = Ukrainian chat):

  first word   the model's own next word (healed half word + the word, no gate) is exactly his, share of key spots
  saved/right  letters saved and first words right through a gate refit on that model by held-out folds (bench/gate.py
               summary, the retrain's own test), so each model is judged with a gate made for it
  word ms      ms from the request to the first whole word (p50 / p90): what the gate needs before anything shows
  tok ms       ms per further token (p50); prefill = ms to read the prompt anew at a key (p50)

    .venv/bin/python bench/models.py data/bench/m-qwen3-1.7b.jsonl data/bench/m-gemma-3-1b.jsonl ...
"""
import json, statistics, sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "bench")); sys.path.insert(0, str(ROOT / "engine"))
import typescore as ts
import gatecore


def q(xs, p):
    return sorted(xs)[min(len(xs) - 1, int(len(xs) * p))] if xs else 0


def raw(path):
    items, rows = ts.load(path)
    out = {}
    for (i, pos), r in rows.items():
        it = items[i]; s = out.setdefault(it["src"], {"n": 0, "right": 0, "word": [], "tok": [], "pre": []})
        toks = r["toks"]
        if not toks: continue
        s["n"] += 1; s["pre"].append(r.get("prefill_ms") or 0)
        done = next((t for t in toks if gatecore.word_done(t[0])), None)
        if done: s["word"].append(done[3])
        s["tok"] += [b[3] - a[3] for a, b in zip(toks, toks[1:])]
        w = gatecore.next_word(toks[-1][0])
        s["right"] += bool(w.strip()) and it["text"][pos:].startswith(w)
    return out


if __name__ == "__main__":
    import gate
    print(f"{'recording':28s} {'lines':6s} {'first word':>10s} {'saved':>6s} {'right':>6s} {'shown':>6s} {'word ms':>10s} {'tok ms':>7s} {'prefill':>8s}")
    for p in sys.argv[1:]:
        r = raw(p)
        try: g = gate.summary(p)
        except Exception as e: g = {}
        for src, s in sorted(r.items()):
            gs = g.get(src, {})
            print(f"{Path(p).stem:28s} {src:6s} {100 * s['right'] / max(1, s['n']):9.1f}% {gs.get('saved', 0):5.1f}% {gs.get('right', 0):5.1f}% "
                  f"{gs.get('shown', 0):6d} {statistics.median(s['word']) if s['word'] else 0:4.0f}/{q(s['word'], .9):4.0f} "
                  f"{statistics.median(s['tok']) if s['tok'] else 0:6.1f} {statistics.median(s['pre']) if s['pre'] else 0:7.0f}", flush=True)

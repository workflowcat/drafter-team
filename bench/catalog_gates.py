"""Model catalog round (2026-11-15): a decision gate for each catalog model without his layer, fitted on that model's
own trial recording (the big round, held-137, 24 tokens a key), the same fit as `bench/gate.py --save`. CPU only: no
model is loaded. Numbers only go out (the weights), as the shipped default gate.

    .venv/bin/python -B bench/catalog_gates.py [--root <checkout with data/>] [--out engine/defaults/gates]
    .venv/bin/python -B bench/catalog_gates.py --rec qwen3-4b-layer=big-q4b-lr5-s10.jsonl --out bench/out/q4b
        (--rec id=recording, repeatable: fit only these, e.g. a model with his layer; q4b round 2026-11-16)

The live model keeps data/gate.json; these are for the others (engine/catalog.json "gate")."""
import json, sys
from pathlib import Path

import numpy as np

HERE = Path(__file__).resolve().parent
# --root: the checkout whose data/ to read (a worktree has none); its bench/ helpers are imported, so paths match
ROOT = Path(sys.argv[sys.argv.index("--root") + 1]) if "--root" in sys.argv else HERE.parent
sys.path.insert(0, str(ROOT / "bench"))
import gate, ngram, typescore as ts
from retrain_state import last_retrain

RECORDINGS = {"qwen35-2b": "big-qwen35-2b-base.jsonl", "qwen3-4b": "big-qwen3-4b-base.jsonl",
              "gemma4-e2b": "big-gemma4-e2b-base.jsonl"}


def main():
    out = Path(sys.argv[sys.argv.index("--out") + 1]) if "--out" in sys.argv else HERE.parent / "engine/defaults/gates"
    out.mkdir(parents=True, exist_ok=True)
    W = ngram.Words(ngram.corpus(last_retrain(ROOT)))
    th = gate.saved_th(ROOT / "data/gate.json")
    recs = dict(a.split("=", 1) for i, a in enumerate(sys.argv) if i and sys.argv[i - 1] == "--rec") or RECORDINGS
    for mid, rec in recs.items():
        path = ROOT / "data/bench" / rec
        if not path.exists(): print(f"{mid}: no recording {rec}"); continue
        items, rows = ts.load(str(path))
        X, y, keys = gate.dataset(items, rows, W)
        w = gate.fit(X, y)
        g = {"names": gate.NAMES, "w": [round(float(v), 4) for v in w],
             "from": f"{rec} (catalog round, fitted on the model's own trial recording, numbers only)",
             "th": th, "more": 0.5, "max_words": 3, "words": [2, 0.6, 1], "words_first": False,
             "boost": ts.meta(str(path)).get("boost", 0.0)}
        (out / f"{mid}.json").write_text(json.dumps(g, indent=1) + "\n")
        print(f"{mid}: {len(y)} keys, {y.mean() * 100:.1f}% right as recorded -> {out / (mid + '.json')}")


if __name__ == "__main__":
    main()

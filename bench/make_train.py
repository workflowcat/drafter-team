"""Training set for a LoRA on Andrii's own writing (local only, data/train/): every line from the phrase memory
(Beeper messages he sent, Voice Notes takes, his prompts to Claude) and what he sent while Drafter was on, in the same
shape the engine prompts with ("[App]\\n" + text). Left out, so the tests stay fair: the 30 replay items and the fresh
set (data/replay-fresh.json, drawn again by every retrain from the lines since the last one: the rolling test set)."""
import argparse, json, random, sys
from pathlib import Path
ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "bench"))
from held import Held, norm


APP_TAG = {"cc": "Claude", "codex": "Codex", "beeper": "Beeper"}


def weighted(rows, weights, seed=3):
    """Each corpus row kept round-down(weight) times, plus once more with the leftover share: weights per source."""
    rnd, out = random.Random(seed), []
    for r in rows:
        w = float(weights.get(r["src"], 0))
        out += [r] * (int(w) + (rnd.random() < w - int(w)))
    return out


def from_corpus(corpus, weights, before=None, out=None, seed=3):
    """Training lines from data/corpus.jsonl (bench/corpus.py), per-source weights, nothing dated at or after `before`
    (the held-out cut: the same prompt can sit in typed.jsonl, a take and a session file) and no held line or near-copy.
    -> counts per source of distinct lines used."""
    import corpus as C
    is_held = Held()
    rows, n = [], {}
    for r in C.load(corpus, before=before):
        t = norm(r["text"])
        if is_held(t) or len(t) < 8 or not weights.get(r["src"]): continue
        app = APP_TAG.get(r["src"]) or r.get("app") or "Claude"
        rows.append({"src": r["src"], "text": f"[{app}]\n{t}"})
        n[r["src"]] = n.get(r["src"], 0) + 1
    random.Random(seed).shuffle(rows)
    k = max(60, len(rows) // 20)
    valid, train = rows[:k], weighted(rows[k:], weights, seed)
    random.Random(seed + 1).shuffle(train)
    out = Path(out or ROOT / "data/train"); out.mkdir(parents=True, exist_ok=True)
    (out / "valid.jsonl").write_text("".join(json.dumps({"text": r["text"]}, ensure_ascii=False) + "\n" for r in valid))
    (out / "train.jsonl").write_text("".join(json.dumps({"text": r["text"]}, ensure_ascii=False) + "\n" for r in train))
    print(f"train {len(train)} (weighted), valid {k}, lines per source {n}, held out {len(is_held.texts)}")
    return n


def from_phrases(phrases, typed=None, out=None, held_set=None, before=None):
    """The live layer's own pipeline (29 October): phrase memory rows plus data/typed.jsonl, "[App]\\n" + text, deduped,
    shuffled with seed 3, a 1/20 valid split. Left out: held lines (bench/held.py), every line of `held_set` (a held
    set json, e.g. data/bench/weights/held-137.json) and near-copies, and with `before` every dated row at or after it
    (rows without a date stay). -> (train rows, valid rows)."""
    # a held line, or the same line in another take (the fresh set keeps the first 240 letters of a long line, and
    # typed.jsonl can hold a sentence twice, one a few letters longer), or a longer text holding one
    is_held = Held()
    extra = Held([x["text"] for x in json.loads(Path(held_set).read_text())]) if held_set else (lambda t: False)
    held = is_held.texts
    APP = {"beeper": "Beeper", "voice": "Voice Notes", "claude": "Claude", "typed": "Claude"}
    late = lambda r: before is not None and (r.get("t") or 0) >= before
    rows = []
    for l in Path(phrases).read_text().splitlines():
        if not l.strip(): continue
        r = json.loads(l); t = norm(r["text"])
        if is_held(t) or extra(t) or late(r) or len(t) < 8: continue
        rows.append({"text": f"[{APP.get(r['src'], 'Claude')}]\n{t}"})
    try:
        for l in Path(typed or ROOT / "data/typed.jsonl").read_text().splitlines():
            r = json.loads(l); t = norm(r["text"])
            if not is_held(t) and not extra(t) and not late(r): rows.append({"text": f"[{r.get('app') or 'Claude'}]\n{t}"})
    except FileNotFoundError:
        pass
    rows = list({r["text"]: r for r in rows}.values())
    random.Random(3).shuffle(rows)
    n = max(60, len(rows) // 20)
    out = Path(out or ROOT / "data/train"); out.mkdir(parents=True, exist_ok=True)
    (out / "valid.jsonl").write_text("\n".join(json.dumps(r, ensure_ascii=False) for r in rows[:n]) + "\n")
    (out / "train.jsonl").write_text("\n".join(json.dumps(r, ensure_ascii=False) for r in rows[n:]) + "\n")
    print(f"train {len(rows) - n}, valid {n}, held out {len(held)}" + (f" + {held_set}" if held_set else ""))
    return rows[n:], rows[:n]


def main(argv=None):
    parser = argparse.ArgumentParser(description="Build the held-out training set")
    parser.add_argument("--phrases", type=Path, default=ROOT / "data/phrases.jsonl")
    parser.add_argument("--corpus", type=Path, default=None, help="data/corpus.jsonl: weighted sources instead of --phrases")
    parser.add_argument("--weights", default=None, help='JSON per source, e.g. {"typed": 2, "cc": 1}; default corpus.WEIGHTS')
    parser.add_argument("--before", type=float, default=None, help="leave out every line dated at or after (unix seconds)")
    parser.add_argument("--out", type=Path, default=None)
    parser.add_argument("--typed", type=Path, default=None, help="phrases mode: typed lines (default data/typed.jsonl)")
    parser.add_argument("--held-set", type=Path, default=None, help="also leave out this held set's lines (e.g. data/bench/weights/held-137.json)")
    a = parser.parse_args(argv)
    if a.corpus:
        import corpus as C
        from_corpus(a.corpus, json.loads(a.weights) if a.weights else C.weights(), a.before, a.out)
        return
    from_phrases(a.phrases, a.typed, a.out, a.held_set, a.before)


if __name__ == "__main__":
    main()

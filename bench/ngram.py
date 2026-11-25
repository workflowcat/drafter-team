"""An instant word finisher from his own writing only (no model): finish the word being typed with the word he
most often wrote after the same one or two words, when that is clear. Scored on the fresh replay set with the same
simulated typist as bench/typescore.py, from text written BEFORE the fresh lines (no leak).

    .venv/bin/python bench/ngram.py [min_count] [min_share]
"""
import bisect, json, re, sys
from collections import Counter, defaultdict
from pathlib import Path
from retrain_state import last_retrain

sys.path.insert(0, str(Path(__file__).resolve().parent))
import typescore as ts

ROOT = Path(__file__).resolve().parent.parent
WORD = re.compile(r"[\w'’-]+")


# Keep the benchmark on the actual live finisher, including case and ambiguity rules.
sys.path.insert(0, str(ROOT / "engine"))
from words import Words as LiveWords, RUSSIAN

class Words(LiveWords):
    def __init__(self, lines):
        super().__init__()
        for line in lines:
            if not RUSSIAN.search(line): self.add(line, rebuild=False)
        self.vocab = sorted(self.uni)


def corpus(cut):
    """His words for a bench, as the live finisher reads them: the sources of engine/words.py Words.SOURCES from
    data/corpus.jsonl, dated before cut, minus the test lines, plus drafted lines from before cut (round four
    cleanup; before 2026-11-14 this read the old phrase file and typed lines only)."""
    return corpus_from(cut, LiveWords.SOURCES)


def corpus_from(cut, srcs, newest_first=False):
    """His lines from data/corpus.jsonl (bench/corpus.py) from these sources, dated before cut, minus the test lines,
    plus drafted lines from before cut. newest_first: the newest line first (phrase memory ties go to the newest)."""
    from held import Held
    import corpus as C
    held = Held()
    rows = [r for r in C.load(ROOT / "data/corpus.jsonl", before=cut or None, srcs=set(srcs)) if not held(r["text"])]
    for l in (ROOT / "data/drafts.jsonl").read_text().splitlines():
        if l.strip():
            r = json.loads(l)
            if (not cut or r["t"] < cut) and not held(r["text"]): rows.append({"t": r["t"], "text": r["text"]})
    if newest_first: rows.sort(key=lambda r: -(r.get("t") or 0))
    return [r["text"] for r in rows]


if __name__ == "__main__":
    mc = int(sys.argv[1]) if len(sys.argv) > 1 else 2
    ms = float(sys.argv[2]) if len(sys.argv) > 2 else 0.6
    cut = last_retrain(ROOT)
    W = Words(corpus(cut))
    items = json.loads((ROOT / "data/replay-fresh.json").read_text())
    rows = {(i, p): {"heal": "", "toks": [], "prefill_ms": 0} for i, it in enumerate(items) for p in range(1, len(it["text"]))}
    pol = lambda row, before, src: (W.finish(before, mc, ms), 0.2)
    print(f"vocab {len(W.vocab)} words")
    for k in (2, 3):
        for mp in (1, 2, 3):
            for sh in (0.5, 0.6, 0.75):
                pol = lambda row, before, src, k=k, sh=sh, mp=mp: (W.finish(before, k, sh, mp), 0.2)
                ts.show(f"ngram count>={k} share>={sh} pre>={mp}", ts.simulate(items, rows, pol))


def next_word(W, before, min_count=3, min_share=0.6):
    """After a space: the word he most often wrote after the same two (or one) words."""
    line = before.split("\n")[-1]
    if not line.endswith(" "): return ""
    prev = [w.lower() for w in WORD.findall(re.split(r"[.!?]", line)[-1])]
    for table in ((W.tri.get(tuple(prev[-2:])) if len(prev) >= 2 else None), (W.bi.get(prev[-1]) if len(prev) == 1 else None)):
        if not table: continue
        w, n = table.most_common(1)[0]
        if n >= min_count and n / sum(table.values()) >= min_share: return w
        return ""
    return ""


def both():
    cut = last_retrain(ROOT)
    W = Words(corpus(cut))
    items = json.loads((ROOT / "data/replay-fresh.json").read_text())
    rows = {(i, p): {"heal": "", "toks": [], "prefill_ms": 0} for i, it in enumerate(items) for p in range(1, len(it["text"]))}
    for mc, sh in ((3, 0.6), (3, 0.75), (5, 0.6), (5, 0.75)):
        pol = lambda row, b, s, mc=mc, sh=sh: (W.finish(b, 2, 0.6, 1) or next_word(W, b, mc, sh), 0)
        ts.show(f"finish + next ({mc}, {sh})", ts.simulate(items, rows, pol))

"""The lines the benches test on (data/replay.json, data/replay-fresh.json). Training (bench/make_train.py) and every
word list a bench builds (bench/ngram.py corpus, so the word booster and the word finisher) leave them out, near-copies
too: before 2 November 2026 the word lists held them, so the booster and finisher were scored on lines they knew
(found by the Gemini 4 Argon review)."""
import json, re
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
norm = lambda t: re.sub(r"[ \t]{2,}", " ", t or "").strip()


def texts():
    return {norm(x["text"]) for f in ("replay.json", "replay-fresh.json") if (ROOT / "data" / f).exists()
            for x in json.loads((ROOT / "data" / f).read_text())}


class Held:
    """held(t) -> True for a test line, the same line in another take (the fresh set keeps the first 240 letters of a
    long line), or a longer text that holds one (a Claude prompt pasted into a bigger one)."""
    def __init__(self, lines=None):
        self.texts = texts() if lines is None else {norm(t) for t in lines}
        self.heads = tuple(h for h in self.texts if len(h) >= 30)

    def __call__(self, t):
        t = norm(t)
        return t in self.texts or (len(t) >= 30 and (t.startswith(self.heads) or any(h.startswith(t) or h in t for h in self.heads)))

"""Spoken tics in ghosts (round three, 2026-11-13): voice takes in the training lines could teach the model to type
the way he talks. Counts filler words per 1,000 words in what a layer would write (every recorded continuation of a
typebench recording) and, for scale, in his typed lines and his takes from data/corpus.jsonl. Numbers only.

    .venv/bin/python bench/fillers.py data/bench/r3-typed.jsonl data/bench/r3-voice.jsonl ...
"""
import json, re, sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
FILLERS = re.compile(r"\b(like|kinda|sorta|sort of|kind of|you know|i mean|basically|actually|literally|right\?|um+|uh+|"
                     r"well|so yeah|yeah|ну|типу|короче|ось|якби|значить|так от|еее+|ммм+)\b", re.I | re.U)
WORDS = re.compile(r"[\w'’-]+", re.U)


def rate(texts):
    words = sum(len(WORDS.findall(t)) for t in texts)
    return round(1000 * sum(len(FILLERS.findall(t)) for t in texts) / max(1, words), 1), words


def recording(path):
    out = []
    for l in open(path):
        r = json.loads(l)
        if r.get("toks"): out.append(r["toks"][-1][0])
    return out


if __name__ == "__main__":
    rows = [json.loads(l) for l in (ROOT / "data/corpus.jsonl").read_text().splitlines() if l.strip()]
    for src in ("typed", "cc", "take"):
        r, w = rate([x["text"] for x in rows if x["src"] == src and not (src != "take" and x.get("dictated"))])
        print(f"his {src:6s} lines: {r:5.1f} fillers per 1,000 words ({w} words)")
    for p in sys.argv[1:]:
        r, w = rate(recording(p))
        print(f"{Path(p).stem:24s} ghosts: {r:5.1f} fillers per 1,000 words ({w} words)")

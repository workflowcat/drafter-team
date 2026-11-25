"""Parity round (2026-11-15): what a writing instruction does to the model's text, from recordings of the same slice.
Numbers only. bench/big/score.py gives the usual table (words in a row, kept letters, first word, ms); this adds:

  latin %      keys where the model's text (24 tokens, to the first line end) has more Latin than Cyrillic letters
  words        mean words in that text up to its first sentence end (a shorter-ghost instruction should cut it)
  greet %      keys where it holds a greeting word (hi, hello, привіт, добрий день, вітаю)
  same %       keys whose text is byte-identical to the first recording's (the baseline)

    .venv/bin/python -B bench/parity_score.py data/bench/parity-notes-none.jsonl data/bench/parity-notes-en.jsonl ..."""
import json, re, sys
from pathlib import Path

GREET = re.compile(r"(?i)\b(hi|hello|hey|dear|привіт|вітаю|добрий день|доброго дня)\b")


def text(row):
    t = row["toks"][-1][0] if row.get("toks") else ""
    return t.split("\n")[0]


def load(p):
    return {(r["i"], r["pos"]): text(r) for r in map(json.loads, Path(p).open())}


def stats(rows, base):
    n = len(rows) or 1
    lat = sum(len(re.findall(r"[A-Za-z]", t)) > len(re.findall(r"[А-Яа-яІіЇїЄєҐґ]", t)) for t in rows.values())
    words = [len(re.split(r"(?<=[.!?…])\s", t.strip())[0].split()) for t in rows.values() if t.strip()]
    same = sum(base.get(k) == t for k, t in rows.items())
    return {"keys": len(rows), "latin %": round(100 * lat / n, 1), "words": round(sum(words) / max(1, len(words)), 2),
            "greet %": round(100 * sum(bool(GREET.search(t)) for t in rows.values()) / n, 1), "same %": round(100 * same / n, 1)}


def main():
    paths = sys.argv[1:]
    base = load(paths[0])
    for p in paths:
        print(Path(p).stem, json.dumps(stats(load(p), base)))


if __name__ == "__main__":
    main()

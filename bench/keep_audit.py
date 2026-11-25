"""Keep-list audit (2026-11-13): which words in the autocorrect keep list look like typos of a word he writes?

A take-back (Backspace right after a fix, or a fix mark undone) counts the word he got back; two count as "keep it"
(app/CorrectionRules.swift). Until 13 November a Backspace he meant for his own typo also counted, so the list can
hold typos. This lists every kept or counted word that is one edit (a missed, extra, wrong or swapped letter) from a
word he writes often, with both counts, for Andrii to review. It changes nothing.

  python3 bench/keep_audit.py              # the table (personal words: read it on this Mac only)
  python3 bench/keep_audit.py --summary    # numbers only
  python3 bench/keep_audit.py --data DIR   # another data folder (tests)

Columns: take-backs, how often he wrote the kept word, the near word, how often he wrote that. "suspect" = he wrote
the near word at least 10 times as often as the kept word (or the kept word under 3 times).
"""
import argparse, json, sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent


def distance(a, b):
    """Damerau (optimal string alignment): a swap of two neighbours counts as one, as in the app."""
    d = [[i + j if i * j == 0 else 0 for j in range(len(b) + 1)] for i in range(len(a) + 1)]
    for i in range(1, len(a) + 1):
        for j in range(1, len(b) + 1):
            d[i][j] = min(d[i - 1][j] + 1, d[i][j - 1] + 1, d[i - 1][j - 1] + (a[i - 1] != b[j - 1]))
            if i > 1 and j > 1 and a[i - 1] == b[j - 2] and a[i - 2] == b[j - 1]:
                d[i][j] = min(d[i][j], d[i - 2][j - 2] + 1)
    return d[-1][-1]


def load(data):
    def read(name):
        try: return (data / name).read_text(encoding="utf-8")
        except OSError: return ""
    counts = {}
    try: counts = {k.lower(): int(v) for k, v in json.loads(read("autocorrect-keep.json") or "{}").items()}
    except (ValueError, AttributeError): pass
    for w in read("autocorrect-keep.txt").splitlines():
        w = w.strip().lower()
        if w: counts[w] = max(counts.get(w, 0), 1)   # the legacy list counts as one take-back, as in the app
    used = {}
    try: used = {k.lower(): int(v) for k, v in json.loads(read("myword-counts.json") or "{}").items()}
    except (ValueError, AttributeError): pass
    mine = {w.strip().lower() for w in read("mywords.txt").splitlines() if w.strip()}
    return counts, used, mine


def audit(counts, used, mine, ratio=10):
    """-> rows (word, take-backs, his uses, near word, its uses, suspect), suspects first."""
    # words he writes: counted ones (5+ uses) and the 3+ list (no count there: taken as 3)
    known = dict(used)
    for w in mine: known.setdefault(w, 3)
    by_first = {}
    for w, n in known.items():
        if w: by_first.setdefault(w[0], []).append((w, n))
    rows = []
    for word, back in counts.items():
        if len(word) < 2: continue
        own = known.get(word, 0)
        # same first letter, or the first two letters swapped
        pool = by_first.get(word[0], []) + (by_first.get(word[1], []) if word[1] != word[0] else [])
        near = [(w, n) for w, n in pool if w != word and abs(len(w) - len(word)) <= 1 and distance(word, w) == 1]
        if not near: continue
        w, n = max(near, key=lambda x: (x[1], x[0]))
        suspect = n >= ratio * max(own, 1) or (own < 3 and n >= 5)
        rows.append((word, back, own, w, n, suspect))
    rows.sort(key=lambda r: (not r[5], -r[4], r[0]))
    return rows


def main(argv=None):
    p = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    p.add_argument("--data", type=Path, default=ROOT / "data")
    p.add_argument("--summary", action="store_true", help="numbers only, no words")
    a = p.parse_args(argv)
    counts, used, mine = load(a.data)
    rows = audit(counts, used, mine)
    kept = sum(1 for n in counts.values() if n >= 2)
    suspects = [r for r in rows if r[5]]
    print(f"keep list: {len(counts)} words counted, {kept} kept (2+ take-backs)")
    print(f"one edit from a word he writes: {len(rows)}; suspect typos: {len(suspects)} "
          f"({sum(1 for r in suspects if r[1] >= 2)} of them kept)")
    if a.summary: return 0
    print()
    print(f"{'kept word':<24} {'backs':>5} {'uses':>5}  {'near word':<24} {'uses':>6}")
    for word, back, own, w, n, suspect in rows:
        print(f"{word:<24} {back:>5} {own:>5}  {w:<24} {n:>6}  {'suspect' if suspect else ''}")
    return 0


if __name__ == "__main__":
    sys.exit(main())

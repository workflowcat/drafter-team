"""Nightly tables for the ranked typo fix (app/TypoRank.swift), 15 November 2026. No model.

- data/typo-bigrams.tsv: "prev<TAB>next<TAB>count" for word pairs he wrote twice or more (his corpus, as engine/words.py
  reads it); the context term of the ranker.
- data/typo-gate.json: the logistic gate refit on his labelled offers and fixes from data/app.log. Each offer or fix
  line carries its numbers (" f=cost,count,gap,ctx,len,uk,ai,chat,mac;p=0.83", no words). Labels: an offer he took = 1,
  one he typed past or let expire = 0; an automatic fix that stayed = 1, one he took back (and left standing) = 0; a fix
  his own fast Backspace hit is not a label. Under 40 labels the app keeps its hand-set gate.

    .venv/bin/python -B engine/typos.py [--data DIR] [--dry-run]
"""
import argparse, json, math, os, re
from collections import Counter
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
WORD = re.compile(r"[\w'’ʼ-]+")
RUSSIAN = re.compile(r"[ыэъёЫЭЪЁ]")
SOURCES = ("typed", "take", "cc", "codex", "beeper", "fb", "vault", "import")
NAMES = ["cost", "count", "gap", "ctx", "len", "uk", "ai", "chat", "mac"]
MIN_LABELS = 40


def lines_of(data):
    """His lines, as Words.load reads them: the corpus, else typed and drafts. Test rows are never learned."""
    out = []
    corpus = data / "corpus.jsonl"
    if corpus.exists():
        for l in corpus.read_text().splitlines():
            try: r = json.loads(l)
            except ValueError: continue
            if r.get("src") in SOURCES: out.append(r.get("text") or "")
    else:
        for f in ("typed.jsonl", "drafts.jsonl"):
            p = data / f
            if p.exists():
                for l in p.read_text().splitlines():
                    try: out.append(json.loads(l).get("text") or "")
                    except ValueError: pass
    return [l for l in out if "⟦drafter-test⟧" not in l]


def bigrams(lines, min_count=2):
    c = Counter()
    for line in lines:
        for sent in re.split(r"[\n.!?]+", line):
            if RUSSIAN.search(sent): continue
            ws = [w.lower() for w in WORD.findall(sent)]
            c.update(zip(ws, ws[1:]))
    return {k: n for k, n in c.items() if n >= min_count and all(re.fullmatch(r"[^\W\d_]+(['’ʼ-][^\W\d_]+)*", w) for w in k)}


def write_bigrams(pairs, path):
    tmp = Path(str(path) + ".tmp")
    tmp.write_text("".join(f"{a}\t{b}\t{n}\n" for (a, b), n in sorted(pairs.items())))
    os.replace(tmp, path)


FEAT = re.compile(r" f=([-\d.,]+);p=([\d.]+)")


def labels(log_lines):
    """(features, label) from app.log lines, numbers only."""
    out, pending = [], None
    for l in log_lines:
        rest = l.split(" ", 1)[1] if " " in l else l
        m = FEAT.search(rest)
        if rest.startswith("fix offer space typo") and m:
            how = rest.split()[4]
            if how in ("taken", "typed", "expired"):
                out.append(([float(x) for x in m.group(1).split(",")], 1 if how == "taken" else 0))
            continue
        if rest.startswith("autocorrect typo") and m:
            if pending: out.append(pending)
            pending = ([float(x) for x in m.group(1).split(",")], 1)
            continue
        if pending and rest.startswith("autocorrect kept, backspace"): pending = None
        elif pending and rest.startswith("autocorrect taken back (typo)"): pending = (pending[0], 0)
        elif pending and rest.startswith("autocorrect take-back not counted"): pending = None
    if pending: out.append(pending)
    return [(f, y) for f, y in out if len(f) == len(NAMES)]


def fit(rows, l2=0.05, steps=3000, lr=0.1):
    """Plain logistic regression by gradient descent, features scaled; weights returned on the raw scale."""
    n, k = len(rows), len(NAMES)
    mean = [sum(r[0][j] for r in rows) / n for j in range(k)]
    sd = [max(1e-6, math.sqrt(sum((r[0][j] - mean[j]) ** 2 for r in rows) / n)) for j in range(k)]
    X = [[(r[0][j] - mean[j]) / sd[j] for j in range(k)] for r in rows]
    y = [r[1] for r in rows]
    w, b = [0.0] * k, 0.0
    for _ in range(steps):
        gw, gb = [l2 * x for x in w], 0.0
        for xi, yi in zip(X, y):
            p = 1 / (1 + math.exp(-max(-30, min(30, b + sum(a * c for a, c in zip(w, xi))))))
            for j in range(k): gw[j] += (p - yi) * xi[j] / n
            gb += (p - yi) / n
        w = [a - lr * g for a, g in zip(w, gw)]; b -= lr * gb
    raw = [w[j] / sd[j] for j in range(k)]
    return b - sum(raw[j] * mean[j] for j in range(k)), raw


def prob(bias, w, f): return 1 / (1 + math.exp(-max(-30, min(30, bias + sum(a * c for a, c in zip(w, f))))))


def trade(rows, bias, w, cuts=(0.5, 0.6, 0.7, 0.8, 0.9)):
    """Offers shown and share accepted at each threshold."""
    out = []
    for c in cuts:
        shown = [y for f, y in rows if prob(bias, w, f) >= c]
        out.append({"at": c, "shown": len(shown), "accepted": sum(shown), "share": round(sum(shown) / len(shown), 3) if shown else None})
    return out


def threshold(rows, bias, w, aim=0.8, least=10):
    """The lowest threshold whose shown offers he accepts at `aim` or more (with at least `least` shown)."""
    for c in [x / 100 for x in range(30, 100)]:
        shown = [y for f, y in rows if prob(bias, w, f) >= c]
        if len(shown) >= least and sum(shown) / len(shown) >= aim: return c
    return 0.99


def gate(rows):
    if len(rows) < MIN_LABELS: return None
    bias, w = fit(rows)
    at = threshold(rows, bias, w)
    return {"bias": round(bias, 4), "weights": [round(x, 4) for x in w], "offerAt": at, "fixAt": max(0.95, min(0.99, at + 0.2)),
            "labels": len(rows), "trade": trade(rows, bias, w)}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--data", default=str(ROOT / "data"))
    ap.add_argument("--dry-run", action="store_true")
    a = ap.parse_args()
    data = Path(a.data)
    pairs = bigrams(lines_of(data))
    log = (data / "app.log").read_text(errors="replace").splitlines() if (data / "app.log").exists() else []
    rows = labels(log)
    g = gate(rows)
    print(f"typos: {len(pairs)} bigrams; {len(rows)} labels; gate {'fitted' if g else 'hand-set (too few labels)'}")
    if a.dry_run: return
    write_bigrams(pairs, data / "typo-bigrams.tsv")
    if g:
        tmp = data / "typo-gate.json.tmp"; tmp.write_text(json.dumps(g)); os.replace(tmp, data / "typo-gate.json")


if __name__ == "__main__":
    main()

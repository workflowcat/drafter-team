"""Kept letters (docs/roadmap.md item 5, built 2026-11-13): how much of the grey text he took with Tab is still there
in what he sends, per app and per length of the ghost when it showed. Copilot's measure: accepted and kept
characters, not accept rate.

data/accepted.jsonl has each Tab: the text taken, the 120 characters before it, the app and (since 2026-11-13) the
ghost's length when shown. The line he sent next in the same app (data/typed.jsonl, Return) or left as a draft
(data/drafts.jsonl) within 30 minutes is searched for the characters before the take; the letters right after them
that match the taken text are kept. A take whose spot is not found in that line (an earlier line of a multi-line
message, a field he cleared) counts as unmatched, not as lost.

    .venv/bin/python bench/kept.py [days]          # prints the table (bench/week.py adds it to the weekly page)
"""
import json, sys, time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
BUCKETS = ((0, 5, "<5"), (5, 10, "5-9"), (10, 15, "10-14"), (15, 20, "15-19"), (20, 10**6, "20+"))
WINDOW = 1800


def bucket(n):
    if n is None: return "?"
    return next(b for lo, hi, b in BUCKETS if lo <= n < hi)


def kept_letters(a, line):
    """Letters of the take `a` still in `line` at its spot (after the same characters), or None when not found."""
    text, before = a.get("text") or "", (a.get("before") or "").split("\n")[-1]
    anchor = before[-16:]
    if not anchor.strip():   # a take at the start of a line: only when the line starts with it
        at = 0 if line.lstrip().startswith(text.strip()[:3]) else -1
        start = len(line) - len(line.lstrip()) if at == 0 else -1
    else:
        i = line.rfind(anchor)
        start = i + len(anchor) if i >= 0 else -1
    if start < 0: return None
    rest = line[start:]
    n = 0
    for x, y in zip(text, rest):
        if x != y: break
        n += 1
    return sum(1 for ch in text[:n] if not ch.isspace())


def measure(acc, sent, drafts):
    """-> {app: {"taken", "kept", "matched", "takes", "by": {bucket: [taken, kept]}}}, letters without spaces."""
    lines = sorted([*sent, *drafts], key=lambda r: r.get("t", 0))
    out = {}
    for a in sorted(acc, key=lambda r: r.get("t", 0)):
        app = a.get("app") or "?"
        r = out.setdefault(app, {"taken": 0, "kept": 0, "matched": 0, "takes": 0, "by": {}})
        taken = sum(1 for ch in a.get("text") or "" if not ch.isspace())
        r["takes"] += 1
        nxt = next((l for l in lines if l.get("app") == app and a["t"] < l.get("t", 0) <= a["t"] + WINDOW
                    and kept_letters(a, l.get("text") or "") is not None), None)
        if nxt is None: continue
        k = kept_letters(a, nxt["text"])
        r["matched"] += 1; r["taken"] += taken; r["kept"] += k
        b = r["by"].setdefault(bucket(a.get("ghost_len")), [0, 0]); b[0] += taken; b[1] += k
    return out


def rows(name, since):
    try:
        return [r for r in (json.loads(l) for l in (ROOT / "data" / name).read_text().splitlines() if l.strip()) if r.get("t", 0) >= since]
    except Exception: return []


def report(days=7):
    since = time.time() - days * 86400
    res = measure(rows("accepted.jsonl", since), rows("typed.jsonl", since), rows("drafts.jsonl", since))
    out = []
    for app, r in sorted(res.items(), key=lambda x: -x[1]["takes"]):
        share = f"{100 * r['kept'] / r['taken']:.0f}%" if r["taken"] else "-"
        by = ", ".join(f"{b} {k}/{t}" for b, (t, k) in sorted(r["by"].items(), key=lambda x: ([b for *_, b in BUCKETS] + ["?"]).index(x[0])))
        out.append(f"- {app}: {r['takes']} Tab, {r['matched']} found in the sent line; {r['kept']} of {r['taken']} letters kept ({share})"
                   + (f"; by ghost length kept/taken: {by}" if by else ""))
    return out


if __name__ == "__main__":
    print("\n".join(report(int(sys.argv[1]) if len(sys.argv) > 1 else 7)) or "no takes")

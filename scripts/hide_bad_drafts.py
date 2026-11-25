#!/usr/bin/env python3
"""Typed-history rows that are not clean drafts, hidden from the window without touching the stores (2026-11-14).

    .venv/bin/python -B scripts/hide_bad_drafts.py              # dry run: counts only (the default)
    .venv/bin/python -B scripts/hide_bad_drafts.py --apply      # writes their ids to data/drafts-hidden.json
    .venv/bin/python -B scripts/hide_bad_drafts.py --shapes ACD # A only after a look by hand; B is never hidden
    .venv/bin/python -B scripts/hide_bad_drafts.py --undo       # takes this script's entries out again

Reads data/drafts.jsonl (drafts, id "draft<t>") and data/typed.jsonl (sent lines, id "sent<t>"); never rewrites them.
The sidecar holds {"hidden": [{"kind": "draft"|"sent", "t": <row t>, "shape": "A".."D", "by": "hide_bad_drafts"}]};
History.read skips those rows when it lists (app/DraftCaptureRules.swift `DraftHide`). Output is numbers only.

Shapes (rules as in docs/rounds/2026-11-14-capture.md):
  A  not his writing: 150+ characters of web page text - 3+ footer/navigation words, or 10+ words run together
     (a small letter then a capital, "HomeAbout"), or 3+ run together with 30%+ capitalised words.
  B  cut by the old tail window: a draft of 1990+ characters (suffix 2000) or a sent line of exactly 600 (suffix 600)
     that starts with a letter or digit (mid-word).
  C  the same text again (spaces and case aside) in the same app within --minutes (default 5) of the row before.
  D  a strict prefix of a later row of the same app within --minutes. Of C and D only the latest row of a chain stays.
Hidden by default: C and D only (earlier copies; their text lives on in the longer row). B rows are his text with a cut
start: never hidden, the journal shows them from the first whole word (DraftCaptureRules.shownText). A is hidden only
when named in --shapes, after the rows were checked by hand.
"""
from __future__ import annotations

import argparse
import collections
import json
import re
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
BY = "hide_bad_drafts"

FOOT = re.compile(r"(?i)(©|privacy|terms of|cookie|all rights reserved|sign in|log in|subscribe|newsletter"
                  r"|політика конфіденційності|умови використання|усі права захищені)")
GLUED = re.compile(r"[a-zа-яіїєґ][A-ZА-ЯІЇЄҐ][a-zа-яіїєґ]")
WORD = re.compile(r"\w+")

KINDS = {"Beeper": "chat", "Slack": "chat", "WhatsApp": "chat", "Telegram": "chat", "Messages": "chat", "Signal": "chat",
         "Discord": "chat", "Claude": "ai", "ChatGPT": "ai", "Codex": "ai", "Perplexity": "ai",
         "Dia": "browser", "Safari": "browser", "Google Chrome": "browser", "Arc": "browser", "Mail": "mail"}


def norm(s: str) -> str:
    return " ".join(s.replace(" ", " ").split()).lower()


def web_text(t: str) -> bool:
    """Shape A from the text alone (old rows carry no key counts)."""
    if len(t) < 150:
        return False
    words = WORD.findall(t)
    cap = sum(w[0].isupper() for w in words) / max(len(words), 1)
    glued = len(GLUED.findall(t))
    return len(FOOT.findall(t)) >= 3 or glued >= 10 or (glued >= 3 and cap >= 0.3)


def tail_cut(t: str, kind: str) -> bool:
    """Shape B: the row is as long as the old tail window and starts inside a word."""
    capped = len(t) >= 1990 if kind == "draft" else len(t) == 600
    return capped and t[:1].isalnum()


def load(path: Path, kind: str) -> list[dict]:
    rows = []
    if not path.exists():
        return rows
    for line in path.read_text(encoding="utf-8", errors="replace").splitlines():
        try:
            r = json.loads(line)
        except ValueError:
            continue
        if isinstance(r, dict) and isinstance(r.get("text"), str) and isinstance(r.get("t"), (int, float)):
            rows.append({"kind": kind, "t": float(r["t"]), "app": r.get("app") or "", "text": r["text"]})
    return rows


def classify(rows: list[dict], minutes: float = 5) -> dict[tuple, set]:
    """(kind, t) -> set of shapes. Rows of both files together, by time."""
    out: dict[tuple, set] = collections.defaultdict(set)
    rows = sorted(rows, key=lambda r: r["t"])
    win = minutes * 60
    for r in rows:
        if web_text(r["text"]):
            out[(r["kind"], r["t"])].add("A")
        if tail_cut(r["text"], r["kind"]):
            out[(r["kind"], r["t"])].add("B")
    for i, r in enumerate(rows):
        if r["kind"] != "draft":
            continue   # a sent line ends a message; only drafts are earlier copies of it
        n = norm(r["text"])
        if not n:
            continue
        for later in rows[i + 1:]:
            if later["t"] - r["t"] > win:
                break
            if later["app"] != r["app"]:
                continue
            m = norm(later["text"])
            if m == n:
                out[(r["kind"], r["t"])].add("C")
                break
            if m.startswith(n):
                out[(r["kind"], r["t"])].add("D")
                break
    return out


def app_kind(app: str) -> str:
    return KINDS.get(app, "other")


def report(rows: list[dict], shapes: dict, days: int) -> None:
    since = time.time() - days * 86400 if days else 0
    inside = [r for r in rows if r["t"] >= since]
    print(f"rows: {len(inside)} (drafts {sum(r['kind'] == 'draft' for r in inside)}, sent {sum(r['kind'] == 'sent' for r in inside)})"
          + (f" in the last {days} days" if days else ""))
    per = collections.Counter()
    by_kind: dict = collections.defaultdict(collections.Counter)
    by_day: dict = collections.defaultdict(collections.Counter)
    by_file: dict = collections.defaultdict(collections.Counter)
    total = 0
    for r in inside:
        s = shapes.get((r["kind"], r["t"]))
        if not s:
            continue
        total += 1
        for x in s:
            per[x] += 1
            by_kind[app_kind(r["app"])][x] += 1
            by_day[time.strftime("%Y-%m-%d", time.localtime(r["t"]))][x] += 1
            by_file[r["kind"]][x] += 1
    cols = "ABCD"
    print(f"rows matching any shape: {total}")
    print("shape   " + "  ".join(f"{c:>4}" for c in cols))
    print("all     " + "  ".join(f"{per[c]:>4}" for c in cols))
    for k in sorted(by_file):
        print(f"{k:<8}" + "  ".join(f"{by_file[k][c]:>4}" for c in cols))
    print("by app kind")
    for k in sorted(by_kind):
        print(f"  {k:<8}" + "  ".join(f"{by_kind[k][c]:>4}" for c in cols)
              + f"   of {sum(app_kind(r['app']) == k for r in inside)} rows")
    print("by day")
    for d in sorted(by_day):
        print(f"  {d}" + "  ".join(f"{by_day[d][c]:>4}" for c in cols))


def read_sidecar(path: Path) -> list[dict]:
    try:
        j = json.loads(path.read_text(encoding="utf-8"))
        return [e for e in j.get("hidden", []) if isinstance(e, dict)]
    except (OSError, ValueError, AttributeError):
        return []


def write_sidecar(path: Path, entries: list[dict]) -> None:
    tmp = path.with_name("." + path.name + ".tmp")
    tmp.write_text(json.dumps({"hidden": entries}, ensure_ascii=False, indent=1) + "\n", encoding="utf-8")
    tmp.replace(path)


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--data", type=Path, default=ROOT / "data")
    ap.add_argument("--days", type=int, default=14, help="window for the counts and for --apply (0 = all rows)")
    ap.add_argument("--minutes", type=float, default=5, help="window for shapes C and D")
    ap.add_argument("--shapes", default="CD", help="which shapes --apply hides: C, D (default), A after a check by hand; never B")
    g = ap.add_mutually_exclusive_group()
    g.add_argument("--dry-run", action="store_true", help="counts only (the default)")
    g.add_argument("--apply", action="store_true", help="write the ids to data/drafts-hidden.json")
    g.add_argument("--undo", action="store_true", help="remove this script's entries from data/drafts-hidden.json")
    a = ap.parse_args(argv)
    a.shapes = a.shapes.upper()
    if "B" in a.shapes or set(a.shapes) - set("ACD"):
        ap.error("--shapes takes A, C and D; B rows are his text and are never hidden")
    side = a.data / "drafts-hidden.json"

    if a.undo:
        old = read_sidecar(side)
        keep = [e for e in old if e.get("by") != BY]
        if side.exists():
            write_sidecar(side, keep)
        print(f"removed {len(old) - len(keep)} entries, {len(keep)} left")
        return 0

    rows = load(a.data / "drafts.jsonl", "draft") + load(a.data / "typed.jsonl", "sent")
    shapes = classify(rows, a.minutes)
    report(rows, shapes, a.days)
    since = time.time() - a.days * 86400 if a.days else 0
    pick = {(r["kind"], r["t"]): sorted(shapes[(r["kind"], r["t"])] & set(a.shapes))
            for r in rows if r["t"] >= since and shapes.get((r["kind"], r["t"])) and shapes[(r["kind"], r["t"])] & set(a.shapes)}
    print(f"would hide: {len(pick)} rows (shapes {a.shapes})")
    if not a.apply:
        return 0
    old = read_sidecar(side)
    have = {(e.get("kind"), e.get("t")) for e in old}
    new = [{"kind": k, "t": t, "shape": "".join(s), "by": BY} for (k, t), s in sorted(pick.items(), key=lambda x: x[0][1])
           if (k, t) not in have]
    write_sidecar(side, old + new)
    print(f"wrote {len(new)} new entries to {side.name} ({len(old) + len(new)} in all)")
    return 0


if __name__ == "__main__":
    sys.exit(main())

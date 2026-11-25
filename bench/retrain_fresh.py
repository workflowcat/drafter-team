"""Retrain round (2026-11-16): the live layer's phrase memory rebuilt now, with a date on each row, so a training set
can be cut at a time (bench/make_train.py --before). Loads no model; reads his files read-only.

    .venv/bin/python -B bench/retrain_fresh.py --out data/bench/retrain/work/phrases.jsonl [--beeper] [--days 60]

Same sources, filters and order as `engine/memory.py build` (the 29 October layer was trained on its output plus
data/typed.jsonl): Beeper (only with --beeper; the 8 November build had none, launchd could not find `beeper`),
Voice Notes takes (no date), his Claude Code prompts of the last `days` (date of the turn), typed lines (their date).
Each row: {"src", "t", "text"}; t = 0 when unknown."""
import argparse, glob, json, os, sys, time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "engine"))
import memory as M


def iso(s):
    from datetime import datetime
    try: return datetime.fromisoformat(s.replace("Z", "+00:00")).timestamp()
    except Exception: return 0.0


def claude_prompts(days=60):
    """memory.claude_prompts with the turn's time: (t, text)."""
    since = time.time() - days * 86400
    for f in glob.glob(str(Path.home() / ".claude/projects/*/*.jsonl")):
        if os.path.getmtime(f) <= since: continue
        try:
            with open(f, errors="ignore") as h:
                for line in h:
                    if '"type":"user"' not in line or '"userType":"external"' not in line: continue
                    try: d = json.loads(line)
                    except Exception: continue
                    c = (d.get("message") or {}).get("content")
                    if not isinstance(c, str) or d.get("isMeta") or d.get("isSidechain"): continue
                    if d.get("entrypoint") not in (None, "cli", "claude-desktop", "claude-vscode"): continue
                    c = c.strip()
                    if 12 <= len(c) <= 600 and not M.SKIP_PROMPT.search(c): yield iso(d.get("timestamp") or ""), c
        except Exception:
            continue


def typed(path):
    try:
        for l in Path(path).read_text().splitlines():
            if l.strip():
                r = json.loads(l); yield float(r.get("t") or 0), r["text"]
    except FileNotFoundError:
        return


def build(out, beeper=False, days=60, typed_path=None):
    seen, rows, n = set(), [], {}
    srcs = (("beeper", ((0.0, x) for x in (M.beeper() if beeper else []))),
            ("voice", ((0.0, x) for x in M.voice_notes())),
            ("claude", claude_prompts(days)),
            ("typed", typed(typed_path or M.DATA / "typed.jsonl")))
    for src, items in srcs:
        for t, x in items:
            x = x.strip()
            if len(M.WORD.findall(x)) < 3 or x in seen: continue
            seen.add(x); rows.append({"src": src, "t": round(t), "text": x}); n[src] = n.get(src, 0) + 1
    out = Path(out); out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text("".join(json.dumps(r, ensure_ascii=False) + "\n" for r in rows))
    print(f"{len(rows)} phrases -> {out}: {n}")
    return rows


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", required=True); ap.add_argument("--beeper", action="store_true")
    ap.add_argument("--days", type=int, default=60); ap.add_argument("--typed", default=None)
    a = ap.parse_args()
    build(a.out, a.beeper, a.days, a.typed)

"""Live ghost numbers from data/app.log (numbers only, never the text): how soon and how often right.

    .venv/bin/python -B bench/live_ghosts.py [--days 7] [--log data/app.log] [--json]

Per local ghost shown (`shown <app> <ms>ms engine <ms>ms ...` lines; Claude's pause ghosts are `claude-pause` and
left out), paired in order with the `ghost ...` line that ends it (written only when some of it was taken with Tab
or typed by hand; no line = dropped unused):
- time: post -> shown (`<ms>ms`), key -> first grey text (` key N`, builds since 13 November), engine, both AX reads;
- taken: share of shown ghosts with any Tab take, by ghost letters and by app kind;
- typed through: he typed the ghost's letters by hand and took nothing;
- ready: the engine answered in 0 ms (a prepared look-ahead/branch hit, phrase memory or his word); `ahead-days.json`
  holds the engine's own made/used counts per day;
- late: `late` lines (builds after round five): answers dropped because he had typed on past them.
"""
import argparse, datetime as dt, json, re, sys
from collections import Counter, defaultdict
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
CHAT = {"com.automattic.beeper.desktop", "com.tinyspeck.slackmacgap", "net.whatsapp.WhatsApp", "ru.keepcoder.Telegram",
        "com.apple.MobileSMS", "com.hnc.Discord", "com.microsoft.teams2", "org.whispersystems.signal-desktop"}
AI = {"com.openai.chat", "com.openai.codex", "com.anthropic.claudefordesktop", "com.perplexity.mac"}
BUCKETS = ((0, 5, "under 5"), (5, 10, "5-9"), (10, 15, "10-14"), (15, 20, "15-19"), (20, 10**6, "20+"))

SHOWN = re.compile(r"^(\S+) shown (\S+) (\d+)ms engine (\d+)ms(.*)$")
GHOST = re.compile(r"^(\S+) ghost (\S+) (\S+) len (\d+) word (\d+) taken (\d+) typed (\d+)")
LATE = re.compile(r"^(\S+) late (\S+) (\d+)ms(.*)$")


def kind(app):
    return "ai" if app in AI else "chat" if app in CHAT else "other"


def bucket(n):
    return next(name for lo, hi, name in BUCKETS if lo <= n < hi)


def pct(a, q):
    if not a: return None
    s = sorted(a)
    return s[min(len(s) - 1, int(len(s) * q))]


def num(rest, key):
    m = re.search(rf" {key} (\d+)ms", rest)
    return int(m.group(1)) if m else None


def parse(lines, since, until="9999"):
    """Each local ghost shown, with its outcome; plus the late lines. Text after « is never read."""
    shown, late, open_ = [], [], {}
    for l in lines:
        l = l.split("«")[0].rstrip("\n")
        if l[:20] < since or l[:20] >= until: continue
        m = SHOWN.match(l)
        if m:
            t, app, ms, eng, rest = m.groups()
            if " fix " in rest + " " or rest.startswith(" claude"): continue   # a mid-word fix offer; Claude before round two
            ln = re.search(r" len (\d+)", rest)
            src = rest.split()[0] if rest.split() and not rest.split()[0][0].isdigit() and rest.split()[0] not in ("ctx", "predicted", "part", "key", "ax", "ax2", "len", "t") else "model"
            row = {"t": t, "app": app, "kind": kind(app), "ms": int(ms), "engine": int(eng), "src": src,
                   "len": int(ln.group(1)) if ln else None, "key": num(rest, "key"), "ax": num(rest, "ax"),
                   "ax2": num(rest, "ax2"), "predicted": " predicted" in rest, "part": " part" in rest,
                   "taken": 0, "typed": 0, "ended": False}
            shown.append(row); open_[app] = row
            continue
        m = GHOST.match(l)
        if m:
            t, app, src, ln, word, taken, typed = m.groups()
            row = open_.pop(app, None)
            if row and not row["ended"]:
                row.update(taken=int(taken), typed=int(typed), ended=True, glen=int(ln))
            continue
        m = LATE.match(l)
        if m: late.append({"app": m.group(2), "kind": kind(m.group(2)), "ms": int(m.group(3))})
    return shown, late


def summary(shown, late, data=ROOT / "data"):
    out = {"shown": len(shown)}
    def lat(rows, f):
        a = [r[f] for r in rows if r.get(f) is not None]
        return {"n": len(a), "p50": pct(a, .5), "p90": pct(a, .9)}
    out["post_to_shown"] = lat(shown, "ms")
    out["key_to_shown"] = lat(shown, "key")
    out["key_to_shown_predicted"] = lat([r for r in shown if r["predicted"]], "key")
    out["key_to_shown_waited"] = lat([r for r in shown if not r["predicted"]], "key")
    out["engine"] = lat([r for r in shown if r["engine"] > 0], "engine")
    out["ax"], out["ax2"] = lat(shown, "ax"), lat(shown, "ax2")
    out["ready_0ms"] = sum(r["engine"] == 0 for r in shown)
    def taken(rows):
        n = len(rows); tk = sum(r["taken"] > 0 for r in rows); ty = sum(r["typed"] > 0 and r["taken"] == 0 for r in rows)
        return {"shown": n, "taken": tk, "taken%": round(100 * tk / n, 1) if n else None,
                "typed_through": ty, "typed%": round(100 * ty / n, 1) if n else None}
    out["all"] = taken(shown)
    by = defaultdict(list)
    for r in shown:
        if r["len"] is not None: by[bucket(r["len"])].append(r)
    out["by_len"] = {b: taken(by[b]) for _, _, b in BUCKETS if by[b]}
    byk = defaultdict(list)
    for r in shown: byk[r["kind"]].append(r)
    out["by_kind"] = {k: {**taken(v), "post_to_shown_p50": pct([r["ms"] for r in v], .5),
                          "post_to_shown_p90": pct([r["ms"] for r in v], .9)} for k, v in sorted(byk.items())}
    bys = defaultdict(list)
    for r in shown: bys[r["src"]].append(r)
    out["by_src"] = {k: taken(v) for k, v in sorted(bys.items(), key=lambda x: -len(x[1]))}
    # ended ghosts by their own length (the ghost line has it in every build; dropped ghosts unknown before 13 Nov)
    be = defaultdict(Counter)
    for r in shown:
        if r["ended"]: c = be[bucket(r["glen"])]; c["ended"] += 1; c["taken"] += r["taken"] > 0
    out["ended_by_len"] = {b: {**be[b], "taken% of ended": round(100 * be[b]["taken"] / be[b]["ended"], 1)} for _, _, b in BUCKETS if be[b]}
    out["late"] = {"n": len(late), "by_kind": dict(Counter(r["kind"] for r in late))}
    try:
        days = json.loads((Path(data) / "ahead-days.json").read_text())
        out["ahead_days"] = days
    except Exception:
        out["ahead_days"] = {}
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--days", type=int, default=7)
    ap.add_argument("--log", default=str(ROOT / "data/app.log"))
    ap.add_argument("--json", action="store_true")
    ap.add_argument("--since", help="UTC time, e.g. 2026-11-13T21:57:29Z (the first build that logs key and len)")
    ap.add_argument("--until", default="9999")
    a = ap.parse_args()
    since = a.since or (dt.datetime.now(dt.timezone.utc) - dt.timedelta(days=a.days)).strftime("%Y-%m-%dT%H:%M:%SZ")
    with open(a.log, errors="replace") as f:
        s = summary(*parse(f, since, a.until), data=Path(a.log).parent)
    if a.json: print(json.dumps(s, indent=1)); return
    print(f"local ghosts shown {since} .. {a.until}: {s['shown']}")
    for k in ("post_to_shown", "key_to_shown", "key_to_shown_predicted", "key_to_shown_waited", "engine", "ax", "ax2"):
        v = s[k]; print(f"  {k:24} n {v['n']:6}  p50 {v['p50']}  p90 {v['p90']}")
    print(f"  engine 0 ms (ready): {s['ready_0ms']}")
    print(f"  all: {s['all']}")
    for k in ("by_len", "ended_by_len", "by_kind", "by_src"):
        print(k)
        for b, v in s[k].items(): print(f"  {b:10} {v}")
    print(f"late: {s['late']}")
    print(f"ahead per day: {s['ahead_days']}")


if __name__ == "__main__":
    sys.exit(main())

"""Live take rate per day (speed plan 2026-11-17, "one typing model"): kept letters per 1,000 letters the user typed, ghosts
shown, Tabs, and key-to-ghost p50/p90, from their own use. Numbers only: no line, take or ghost text is printed.

Sources, all local:
- data/accepted.jsonl: each Tab (text taken, characters before it, app, t).
- data/typed.jsonl and data/drafts.jsonl: the lines the user sent or left; bench/kept.py finds the take in them.
- data/app.log and data/logs/app-*.log.gz: "shown <app> <n>ms ..." lines; a streamed ghost logs "part" pieces and a
  final line, counted once at its first grey text (shown_by_day). p50/p90 are key to ghost: idle ghosts (from a rest,
  no key) are counted in their own column.

Kept letters per 1,000 = kept letters of the user's takes / letters (no spaces) in the lines the user sent that day, x 1,000.
That is the same rate the replay benches print (bench/cadence_replay.py), so live and replay can sit side by side.

    .venv/bin/python bench/take_rate.py [days]     # default 14; DRAFTER_DATA=<folder> for another data folder
"""
import gzip, json, os, re, sys, time
from datetime import datetime, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "bench"))
import kept  # noqa: E402

SHOWN = re.compile(r"^(\d{4}-\d{2}-\d{2})T\S* shown \S+ (\d+)ms\b")


def day_of(t):
    return datetime.fromtimestamp(t, timezone.utc).strftime("%Y-%m-%d")


def rows(data, name, since):
    try:
        text = (Path(data) / name).read_text()
    except Exception:
        return []
    out = []
    for l in text.splitlines():
        try:
            r = json.loads(l)
        except Exception:
            continue
        if r.get("t", 0) >= since: out.append(r)
    return out


def log_lines(data):
    """app.log and its rotated archives, oldest first."""
    d = Path(data)
    for p in sorted((d / "logs").glob("app-*.log.gz")) if (d / "logs").exists() else []:
        try:
            with gzip.open(p, "rt", errors="replace") as f: yield from f
        except Exception:
            continue
    try:
        with open(d / "app.log", errors="replace") as f: yield from f
    except Exception:
        return


KEY = re.compile(r" key \d+ms")
IDLE_FROM = "2026-11-16"   # the idle ghost shipped that day; before it a line without " key" was a key's ghost too


def shown_by_day(lines, first_day):
    """-> {day: {"ms": [...], "idle": n}}, one entry per ghost at its first grey text. Since 2026-11-14 ghosts stream:
    the first piece is a "part" line, more parts and a final line follow for the same key. A part opens a ghost unless
    one is open and its time since the key did not drop (a lower time = a newer key); a final line closes the open
    ghost, or is a ghost of its own when none is open.
    Latency is key to ghost: the idle ghost (marked " idle" since the ghost p90 round, 2026-11-17; before that a line
    with no " key" field, from IDLE_FROM) starts from a rest, not a key, and is counted apart."""
    out, open_ms = {}, None
    for l in lines:
        m = SHOWN.match(l)
        if not m: continue
        ms = int(m.group(2))
        tail = l.split(" «", 1)[0].split(" engine ", 1)
        rest = tail[1] if len(tail) > 1 else ""
        part = " part" in rest
        new = (open_ms is None or ms < open_ms) if part else open_ms is None
        open_ms = ms if part else None
        if not new or m.group(1) < first_day: continue
        d = out.setdefault(m.group(1), {"rows": [], "idle": 0})
        if " idle" in rest: d["idle"] += 1; continue
        d["rows"].append((ms, bool(KEY.search(rest)) or " predicted" in rest))
    res = {}
    for day, d in out.items():
        keyed = [ms for ms, k in d["rows"] if k] if day >= IDLE_FROM else []
        res[day] = {"ms": keyed if keyed else [ms for ms, _ in d["rows"]],
                    "idle": d["idle"] + (len(d["rows"]) - len(keyed) if keyed else 0)}
    return res


def letters(s):
    return sum(1 for ch in s or "" if not ch.isspace())


def pct(xs, q):
    if not xs: return None
    xs = sorted(xs)
    return xs[min(len(xs) - 1, int(round(q * (len(xs) - 1))))]


def measure(data, days=14, now=None):
    """-> list of per-day dicts, oldest first; only counts and times."""
    now = now or time.time()
    since = now - days * 86400
    first = day_of(since)
    acc = rows(data, "accepted.jsonl", since)
    sent = rows(data, "typed.jsonl", since)
    drafts = rows(data, "drafts.jsonl", since)
    shown = shown_by_day(log_lines(data), first)
    out = {}
    for d in sorted({*(day_of(r["t"]) for r in acc + sent), *shown}):
        if d < first: continue
        a = [r for r in acc if day_of(r["t"]) == d]
        res = kept.measure(a, sent, drafts)   # lines may fall in the next day (30 min window)
        k = sum(r["kept"] for r in res.values())
        typed = sum(letters(r.get("text")) for r in sent if day_of(r["t"]) == d)
        sh = shown.get(d, {"ms": [], "idle": 0}); ms = sh["ms"]
        out[d] = {"day": d, "typed": typed, "takes": len(a), "kept": k,
                  "kept_per_1k": round(1000 * k / typed, 1) if typed else None,
                  "shown": len(ms), "idle": sh["idle"], "p50": pct(ms, 0.5), "p90": pct(ms, 0.9)}
    return [out[d] for d in sorted(out)]


def table(res):
    head = "day          typed  Tab  kept  kept/1k  shown  idle  p50 ms  p90 ms"
    out = [head]
    for r in res:
        f = lambda v: "-" if v is None else v
        out.append(f"{r['day']}  {r['typed']:>6} {r['takes']:>4} {r['kept']:>5}  {f(r['kept_per_1k']):>7}  {r['shown']:>5}  {r['idle']:>4}  "
                   f"{f(r['p50']):>6}  {f(r['p90']):>6}")
    return out


if __name__ == "__main__":
    data = Path(os.environ.get("DRAFTER_DATA") or ROOT / "data")   # a worktree has no data/: point at the main one
    print("\n".join(table(measure(data, int(sys.argv[1]) if len(sys.argv) > 1 else 14))))

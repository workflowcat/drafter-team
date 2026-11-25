"""Ghost quality and screen-context cost from app.log, numbers only (speed run, 2026-11-17, track 2).

    .venv/bin/python -B bench/ghost_quality.py [--log data/app.log] [--hours 24] [--since ISO] [--until ISO]

Ghosts: one line per ghost shown ("ghost <app> <source> len N word N taken N typed N", app/Keys.swift). Taken = a line
with taken > 0. Screen context: the 10-minute "screen context: R reads + L looks in M typing min" lines. Reads nothing
but the log's event lines; prints counts and rates, never text.
"""
import argparse
import re
import sys
from datetime import datetime, timedelta, timezone
from pathlib import Path

GHOST = re.compile(r"^(\S+) ghost (\S+) (\S+) len (\d+) word (\d+) taken (\d+) typed (\d+)")
SCREEN = re.compile(r"^(\S+) screen context: (\d+) reads \+ (\d+) looks in (\d+) typing min")


def stamp(s):
    return datetime.strptime(s, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)


def measure(lines, since=None, until=None):
    shown = taken = shown_chars = taken_chars = 0
    reads = looks = minutes = 0
    by_source = {}
    for line in lines:
        g = GHOST.match(line)
        if g:
            t = stamp(g.group(1))
            if (since and t < since) or (until and t >= until):
                continue
            n, k = int(g.group(4)), int(g.group(6))
            shown += 1; shown_chars += n
            src = by_source.setdefault(g.group(3), [0, 0])
            src[0] += 1
            if k > 0:
                taken += 1; taken_chars += min(k, n); src[1] += 1
            continue
        s = SCREEN.match(line)
        if s:
            t = stamp(s.group(1))
            if (since and t < since) or (until and t >= until):
                continue
            reads += int(s.group(2)); looks += int(s.group(3)); minutes += int(s.group(4))
    return {
        "shown": shown, "taken": taken,
        "taken_rate": round(taken / shown, 3) if shown else None,
        "char_rate": round(taken_chars / shown_chars, 3) if shown_chars else None,
        "by_source": {k: {"shown": v[0], "taken": v[1]} for k, v in sorted(by_source.items())},
        "screen_reads": reads, "screen_looks": looks, "typing_min": minutes,
        "reads_per_min": round(reads / minutes, 1) if minutes else None,
        "looks_per_min": round(looks / minutes, 1) if minutes else None,
    }


def main(argv=None):
    p = argparse.ArgumentParser()
    p.add_argument("--log", default=str(Path(__file__).resolve().parent.parent / "data/app.log"))
    p.add_argument("--hours", type=float, default=24)
    p.add_argument("--since"); p.add_argument("--until")
    a = p.parse_args(argv)
    until = stamp(a.until) if a.until else None
    since = stamp(a.since) if a.since else (until or datetime.now(timezone.utc)) - timedelta(hours=a.hours)
    with open(a.log, encoding="utf-8", errors="replace") as f:
        r = measure(f, since, until)
    print(f"ghosts {since:%Y-%m-%dT%H:%MZ}..{(until or datetime.now(timezone.utc)):%H:%MZ}: shown {r['shown']}, taken {r['taken']} "
          f"({r['taken_rate']}), chars taken {r['char_rate']}")
    for k, v in r["by_source"].items():
        print(f"  {k}: shown {v['shown']}, taken {v['taken']}")
    print(f"screen context: {r['screen_reads']} reads + {r['screen_looks']} looks in {r['typing_min']} typing min "
          f"({r['reads_per_min']} reads/min, {r['looks_per_min']} looks/min)")
    return r


if __name__ == "__main__":
    sys.exit(0 if main() else 1)

"""Two models, offline: the small model answers at the key at once; a bigger model, in a second process (never the
engine's), starts after `pause` ms with no key and extends or replaces the ghost when its answer comes before the user's next
key. Simulated from two recordings of the same held set (bench/typebench.py rows: every token with its ms), no model.

    .venv/bin/python -B bench/models/twotier.py --small data/bench/<small>.jsonl --big data/bench/<big>.jsonl
    .venv/bin/python -B bench/models/twotier.py --small ... --big ... --pause 0,50,100,200 --ipc 3
    .venv/bin/python -B bench/models/twotier.py --gaps-only                     # what data/app.log holds
Key gaps come only from data/app.log: `keygap <kind> lt60 N lt90 N ... lt1000 N pause N ghost N` lines when the app
writes them (app/KeyGapRules.swift, a histogram a minute; each bucket stands for its middle, a pause for PAUSE_MS;
`--kind ai|chat|mail|other` keeps one kind), else `late <app> <ms>ms typed <n>` lines (round five: <n> keys came
within <ms>, so one gap is about ms / n). With fewer than --min-gaps
numbers the script stops and says so; `--assume 120,150,200,300` then gives a what-if marked ASSUMED.

Reported per pause: how often the big answer comes before the next key; at spots where the small ghost was wrong or
missing, how often the big one is right; where the small one was right, how often the big one would replace it with a
wrong one; letters saved and right % of small alone against the pair (the one replay, bench/measure.py, averaged over
the gap deciles); total memory of both processes. Output: data/bench/models/twotier-<small>-<big>.json."""
import argparse, json, re, statistics, sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import shared as S

KEYGAP = re.compile(r" keygap (ai|chat|mail|other)((?: lt\d+ \d+)+) pause (\d+) ghost (\d+)")
BUCKET = re.compile(r"lt(\d+) (\d+)")
PAUSE_MS = 1500.0      # what one pause (a gap of 1000 ms or more) stands for in the deciles
LATE = re.compile(r" late \S+ (\d+)ms typed (\d+)")
PROCESS_GB = 0.35      # Python + MLX runtime of a second process beyond its model's peak (estimate)


def keygap_hist(lines, kind=None):
    """The `keygap` histogram lines summed: ({upper edge ms: count}, pauses, after a ghost)."""
    hist, pauses, ghost = {}, 0, 0
    for l in lines:
        m = KEYGAP.search(l)
        if not m or (kind and m.group(1) != kind): continue
        for e, n in BUCKET.findall(m.group(2)): hist[int(e)] = hist.get(int(e), 0) + int(n)
        pauses += int(m.group(3)); ghost += int(m.group(4))
    return hist, pauses, ghost


def hist_gaps(hist, pauses):
    """One value per gap: the middle of its bucket (the first from 0), PAUSE_MS for a pause."""
    out, lo = [], 0
    for e in sorted(hist):
        out += [(lo + e) / 2] * hist[e]; lo = e
    return out + [PAUSE_MS] * pauses


def parse_gaps(lines, kind=None):
    """Key gaps in ms from app.log lines. -> (gaps, source)."""
    lines = list(lines)
    hist, pauses, _ = keygap_hist(lines, kind)
    kg = hist_gaps(hist, pauses)
    if kg: return kg, "keygap"
    late = [float(m.group(1)) / int(m.group(2)) for l in lines for m in [LATE.search(l)] if m and int(m.group(2)) > 0]
    return late, ("late" if late else "none")


def deciles(gaps):
    """Ten gap values that stand for the distribution (the 5th, 15th, ... 95th percentile)."""
    g = sorted(gaps)
    return [g[min(len(g) - 1, int(len(g) * (k + 0.5) / 10))] for k in range(10)] if g else []


def in_time(gap, pause, big_ms, ipc):
    """The big answer is there before the next key: the pause passed with no key, and the answer came after it."""
    return gap > pause and pause + ipc + big_ms < gap


def spot_stats(spots, gaps, pause, ipc):
    """spots: [{"small": (ghost, ms, right), "big": (ghost, ms, right)}] where a ghost of "" = nothing shown.
    -> shares over spots x gap deciles."""
    n = arrive = fix_base = fixed = keep_base = broke = extend = 0
    for s in spots:
        sg, sms, sok = s["small"]
        bg, bms, bok = s["big"]
        for g in gaps:
            n += 1
            small_shown = bool(sg) and sms <= g
            ok = in_time(g, pause, bms, ipc) and bool(bg)
            arrive += ok
            if not (small_shown and sok):
                fix_base += 1; fixed += ok and bok
            else:
                keep_base += 1; broke += ok and not bok and not bg.startswith(sg.rstrip())
            extend += ok and small_shown and bg != sg and bg.startswith(sg.rstrip())
    pct = lambda a, b: round(100 * a / b, 1) if b else None
    return {"arrives": pct(arrive, n), "right_where_small_wrong": pct(fixed, fix_base),
            "wrong_where_small_right": pct(broke, keep_base), "extends_small": pct(extend, n)}


def pair_policy(small_pol, big_pol, big_rows, pause, ipc, gap):
    """The pair as one policy for measure.replay: the big ghost when it comes in time and its gate says yes, else the
    small ghost. The ms returned is when the shown ghost is there."""
    def pol(row, before, src):
        g, ms = small_pol(row, before, src)
        b = big_rows.get(row.get("_key"))
        if b is not None:
            bg, bms = big_pol(b, before, src)
            if bg and in_time(gap, pause, bms, ipc): return bg, pause + ipc + bms
        return g, ms
    return pol


def peak_from_log(rec):
    """Peak GB from the recording's log (bench/models or bench/weights logs)."""
    name = Path(rec).stem
    for d in (S.RESULTS / "logs", S.W.RESULTS / "logs"):
        p = d / f"{name}.log"
        if p.exists(): return S.peak_gb(p.read_text().splitlines())
    return None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--small")
    ap.add_argument("--big")
    ap.add_argument("--pause", default="0,50,100,150,200")
    ap.add_argument("--ipc", type=float, default=3.0, help="ms to pass the big answer to the app")
    ap.add_argument("--big-words", type=int, default=6, help="sure words the big ghost may show")
    ap.add_argument("--log", default=str(S.W.DATA / "app.log"))
    ap.add_argument("--min-gaps", type=int, default=200)
    ap.add_argument("--assume", default=None, help="what-if gaps in ms when app.log has too few (marked ASSUMED)")
    ap.add_argument("--gaps-only", action="store_true")
    ap.add_argument("--kind", choices=["ai", "chat", "mail", "other"], help="only `keygap` lines of this app kind")
    ap.add_argument("--small-gb", type=float, default=None)
    ap.add_argument("--big-gb", type=float, default=None)
    a = ap.parse_args()
    lines = Path(a.log).read_text(errors="replace").splitlines() if Path(a.log).exists() else []
    gaps, source = parse_gaps(lines, a.kind)
    print(f"key gaps in {Path(a.log).name}: {len(gaps)} from `{source}` lines"
          + (f", p10/p50/p90 {statistics.quantiles(gaps, n=10)[0]:.0f}/{statistics.median(gaps):.0f}/"
             f"{statistics.quantiles(gaps, n=10)[-1]:.0f} ms" if len(gaps) >= 10 else ""))
    if source == "keygap":
        _, _, ghost = keygap_hist(lines, a.kind)
        print(f"  of them after a shown ghost: {ghost}")
    if a.gaps_only: return
    assumed = False
    if len(gaps) < a.min_gaps:
        if not a.assume:
            raise SystemExit(f"under {a.min_gaps} key gaps in app.log: no honest arrival numbers. The app logs `late` "
                             f"lines since round five; rerun after a week of typing, or pass --assume for a what-if.")
        gaps, assumed, source = [float(x) for x in a.assume.split(",")], True, "ASSUMED"
    dec = deciles(gaps) if not assumed else gaps
    if not (a.small and a.big): raise SystemExit("--small and --big recordings are needed")
    import measure
    small_pol, items, small_rows = S.gate_policy(a.small)
    big_pol, items_b, big_rows = S.gate_policy(a.big, max_words=a.big_words)
    if [x["text"] for x in items] != [x["text"] for x in items_b][: len(items)]:
        raise SystemExit("the two recordings are of different sets")
    spots = []
    for k, row in small_rows.items():
        b = big_rows.get(k)
        if b is None: continue
        i, pos = k
        text, before, src = items[i]["text"], items[i]["text"][:pos], items[i]["src"]
        sg, sms = small_pol(row, before, src)
        bg, bms = big_pol(b, before, src)
        sg, bg = measure.clean(before, sg), measure.clean(before, bg)
        spots.append({"small": (sg, sms, measure.first_right(sg, text[pos:]) if sg else False),
                      "big": (bg, bms, measure.first_right(bg, text[pos:]) if bg else False)})
    small_alone, _ = measure.replay(items, small_rows, small_pol, gap_ms=None)
    out = {"small": Path(a.small).name, "big": Path(a.big).name, "gaps": {"n": len(gaps), "source": source,
           "deciles": dec}, "spots": len(spots), "small_alone": {k: small_alone[k] for k in small_alone if "/" not in k},
           "pauses": {}}
    gb_small = a.small_gb or peak_from_log(a.small)
    gb_big = a.big_gb or peak_from_log(a.big)
    out["memory_gb"] = {"small": gb_small, "big": gb_big, "process_overhead_each": PROCESS_GB,
                        "total": round(gb_small + gb_big + 2 * PROCESS_GB, 2) if gb_small and gb_big else None}
    for pause in [float(x) for x in a.pause.split(",")]:
        st = spot_stats(spots, dec, pause, a.ipc)
        per = []
        for g in dec:
            r, _ = measure.replay(items, small_rows, pair_policy(small_pol, big_pol, big_rows, pause, a.ipc, g), gap_ms=g)
            per.append(r)
        pair = {}
        for k in (k for k in per[0] if "/" not in k):
            pair[k] = {m: round(statistics.mean(r[k][m] for r in per), 1) for m in ("saved", "right", "wrong_1k", "late")}
        alone = [measure.replay(items, small_rows, small_pol, gap_ms=g)[0] for g in dec]
        for k in pair:
            pair[k]["small_saved_at_gaps"] = round(statistics.mean(r[k]["saved"] for r in alone), 1)
            pair[k]["small_right_at_gaps"] = round(statistics.mean(r[k]["right"] for r in alone), 1)
        out["pauses"][str(int(pause))] = {**st, "replay": pair}
        print(f"pause {pause:.0f} ms: {st} | {pair}", flush=True)
    name = f"twotier-{Path(a.small).stem}-{Path(a.big).stem}" + ("-assumed" if assumed else "")
    p = S.write(name, out)
    print(f"-> {p.relative_to(S.ROOT)}{'  (gaps ASSUMED, not from app.log)' if assumed else ''}")


if __name__ == "__main__":
    main()

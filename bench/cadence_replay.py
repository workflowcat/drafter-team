"""Cadence round (2026-11-17, Andrii: "even less confidence and earlier start... a combo of models and algorithms as
long as stuff works better"). Two models, one GPU, one model per key: the fast one (1.7B) answers while he types
fast, the 4B in longer gaps; the 4B may extend a shown 1.7B ghost in the time left before his next key, only when its
text starts with the whole ghost on screen. Offline on the recordings of the held set (bench/big/run.py rec), each
model under its own out-of-fold gate, the waits of bench/earlier.py (his live key-gap histograms, seeds 1-3).
Loads no model. Numbers only.

    .venv/bin/python -B bench/cadence_replay.py data/bench/big-live.jsonl data/bench/big-q4b-lr5-s10.jsonl \
        [--policy-mode current-2026-11-16] [--early] [--out bench/out/cadence.json]

Routing reads only what the app knows at the key: the gap before it (and the one before that for "mean2"), never his
next key. The first key of a line (no gap yet) goes to the 4B.
Columns as bench/earlier.py waits; key-to-ghost "first" is the first grey text at the key, "final" the ghost he has
at his next key (an extension that came in time). A cut extension costs the next ask up to `contend` ms (it stops at
its next 4B token, server.run stale)."""
import argparse, json, sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
for p in (ROOT / "bench", ROOT / "bench/big", ROOT / "engine"):
    if str(p) not in sys.path: sys.path.insert(0, str(p))
import earlier, measure, request_policy

CONTEND_MS = 15.0   # one 4B token on this Mac (13.3 ms quiet, docs/rounds/2026-11-16-opt4b.md), rounded up


def fast_cadence(g1, g2, th, signal="last"):
    """True when he is typing fast: the gap before this key (signal "last") or the mean of the last two ("mean2") is
    under `th` ms. No gap yet (the line's first key, after a Tab) -> False: the 4B answers."""
    if g1 is None or th <= 0: return False
    if signal == "mean2" and g2 is not None: return (g1 + g2) / 2 < th
    return g1 < th


def agrees(before, shown, longer):
    """The 4B's text extends the shown ghost: it starts with all of it and adds something."""
    a, b = measure.clean(before, shown), measure.clean(before, longer)
    return bool(a) and b.startswith(a) and len(b.strip()) > len(a.strip())


class Cadence:
    """One model per key by his typing cadence, the 4B extension in the time left (see the module doc)."""
    firsts = True

    def __init__(self, fast, big, rows_big, th, signal="last", extend=True, contend=CONTEND_MS):
        self.fast, self.big, self.rows_big, self.th, self.signal, self.extend = fast, big, rows_big, th, signal, extend
        self.contend = contend if extend else 0.0
        self.g1 = self.g2 = None
        self.info, self.why, self.opts = None, None, None
        self.routed = {"fast": 0, "big": 0, "ext": 0}

    def see(self, g1, g2):
        self.g1, self.g2 = g1, g2

    def __call__(self, row, before, src):
        self.opts, self.info = [], None
        rb = self.rows_big.get(row["_key"])
        if not fast_cadence(self.g1, self.g2, self.th, self.signal):
            self.routed["big"] += 1
            if rb is None: self.why = "norow"; return "", 0
            gb, _ = self.big(rb, before, src)
            self.why = self.big.why
            if not gb: return "", 0
            ib = self.big.info
            self.opts.append((ib["first_ms"], gb, ib["shade"], "big"))
        else:
            self.routed["fast"] += 1
            ga, _ = self.fast(row, before, src)
            self.why = self.fast.why
            if not ga: return "", 0
            ia = self.fast.info
            self.opts.append((ia["first_ms"], ga, ia["shade"], "fast"))
            if self.extend and rb is not None:
                gb, _ = self.big(rb, before, src)
                if gb and agrees(before, ga, gb):
                    self.routed["ext"] += 1
                    self.opts.append((ia["full_ms"] + self.big.info["full_ms"], gb, ia["shade"], "ext"))
        self.why = None
        self.info = {"shade": self.opts[0][2], "first_ms": self.opts[0][0], "full_ms": self.opts[-1][0], "src": self.opts[0][3]}
        return self.opts[0][1], self.opts[0][0]


def load(rec):
    import score as big
    items, rows, P = big.oof(rec)
    p50 = earlier.q([r.get("prefill_ms", 0) for r in rows.values()], .5)
    for r in rows.values(): r["_prefill50"] = p50
    return items, rows, P


def cases(Pa, Pb, ra, rb, mode, early=False, ths=(60, 90, 120, 150, 200)):
    knobs = {"policy_mode": mode}
    if early: knobs.update(guess=0.25, places={"space": 0.2})   # live earlyStart (gatecore.early_bar)
    pa, pb = (lambda: earlier.Policy(Pa, **knobs)), (lambda: earlier.Policy(Pb, **knobs))
    out = [("4B alone", pb(), rb), ("1.7B alone", pa(), ra)]
    for th in ths:
        for ext in (False, True):
            out.append((f"cadence {th} ms{' + extend' if ext else ''}", Cadence(pa(), pb(), rb, th, extend=ext), ra))
    out.append(("cadence 120 ms mean2 + extend", Cadence(pa(), pb(), rb, 120, "mean2"), ra))
    for o in out: o[1].firsts = True
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("fast"); ap.add_argument("big")
    ap.add_argument("--early", action="store_true", help="also the live earlyStart bars (guess 0.25, 0.2 after a space)")
    ap.add_argument("--th", default="60,90,120,150,200")
    ap.add_argument("--out", default=None)
    request_policy.add_argument(ap, request_policy.CURRENT)
    a = ap.parse_args()
    live = earlier.live_numbers()
    ia, ra, Pa = load(a.fast); ib, rb, Pb = load(a.big)
    assert [x["text"] for x in ia] == [x["text"] for x in ib]
    keep = request_policy.build(a.policy_mode).timing_kwargs()
    table = {}
    for early in ((False, True) if a.early else (False,)):
        tag = a.policy_mode + (" + earlyStart" if early else "")
        for name, pol, rows in cases(Pa, Pb, ra, rb, a.policy_mode, early, tuple(int(x) for x in a.th.split(","))):
            s = earlier.waits(ia, rows, pol, live, **keep)
            if isinstance(pol, Cadence): s["routed"] = dict(pol.routed)
            table[f"{tag}: {name}"] = s
            print(f"{tag:40s} {name:30s} shown {s['shown']:5.1f}% row {s['row_shown']:.2f}/{s['row_all']:.3f} kept {s['kept']:6.1f} "
                  f"wrong {s['wrong']:5.1f} first {s['first_p50']:.0f}/{s['first_p95']:.0f} final {s['p50']:.0f}/{s['p95']:.0f}"
                  + (f" routed {s['routed']}" if "routed" in s else ""), flush=True)
    if a.out: Path(a.out).write_text(json.dumps(table, indent=1))


if __name__ == "__main__":
    main()

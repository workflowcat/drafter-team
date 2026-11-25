"""Screen context sweep (2026-11-14, app/ScreenContext.swift + engine/prompt.py screen_text): what the model gains from
the screen text above the field, in which form and how much of it. Run ONLY when the lead says the model slot is free
(one model, under the guard, through bench/models/shared.py like bench/models/context.py).

    .venv/bin/python -B bench/screen_context.py --list
    .venv/bin/python -B bench/screen_context.py --smoke --sleep-engine                 # 2 variants, 3 lines: plumbing
    .venv/bin/python -B bench/screen_context.py --sleep-engine                         # held-137 (Accessibility text)
    .venv/bin/python -B bench/screen_context.py --set data/replay.json --marks --sleep-engine   # who-said-what lines

Variants (each one recording of the set; prompt knobs through env, engine/prompt.py CTX_FORM / CTX_BUDGET):
    none            no screen text (--ctx-chars 0)
    raw-1600        today's prompt: the last 1,600 characters as they came
    plain-800/1600/3000   the app's marks off (today's live look), the last N characters
    tail-800/1600/3000    turns picked by engine/prompt.py pick_tail: the other side's last message whole, his last,
                          then older ones while N lasts, WITH who-said-what marks
    tail-plain-1600       the same pick, marks off
--marks runs the set whose screen text carries speaker marks (data/replay.json: 13 of 30 lines from Beeper history,
"Я:" / a first name); held-137 has none, so there tail == tail-plain == plain cut at line starts.

Output: data/bench/models/screen-context-<model>.json and a table per variant and app kind: saved, right, wrong/1k,
ms to the first token, ms at a line start (reading the screen text anew), each against raw-1600. Keep a change only
if it gains 0.5 points of saved or right in chat or AI lines without more wrong/1k and under +40 ms at a line start."""
import argparse, sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "bench" / "models"))
import shared as S
from context import adapter_for, delta, show

# name: (extra record.py arguments, env)
VARIANTS = {
    "none": (["--ctx-chars", 0], {}),
    "raw-1600": ([], {"DRAFTER_CTX_FORM": "raw", "DRAFTER_CTX_BUDGET": "1600"}),
    "plain-800": ([], {"DRAFTER_CTX_FORM": "plain", "DRAFTER_CTX_BUDGET": "800"}),
    "plain-1600": ([], {"DRAFTER_CTX_FORM": "plain", "DRAFTER_CTX_BUDGET": "1600"}),
    "plain-3000": ([], {"DRAFTER_CTX_FORM": "plain", "DRAFTER_CTX_BUDGET": "3000"}),
    "tail-800": ([], {"DRAFTER_CTX_FORM": "tail", "DRAFTER_CTX_BUDGET": "800"}),
    "tail-1600": ([], {"DRAFTER_CTX_FORM": "tail", "DRAFTER_CTX_BUDGET": "1600"}),
    "tail-3000": ([], {"DRAFTER_CTX_FORM": "tail", "DRAFTER_CTX_BUDGET": "3000"}),
    "tail-plain-1600": ([], {"DRAFTER_CTX_FORM": "tail-plain", "DRAFTER_CTX_BUDGET": "1600"}),
}
SMOKE = ["raw-1600", "tail-1600"]
MARKS = ["none", "raw-1600", "plain-1600", "tail-1600", "tail-plain-1600"]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--model", default="live")
    ap.add_argument("--adapter", default="auto")
    ap.add_argument("--set", default=S.SET)
    ap.add_argument("--smoke", action="store_true")
    ap.add_argument("--marks", action="store_true", help="the short list for a set with speaker marks")
    ap.add_argument("--only", default=None)
    ap.add_argument("--list", action="store_true")
    ap.add_argument("--sleep-engine", action="store_true")
    a = ap.parse_args()
    if a.list:
        for n, (x, e) in VARIANTS.items(): print(f"{n:16s} {' '.join(map(str, x))} {e}")
        return
    S.candidate(a.model)
    S.W.need_data()
    S.SET = a.set
    names = a.only.split(",") if a.only else SMOKE if a.smoke else MARKS if a.marks else list(VARIANTS)
    bad = [n for n in names if n not in VARIANTS]
    if bad: raise SystemExit(f"unknown variants {bad}; --list shows them")
    adapter = adapter_for(a.model, a.adapter)
    tag = Path(a.set).stem + ("-smoke" if a.smoke else "")
    res = {"model": a.model, "adapter": adapter, "set": str(a.set), "smoke": a.smoke, "variants": {}, "peak_gb": {}}
    from contextlib import nullcontext
    from retrain import sleeping_engine
    with (sleeping_engine() if a.sleep_engine else nullcontext()):
        for n in names:
            extra, env = VARIANTS[n]
            rec, lines = S.record(f"screen-ctx-{a.model}-{tag}-{n}", a.model, adapter=adapter, smoke=a.smoke, extra=extra, env=env)
            _, detail = S.score(rec, a.smoke)
            res["variants"][n] = detail
            res["peak_gb"][n] = S.peak_gb(lines)
            S.write(f"screen-context-{a.model}-{tag}", res)
            print(f"{n}: done", flush=True)
    ok = {k: v for k, v in res["variants"].items() if "smoke_error" not in v}
    if ok and "raw-1600" in ok:
        delta(ok, base="raw-1600"); show(ok)
    print(f"-> {S.write(f'screen-context-{a.model}-{tag}', res).relative_to(S.ROOT)}")


if __name__ == "__main__":
    main()

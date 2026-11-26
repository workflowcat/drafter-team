"""What each part of the prompt buys in accuracy and costs in ms, on the live model and on each candidate.

    .venv/bin/python -B bench/models/context.py --smoke                          # live model, 2 variants, 3 lines
    .venv/bin/python -B bench/models/context.py --sleep-engine                   # live model, every variant
    .venv/bin/python -B bench/models/context.py --model qwen35-2b --quick --sleep-engine
    .venv/bin/python -B bench/models/context.py --list                           # the variants
Options: --set <held set>, --only <variant,...>, --adapter auto|none|<path> (auto: the live layer for `live`, the
candidate's `ref` layer from bench/models/trial.py when it exists, else none).

The prompt (engine/prompt.py, engine/server.py): a fixed head (the user's style rules, their words and names, their example
messages) and a tail (app and per-app style line, their older lines in this chat, the screen text above the field, the
text before the caret). Beside the prompt: the knowledge pack and the user's word list steer the word booster and finisher.
Each variant changes one thing from the full prompt; every variant is one recording of the held set, scored with a
gate refit on it, so a variant is judged at its best. The held lines are short (p50 43, p90 126, max 240 letters)
and the set keeps at most 1,500 letters of screen text, so `ctx-all` is the most the set can show (about 400-750
tokens) and the `before-*` cut bites only in long lines.

Output: data/bench/models/context-<model>.json and a table: per variant and app kind, saved, right, wrong/1k, ms to
the first token, ms at the start of a line (reading the screen text), the difference to `full`."""
import argparse, sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import shared as S

# name: extra arguments for bench/models/record.py (on top of the full prompt)
VARIANTS = {
    "full": [],
    "ctx-0": ["--ctx-chars", 0],
    "ctx-64": ["--ctx-tokens", 64],
    "ctx-128": ["--ctx-tokens", 128],
    "ctx-256": ["--ctx-tokens", 256],
    "ctx-512": ["--ctx-tokens", 512],
    "before-16": ["--before-tokens", 16],
    "before-32": ["--before-tokens", 32],
    "before-64": ["--before-tokens", 64],
    "no-know": ["--know", "none"],
    "no-people": ["--no-people"],
    "no-examples": ["--head", "rules,words"],
    "no-words": ["--head", "rules,examples"],
    "no-style": ["--head", "words,examples"],
    "no-head": ["--head", ""],
    "no-booster": ["--boost", 0],
}
QUICK = ["full", "ctx-0", "ctx-256", "no-know", "no-people", "no-examples", "no-head"]
SMOKE = ["full", "ctx-0"]


def adapter_for(model, choice):
    if choice == "none": return None
    if choice != "auto": return choice
    if model == "live": return S.W.LIVE
    p = S.OUT / f"{model}-ref"
    return str(p.relative_to(S.ROOT)) if (p / "adapters.safetensors").exists() else None


def delta(rows, base="full"):
    """Adds, per variant and app kind, the change against `base` in saved, right and first-token ms."""
    b = rows.get(base) or {}
    for name, per in rows.items():
        for src, v in per.items():
            ref = (b.get(src) or {})
            for k in ("saved", "right", "wrong_1k", "first_ms_p50", "line_start_ms_p50"):
                if isinstance(v.get(k), (int, float)) and isinstance(ref.get(k), (int, float)):
                    v[f"d_{k}"] = round(v[k] - ref[k], 2)
    return rows


def show(rows):
    print(f"{'variant':12s} {'kind':7s} {'saved':>6s} {'d':>6s} {'right':>6s} {'d':>6s} {'wr/1k':>6s} {'first':>6s} {'d':>6s} {'line':>6s}")
    for name, per in rows.items():
        for src in sorted(k for k in per if "/" not in k):
            v = per[src]
            f = lambda k: f"{v[k]:6.1f}" if isinstance(v.get(k), (int, float)) else f"{'':6s}"
            print(f"{name:12s} {src:7s} {f('saved')} {f('d_saved')} {f('right')} {f('d_right')} {f('wrong_1k')} "
                  f"{f('first_ms_p50')} {f('d_first_ms_p50')} {f('line_start_ms_p50')}")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--model", default="live")
    ap.add_argument("--adapter", default="auto")
    ap.add_argument("--smoke", action="store_true")
    ap.add_argument("--quick", action="store_true")
    ap.add_argument("--only", default=None)
    ap.add_argument("--list", action="store_true")
    ap.add_argument("--set", default=S.SET)
    ap.add_argument("--sleep-engine", action="store_true")
    a = ap.parse_args()
    if a.list:
        for n, v in VARIANTS.items(): print(f"{n:12s} {' '.join(map(str, v)) or 'the full prompt'}")
        return
    S.candidate(a.model)
    S.W.need_data()
    S.SET = a.set
    names = a.only.split(",") if a.only else SMOKE if a.smoke else QUICK if a.quick else list(VARIANTS)
    bad = [n for n in names if n not in VARIANTS]
    if bad: raise SystemExit(f"unknown variants {bad}; --list shows them")
    adapter = adapter_for(a.model, a.adapter)
    sfx = "-smoke" if a.smoke else ""
    res = {"model": a.model, "adapter": adapter, "set": str(a.set), "smoke": a.smoke, "variants": {}, "peak_gb": {}}
    from contextlib import nullcontext
    from retrain import sleeping_engine
    with (sleeping_engine() if a.sleep_engine else nullcontext()):
        for n in names:
            rec, lines = S.record(f"models-ctx-{a.model}-{n}{sfx}", a.model, adapter=adapter, smoke=a.smoke,
                                  extra=VARIANTS[n])
            _, detail = S.score(rec, a.smoke)
            res["variants"][n] = detail
            res["peak_gb"][n] = S.peak_gb(lines)
            S.write(f"context-{a.model}{sfx}", res)
            print(f"{n}: done", flush=True)
    if not a.smoke or all("smoke_error" not in v for v in res["variants"].values()):
        delta({k: v for k, v in res["variants"].items() if "smoke_error" not in v})
        show({k: v for k, v in res["variants"].items() if "smoke_error" not in v})
    p = S.write(f"context-{a.model}{sfx}", res)
    print(f"-> {p.relative_to(S.ROOT)}")


if __name__ == "__main__":
    main()

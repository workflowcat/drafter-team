"""Idle ghost (round "earlier", step 7): with the caret still in a chat box, empty or after a finished sentence, the
loaded local model drafts his likely next message. Made-up conversations only (bench/idle_set.json: Ukrainian,
English, mixed). The engine runs in this process (it loads the model the settings pick), under the guard:

    .venv/bin/python -B bench/weights/guarded.py 6 bench/idle.py --policy-mode current-2026-11-16 [--n 24]
        [--forms screen,turns,chat] [--words-min 3] [--out bench/out/idle.json]

The request flags come from bench/request_policy.py (the named policy mode), then the idle keys on top.

Step 7b: --forms runs each empty-box prompt (engine/idle_prompt.py: screen = step 7's typing prompt, turns, chat) on the
same chats; rows after a finished sentence always use the typing prompt. --words-min sets the 3-5 words rule's
minimum (the after-sentence check). "close" = the first word exact or in the row's hand-made list of fitting first
words (a synonym, a greeting or agreement form: bench/idle_set.json "close").

Per form and idle bar (the lowest gate score that still shows): shown share (all, empty boxes), first word right and
close (of shown, of all), kept letters
per 1,000 letters of the next message (Tab word by word while the words match, one key per Tab off), time to the
first words and the whole ghost p50/p95, memory the requests add over the loaded model. Nothing leaves the Mac.
"""
import argparse, json, re, sys, time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "engine")); sys.path.insert(0, str(ROOT / "bench"))
import request_policy

BARS = (0.0, 0.05, 0.1, 0.2, 0.3)


def words(s): return re.findall(r"\S+", s or "")


def fold(w): return re.sub(r"[^\w'’ʼ]", "", w.casefold())


def kept(ghost, nxt):
    g, n = words(ghost), words(nxt)
    k = tabs = 0
    for a, b in zip(g, n):
        if fold(a) != fold(b) or not fold(a): break
        k += len(b) + 1; tabs += 1
    return max(0, k - tabs)


def pct(xs, p):
    xs = sorted(xs)
    return round(xs[min(len(xs) - 1, int(p * len(xs)))]) if xs else None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--n", type=int, default=0)
    ap.add_argument("--forms", default="screen,turns,chat")
    ap.add_argument("--words-min", type=int, default=None)
    ap.add_argument("--out", default=str(ROOT / "bench/out/idle.json"))
    request_policy.add_argument(ap, request_policy.CURRENT)
    a = ap.parse_args()
    policy = request_policy.build(a.policy_mode)
    rows = json.loads((ROOT / "bench/idle_set.json").read_text())
    if a.n: rows = rows[:a.n]
    import mlx.core as mx
    import server
    print("model:", ((server.CURRENT or {}).get("entry") or {}).get("id"), flush=True)
    base = mx.get_active_memory() / 2**30
    mx.reset_peak_memory()
    result = {"policy": a.policy_mode, "n": len(rows), "words_min": a.words_min, "forms": {}}
    for form in a.forms.split(","):
        out = []
        for i, r in enumerate(rows):
            req = dict(policy.request, before=r["before"], app=r["app"], title="chat", context=r["context"], idle=True, idle_bar=0.0,
                       idle_form=form, ahead=False, chips=False, early=False, fix=False, keep_on=False)
            if a.words_min is not None: req["words_min"] = a.words_min
            t = time.perf_counter()
            res = server._complete(req, seq=server.request_seq())
            ms = (time.perf_counter() - t) * 1000
            text = (res.get("text") or "").strip()
            fw = fold(words(text)[0]) if text else ""
            right = bool(text) and fw == fold(words(r["next"])[0])
            row = {"lang": r["lang"], "after_sentence": bool(r["before"]), "text": text, "text_len": len(text), "gate": res.get("gate"),
                   "src": res.get("src"), "form": res.get("idle_form"), "first_ms": res.get("first_ms"), "ms": round(ms),
                   "first_right": right, "close": right or (bool(fw) and fw in [fold(c) for c in r.get("close", [])]),
                   "kept": kept(text, r["next"]), "letters": len(r["next"])}
            out.append(row)
            print(form, i, r["lang"], row["form"], row["gate"], row["first_right"], row["close"], row["kept"], row["ms"], repr(text), flush=True)
        letters = sum(r["letters"] for r in out)
        empty = sum(not r["after_sentence"] for r in out)
        bars = {}
        for bar in BARS:
            shown = [r for r in out if r["text_len"] and (r["gate"] or 0) >= bar]
            fm = [r["first_ms"] for r in shown if r["first_ms"] is not None]
            bars[str(bar)] = {
                "shown": f"{len(shown)}/{len(out)}", "shown_empty": f"{sum(not r['after_sentence'] for r in shown)}/{empty}",
                "shown_after": f"{sum(r['after_sentence'] for r in shown)}/{len(out) - empty}",
                "first_right_of_shown": f"{sum(r['first_right'] for r in shown)}/{len(shown)}",
                "close_of_shown": f"{sum(r['close'] for r in shown)}/{len(shown)}",
                "empty_right": f"{sum(r['first_right'] for r in shown if not r['after_sentence'])}/{sum(not r['after_sentence'] for r in shown)}",
                "empty_close": f"{sum(r['close'] for r in shown if not r['after_sentence'])}/{sum(not r['after_sentence'] for r in shown)}",
                "after_right": f"{sum(r['first_right'] for r in shown if r['after_sentence'])}/{sum(r['after_sentence'] for r in shown)}",
                "after_close": f"{sum(r['close'] for r in shown if r['after_sentence'])}/{sum(r['after_sentence'] for r in shown)}",
                "first_right_of_all": round(sum(r["first_right"] for r in shown) / max(1, len(out)), 2),
                "kept_1k": round(1000 * sum(r["kept"] for r in shown) / max(1, letters), 1),
                "first_ms": (pct(fm, .5), pct(fm, .95)), "ms": (pct([r["ms"] for r in shown], .5), pct([r["ms"] for r in shown], .95))}
        result["forms"][form] = {"bars": bars, "rows": out}
        print(form, json.dumps(bars["0.05"], ensure_ascii=False), flush=True)
    peak = mx.get_peak_memory() / 2**30
    result.update(model_gb=round(base, 2), added_gb=round(peak - base, 2))
    Path(a.out).parent.mkdir(parents=True, exist_ok=True)
    Path(a.out).write_text(json.dumps(result, indent=1, ensure_ascii=False))
    print(json.dumps({f: v["bars"] for f, v in result["forms"].items()}, indent=1, ensure_ascii=False), flush=True)
    import os; os._exit(0)     # the engine's threads would keep the process alive


if __name__ == "__main__":
    main()

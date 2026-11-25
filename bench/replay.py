"""LEGACY (labelled 2026-11-16): fixed old set, separate acceptance loop, no Tab cost, live engine by default.
Keep for historical results; use bench/measure.py for supported scoring. Do not import this runner: it reads data
and sends requests at module scope. It lacks the current length, guess, minimum-three and keep-in-flight flags.

Replays data/replay.json (his real messages, 30 items) letter by letter against the running engine, accepting
the offered next word whenever it is exactly what he wrote (Tab word by word). Prints letters saved, wrong offers
and speed. Phrase memory is off (these lines are in it).

    .venv/bin/python bench/replay.py '<json of /complete overrides>' [label]
"""
import json, re, statistics, sys, time, urllib.request
from pathlib import Path
ROOT = Path(__file__).resolve().parent.parent
items = json.loads((ROOT / "data/replay.json").read_text())
over = json.loads(sys.argv[1]) if len(sys.argv) > 1 else {}
label = sys.argv[2] if len(sys.argv) > 2 else json.dumps(over)


def ask(before, it):
    body = {"before": before, "app": it["app"], "context": it["context"], "chips": False, "memory": False, "max_tokens": 6, **over}
    t = time.perf_counter()
    for attempt in range(30):   # the engine may be restarting: wait for it instead of failing the whole run
        try:
            r = json.loads(urllib.request.urlopen(urllib.request.Request("http://127.0.0.1:8798/complete", data=json.dumps(body).encode(), headers={"Content-Type": "application/json"}), timeout=20).read())
            break
        except Exception:
            time.sleep(2); t = time.perf_counter()
    else:
        raise SystemExit("engine not answering")
    return r.get("text", ""), (time.perf_counter() - t) * 1000


res = {}
for src in ("beeper", "claude"):
    saved = total = offers = wrong = multi = multi_ok = extra_shown = extra_right = 0; ms = []
    for it in [i for i in items if i["src"] == src]:
        text, pos = it["text"], 1
        total += len(text)
        while pos < len(text):
            s, t = ask(text[:pos], it); ms.append(t)
            if s:
                offers += 1
                ws = s.split()
                if len(ws) >= 2:   # a 2-3 word offer: all of it right, as Cotypist-style Tab, Tab would take it
                    multi += 1
                    multi_ok += text[pos:].startswith(s.rstrip())
                    # extra words (after the first): how many are right, of how many shown
                    rest = text[pos:]
                    k = 0
                    for i in range(1, len(ws) + 1):
                        if rest.startswith(s[: s.find(ws[i - 1]) + len(ws[i - 1])]): k = i
                        else: break
                    extra_shown += len(ws) - 1; extra_right += max(0, k - 1)
                w = re.match(r"\s*\S+", s)
                w = w.group(0) if w else ""
                if w and text[pos:].startswith(w):
                    saved += len(w); pos += len(w); continue
                wrong += 1
            pos += 1
    res[src] = f"saved {100 * saved / total:.0f}% of {total} letters, offers {offers}, wrong {100 * wrong / max(1, offers):.0f}%, 2-3 words {multi} ({100 * multi_ok / max(1, multi):.0f}% all right; extra words right {extra_right}/{extra_shown}), ms p50 {statistics.median(ms):.0f} p90 {sorted(ms)[int(len(ms) * .9)]:.0f}"
print(label, "|", " | ".join(f"{k}: {v}" for k, v in res.items()))
with open(ROOT / "data/replay-results.txt", "a") as f: f.write(label + " | " + json.dumps(res, ensure_ascii=False) + "\n")

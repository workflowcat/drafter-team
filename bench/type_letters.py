"""Types sentences into the running engine letter by letter, as the app does, and prints per-letter time and what
was offered. .venv/bin/python bench/type_letters.py"""
import json, statistics, time, urllib.request
S = ["хелоу) можем голосом на тижні бо я хотів обговорити", "I will send you the draft tomorrow morning",
     "давай завтра зідзвонимося і пройдемося по договору", "Mila, can you check the invoice before Friday"]
ms, shown, total = [], 0, 0
for s in S:
    seen = []
    for i in range(8, len(s) + 1):
        b = s[:i]
        t = time.perf_counter()
        r = json.loads(urllib.request.urlopen(urllib.request.Request("http://127.0.0.1:8798/complete",
            data=json.dumps({"before": b, "app": "Beeper", "chips": False, "max_tokens": 6}).encode(),
            headers={"Content-Type": "application/json"}), timeout=10).read())
        ms.append((time.perf_counter() - t) * 1000); total += 1
        if r.get("text"): shown += 1; seen.append(f"{b[-8:]}|{r['text']}")
    print(s[:30], "->", "; ".join(seen[:8]))
print(f"letters {total}, offered on {shown}, ms p50 {statistics.median(ms):.0f} p90 {sorted(ms)[int(len(ms)*.9)]:.0f}")

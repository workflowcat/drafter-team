"""Daily review of Drafter's own logs (local only): where suggestions showed and how fast, where it stayed quiet and
why, voice takes (empty ones, corrections), engine stops. Writes data/review/YYYY-MM-DD.md and prints it.

    .venv/bin/python bench/review.py [YYYY-MM-DD]      (default: today, UTC log dates)"""
import json, re, statistics, sys, time
from collections import Counter, defaultdict
from pathlib import Path
ROOT = Path(__file__).resolve().parent.parent
day = sys.argv[1] if len(sys.argv) > 1 else time.strftime("%Y-%m-%d", time.gmtime())
lines = [l for l in (ROOT / "data/app.log").read_text(errors="ignore").splitlines() if l.startswith(day)]
shown, quiet, takes, other = defaultdict(list), Counter(), [], Counter()
by_src, used = Counter(), defaultdict(Counter)   # what each source showed, and what became of it (2026-10-31)
speed = defaultdict(list)   # round two: measured parts of key-to-ghost (local ghosts only), and Claude's pause apart
for l in lines:
    m = re.search(r"claude-pause (\S+) (\d+)ms engine (\d+)ms", l)
    if m:
        speed["claude pause"].append(int(m.group(2))); by_src["claude"] += 1
        continue
    m = re.search(r"shown (\S+) (\d+)ms engine (\d+)ms(.*)", l)
    if m:
        rest = m.group(4)
        for k, pat in (("key to first grey text", r" key (\d+)ms"), ("first AX read", r" ax (\d+)ms"), ("AX read before drawing", r" ax2 (\d+)ms")):
            v = re.search(pat, rest)
            if v: speed[k].append(int(v.group(1)))
        if " key " in rest: speed["key to first grey text, predicted" if " predicted" in rest else "key to first grey text, after the wait"].append(int(re.search(r" key (\d+)ms", rest).group(1)))
        other["drawn from a first part"] += " part" in rest
        shown[m.group(1)].append(int(m.group(2))); other["memory hits"] += " memory" in m.group(4)
        src = re.match(r" (memory|words|gate|snippet|claude)", m.group(4)); by_src[src.group(1) if src else "model"] += 1
        continue
    m = re.search(r"ghost \S+ (\S+) len (\d+) word (\d+) taken (\d+) typed (\d+)", l)
    if m:
        src, n, word, taken, typed = m.group(1), *map(int, m.groups()[1:])
        u = used[src]
        u["taken"] += taken > 0; u["taken chars"] += taken
        u["typed, not taken"] += taken == 0 and typed >= word   # right, but he typed it himself
        u["typed chars"] += typed if taken == 0 else 0
        continue
    m = re.search(r"quiet (\S+): (.+?)( «|$)", l)
    if m: quiet[(m.group(1), m.group(2))] += 1; continue
    m = re.search(r"take ([\d.]+) s, peak ([\d.]+), (\d+) chars", l)
    if m: takes.append((float(m.group(1)), int(m.group(3)))); continue
    for k in ("accept", "engine exited", "voice engine exited", "live typing", "voice piece", "chip ", "guard"):
        if k in l: other[k.strip()] += 1
out = [f"# Drafter review {day}", "", "## Suggestions shown (app: count, ms p50 / p90)"]
for app, ms in sorted(shown.items(), key=lambda x: -len(x[1])):
    s = sorted(ms); out.append(f"- {app}: {len(ms)}, {statistics.median(s):.0f} / {s[int(len(s) * .9)]} ms")
if speed:
    out += ["", "## Speed, measured (ms p50 / p90 / p99, count)"]
    for k, v in speed.items():
        v = sorted(v); out.append(f"- {k}: {v[len(v) // 2]} / {v[int(len(v) * .9)]} / {v[min(len(v) - 1, int(len(v) * .99))]}, {len(v)}")
if by_src:
    out += ["", "## Each source (shown; taken with Tab; whole next word typed by hand without Tab)"]
    for src, n in by_src.most_common():
        u = used.get(src, Counter())
        out.append(f"- {src}: {n} shown, {u['taken']} taken ({u['taken chars']} chars), {u['typed, not taken']} right but typed")
out += ["", "## Quiet (app: reason, count) - only logged while data/debug exists"]
out += [f"- {a}: {r}, {n}" for (a, r), n in quiet.most_common(12)] or ["- none logged"]
empty = [t for t in takes if t[1] == 0]
out += ["", f"## Voice: {len(takes)} takes, {sum(t[0] for t in takes):.0f} s, {len(empty)} empty"]
out += ["", "## Other"] + [f"- {k}: {v}" for k, v in other.items() if v]
try:
    acc = [json.loads(l) for l in (ROOT / "data/accepted.jsonl").read_text().splitlines() if l.strip()]
    today = [a for a in acc if time.strftime("%Y-%m-%d", time.gmtime(a["t"])) == day]
    out += ["", f"## Accepted with Tab: {len(today)}, {sum(len(a['text']) for a in today)} characters"]
except Exception:
    pass
text = "\n".join(out) + "\n"
(ROOT / "data/review" / f"{day}.md").write_text(text)
print(text)

"""Phrase memory, leave-one-out: 300 of his messages are taken out, cut mid-way, and the memory (without them) is asked
to finish them. Prints how often it speaks, how often it is right, and its speed."""
import json, random, re, sys, time
from pathlib import Path
ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "engine"))
import memory

rows = [json.loads(l) for l in (ROOT / "data/phrases.jsonl").read_text().splitlines() if l.strip()]
rnd = random.Random(5)
test = rnd.sample([r for r in rows if r["src"] in ("beeper", "claude") and len(r["text"].split()) >= 6], 300)
held = {r["text"] for r in test}
m = memory.Memory.__new__(memory.Memory)
if len(sys.argv) > 1: memory.Memory.RULE = sys.argv[1]
texts = [r["text"] for r in rows if r["text"] not in held]
m.text = "\n" + "\n".join(texts) + "\n"; m.low = m.text.lower(); m.n = len(texts)
spoke = right = word = 0; ts = []
for r in test:
    t = r["text"].split("\n")[0]
    ws = list(re.finditer(r"\S+", t))
    if len(ws) < 4: continue
    k = rnd.randint(2, len(ws) - 2); cut = ws[k].start() + (rnd.randint(1, len(ws[k].group())) if rnd.random() < .4 else 0)
    before, truth = t[:cut], t[cut:]
    a = time.perf_counter(); s, hits = m.suggest(before); ts.append((time.perf_counter() - a) * 1000)
    if not s: continue
    spoke += 1
    if truth.startswith(s.rstrip()) or s.strip().startswith(truth.strip()): right += 1
    if truth.split()[:1] and s.split()[:1] and (truth[:1].isspace() == s[:1].isspace()) and truth.split()[0] == s.split()[0]: word += 1
print(memory.Memory.RULE, f"spoke {spoke}/300, all right {right}, first word right {word}, ms p50 {sorted(ts)[150]:.1f} max {max(ts):.1f}")

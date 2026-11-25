"""Andrii's own writing, local only (data/ is not in git).

    .venv/bin/python engine/style.py      # reads Beeper (read-only), writes data/style.json

Examples feed the fixed prompt head; cases (held out) feed bench/bench.py.
"""
import html, json, random, re, subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
DATA = ROOT / "data"


def clean(t):
    t = re.sub(r"<br\s*/?>", "\n", t); t = re.sub(r"</p>\s*<p>", "\n", t); t = re.sub(r"<[^>]+>", "", t)
    t = html.unescape(t)
    return "\n".join(l.strip() for l in t.splitlines() if l.strip())


def messages(after="2026-07-01T00:00:00Z", limit=1500):
    out = subprocess.run([__import__("people").beeper_bin(), "messages", "search", "--sender", "me", "--after", after, "--limit", str(limit),
                          "--json", "-q", "--read-only", "--full"], capture_output=True, text=True, timeout=120,
                         env={"BEEPER_READONLY": "1", **__import__("os").environ}).stdout
    rows = json.loads(out)["data"]
    seen, res = set(), []
    for m in rows:
        if m.get("type") != "TEXT" or not m.get("text"): continue
        t = clean(m["text"])
        if t.startswith(("клод:", "Клод:")) or len(t) > 400 or t in seen: continue   # pasted AI output is not his voice
        seen.add(t); res.append(t)
    return res


def build():
    import integrations
    if not integrations.available("beeper"):
        print("style: the beeper integration is off on this Mac (engine/integrations.py); data/style.json unchanged"); return None
    msgs = messages()
    rnd = random.Random(7)
    longish = [t for t in msgs if 35 <= len(t) <= 220 and len(t.split()) >= 6]
    rnd.shuffle(longish)
    cases_src, rest = longish[:30], set(longish[30:])
    examples = [t for t in msgs if t not in cases_src and 15 <= len(t) <= 160][:40]
    cases = []
    for t in cases_src:
        words = list(re.finditer(r"\S+", t))
        k = max(2, min(len(words) - 2, int(len(words) * rnd.uniform(0.45, 0.7))))
        cut = words[k].start()
        if rnd.random() < 0.35:                  # sometimes cut inside a word, as when he is still typing
            w = words[k]; cut = w.start() + max(1, (w.end() - w.start()) // 2)
        cases.append({"before": t[:cut], "truth": t[cut:], "app": "Beeper"})
    DATA.mkdir(exist_ok=True)
    (DATA / "style.json").write_text(json.dumps({"examples": examples, "count": len(msgs)}, ensure_ascii=False, indent=1))
    (DATA / "cases.json").write_text(json.dumps(cases, ensure_ascii=False, indent=1))
    print(f"{len(msgs)} messages, {len(examples)} examples, {len(cases)} cases")


if __name__ == "__main__":
    build()

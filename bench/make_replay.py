"""Replay set from Andrii's real writing (local only, data/replay.json): 15 Beeper replies he sent in the last weeks,
each with the 8 messages before it in that chat (the reply context), and 15 lines he typed to Claude (typed.jsonl).
Messages also in the phrase memory are fine: the memory is switched off during the replay."""
import json, os, random, re, subprocess
from pathlib import Path
ROOT = Path(__file__).resolve().parent.parent
ENV = {**os.environ, "BEEPER_READONLY": "1"}


def run(*a):
    out = subprocess.run(["beeper", *a, "--json", "-q", "--read-only", "--full"], capture_output=True, text=True, timeout=60, env=ENV).stdout
    return json.loads(out)["data"]


def clean(t):
    t = re.sub(r"<br\s*/?>", "\n", t or ""); t = re.sub(r"<[^>]+>", "", t)
    return "\n".join(l.strip() for l in t.splitlines() if l.strip())


mine = [m for m in run("messages", "search", "--sender", "me", "--after", "2026-09-20T00:00:00Z", "--limit", "400")
        if m.get("type") == "TEXT" and 25 <= len(clean(m.get("text", ""))) <= 220 and len(clean(m["text"]).split()) >= 5]
rnd = random.Random(11); rnd.shuffle(mine)
out, chats = [], set()
for m in mine:
    if len(out) >= 15: break
    if m["chatID"] in chats: continue
    try: hist = run("messages", "list", "--chat", m["chatID"], "--before-cursor", m["id"], "--limit", "8")
    except Exception: continue
    hist = [h for h in reversed(hist) if h.get("type") == "TEXT" and h.get("text")]
    ctx = "\n".join(("Я: " if h.get("isSender") else (h.get("senderName") or "Вони").split()[0] + ": ") + clean(h["text"])[:200] for h in hist)
    if not ctx: continue
    chats.add(m["chatID"])
    out.append({"src": "beeper", "app": "Beeper", "context": ctx[-1500:], "text": clean(m["text"])})
typed = [json.loads(l)["text"] for l in (ROOT / "data/typed.jsonl").read_text().splitlines() if l.strip()]
typed = [t for t in dict.fromkeys(typed) if len(t.split()) >= 5][-15:]
out += [{"src": "claude", "app": "Claude", "context": "", "text": t} for t in typed]
(ROOT / "data/replay.json").write_text(json.dumps(out, ensure_ascii=False, indent=1))
print(len(out), "items:", sum(o["src"] == "beeper" for o in out), "beeper,", sum(o["src"] == "claude" for o in out), "claude")

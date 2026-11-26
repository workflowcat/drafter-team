"""Fresh replay set (local only, data/replay-fresh.json) from lines the user wrote AFTER the last retrain, so no model
layer has seen them: lines typed into a chat app's box (typed.jsonl, the apps in CHAT_APPS), each with the text above it,
and lines typed into an AI app's box (the apps in AI_APPS). Bigger than data/replay.json (30) so show/hide rules can be
told apart. Items from an AI app keep src "claude": the benches read that as the AI kind of box, whichever AI app it was;
chat items keep src "beeper", the historical name of the chat kind.

    .venv/bin/python bench/make_fresh.py [claude_n] [chat_n]
"""
import argparse, datetime, json, random, sys, tempfile
from pathlib import Path
from retrain_state import last_retrain
ROOT = Path(__file__).resolve().parent.parent
# the app names typed.jsonl holds for an AI assistant's box (app/AppKind.swift "ai"); add yours here
AI_APPS = {"Claude", "ChatGPT", "Codex", "Gemini", "Perplexity", "Le Chat", "Copilot", "Cursor"}
# chat apps, matched in lower case as part of the app name (the same list as engine/tweaks.py CHAT_APPS)
CHAT_APPS = ("beeper", "whatsapp", "telegram", "signal", "slack", "messages", "discord", "messenger")
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("claude_n", nargs="?", type=int, default=60)
parser.add_argument("chat_n", nargs="?", type=int, default=40)
parser.add_argument("--output", type=Path, default=ROOT / "data/replay-fresh.json")
parser.add_argument("--min-items", type=int, default=50)
parser.add_argument("--since", type=float, default=None, help="unix seconds: lines after this instead of the last retrain")
args = parser.parse_args()
CLAUDE_N, CHAT_N = args.claude_n, args.chat_n


def is_chat(app):
    a = (app or "").lower()
    return any(x in a for x in CHAT_APPS)


def since(given=None):
    """Only lines newer than the current layer or the last completed comparison."""
    cut = given or last_retrain(ROOT)
    if not cut: raise RuntimeError("No training cutoff: current adapter and retrain stamp are missing")
    return datetime.datetime.fromtimestamp(cut, datetime.timezone.utc)


def publish(items, target, minimum):
    """Stage before replacing the last usable replay set, including standalone runs."""
    with tempfile.TemporaryDirectory(prefix="fresh-", dir=target.parent) as folder:
        candidate = Path(folder) / "fresh.json"
        candidate.write_text(json.dumps(items, ensure_ascii=False, indent=1))
        if len(items) < minimum: return False
        candidate.replace(target)
    return True


cut = since(args.since)
rnd = random.Random(31)
out = []
ts = cut.timestamp()
typed = [json.loads(l) for l in (ROOT / "data/typed.jsonl").read_text().splitlines() if l.strip()]
fresh = [r for r in typed if (r.get("t") or 0) > ts and len((r.get("text") or "").split()) >= 3]
chats = [r for r in fresh if is_chat(r.get("app")) and 12 <= len(r["text"].strip()) <= 240]
rnd.shuffle(chats)
seen = set()
for r in chats:
    if len(out) >= CHAT_N: break
    t = r["text"].strip()
    if t in seen: continue
    seen.add(t)
    out.append({"src": "beeper", "app": r.get("app") or "", "context": (r.get("context") or "")[-1500:], "text": t})
lines = list(dict.fromkeys(r["text"].strip() for r in fresh if r.get("app") in AI_APPS and len(r["text"].split()) >= 4))
rnd.shuffle(lines)
out += [{"src": "claude", "app": "Claude", "context": "", "text": t[:240]} for t in lines[:CLAUDE_N]]
published = publish(out, args.output, args.min_items)
print(f"since {cut:%Y-%m-%d %H:%M}Z:", len(out), "items:", sum(o["src"] == "beeper" for o in out), "chat,",
      sum(o["src"] == "claude" for o in out), "AI app,", sum(len(o["text"]) for o in out), "letters")

if not published:
    print(f"fewer than {args.min_items} fresh lines: previous set kept")
    sys.exit(1)

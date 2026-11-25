"""Fresh replay set (local only, data/replay-fresh.json) from lines Andrii wrote AFTER the last retrain, so no model
layer has seen them: Beeper messages he sent, each with the 8 messages before it (the reply context), and lines he
typed to Claude (typed.jsonl). Bigger than data/replay.json (30) so show/hide rules can be told apart.

    .venv/bin/python bench/make_fresh.py [claude_n] [beeper_n]
"""
import argparse, datetime, json, os, random, re, subprocess, sys, tempfile
from pathlib import Path
from retrain_state import last_retrain
ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "engine"))
from people import beeper_bin
ENV = {**os.environ, "BEEPER_READONLY": "1"}
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("claude_n", nargs="?", type=int, default=60)
parser.add_argument("beeper_n", nargs="?", type=int, default=40)
parser.add_argument("--output", type=Path, default=ROOT / "data/replay-fresh.json")
parser.add_argument("--min-items", type=int, default=50)
parser.add_argument("--since", type=float, default=None, help="unix seconds: lines after this instead of the last retrain")
args = parser.parse_args()
CLAUDE_N, BEEPER_N = args.claude_n, args.beeper_n


def since(given=None):
    """Only lines newer than the current layer or the last completed comparison."""
    cut = given or last_retrain(ROOT)
    if not cut: raise RuntimeError("No training cutoff: current adapter and retrain stamp are missing")
    return datetime.datetime.fromtimestamp(cut, datetime.timezone.utc)


def run(*a):
    out = subprocess.run([beeper_bin(), *a, "--json", "-q", "--read-only", "--full"], capture_output=True, text=True, timeout=60, env=ENV).stdout
    return json.loads(out)["data"]


def clean(t):
    t = re.sub(r"<br\s*/?>", "\n", t or ""); t = re.sub(r"<[^>]+>", "", t)
    return "\n".join(l.strip() for l in t.splitlines() if l.strip())


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
try:
    mine = [m for m in run("messages", "search", "--sender", "me", "--after", cut.strftime("%Y-%m-%dT%H:%M:%SZ"), "--limit", "400")
            if m.get("type") == "TEXT" and 12 <= len(clean(m.get("text", ""))) <= 240 and len(clean(m["text"]).split()) >= 3]
except Exception as e:
    print("beeper:", e); mine = []
rnd.shuffle(mine)
per_chat = {}
for m in mine:
    if sum(o["src"] == "beeper" for o in out) >= BEEPER_N: break
    if per_chat.get(m["chatID"], 0) >= 4: continue   # many chats, not one long thread
    try: hist = run("messages", "list", "--chat", m["chatID"], "--before-cursor", m["id"], "--limit", "8")
    except Exception: continue
    hist = [h for h in reversed(hist) if h.get("type") == "TEXT" and h.get("text")]
    ctx = "\n".join(("Я: " if h.get("isSender") else (h.get("senderName") or "Вони").split()[0] + ": ") + clean(h["text"])[:200] for h in hist)
    per_chat[m["chatID"]] = per_chat.get(m["chatID"], 0) + 1
    out.append({"src": "beeper", "app": "Beeper", "context": ctx[-1500:], "text": clean(m["text"])})

ts = cut.timestamp()
typed = [json.loads(l) for l in (ROOT / "data/typed.jsonl").read_text().splitlines() if l.strip()]
lines = list(dict.fromkeys(r["text"].strip() for r in typed if r["t"] > ts and r.get("app") == "Claude" and len(r["text"].split()) >= 4))
rnd.shuffle(lines)
out += [{"src": "claude", "app": "Claude", "context": "", "text": t[:240]} for t in lines[:CLAUDE_N]]
published = publish(out, args.output, args.min_items)
print(f"since {cut:%Y-%m-%d %H:%M}Z:", len(out), "items:", sum(o["src"] == "beeper" for o in out), "beeper,",
      sum(o["src"] == "claude" for o in out), "claude,", sum(len(o["text"]) for o in out), "letters")

if not published:
    print(f"fewer than {args.min_items} fresh lines: previous set kept")
    sys.exit(1)

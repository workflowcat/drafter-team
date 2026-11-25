"""A bigger held-out set for typing benches (2026-11-13 typing round): lines he sent with Return (data/typed.jsonl)
AFTER the last retrain cutoff, so neither the live layer (trained before it) nor the bench word lists
(bench/ngram.py corpus, cut at the same time) have seen them. Unlike bench/make_fresh.py it keeps the screen text
Drafter saw (`context`) and every app, so AI-app prompts dominate as they do live (91% of ghosts are in Claude).

    .venv/bin/python bench/make_held.py [--ai 120] [--chat 60] [--output data/replay-fresh.json]

Write it into a worktree's own data/ (bench/held.py then leaves these lines out of every word list).
"""
import argparse, json, random, re
from pathlib import Path
from retrain_state import last_retrain

ROOT = Path(__file__).resolve().parent.parent
AI = {"Claude": "claude", "ChatGPT": "claude", "Codex": "claude"}
CHAT = {"Beeper": "beeper", "Slack": "beeper", "WhatsApp": "beeper", "Telegram": "beeper"}


def pick(rows, cut, ai_n, chat_n, seed=13, limit=240):
    rnd = random.Random(seed)
    seen, ai, chat = set(), [], []
    for r in rows:
        t = (r.get("text") or "").strip()
        if r.get("t", 0) <= cut or len(t.split()) < 4 or t[:60] in seen or "⟦drafter-test⟧" in t: continue
        seen.add(t[:60])
        app = r.get("app", "")
        item = {"app": app if app in AI or app in CHAT else app, "context": (r.get("context") or "")[-1500:], "text": t[:limit]}
        if app in AI: ai.append({**item, "src": "claude"})
        elif app in CHAT: chat.append({**item, "src": "beeper"})
    rnd.shuffle(ai); rnd.shuffle(chat)
    return ai[:ai_n] + chat[:chat_n]


if __name__ == "__main__":
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--ai", type=int, default=120)
    ap.add_argument("--chat", type=int, default=60)
    ap.add_argument("--output", type=Path, default=ROOT / "data/replay-fresh.json")
    a = ap.parse_args()
    rows = [json.loads(l) for l in (ROOT / "data/typed.jsonl").read_text().splitlines() if l.strip()]
    out = pick(rows, last_retrain(ROOT), a.ai, a.chat)
    a.output.write_text(json.dumps(out, ensure_ascii=False, indent=1))
    from collections import Counter
    print(len(out), "items", dict(Counter(o["app"] for o in out)), sum(len(o["text"]) for o in out), "letters,",
          sum(bool(o["context"]) for o in out), "with screen text")

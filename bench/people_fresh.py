"""Per-person bench data (2026-11-01, local only, data/bench/people-fresh.json): for each fresh Beeper reply in
data/replay-fresh.json, the chat it was sent in and what he wrote in that chat BEFORE it (from the Beeper CLI, read
only), plus fingerprints of the chat's earlier lines (to test finding the chat from the screen).

    .venv/bin/python bench/people_fresh.py [history]
    .venv/bin/python bench/typebench.py <repo> --adapter data/adapters --boost 0.3 --people --app Beeper --label people-beeper
"""
import datetime, json, os, subprocess, sys
from pathlib import Path
from retrain_state import last_retrain
ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "engine"))
import people
from people import clean      # the same cleaning as bench/make_fresh.py (importing that one would rebuild the set)


def since():
    return datetime.datetime.fromtimestamp(last_retrain(ROOT), datetime.timezone.utc)

ENV = {**os.environ, "BEEPER_READONLY": "1"}
HIST = int(sys.argv[1]) if len(sys.argv) > 1 else 400


def run(*a):
    out = subprocess.run([people.beeper_bin(), *a, "--json", "-q", "--read-only", "--full"], capture_output=True, text=True, timeout=90, env=ENV, stdin=subprocess.DEVNULL).stdout
    return json.loads(out)["data"]


items = json.loads((ROOT / "data/replay-fresh.json").read_text())
cut = since()
sent = run("messages", "search", "--sender", "me", "--after", cut.strftime("%Y-%m-%dT%H:%M:%SZ"), "--limit", "1000")
by_text = {}
for m in sent:
    if m.get("type") == "TEXT": by_text.setdefault(clean(m.get("text", "")), m)
out = []
for i, it in enumerate(items):
    if it["app"] != "Beeper": continue
    m = by_text.get(it["text"])
    if not m: print("not found:", i); continue
    hist = [h for h in reversed(run("messages", "list", "--chat", m["chatID"], "--before-cursor", m["id"], "--limit", str(HIST)))
            if h.get("type") == "TEXT" and h.get("text")]
    mine = [t for t in (clean(h["text"]) for h in hist if h.get("isSender")) if t and not people.signed(t)]
    out.append({"i": i, "chat": m["chatID"], "t": m["timestamp"], "mine": mine,
                "marks": sorted({people.mark(l) for h in hist[-60:] for l in clean(h["text"]).splitlines() if people.mark(l)})})
sys.path.insert(0, str(ROOT / "bench"))
import typescore     # the rows go with this exact fresh set (typebench --people checks it)
(ROOT / "data/bench/people-fresh.json").write_text(json.dumps({"set_sha": typescore.set_sha(ROOT / "data/replay-fresh.json"), "rows": out}, ensure_ascii=False))
print(len(out), "replies,", len({o["chat"] for o in out}), "chats, his earlier lines per reply:",
      sorted(len(o["mine"]) for o in out))

# finding the chat from the lines above each reply (the bench context has "Name: " in front of each message; the
# screen does not), against fingerprints of all 40 chats' earlier lines: 30 found, 0 wrong, 10 not found on 2026-11-01
import re
marks = {}
for r in out:
    for m in r["marks"]: marks[m] = r["chat"] if marks.get(m) in (None, r["chat"]) else ""
found = [people.find(marks, "\n".join(re.sub(r"^[^:\n]{1,30}: ", "", l) for l in items[r["i"]]["context"].splitlines())) for r in out]
print("chat found", sum(f == r["chat"] for f, r in zip(found, out)), "wrong", sum(f not in (None, r["chat"]) for f, r in zip(found, out)),
      "not found", sum(f is None for f in found))

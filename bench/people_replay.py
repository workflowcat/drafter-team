"""Replay for engine/whom.py (2026-11-16): over his Beeper lines in data/typed.jsonl (each with the chat above), how
often the chat on screen is found, matched to a person in data/names.json, how big the block is, and how often the
line he then sent holds a name word of that person that was not on screen (what the booster gains). Prints numbers only.

The chats' other names come from the Beeper CLI, read only, held in memory (data/people.json is not written):

    .venv/bin/python -B bench/people_replay.py            # reads Beeper for names (read only)
    .venv/bin/python -B bench/people_replay.py --no-beeper  # only what people.json already holds
"""
import argparse, json, statistics, sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "engine"))
import people, whom

ap = argparse.ArgumentParser()
ap.add_argument("--no-beeper", action="store_true")
a = ap.parse_args()

mem = people.People(ROOT / "data/people.json")
mem.save = lambda: None                               # never written here
if not a.no_beeper:
    for chat, c in list(mem.chats.items()):
        if "who" in c: continue
        try: hist = people.beeper("messages", "list", "--chat", chat, "--limit", str(people.MARK_LINES), timeout=60)
        except Exception: continue
        people.note_who(c, [h for h in hist if h.get("type") == "TEXT"])

rows = []
for l in (ROOT / "data/typed.jsonl").read_text().splitlines():
    try: r = json.loads(l)
    except ValueError: continue
    if not (r.get("app") or "").lower().startswith("beeper") or not (r.get("context") or "").strip(): continue
    if "⟦drafter-test⟧" not in (r.get("text") or "") + r["context"]: rows.append(r)

w = whom.Who(mem, ROOT / "data/names.json")
chats_found, person, sizes, gains, chats_seen, chats_person = 0, 0, [], 0, set(), set()
kb = len(whom.kb_line("uk"))
for r in rows:
    ctx = r["context"]
    chat = people.find(mem.marks, ctx)
    if not chat: continue
    chats_found += 1; chats_seen.add(chat)
    b = w.block("Beeper", ctx)
    if not b: continue
    person += 1; chats_person.add(chat); sizes.append(len(b))
    screen = set(whom.toks(ctx))
    e = next((w.names.match(n) for n in (mem.info(chat) or {}).get("who", []) if w.names.match(n)), None)
    words = {t for x in whom.labels(e) + list(e.get("forms") or []) for t in whom.toks(x)} if e else set()
    if any(t in words and t not in screen for t in whom.toks(r.get("text") or "")): gains += 1

named = sum(1 for c in mem.chats.values() if c.get("who"))
print(json.dumps({
    "beeper_rows": len(rows), "chat_found": chats_found, "person_matched": person,
    "chats_in_people_json": len(mem.chats), "chats_with_names": named,
    "distinct_chats_found": len(chats_seen), "distinct_chats_person": len(chats_person),
    "block_chars_mean": round(statistics.mean(sizes)) if sizes else 0, "block_chars_max": max(sizes, default=0),
    "kb_line_chars": kb, "extra_chars_per_claude_message": (round(statistics.mean(sizes)) if sizes else 0) + kb,
    "lines_with_person_name_off_screen": gains,
}))

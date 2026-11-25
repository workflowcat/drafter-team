"""Answer to a running Claude thread: "передай в потік Lanterna: беремо варіант 2", "tell the atlas thread to ship it".

The thread is found by title in ~/Codius/Inbox/data/stories.json and the text goes through Aleph's outbox move."""
import json, re
from pathlib import Path
from _ask import fields
import _aleph

ID = "thread.reply"
NEEDS = ("aleph", "inbox")   # engine/integrations.py: the chip is offered only when all of these are on and answer
TRIGGER = re.compile(r"(?i)(?:^|[\s,.])(передай|скинь|напиши|скажи|tell|send)\s+(в|у|до|to)?\s*(потік|потоку|тред|треду|thread|the\s+[\w-]+\s+thread)\b")
import sys
sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "engine"))
import local
STORIES = Path(local.setting("inbox", "path") or "/nonexistent") / "stories.json"   # optional integration (engine/integrations.py)


def threads():
    try: d = json.loads(STORIES.read_text())
    except Exception: return []
    ts = [t for st in d["stories"] for t in st["threads"]] + d.get("loose_threads", [])
    return [t for t in ts if t.get("source") == "claude"]


def extract(line, ask):
    f = fields(ask, "З команди передати щось у робочий потік Claude витягни назву потоку (ключові слова) і сам текст для потоку.",
               line, ["thread", "text"])
    key, text = f.get("thread", "").lower(), f.get("text", "")
    if ":" in line: text = line.split(":", 1)[1].strip()          # "передай в потік X: <text>" - the words after the colon
    if not key or not text: return None
    words = [w for w in re.findall(r"\w+", key) if len(w) > 2]
    scored = sorted(((sum(w in t["title"].lower() for w in words), t.get("last", 0), t) for t in threads()), key=lambda x: (-x[0], -x[1]))
    if not scored or scored[0][0] == 0: return {"chip": f"Thread «{key}» was not found", "run": {"kind": "none"}, "fields": {}}
    t = scored[0][2]
    return {"chip": f"To thread «{t['title']}»: «{text}»", "run": {"kind": "python"}, "fields": {"sid": t["id"], "title": t["title"], "text": text}}


def run(fields):
    return _aleph.do({"type": "thread", "item": "thread:" + fields["sid"], "text": fields["text"]})

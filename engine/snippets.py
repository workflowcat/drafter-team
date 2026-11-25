"""Quick inserts while typing (2026-10-21): his email, calendar link and other snippets from data/snippets.json
({";key": "text"}, the same file the command panel saves to). Answered before phrase memory and the model, in well
under a millisecond.

- Trigger: ";" at the start of a word, then the first letters of a key (";m" -> ";mail"). A chip shows the text; Tab
  replaces the trigger with it. The full key and a space expand at once in the app (Keys.swift).
- Cue: the line ends with words that ask for one ("my email is", "мій імейл:", "лінк на календар") and the matching
  snippet exists: the chip offers it; Tab adds it after the cue.

    .venv/bin/python engine/snippets.py "напиши мені на мій імейл"     (what it would offer)
"""
import json, re, sys, threading
from pathlib import Path

FILE = Path(__file__).resolve().parent.parent / "data/snippets.json"
_lock = threading.Lock()
_cache = {"mtime": None, "data": {}}

# which snippet a cue asks for; the first key that exists wins
CUES = [(tuple(row["keys"]), re.compile(row["pattern"])) for row in
        json.loads((FILE.parent.parent / "dictionary/snippet-cues.json").read_text())]
TRIGGER = re.compile(r"(?:^|(?<=\s))(;[\w\-]{1,20})$")


def load():
    with _lock:
        try:
            m = FILE.stat().st_mtime
            if m != _cache["mtime"]:
                _cache["data"] = {k: v for k, v in json.loads(FILE.read_text()).items() if k.startswith(";") and v}
                _cache["mtime"] = m
        except Exception:
            _cache["data"] = {}
        return _cache["data"]


def chip(text, run):
    short = text if len(text) <= 48 else text[:45] + "…"
    return {"id": "snippet", "chip": f"⇥ {short}", "run": run}


def offer(before):
    """A chip for the end of `before`, or None."""
    snip = load()
    if not snip:
        return None
    line = before.split("\n")[-1]
    m = TRIGGER.search(line)
    if m:
        typed = m.group(1).lower()
        keys = sorted((k for k in snip if k.lower().startswith(typed)), key=lambda k: (len(k), k))
        if keys:
            k = keys[0]
            return chip(snip[k], {"kind": "expand", "old": m.group(1), "new": snip[k], "key": k})
        return None
    typed = line.split()[-1] if line.split() and not line[-1:].isspace() else ""
    key = next((k for k in (";mail", ";email", ";e") if k in snip), None)
    if key and len(typed) >= 2 and typed != snip[key] and (typed == "AU" or snip[key].lower().startswith(typed.lower())):
        return chip(snip[key], {"kind": "expand", "old": typed, "new": snip[key], "key": key})
    for keys, rx in CUES:
        if rx.search(line[-80:]):
            k = next((k for k in keys if k in snip), None)
            if k:
                lead = "" if line.endswith((" ", "\t")) else " "
                return chip(snip[k], {"kind": "expand", "old": "", "new": lead + snip[k], "key": k})
    return None


if __name__ == "__main__":
    print(json.dumps(offer(" ".join(sys.argv[1:])), ensure_ascii=False))

"""Aleph (127.0.0.1:8797) already does some actions, each with an undo: beeper_draft, gmail_draft, remind (follow-up),
thread (answer to a running Claude thread). Drafter calls those instead of doing them itself."""
import json, urllib.request

import sys
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "engine"))
import local
ALEPH = local.setting("aleph", "url") or "http://127.0.0.1:8797"   # optional integration (engine/integrations.py)


def post(path, body, timeout=40):
    req = urllib.request.Request(ALEPH + path, data=json.dumps(body, ensure_ascii=False).encode(),
                                 headers={"Content-Type": "application/json"})
    return json.loads(urllib.request.urlopen(req, timeout=timeout).read())


def get(path, timeout=5):
    return json.loads(urllib.request.urlopen(ALEPH + path, timeout=timeout).read())


def do(move):
    """One move through Aleph's /api/do. Returns the line to show; the undo is kept in Aleph's own log."""
    r = post("/api/do", {"moves": [move]})["results"][0]
    if not r.get("ok"): raise RuntimeError(r.get("say") or r.get("err") or "Aleph could not do it")
    return r.get("say", "готово")


def person(name):
    """Best Aleph match for a name ('Савою' -> Sava Example), or None."""
    try:
        hits = get("/api/find?q=" + urllib.parse.quote(name) + "&kinds=person&limit=3")
        return hits[0] if hits else None
    except Exception:
        return None


import urllib.parse  # noqa: E402

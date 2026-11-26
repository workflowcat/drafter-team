"""Learn from the user's edits (idea 6): when the user sends a line that came from a voice take, the words the user changed are
"heard -> fixed" pairs. They wait in data/edits.jsonl until the user accepts one in the menu; an accepted pair goes into the
shared dictionary (spelling fixes for Voice and Whisper's hint)."""
import difflib, json, re, sys, time
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parent))
import dictionary
from data_dir import data_dir

ROOT = Path(__file__).resolve().parent.parent
DATA = data_dir()
TAKES, EDITS = DATA / "takes.jsonl", DATA / "edits.jsonl"
WORD = re.compile(r"[\w'’-]+", re.U)


def _load():
    try: return [json.loads(l) for l in EDITS.read_text().splitlines() if l.strip()]
    except FileNotFoundError: return []


def _save(rows):
    tmp = EDITS.with_suffix(".tmp"); tmp.write_text("\n".join(json.dumps(r, ensure_ascii=False) for r in rows) + "\n"); tmp.replace(EDITS)


def recent_takes(minutes=30):
    try: rows = [json.loads(l) for l in TAKES.read_text().splitlines()[-40:] if l.strip()]
    except FileNotFoundError: return []
    return [r for r in rows if time.time() - r.get("t", 0) < minutes * 60 and r.get("text")]


def pairs(take, sent):
    """Word changes between what Drafter put in and what the user sent: 1-3 words each side, not just case or punctuation."""
    a, b = WORD.findall(take), WORD.findall(sent)
    out = []
    for op, i1, i2, j1, j2 in difflib.SequenceMatcher(None, [w.lower() for w in a], [w.lower() for w in b]).get_opcodes():
        if op == "replace" and 1 <= i2 - i1 <= 3 and 1 <= j2 - j1 <= 3:
            h, f = " ".join(a[i1:i2]), " ".join(b[j1:j2])
            if h.lower() != f.lower() and len(f) >= 2: out.append((h, f))
    # case-only changes of a name ("sava" -> "Sava") count too
    for op, i1, i2, j1, j2 in difflib.SequenceMatcher(None, a, b).get_opcodes():
        if op == "replace" and i2 - i1 == j2 - j1 == 1 and a[i1].lower() == b[j1].lower() and b[j1][:1].isupper():
            out.append((a[i1], b[j1]))
    return out


def sent(text):
    """A line the user sent: find the take it came from (most words shared) and keep its changed words as candidates."""
    best, score = None, 0.0
    tw = set(w.lower() for w in WORD.findall(text))
    for t in recent_takes():
        k = set(w.lower() for w in WORD.findall(t["text"]))
        if not k: continue
        s = len(tw & k) / max(len(k), 1)
        if s > score: best, score = t, s
    if not best or score < 0.5: return []
    found = pairs(best["text"], text)
    if not found: return []
    rows = _load()
    for h, f in found:
        r = next((r for r in rows if r["heard"].lower() == h.lower() and r["fixed"] == f), None)
        if r: r["count"] += 1; r["t"] = time.time()
        else: rows.append({"heard": h, "fixed": f, "count": 1, "t": time.time(), "state": "new"})
    _save(rows)
    return found


def waiting():
    return [r for r in _load() if r.get("state") == "new"]


def decide(heard, fixed, accept):
    rows = _load()
    for r in rows:
        if r["heard"].lower() == heard.lower() and r["fixed"] == fixed: r["state"] = "learned" if accept else "ignored"
    _save(rows)
    if accept:
        dictionary.add(fixed, kind="term" if " " not in fixed else "phrase", source="edits", heard=[heard.lower()])

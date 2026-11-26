"""The command line (2026-10-21; ⌘K in Drafter's window): one line - "забукай 30 хв з Савою завтра після обіду",
"find a free hour on Thursday", "remind me to send the act on Friday", ";sig" - becomes up to three options, each one
step the user can run with Enter (nothing runs before that). Online: Claude Haiku reads the line (router.py); offline: the
same action triggers and the local model as the chips use. Snippets live in data/snippets.json ({";key": "text"})."""
import json, re, time
from datetime import datetime
from pathlib import Path
import actions, router, claude_worker, local
from data_dir import data_dir

ROOT = Path(__file__).resolve().parent.parent
SNIPPETS = data_dir() / "snippets.json"


def snippets():
    try: return json.loads(SNIPPETS.read_text())
    except Exception: return {}


def save_snippet(key, text):
    d = snippets(); d[key if key.startswith(";") else ";" + key] = text
    SNIPPETS.write_text(json.dumps(d, ensure_ascii=False, indent=1))
    return f"Snippet {key} saved"


def show(dt, minutes=None):
    import sys; sys.path.insert(0, str(ROOT / "actions"))
    from _when import show as s
    return s(dt, minutes)


def option(kind, f):
    """One plan from the reader -> a chip the app knows how to run."""
    try:
        if kind == "event":
            start = datetime.fromisoformat(f["start"]); m = int(f.get("minutes") or 30)
            t = f.get("title") or "Meeting"
            return {"chip": f"Event «{t}» · {show(start, m)}",
                    "run": {"kind": "eventkit.event", "title": t, "start": start.strftime("%Y-%m-%dT%H:%M"), "minutes": m, "notes": "Drafter"}}
        if kind == "free":
            d0 = f.get("from") or datetime.now().strftime("%Y-%m-%d"); d1 = f.get("to") or d0
            m = int(f.get("minutes") or 30)
            return {"chip": f"Free {m}-minute slots · {d0[5:]}" + (f"–{d1[5:]}" if d1 != d0 else "") + " (choose a time)",
                    "run": {"kind": "eventkit.free", "from": d0, "to": d1, "minutes": m, "title": f.get("title") or "Meeting",
                            "earliest": f.get("earliest") or "09:00", "latest": f.get("latest") or "19:00"}}
        if kind == "reminder":
            due = f.get("due")
            return {"chip": f"Reminder «{f['title']}»" + (f" · {show(datetime.fromisoformat(due))}" if due else ""),
                    "run": {"kind": "eventkit.reminder", "title": f["title"], "due": due}}
        if kind == "snippet":
            return {"chip": f"Save snippet {f['key']} → «{f['text'][:50]}»", "run": {"kind": "snippet.save", "key": f["key"], "text": f["text"]}}
        if kind == "answer":
            return {"chip": f["text"][:300], "run": {"kind": "copy", "text": f["text"]}, "answer": True}
    except Exception:
        return None
    return None


PROMPT = """You turn one line {user} typed into up to three things Drafter can do on his Mac. Now: {now} ({wd}).
Kinds and fields (dates "YYYY-MM-DDTHH:MM" or "YYYY-MM-DD", his time zone):
- event: book a time. title (short, calendar style, language of the line, with the person's name), start, minutes (default 30)
- free: find free time in his calendar. from, to (days), minutes, title, earliest ("09:00"), latest ("19:00")
- reminder: title, due
- snippet: save a text snippet. key (starts with ;), text
- answer: a direct short answer (a sum, a conversion, a date, a quick fact). text
UI labels must be English. Preserve the language of authored content (titles and notes).
The most likely reading first; the others are real alternatives (e.g. book a time vs find free spots), never rewordings.
"after lunch" = 14:00, "morning" = 10:00, "evening" = 18:00, "tomorrow" = the next day. Reply with JSON only:
{{"options": [{{"kind": "...", "label": "2-4 words", "fields": {{...}}}}]}}
Line: {line}"""


def plan(line, local_ask=None):
    line = (line or "").strip()
    if not line: return {"options": []}
    t = time.perf_counter()
    snip = snippets()
    if line in snip:
        return {"options": [{"chip": f"Insert {line} → «{snip[line][:60]}»", "run": {"kind": "insert", "text": snip[line]}}], "by": "snippet", "ms": 0}
    opts, by = [], "local"
    if router.online():
        now = datetime.now()
        raw = claude_worker.ask(PROMPT.format(user=local.short_name(), now=now.strftime("%Y-%m-%d %H:%M"), wd=now.strftime("%A"), line=line), 25) or ""
        m = re.search(r"\{.*\}", raw, re.S)
        try:
            for o in (json.loads(m.group(0)).get("options") or [])[:3] if m else []:
                c = option(o.get("kind"), o.get("fields") or {})
                if c: c["label"] = o.get("label", ""); opts.append(c)
            by = "haiku" if opts else by
        except Exception:
            pass
    if not opts:   # offline, or Haiku gave nothing: the chips' own triggers and the local model
        found = actions.detect(line if len(line.split()) >= 3 else line + " . .")
        if found and local_ask:   # never import server here: it is __main__, a second import would load a second model
            r = actions.cached(found, line, local_ask)
            if r: opts.append({"id": found.mod.ID, **r})
        if re.search(r"(?i)вільн|вікно|free (time|slot|spot|hour)|slot", line):
            import sys; sys.path.insert(0, str(ROOT / "actions"))
            from _when import parse
            start, minutes, _ = parse(line)
            d = (start or datetime.now()).strftime("%Y-%m-%d")
            opts.append(option("free", {"from": d, "to": d, "minutes": minutes or 30}))
    return {"options": [o for o in opts if o][:3], "by": by, "ms": round((time.perf_counter() - t) * 1000)}

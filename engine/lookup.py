"""Explicit read-only typing lookups. No model, event creation, sharing or message sending."""
import csv
import io
import json
import re
import subprocess
import sys
import threading
from datetime import datetime, timedelta, time
from pathlib import Path
from urllib.parse import urlparse
from zoneinfo import ZoneInfo

sys.path.insert(0, str(Path(__file__).resolve().parent))
import local

DATA = Path(__file__).resolve().parent.parent / "data"
GAM = Path(local.setting("gam", "bin") or "/nonexistent/gam")   # optional integration (engine/integrations.py)
LOCK = threading.BoundedSemaphore(2)
KINDS = {"docs", "links", "meetings", "free", "accounts"}


def config():
    try:
        value = json.loads((DATA / "workspace.json").read_text())
    except (OSError, ValueError):
        value = {}
    if not isinstance(value, dict):
        raise ValueError("Set your Google account in Shortcuts before searching.")
    account = str(value.get("account", "")).strip()
    if not re.fullmatch(r"[^\s@]+@[^\s@]+\.[^\s@]+", account):
        raise ValueError("Set your Google account in Shortcuts before searching.")
    try:
        zone = ZoneInfo(str(value.get("timezone") or local.timezone()))
    except (ValueError, KeyError):
        raise ValueError("The search time zone is invalid. Use a zone like Europe/Kyiv in workspace.json.")
    return account, zone


def gam(account, *args):
    import integrations
    if not GAM.is_file() or not integrations.available("gam"):
        raise ValueError("The local Google connection is unavailable.")
    try:
        p = subprocess.run([str(GAM), "user", account, *args], capture_output=True, text=True, timeout=25)
    except subprocess.TimeoutExpired:
        raise ValueError("Google did not answer in time. Try the search again.")
    # Never return credentials, raw provider output or private event details in an error.
    if p.returncode or re.search(r"(?im)^\s*(ERROR|WARNING:.*(denied|unauthorized))", p.stderr):
        raise ValueError("Google could not read this account. Check its existing Drive and Calendar access.")
    return p.stdout


def public_url(value):
    try:
        p = urlparse(value)
        return value if p.scheme in ("https", "http") and p.netloc and not p.username and not p.password else ""
    except ValueError:
        return ""


def result(label, text):
    return {"chip": label, "run": {"kind": "lookup.insert", "text": text}}


def quote(value):
    return value.replace("\\", "\\\\").replace("'", "\\'")


def documents(account, query):
    if len(query.strip()) < 2:
        raise ValueError("Type a document name, for example ;docs project notes.")
    where = "trashed = false and mimeType != 'application/vnd.google-apps.folder'"
    for word in query.split()[:8]:
        where += " and name contains '" + quote(word) + "'"
    data = gam(account, "print", "filelist", "anyowner", "query", where,
               "fields", "id,name,webviewlink", "maxfiles", "9", "orderby", "modifiedtime", "descending")
    out = []
    for row in csv.DictReader(io.StringIO(data)):
        url = public_url(row.get("webViewLink", ""))
        if url:
            out.append(result(f"{row.get('name') or 'Untitled'} · Google Drive", url))
    return out


def links(query):
    saved = {}
    for name in ("replacements.json", "snippets.json"):
        try:
            values = json.loads((DATA / name).read_text())
            if isinstance(values, dict):
                saved.update(values)
        except (OSError, ValueError):
            pass
    words = query.lower().split()
    return [result(f"{key} · saved link", value) for key, value in saved.items()
            if isinstance(value, str) and public_url(value)
            and all(w in (key + " " + value).lower() for w in words)][:9]


def window(query, now, default_days):
    """Small explicit date vocabulary; never use an LLM to guess availability dates."""
    lower = query.lower().strip()
    day = now.date()
    days = default_days
    used = ""
    match = re.search(r"\b\d{4}-\d{2}-\d{2}\b", lower)
    if match:
        try:
            day = datetime.strptime(match.group(), "%Y-%m-%d").date()
        except ValueError:
            raise ValueError("Use a valid date in YYYY-MM-DD format.")
        used, days = match.group(), 1
    else:
        for token in ("next week", "this week", "tomorrow", "today", "завтра", "сьогодні", "сегодня", "наступного тижня", "наступний тиждень",
                      "следующей неделе", "следующая неделя", "цього тижня", "этой неделе"):
            if re.search(r"(?<!\w)" + token + r"(?!\w)", lower):
                used = token
                if token in ("tomorrow", "завтра"):
                    day += timedelta(days=1); days = 1
                elif token in ("today", "сьогодні", "сегодня"):
                    days = 1
                elif token in ("next week", "наступного тижня", "наступний тиждень", "следующей неделе", "следующая неделя"):
                    day += timedelta(days=7 - day.weekday()); days = 5
                else:
                    days = max(1, 5 - day.weekday())
                break
    remaining = re.sub(re.escape(used), "", query, flags=re.I).strip() if used else query.strip()
    start = datetime.combine(day, time.min, now.tzinfo)
    return start, start + timedelta(days=days), remaining


def events(account, start, end):
    data = gam(account, "show", "events", "primary", "after", start.isoformat(), "before", end.isoformat(),
               "singleevents", "orderby", "starttime", "fields",
               "id,summary,start,end,htmllink,hangoutlink,transparency,status,attendees,eventtype", "formatjson")
    out = []
    for line in data.splitlines():
        if not line.strip():
            continue
        try:
            row = json.loads(line)
            event = row["event"]
            if not isinstance(event, dict):
                raise ValueError()
        except (ValueError, KeyError, TypeError):
            raise ValueError("Calendar returned an unreadable response. No times were suggested.")
        if event.get("status") == "cancelled":
            continue
        if any(a.get("self") and a.get("responseStatus") == "declined" for a in event.get("attendees", [])):
            continue
        out.append(event)
    return out


def event_time(value, zone):
    s = value.get("dateTime") or value.get("date")
    if not isinstance(s, str):
        raise ValueError("Calendar returned an event without a time.")
    dt = datetime.fromisoformat(s.replace("Z", "+00:00"))
    return dt.replace(tzinfo=zone) if dt.tzinfo is None else dt.astimezone(zone)


# the picker's part of the day (17 November 2026): the user's working hours split at 13:00
PARTS = {"morning": (9, 13), "afternoon": (13, 18)}
PART_WORDS = {"morning": ("morning", "mornings", "ранок", "вранці", "зранку", "утром", "утро"),
              "afternoon": ("afternoon", "afternoons", "після обіду", "пообіді", "после обеда", "днем", "днём")}


def part_of(words):
    """("morning" | "afternoon" | "", the words without it)."""
    low = words.lower()
    for part, ws in PART_WORDS.items():
        for w in ws:
            if re.search(r"(?<!\w)" + re.escape(w) + r"(?!\w)", low):
                return part, re.sub(r"(?<!\w)" + re.escape(w) + r"(?!\w)", "", words, flags=re.I).strip()
    return "", words


def free_times(rows, start, end, minutes, now, hours=(9, 18)):
    busy = []
    for row in rows:
        if row.get("transparency") == "transparent" or row.get("eventType") == "workingLocation":
            continue
        try:
            a, b = event_time(row["start"], now.tzinfo), event_time(row["end"], now.tzinfo)
            if b <= a:
                raise ValueError()
        except (ValueError, KeyError, TypeError):
            raise ValueError("An event has unreadable times. No free times were suggested.")
        busy.append((a, b))  # Opaque all-day events block the day too.
    found = []
    day = start.date()
    while day < end.date() and len(found) < 3:
        if day.weekday() < 5:
            t = datetime.combine(day, time(hours[0]), now.tzinfo)
            stop = datetime.combine(day, time(hours[1]), now.tzinfo)
            while t + timedelta(minutes=minutes) <= stop and len(found) < 3:
                finish = t + timedelta(minutes=minutes)
                if t >= now + timedelta(minutes=15) and not any(a < finish and b > t for a, b in busy):
                    found.append((t, finish))
                    t += timedelta(minutes=((minutes + 14) // 15) * 15 + 60)
                else:
                    t += timedelta(minutes=15)
        day += timedelta(days=1)
    return found


def search(request):
    kind = request.get("kind")
    query = str(request.get("query") or "").strip()[:200]
    if kind not in KINDS:
        return {"options": [], "error": "Unknown search. Use ;docs, ;links, ;meetings or ;free."}
    if not LOCK.acquire(blocking=False):
        return {"options": [], "error": "A search is still running. Try again shortly."}
    try:
        # Saved links work even when there is no Google account configured.
        if kind == "links":
            return {"options": links(query), "source": "Saved links on this Mac", "status": "Choose a saved link"}
        account, zone = config()
        now = datetime.now(zone)
        source = f"Primary calendar only · {zone.key} · {account}"
        if kind == "docs":
            options = documents(account, query)
            source = f"{account} · Google Drive · name search"
        elif kind == "accounts":
            gam(account, "print", "filelist", "query", "trashed = false", "fields", "id", "maxfiles", "1")
            events(account, now, now + timedelta(days=1))
            return {"options": [], "source": source, "status": "Drive and primary Calendar read access verified"}
        else:
            start, end, words = window(query, now, 7 if kind == "free" else 14)
            part = ""
            if kind == "free":
                part, words = part_of(words)
                hour = re.fullmatch(r"(?:1\s*)?(?:h|hr|hour|год|година|час)", words.strip(), re.I)
                if hour: words = "60"
                match = re.fullmatch(r"(?:(\d{1,3})(?:\s*(?:min|minutes|хв|мин))?)?", words.strip(), re.I)
                if not match:
                    raise ValueError("Use ;free 30 tomorrow, ;free 60 next week, or ;free 30 YYYY-MM-DD.")
                minutes = int(match.group(1) or 30)
                if not 15 <= minutes <= 240:
                    raise ValueError("Choose a meeting length between 15 and 240 minutes.")
            rows = events(account, start, end)
            source += f" · {start:%d %b}–{(end - timedelta(days=1)):%d %b}"
            if kind == "meetings":
                options = []
                for row in rows:
                    title = row.get("summary") or "Untitled meeting"
                    if not all(word in title.lower() for word in words.lower().split()):
                        continue
                    at = event_time(row["start"], zone)
                    url = public_url(row.get("hangoutLink", "")) or public_url(row.get("htmlLink", ""))
                    if url:
                        label = "call link" if row.get("hangoutLink") else "calendar link"
                        options.append(result(f"{at:%a %d %b, %H:%M} · {title} · {label}", url))
                options = options[:9]
            else:
                hours = PARTS.get(part, (9, 18))
                times = free_times(rows, start, end, minutes, now, hours)
                # plain words (the user, 17 November 2026); the app writes them again in the field's language from "slots"
                texts = [f"{a:%a %d %b} {a.hour}:{a:%M}-{b.hour}:{b:%M}" for a, b in times]
                options = [result(text, text) for text in texts]
                if len(texts) > 1:
                    options.insert(0, result(f"All {len(texts)} times", "Free: " + ", ".join(texts)))
                source += f" · weekdays {hours[0]:02d}:00–{hours[1]:02d}:00"
                return {"options": options, "source": source, "status": "Choose text to insert" if options else "No matching results",
                        "slots": [{"start": a.isoformat(), "end": b.isoformat()} for a, b in times], "minutes": minutes,
                        "part": part, "zone": zone.key}
        return {"options": options, "source": source, "status": "Choose text to insert" if options else "No matching results"}
    except (ValueError, OSError, TypeError, KeyError):
        import sys
        error = sys.exc_info()[1]
        return {"options": [], "error": str(error) if isinstance(error, ValueError) else "Search is unavailable. Check the local Google connection."}
    finally:
        LOCK.release()

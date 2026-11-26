"""Calendar event: "створи зустріч з Савою у вівторок о 15", "запланируй дзвінок завтра о 10", "create a meeting with Mila tomorrow at 3pm"."""
import re
from _when import parse, show
from _ask import fields, is_cyrillic

ID = "calendar.event"
NEEDS = ()   # engine/integrations.py: the chip is offered only when all of these are on and answer
TRIGGER = re.compile(r"(?i)(?:^|[\s,.])(створи|створити|запланую|заплануй|запланувати|постав|поставити|додай|забукай|"
                     r"create|schedule|book|set up|add)\s+(?:мені\s+|me\s+|a\s+|an\s+)?(зустріч|дзвінок|колл?|мітинг|міт|"
                     r"подію|івент|meeting|call|event|sync)\b")
INSTRUCTION = {
    "uk": "З команди створити подію в календарі витягни коротку назву події (як у календарі, мовою команди) "
          "і хто буде (імена в називному відмінку, через кому; порожньо, якщо нікого).",
    "en": "From this command to create a calendar event, take a short event title (as in a calendar) "
          "and who will attend (names, comma-separated; empty if nobody).",
}


def extract(line, ask):
    start, minutes, _ = parse(line)
    if not start: return None
    f = fields(ask, INSTRUCTION, line, ["title", "who"])
    title = f.get("title") or "Meeting"
    who = f.get("who", "")
    # a small model may hand back the command itself: then the title is built by rule ("Зустріч: Сава", "Meeting: Mila")
    # (an English line also gets one when the model answered in Cyrillic)
    if TRIGGER.search(" " + title) or len(title.split()) > 6 or (not is_cyrillic(line) and is_cyrillic(title)):
        kind = re.search(r"(?i)(зустріч|дзвінок|колл?|мітинг|міт|meeting|call|sync)", line)
        title = (kind.group(1).capitalize() if kind else "Meeting")
    if not is_cyrillic(line) and is_cyrillic(who): who = ""
    if who and who.lower() not in title.lower(): title = f"{title}: {who}"
    return {"chip": f"Calendar event «{title}» · {show(start, minutes)}",
            "run": {"kind": "eventkit.event", "title": title, "start": start.strftime("%Y-%m-%dT%H:%M"), "minutes": minutes,
                    "notes": "Drafter: " + line.strip()},
            "fields": {"title": title, "who": who, "start": start.isoformat(), "minutes": minutes}}


def to_run(fields):
    """The app-side step for callers that only kept the fields."""
    from datetime import datetime
    start = datetime.fromisoformat(fields["start"])
    return {"kind": "eventkit.event", "title": fields["title"], "start": start.strftime("%Y-%m-%dT%H:%M"),
            "minutes": int(fields.get("minutes") or 60), "notes": "Drafter"}

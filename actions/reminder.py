"""Reminder: "нагадай мені завтра о 10 подзвонити в банк", "remind me to send the invoice on friday"."""
import re
from _when import parse, show
from _ask import fields, is_cyrillic

ID = "reminder"
NEEDS = ()   # engine/integrations.py: the chip is offered only when all of these are on and answer
TRIGGER = re.compile(r"(?i)(?:^|[\s,.])(нагадай|нагадати|remind me)\b")
INSTRUCTION = {
    "uk": "З команди-нагадування витягни, про що нагадати: коротко, з дієсловом, мовою команди, без дати й часу.",
    "en": "From this reminder command, take what to be reminded of: short, starting with a verb, no date or time.",
}
# English words of time the fallback title drops: "tomorrow at 10", "on friday", "by 5pm"
EN_WHEN = re.compile(r"(?i)\b(?:(?:on|by|at|next)\s+)?(?:today|tonight|tomorrow|day after tomorrow|"
                     r"monday|tuesday|wednesday|thursday|friday|saturday|sunday)\b|"
                     r"\b(?:at|by)\s+\d{1,2}(?:[:.]\d{2})?\s*(?:am|pm)?\b|\b\d{1,2}(?::\d{2})?\s*(?:am|pm)\b")


def fallback(line):
    """The title by rule when the model gave none: the line without the trigger (and, in English, without the time)."""
    t = re.sub(TRIGGER, "", line).strip(" ,.")
    if t and not is_cyrillic(line):
        t = re.sub(r"^(?:me\s+)?(?:to\s+)?", "", re.sub(r"\s+", " ", EN_WHEN.sub(" ", t)).strip(" ,.")).strip(" ,.")
        t = t[:1].upper() + t[1:]
    return t or line.strip()


def extract(line, ask):
    due, _, said = parse(line)
    f = fields(ask, INSTRUCTION, line, ["title"])
    title = f.get("title")
    # a small model may echo the command or answer in the wrong script: then the title is built by rule
    if not title or TRIGGER.search(" " + title) or (not is_cyrillic(line) and is_cyrillic(title)):
        title = fallback(line)
    when = show(due) if due else "no time set"
    return {"chip": f"Reminder «{title}» · {when}",
            "run": {"kind": "eventkit.reminder", "title": title, "due": due.strftime("%Y-%m-%dT%H:%M") if due else None},
            "fields": {"title": title, "due": due.isoformat() if due else None}}


def to_run(fields):
    from datetime import datetime
    due = fields.get("due")
    return {"kind": "eventkit.reminder", "title": fields["title"],
            "due": datetime.fromisoformat(due).strftime("%Y-%m-%dT%H:%M") if due else None}

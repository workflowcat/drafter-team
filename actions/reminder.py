"""Reminder: "нагадай мені завтра о 10 подзвонити в банк", "remind me to send the invoice on friday"."""
import re
from _when import parse, show
from _ask import fields

ID = "reminder"
NEEDS = ()   # engine/integrations.py: the chip is offered only when all of these are on and answer
TRIGGER = re.compile(r"(?i)(?:^|[\s,.])(нагадай|нагадати|remind me)\b")


def extract(line, ask):
    due, _, said = parse(line)
    f = fields(ask, "З команди-нагадування витягни, про що нагадати: коротко, з дієсловом, мовою команди, без дати й часу.",
               line, ["title"])
    title = f.get("title")
    if not title:
        title = re.sub(TRIGGER, "", line).strip(" ,.") or line.strip()
    when = show(due) if due else "no time set"
    return {"chip": f"Reminder «{title}» · {when}",
            "run": {"kind": "eventkit.reminder", "title": title, "due": due.strftime("%Y-%m-%dT%H:%M") if due else None},
            "fields": {"title": title, "due": due.isoformat() if due else None}}


def to_run(fields):
    from datetime import datetime
    due = fields.get("due")
    return {"kind": "eventkit.reminder", "title": fields["title"],
            "due": datetime.fromisoformat(due).strftime("%Y-%m-%dT%H:%M") if due else None}

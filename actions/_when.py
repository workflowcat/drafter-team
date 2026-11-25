"""Day and time out of Ukrainian or English words: "у вівторок о 15", "завтра о 9:30", "tomorrow at 3pm", "20.10 о 18"."""
import re
from datetime import datetime, timedelta

DAYS = [("понеділ", "пн", "monday", "mon"), ("вівтор", "вт", "tuesday", "tue"), ("серед", "ср", "wednesday", "wed"),
        ("четвер", "чт", "thursday", "thu"), ("п'ятниц", "пт", "friday", "fri"), ("субот", "сб", "saturday", "sat"),
        ("неділ", "нд", "sunday", "sun")]
SHORT = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]
MONTHS = ["січ", "лют", "берез", "квіт", "трав", "черв", "лип", "серп", "верес", "жовт", "листопад", "груд"]


def parse(text, now=None):
    """-> (start datetime or None, minutes, the words that said it)"""
    now = now or datetime.now()
    t = text.lower().replace("’", "'").replace("ʼ", "'")
    day, said = None, []
    if re.search(r"\bпіслязавтра\b|\bday after tomorrow\b", t): day = now.date() + timedelta(2); said.append("післязавтра")
    elif re.search(r"\bзавтра\b|\btomorrow\b", t): day = now.date() + timedelta(1); said.append("завтра")
    elif re.search(r"\bсьогодні\b|\btoday\b|\btonight\b", t): day = now.date(); said.append("сьогодні")
    if day is None:
        for i, names in enumerate(DAYS):
            if any(re.search(r"(?<![\w'])" + re.escape(n) + (r"\w*" if len(n) > 3 else r"\b"), t) for n in names):
                ahead = (i - now.weekday()) % 7 or 7
                if re.search(r"наступн\w* |next ", t) and ahead < 7: ahead += 7 if ahead <= 0 else 0
                day = now.date() + timedelta(ahead); said.append(SHORT[i]); break
    if day is None:
        m = re.search(r"\b(\d{1,2})[./](\d{1,2})\b", t)
        if m and 1 <= int(m.group(2)) <= 12:
            try: day = now.replace(month=int(m.group(2)), day=int(m.group(1))).date()
            except ValueError: day = None
        else:
            m = re.search(r"\b(\d{1,2})\s+(" + "|".join(MONTHS) + r")\w*", t)
            if m:
                try: day = now.replace(month=MONTHS.index(m.group(2)) + 1, day=int(m.group(1))).date()
                except ValueError: day = None
        if day and day < now.date(): day = day.replace(year=day.year + 1)
    hour = minute = None
    m = (re.search(r"(?:\bо|\bна|\bв|\bat|\bby)\s+(\d{1,2})(?:[:.](\d{2}))?\s*(am|pm|ранку|дня|вечора|ночі)?(?!\d)", t)
         or re.search(r"\b(\d{1,2})[:](\d{2})\b\s*(am|pm)?", t) or re.search(r"\b(\d{1,2})\s*(am|pm)\b", t))
    if m:
        g = m.groups(); hour = int(g[0]); minute = int(g[1]) if len(g) > 1 and g[1] and g[1].isdigit() else 0
        suf = g[-1] if g[-1] and not g[-1].isdigit() else None
        if suf in ("pm", "дня", "вечора") and hour < 12: hour += 12
        if suf in ("am", "ночі") and hour == 12: hour = 0
        if suf is None and 1 <= hour <= 7: hour += 12          # "о 3" in a work chat means 15:00
        if hour > 23 or minute > 59: hour = minute = None
    minutes = 60
    d = re.search(r"на\s+(\d+)\s*(хв|год)|for\s+(\d+)\s*(min|h)", t)
    if d:
        n = int(d.group(1) or d.group(3)); u = d.group(2) or d.group(4)
        minutes = n if u in ("хв", "min") else n * 60
    elif re.search(r"на\s+пів\s*години|half an hour", t): minutes = 30
    elif re.search(r"на\s+годину|for an hour", t): minutes = 60
    if day is None and hour is None: return None, minutes, said
    if day is None:
        day = now.date() if (hour, minute) > (now.hour, now.minute) else now.date() + timedelta(1)
    if hour is None: hour, minute = 10, 0
    return datetime(day.year, day.month, day.day, hour, minute), minutes, said


def show(dt, minutes=None):
    s = f"{SHORT[dt.weekday()]} {dt.day:02d}.{dt.month:02d}, {dt.hour:02d}:{dt.minute:02d}"
    if minutes:
        e = dt + timedelta(minutes=minutes); s += f"–{e.hour:02d}:{e.minute:02d}"
    return s

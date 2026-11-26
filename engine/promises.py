"""Promises (2026-11-17): promises in lines the user sent ("I'll send the deck tomorrow", "завтра скину договір"),
kept locally in data/promises.json, offered back in that chat's empty box when they come due.

- detect(text, now): pure rule, no model. A first-person promise verb (English: I'll / I will / I'm going to / a
  sentence starting with "will"; Ukrainian: a first-person future verb such as скину, надішлю, поділюсь) and what
  follows it; a small fixed vocabulary of time words gives `due`. Never in questions, negations ("I won't",
  "не скину"), maybes, reported speech ("he will send": only I/we count) or lines signed "Claude:".
- Book(path): the rows {id, t, due, what, phrase, chat, person, app, done, lang}; the same what in the same chat
  within 2 days is kept once; at most 200 open rows.
- offer(row, data_dir): a saved link (snippets.json / replacements.json) or a recent clipboard link or file path
  that shares a word with `what`, else a follow-up line in the promise's language.

Local only: nothing here leaves the Mac.
"""
import json
import re
import threading
import time
import uuid
from datetime import datetime, timedelta
from pathlib import Path

TEST = "⟦drafter-test⟧"
DEDUPE = 2 * 86400
MAX_OPEN = 200
SOON = 12 * 3600         # /promises/due: due within this many seconds (or overdue) counts as due
SETTLE = 30 * 60         # ... and only once it is this old (the box empties right after the user sends the promise)
CLIP_ROWS = 500

SIGNED = re.compile(r"^\s*(claude|клод)\s*:", re.I)

# ---- the vocabulary ----------------------------------------------------------------------------------------------

EN_SUBJ = r"(?:\bi\s*['’]?ll|\bi\s+will|\bi\s*['’]?m\s+(?:going\s+to|gonna)|\bi\s+am\s+going\s+to|\bwe\s*['’]?ll|\bwe\s+will|^\s*will|\blet\s+me)"
EN_ADV = r"(?:\s+(?:also|just|quickly|definitely|surely|then|still|try\s+to|be\s+sure\s+to|make\s+sure\s+to|probably))*"
EN_VERBS = ("get back", "follow up", "circle back", "send", "share", "forward", "email", "mail", "write", "prepare",
            "finish", "update", "ping", "drop", "post", "fix", "sign", "pay", "transfer", "reply", "confirm", "upload",
            "check", "look", "review", "call", "text", "book", "schedule", "deliver", "bring", "draft", "submit")
EN_RE = re.compile(EN_SUBJ + EN_ADV + r"\s+(" + "|".join(v.replace(" ", r"\s+") for v in EN_VERBS) + r")\b(.*)$", re.I)
EN_NEG = re.compile(r"\b(won['’]?t|will\s+not|wouldn['’]?t|can['’]?t|cannot|not|never|don['’]?t|doesn['’]?t|maybe|might|perhaps|if\s+i\s+can)\b", re.I)

UK_VERBS = ("скину", "скинемо", "закину", "кину", "надішлю", "надішлемо", "вишлю", "пришлю", "відправлю", "відправимо",
            "перешлю", "поділюсь", "поділюся", "напишу", "передзвоню", "подзвоню", "наберу", "гляну", "подивлюсь",
            "подивлюся", "перевірю", "зроблю", "підготую", "допишу", "дам знати", "повернусь", "повернуся",
            "відповім", "підпишу", "оплачу", "оновлю", "сформую", "доповім", "покажу", "занесу", "привезу", "передам")
LETTER = r"[^\W\d_]"
UK_RE = re.compile(r"(?<!" + LETTER + r")(" + "|".join(v.replace(" ", r"\s+") for v in UK_VERBS) + r")(?!" + LETTER + r")(.*)$", re.I)
UK_NEG = re.compile(r"(?<!" + LETTER + r")(не|ні|ніколи|може|можливо|мабуть|навряд|якщо\s+встигну)(?!" + LETTER + r")", re.I)
UK_QUESTION_START = re.compile(r"^\s*(чи|а\s+чи|може|можеш|можете)(?!" + LETTER + r")", re.I)

# what follows the verb up to here is the object; these words end it
EN_STOP = {"today", "tonight", "tomorrow", "later", "soon", "asap", "now", "next", "this", "in", "by", "on", "at", "after",
           "before", "when", "once", "until", "till", "and", "but", "so", "as", "for", "to", "over", "first", "right",
           "shortly", "then", "within", "via", "from", "with", "back", "this", "end", "eod", "monday", "tuesday",
           "wednesday", "thursday", "friday", "saturday", "sunday"}
EN_DROP = {"you", "u", "it", "that", "this", "them", "these", "those", "him", "her", "us", "everyone", "everybody", "all",
           "yall", "y'all", "guys", "over", "out", "up", "along", "across", "through"}
UK_STOP = {"сьогодні", "завтра", "післязавтра", "ввечері", "увечері", "вранці", "зранку", "вдень", "пізніше", "потім",
           "зараз", "одразу", "скоро", "через", "до", "в", "у", "на", "о", "після", "по", "наступного", "наступному",
           "цього", "цієї", "і", "й", "та", "а", "але", "як", "коли", "щойно", "за", "для", "з", "із", "зі", "вже",
           "понеділок", "вівторок", "середу", "четвер", "пʼятницю", "п'ятницю", "суботу", "неділю", "тижня",
           "тижні", "годину", "хвилину"}
UK_DROP = {"тобі", "вам", "тебе", "вас", "це", "його", "її", "їх", "все", "усе", "всім", "тобi", "тоді", "ще", "теж",
           "також", "швидко", "обовʼязково", "обов'язково", "сам", "сама"}

EN_DAYS = ["monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday"]
UK_DAYS = [("понеділ",), ("вівтор",), ("серед",), ("четвер",), ("пʼятниц", "п'ятниц", "п’ятниц"), ("субот",), ("неділ",)]


def lang_of(text):
    return "uk" if re.search(r"[а-яіїєґ]", text or "", re.I) else "en"


def _norm(s):
    return s.replace("’", "'").replace("`", "'")


def _at(day, hour):
    return day.replace(hour=hour, minute=0, second=0, microsecond=0)


def due_from(text, now):
    """Epoch seconds for the first time word in `text` (lower case), else now + 24 h."""
    t = " " + _norm(text.lower()) + " "
    base = datetime.fromtimestamp(now)
    later = lambda secs: now + secs
    m = re.search(r"\b(?:in|within)\s+(\d{1,3})\s*(hours?|hrs?|h|days?|d|minutes?|mins?)\b", t)
    if m:
        n, u = int(m.group(1)), m.group(2)
        return later(n * (86400 if u.startswith("d") else 60 if u.startswith("m") else 3600))
    m = re.search(r"через\s+(\d{1,3})\s*(годин\w*|год|днів|дні|день|хвилин\w*|хв)", t)
    if m:
        n, u = int(m.group(1)), m.group(2)
        return later(n * (86400 if u.startswith("д") else 60 if u.startswith("хв") else 3600))
    if re.search(r"\b(?:in|within)\s+an?\s+hour\b|через\s+годину", t): return later(3600)
    if re.search(r"\b(?:asap|right\s+away|right\s+now|in\s+a\s+(?:minute|sec|second|moment))\b|(?<![^\W\d_])(?:зараз|одразу|за\s+хвилину)(?![^\W\d_])", t):
        return later(3600)
    if re.search(r"\b(?:next\s+week)\b|наступного\s+тижня|на\s+наступному\s+тижні", t):
        d = base + timedelta(days=7 - base.weekday())
        return _at(d, 10).timestamp()
    if re.search(r"(?<![^\W\d_])післязавтра(?![^\W\d_])|\bday\s+after\s+tomorrow\b", t):
        return _at(base + timedelta(days=2), 10).timestamp()
    if re.search(r"\btomorrow\b|(?<![^\W\d_])завтра(?![^\W\d_])", t):
        return _at(base + timedelta(days=1), 10).timestamp()
    for i, w in enumerate(EN_DAYS):
        if re.search(r"\b" + w + r"\b", t): return _weekday(base, i)
    for i, stems in enumerate(UK_DAYS):
        if any(re.search(r"(?<![^\W\d_])" + s, t) for s in stems): return _weekday(base, i)
    if re.search(r"\b(?:today|tonight|this\s+evening|later\s+today|eod|end\s+of\s+(?:the\s+)?day)\b|(?<![^\W\d_])(?:сьогодні|ввечері|увечері|до\s+вечора)(?![^\W\d_])", t):
        d = _at(base, 18).timestamp()
        return d if d > now else later(2 * 3600)
    return later(86400)


def _weekday(base, i):
    ahead = (i - base.weekday()) % 7 or 7
    return _at(base + timedelta(days=ahead), 10).timestamp()


def _object(rest, stop, drop, limit=4):
    """The object phrase at the start of `rest`: words until a stop word or punctuation, pronouns left out."""
    rest = re.split(r"[,.;:!?()\[\]\n—–]| - ", rest, maxsplit=1)[0]
    out = []
    for w in rest.split():
        lw = _norm(w.lower()).strip("\"'«»“”")
        if not lw: continue
        if lw in stop or re.fullmatch(r"\d+", lw): break
        if lw in drop and not out: continue
        if lw in drop: break
        out.append(w.strip("\"'«»“”"))
        if len(out) >= limit: break
    return " ".join(out)


def _clauses(line):
    """Sentences of a line, each with whether it was asked (ends with "?")."""
    for m in re.finditer(r"[^.!?\n;]+[.!?;]*", line):
        s = m.group(0).strip()
        if s: yield s.rstrip(".!;").strip(), s.endswith("?")


def detect(text, now=None):
    """-> [{what, due, phrase, lang}] for promises in a line the user sent."""
    now = time.time() if now is None else now
    if not text or TEST in text or SIGNED.match(text): return []
    out = []
    for s, asked in _clauses(text):
        if asked: continue
        hit = _english(s) or _ukrainian(s)
        if not hit: continue
        what, phrase, lang = hit
        out.append({"what": what, "due": round(due_from(s, now)), "phrase": phrase[:160], "lang": lang})
    return out


def _english(s):
    m = EN_RE.search(s)
    if not m or lang_of(s[:m.start(1)]) == "uk": return None
    if EN_NEG.search(s[:m.start(1)]): return None
    if re.search(r"\b(he|she|they|someone|somebody)\b[^.]*$", s[:m.start()].lower()) and not re.match(r"\s*(i|we)\b", s[m.start():].lower()):
        return None
    verb = re.sub(r"\s+", " ", m.group(1).lower())
    what = _object(m.group(2), EN_STOP, EN_DROP)
    if what.lower() in ("a", "an", "the", "my", "our", "your"): what = ""
    if not what: what = {"get back": "getting back to you", "follow up": "the follow-up", "circle back": "getting back to you",
                         "call": "the call", "check": "the check", "look": "a look", "review": "the review"}.get(verb, "")
    return what, s.strip(), "en"


def _ukrainian(s):
    m = UK_RE.search(s)
    if not m: return None
    head = s[:m.start(1)]
    if UK_NEG.search(head[-24:]) or UK_QUESTION_START.search(s): return None
    # reported speech: "він каже, що скину" is rare; a third person subject right before the verb is not the user's promise
    if re.search(r"(?<![^\W\d_])(він|вона|вони|воно)\s*$", head.lower()): return None
    verb = re.sub(r"\s+", " ", m.group(1).lower())
    what = _object(m.group(2), UK_STOP, UK_DROP)
    if not what:
        what = {"передзвоню": "дзвінок", "подзвоню": "дзвінок", "наберу": "дзвінок", "дам знати": "відповідь",
                "відповім": "відповідь", "повернусь": "відповідь", "повернуся": "відповідь"}.get(verb, "")
    return what, s.strip(), "uk"


# ---- the store ---------------------------------------------------------------------------------------------------

def _key(what): return " ".join(re.findall(r"[^\W_]+", (what or "").casefold()))


class Book:
    def __init__(self, path):
        self.path, self.lock = Path(path), threading.Lock()

    def _load(self):
        try:
            d = json.loads(self.path.read_text())
            rows = d.get("rows") if isinstance(d, dict) else None
            return [r for r in rows or [] if isinstance(r, dict) and r.get("id")]
        except (OSError, ValueError):
            return []

    def _save(self, rows):
        self.path.parent.mkdir(parents=True, exist_ok=True)
        tmp = self.path.with_suffix(".tmp")
        tmp.write_text(json.dumps({"rows": rows}, ensure_ascii=False, indent=1)); tmp.replace(self.path)

    def add(self, found, chat=None, person=None, app="", now=None):
        """Keep promises found in one sent line. -> the new rows."""
        now = time.time() if now is None else now
        if not found: return []
        new = []
        with self.lock:
            rows = self._load()
            for p in found:
                if TEST in (p.get("phrase") or "") or TEST in (p.get("what") or ""): continue
                k = _key(p.get("what"))
                if any(not r.get("done") and r.get("chat") == chat and _key(r.get("what")) == k and now - r.get("t", 0) < DEDUPE
                       for r in rows + new):
                    continue
                new.append({"id": uuid.uuid4().hex[:12], "t": round(now), "due": int(p["due"]), "what": p.get("what") or "",
                            "phrase": p.get("phrase") or "", "chat": chat, "person": person, "app": app or "",
                            "done": None, "lang": p.get("lang") or lang_of(p.get("phrase"))})
            if not new: return []
            rows += new
            open_ = [r for r in rows if not r.get("done")]
            if len(open_) > MAX_OPEN:
                gone = {r["id"] for r in sorted(open_, key=lambda r: r.get("t", 0))[:len(open_) - MAX_OPEN]}
                rows = [r for r in rows if r["id"] not in gone]
            done_rows = [r for r in rows if r.get("done")]
            if len(done_rows) > MAX_OPEN:    # finished ones: the newest 200 stay for the record
                keep = {r["id"] for r in sorted(done_rows, key=lambda r: r.get("done") or 0)[-MAX_OPEN:]}
                rows = [r for r in rows if not r.get("done") or r["id"] in keep]
            self._save(rows)
        return new

    def open(self, now=None):
        now = time.time() if now is None else now
        rows = [dict(r, overdue=r.get("due", 0) < now) for r in self._load() if not r.get("done")]
        return sorted(rows, key=lambda r: r.get("t", 0), reverse=True)

    def done(self, pid, now=None):
        with self.lock:
            rows = self._load()
            hit = False
            for r in rows:
                if r["id"] == pid and not r.get("done"): r["done"] = round(time.time() if now is None else now); hit = True
            if hit: self._save(rows)
            return hit

    def drop(self, pid):
        with self.lock:
            rows = self._load()
            left = [r for r in rows if r["id"] != pid]
            if len(left) != len(rows): self._save(left)
            return len(left) != len(rows)

    def due(self, chat, now=None):
        """The open promise in this chat that has come due (or will within SOON), most overdue first; None."""
        now = time.time() if now is None else now
        if not chat: return None
        rows = [r for r in self._load() if not r.get("done") and r.get("chat") == chat
                and now - r.get("t", 0) >= SETTLE and r.get("due", 0) - now <= SOON]
        return min(rows, key=lambda r: r.get("due", 0)) if rows else None


# ---- the offer ---------------------------------------------------------------------------------------------------

STOPWORDS = {"the", "a", "an", "my", "our", "your", "this", "that", "and", "for", "you", "with", "about",
             "про", "для", "мій", "моє", "мою", "наш", "нашу", "твій"}


def words(s):
    return [w for w in re.findall(r"[^\W\d_]+", (s or "").casefold()) if len(w) >= 3 and w not in STOPWORDS]


def _shares(a, b):
    """Two word lists share a word: equal, or the same first 5 letters (case forms: договір / договору)."""
    for x in a:
        for y in b:
            if x == y or (len(x) >= 5 and len(y) >= 5 and x[:5] == y[:5]): return True
    return False


def _public(v):
    try:
        import lookup
        return lookup.public_url(v)
    except Exception:
        return v if re.match(r"https?://\S+$", v or "") else ""


def saved_links(data_dir):
    saved = {}
    for name in ("replacements.json", "snippets.json"):
        try:
            values = json.loads((Path(data_dir) / name).read_text())
            if isinstance(values, dict): saved.update(values)
        except (OSError, ValueError):
            pass
    return [(k, v) for k, v in saved.items() if isinstance(v, str) and _public(v.strip())]


def _tail(path, n):
    try:
        with open(path, "rb") as f:
            f.seek(0, 2); size = f.tell(); f.seek(max(0, size - 400_000))
            lines = f.read().decode("utf-8", "ignore").splitlines()[-n:]
    except OSError:
        return []
    out = []
    for l in lines:
        try: out.append(json.loads(l))
        except ValueError: pass
    return out


def clip_links(data_dir, n=CLIP_ROWS):
    """Recent copied links and file paths, newest first (only those; other copies are never read on)."""
    out = []
    for r in reversed(_tail(Path(data_dir) / "clipboard.jsonl", n)):
        t = r.get("text") if isinstance(r, dict) else None
        if not isinstance(t, str) or TEST in t: continue
        t = t.strip()
        if "\n" in t or len(t) > 500: continue
        if _public(t) or (r.get("kind") == "file" and t.startswith("/")) or re.match(r"^(/|~/)\S+$", t):
            out.append(t)
    return out


def offer(row, data_dir):
    """-> (text, kind): a link that shares a word with `what`, else the follow-up line."""
    w = words(row.get("what"))
    if w:
        for k, v in saved_links(data_dir):
            if _shares(w, words(k + " " + v)): return v.strip(), "link"
        for t in clip_links(data_dir):
            if _shares(w, words(t)): return t, "link"
    return followup(row), "followup"


def followup(row):
    what = (row.get("what") or "").strip()
    if (row.get("lang") or lang_of(row.get("phrase"))) == "uk":
        return f"Повертаюсь щодо {what} - " if what else "Повертаюсь, як обіцяв - "
    return f"Following up on {what} - " if what else "Following up, as promised - "

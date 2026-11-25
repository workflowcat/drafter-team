"""Who he is writing to, and in which keyboard (2026-11-16, Andrii: "pass the fact of my current language setting to
Claude", "build some proactive context from previous people there").

Two hints for the Claude helpers (pause, word-end early ask, proofread, translate, rework), one line or a short block
each, added to their message:
- the keyboard: the app sends the current macOS input source's language (`kb`: "uk", "en", ...). It says which
  language his next words likely are in; his mixed messages stay mixed.
- the person: in a Beeper chat the chat on screen is found from fingerprints of its lines (engine/people.py), its
  other person's display name is matched to the names reference (data/names.json, engine/names.py), and a block of at
  most BLOCK_MAX characters says who it is (company, projects, how he writes the name, case forms) and his last
  lines to them, and (engine/sources.py) up to 3 recent mail subjects and group chat titles with them. The block is fixed per chat for TTL seconds, so the message stays the same while he types.

Never: an entry that is hidden, marked private, or from a private scope (names.py and know.py leave those out; this
file checks again). The hints go only where the caller already sends to Claude, under the same switches.
"""
import json
import re
import threading
import time
from collections import Counter
from pathlib import Path

LANGS = {"uk": "Ukrainian", "en": "English", "ru": "Russian", "pl": "Polish", "de": "German", "fr": "French",
         "es": "Spanish", "it": "Italian", "pt": "Portuguese", "cs": "Czech", "tr": "Turkish", "he": "Hebrew",
         "ja": "Japanese", "zh": "Chinese", "ko": "Korean", "ka": "Georgian", "be": "Belarusian"}
BLOCK_MAX = 600
TTL = 3600
LINES = 4          # his last lines to them, at most
LINE_MAX = 120
FORMS = 6          # case forms shown
TOPIC_MAX = 70     # one mail subject or chat title (engine/sources.py), at most 3 of each
WORD = re.compile(r"[^\W\d_]+(?:['’ʼ-][^\W\d_]+)*", re.UNICODE)


def fold(s): return " ".join(str(s or "").casefold().replace("’", "'").replace("ʼ", "'").split())


def toks(s): return [w for w in WORD.findall(s or "") if len(w) >= 2]


# ---- keyboard ----------------------------------------------------------------------------------------------------

def kb_name(code):
    """'uk' / 'uk-UA' / 'en' -> 'Ukrainian' / 'English'; '' for nothing; an unknown code as it is (letters only)."""
    c = re.sub(r"[^a-z]", "", str(code or "").split("-")[0].split("_")[0].lower())[:3]
    return LANGS.get(c, c)


def kb_line(code, task="type"):
    """One line for a Claude message, or ''."""
    name = kb_name(code)
    if not name: return ""
    if task == "type":
        return f"Keyboard now: {name}. A hint for the language of his next words; mixed messages stay mixed.\n"
    if task == "proofread":
        return f"Keyboard now: {name}. A hint only: never change the language of his words; mixed stays mixed.\n"
    return f"Keyboard now: {name}. A hint only; the task decides the language.\n"


# ---- names reference ---------------------------------------------------------------------------------------------

def private(e):
    return (not isinstance(e, dict) or e.get("hidden") or e.get("private") or e.get("scope") == "private"
            or "private" in (e.get("sources") or []))


def labels(e): return [x for x in [e.get("uk"), e.get("latin")] + list(e.get("short") or []) if x]


def display(e): return e.get("uk") or e.get("latin") or ""


class Names:
    """data/names.json for matching: read again when the file changes; a broken file keeps the last good one."""

    def __init__(self, path):
        self.path, self.stamp = Path(path) if path else None, None
        self.by_id, self.full, self.parts = {}, {}, {}

    def load(self, store):
        es = [e for e in (store.get("entries") or []) if not private(e) and e.get("id")]
        self.by_id = {e["id"]: e for e in es}
        full, parts = {}, {}
        for e in es:
            for x in labels(e):
                full.setdefault(fold(x), set()).add(e["id"])
                t = tuple(sorted(fold(w) for w in toks(x)))
                if len(t) >= 2: parts.setdefault(t, set()).add(e["id"])
        self.full, self.parts = full, parts
        return self

    def reload(self):
        if self.path is None: return self
        try:
            st = self.path.stat(); stamp = (st.st_mtime_ns, st.st_size)
            if stamp != self.stamp:
                self.stamp = stamp
                self.load(json.loads(self.path.read_text()))
        except FileNotFoundError: self.by_id, self.full, self.parts, self.stamp = {}, {}, {}, None
        except (OSError, ValueError, TypeError, AttributeError): pass
        return self

    def match(self, name, kinds=("person",)):
        """The one entry `name` (a chat's display name or title) names, or None: the whole name equals a label, else
        the name's words hold all words of a two-or-more-word label. Shared by two entries -> None."""
        f = fold(name)
        if len(f) < 2: return None
        def pick(ids):
            hits = [i for i in ids if self.by_id[i].get("kind") in kinds]
            return self.by_id[hits[0]] if len(set(hits)) == 1 else None
        if f in self.full: return pick(self.full[f])
        words = {fold(w) for w in toks(name)}
        if len(words) < 2: return None
        ids = set()
        for t, hit in self.parts.items():
            if set(t) <= words: ids |= hit
        return pick(ids)


# ---- the block ---------------------------------------------------------------------------------------------------

def spoken(e, mine):
    """How he writes the name: the name words he used in his lines to them, most used first."""
    words = {}
    for x in labels(e) + list(e.get("forms") or []):
        for w in toks(x):
            if w[:1].isupper(): words.setdefault(w, w)
    seen = Counter()
    for line in mine:
        for w in toks(line):
            if w in words: seen[w] += 1
    return [w for w, _ in seen.most_common(3)]


def card(e, by_id, mine, title="", limit=BLOCK_MAX, topics=None):
    """The block for a matched entry: who, linked companies and projects, name forms, his last lines. <= limit chars."""
    kind = e.get("kind", "person")
    head = f"Chat with: {display(e)}" + (f" ({e['latin']})" if e.get("uk") and e.get("latin") and kind == "person" else "")
    if kind != "person": head = f"Group chat{(' ' + title) if title else ''}: about {display(e)} ({kind})"
    out = [head]
    linked = [by_id[i] for i in (e.get("links") or []) if i in by_id and not private(by_id[i])]
    linked.sort(key=lambda x: -(x.get("weight") or 0))
    comp = [display(x) for x in linked if x.get("kind") == "company"][:2]
    proj = [display(x) for x in linked if x.get("kind") == "project"][:3]
    if comp: out.append("Company: " + ", ".join(comp))
    if proj: out.append("Projects: " + ", ".join(proj))
    used = spoken(e, mine)
    if used: out.append("He calls them: " + ", ".join(used))
    if kind == "person":
        forms = [f for f in (e.get("forms") or []) if f not in used][:FORMS]
        if forms: out.append("Name forms: " + ", ".join(forms))
    if topics:
        if topics.get("mail"): out.append("Recent mail with them: " + "; ".join(t[:TOPIC_MAX] for t in topics["mail"]))
        if topics.get("chats"): out.append("Recent group chats with them: " + "; ".join(t[:TOPIC_MAX] for t in topics["chats"]))
    text = "\n".join(out)
    lines = [" ".join(t.split())[:LINE_MAX] for t in mine[-LINES:] if t.strip()]
    if lines:
        head = "\nHis last lines to them (oldest first):"
        room = limit - len(text) - len(head)
        keep = []
        for l in reversed(lines):
            if room - len(l) - 3 < 0: break
            keep.insert(0, "- " + l); room -= len(l) + 3
        if keep: text += head + "\n" + "\n".join(keep)
    return text[:limit]


LINK = re.compile(r"https?://[^\s<>\"'«»]+")


def last_link(mine):
    """The last link in his lines to them, without a closing dot or bracket; "" when none."""
    for line in reversed(mine or []):
        hits = LINK.findall(line or "")
        if hits: return hits[-1].rstrip(".,;:!?)]")
    return ""


def fields_for(e, by_id, mine):
    """{name, first name, company, last link to them} for a person entry: the name as written, the first name as he
    calls them (his own lines decide), the heaviest linked company."""
    name = display(e)
    used = spoken(e, mine)
    first = used[0] if used else (toks(name)[0] if toks(name) else "")
    linked = sorted((by_id[i] for i in (e.get("links") or []) if i in by_id and not private(by_id[i])),
                    key=lambda x: -(x.get("weight") or 0))
    comp = next((display(x) for x in linked if x.get("kind") == "company"), "")
    return {"name": name, "first name": first, "company": comp, "last link to them": last_link(mine)}


THEIR_LINE = re.compile(r"^([A-ZА-ЯІЇЄҐ][\w'’.-]{1,20}(?: [A-ZА-ЯІЇЄҐ][\w'’.-]{1,20})?): ")


def screen_name(context):
    """The name on their last line on screen ("Олег Петренко: ..."), never his own (Я) or the app's marks."""
    for line in reversed([l.strip() for l in (context or "").splitlines() if l.strip()][-30:]):
        m = THEIR_LINE.match(line)
        if m and m.group(1) not in ("Я", "Вони", "Асистент", "Me", "You"): return m.group(1)
    return ""


class Who:
    """The hints for a request: keyboard line and, in a matched Beeper chat, the person block (fixed per chat)."""

    def __init__(self, people, names_path, ttl=TTL, topics=None):
        self.people, self.names, self.ttl, self.topics = people, Names(names_path), ttl, topics
        self.cache, self.lock = {}, threading.Lock()   # chat -> (when, block)
        self.stats = {"asked": 0, "chats": 0, "matched": 0, "chars": 0}

    def _chat(self, app, context):
        if not (app or "").lower().startswith("beeper") or not (context or "").strip() or self.people is None: return None
        try: return self.people.chat_for(context)
        except Exception: return None

    def _entry(self, chat):
        """-> the block for a chat id ("" when no one matched); cached for ttl."""
        with self.lock:
            c = self.cache.get(chat)
            if c and time.time() - c[0] < self.ttl: return c[1]
        info = self.people.info(chat) or {}
        names = self.names.reload()
        e = self._match(info, names)
        tp = None
        if e is not None and e.get("kind", "person") == "person" and self.topics is not None:
            try: tp = self.topics.topics(e.get("emails") or [], labels(e) + list(info.get("who") or []))
            except Exception as ex: print("whom: topics:", type(ex).__name__, flush=True)
        block = card(e, names.by_id, info.get("mine") or [], info.get("title", ""), topics=tp) if e is not None else ""
        with self.lock: self.cache[chat] = (time.time(), block)
        return block

    @staticmethod
    def _match(info, names):
        """The names entry a chat is with (a person; a group's project or company by its title), or None."""
        e = None
        if not info.get("group"):
            for n in info.get("who") or []:
                e = names.match(n)
                if e: break
        if e is None and info.get("title"):
            e = names.match(info["title"], ("person",) if not info.get("group") else ("project", "company"))
        return e

    def fields(self, app, context):
        """Smart snippet fields (17 November 2026) for the chat on screen: {name, first name, company, last link to them},
        each "" when unknown. A matched person from the names reference first; else the name the screen's last line from
        them carries ("Олег: ..."). Private entries are never in `names` (Names.load). Local only."""
        out = {"name": "", "first name": "", "company": "", "last link to them": ""}
        chat = self._chat(app, context)
        info = (self.people.info(chat) or {}) if chat else {}
        e = self._match(info, self.names.reload()) if info else None
        if e is not None and e.get("kind", "person") == "person":
            out.update(fields_for(e, self.names.by_id, info.get("mine") or []))
        elif info.get("mine"):
            out["last link to them"] = last_link(info["mine"])
        if not out["name"]:
            n = screen_name(context)
            if n: out["name"], out["first name"] = n, n.split()[0]
        return out

    def person(self, chat):
        """The names id of a one-to-one chat's person (engine/promises.py), or None; private entries never."""
        if not chat or self.people is None: return None
        try:
            info = self.people.info(chat) or {}
            if info.get("group"): return None
            e = self._match(info, self.names.reload())
            return e["id"] if e is not None and not private(e) and e.get("kind") == "person" else None
        except Exception as ex: print("whom:", ex, flush=True); return None

    def display(self, pid):
        """A names id -> its display name ("" when unknown or private)."""
        e = self.names.reload().by_id.get(pid) if pid else None
        return display(e) if e is not None and not private(e) else ""

    def block(self, app, context):
        chat = self._chat(app, context)
        if not chat: return ""
        try: return self._entry(chat)
        except Exception as ex: print("whom:", ex, flush=True); return ""

    def hint(self, req, task="type"):
        """Keyboard line plus the person block, for a Claude message; '' when there is neither."""
        req = req or {}
        b = self.block(str(req.get("app") or ""), str(req.get("context") or ""))
        self.stats["asked"] += 1
        if b: self.stats["matched"] += 1; self.stats["chars"] += len(b)
        line = kb_line(req.get("kb"), task)
        return line + (b + "\n" if b else "")

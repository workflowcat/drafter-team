"""Who the user is writing to, and in which keyboard (2026-11-16, the user: "pass the fact of my current language setting to
Claude").

The keyboard hint for the Claude helpers (pause, word-end early ask, proofread, translate, rework), one line added to
their message: the app sends the current macOS input source's language (`kb`: "uk", "en", ...). It says which language
the user's next words likely are in; the user's mixed messages stay mixed.

Smart snippet fields: the name on their last line on screen ("Олег: ..."), local only. Names in the names reference
(data/names.json) give a promise row's display name.

Never: an entry that is hidden, marked private, or from a private scope (names.py and know.py leave those out; this
file checks again). The hint goes only where the caller already sends to Claude, under the same switches.
"""
import json
import re
from pathlib import Path

LANGS = {"uk": "Ukrainian", "en": "English", "ru": "Russian", "pl": "Polish", "de": "German", "fr": "French",
         "es": "Spanish", "it": "Italian", "pt": "Portuguese", "cs": "Czech", "tr": "Turkish", "he": "Hebrew",
         "ja": "Japanese", "zh": "Chinese", "ko": "Korean", "ka": "Georgian", "be": "Belarusian"}
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


THEIR_LINE = re.compile(r"^([A-ZА-ЯІЇЄҐ][\w'’.-]{1,20}(?: [A-ZА-ЯІЇЄҐ][\w'’.-]{1,20})?): ")


def screen_name(context):
    """The name on their last line on screen ("Олег Петренко: ..."), never the user's own (Я) or the app's marks."""
    for line in reversed([l.strip() for l in (context or "").splitlines() if l.strip()][-30:]):
        m = THEIR_LINE.match(line)
        if m and m.group(1) not in ("Я", "Вони", "Асистент", "Me", "You"): return m.group(1)
    return ""


class Who:
    """The keyboard hint for a request and the smart fields from the screen."""

    def __init__(self, names_path):
        self.names = Names(names_path)
        self.stats = {"asked": 0}

    def fields(self, app, context):
        """Smart snippet fields (17 November 2026) for the chat on screen: {name, first name, company, last link to them},
        each "" when unknown: the name the screen's last line from them carries ("Олег: ..."). Local only."""
        out = {"name": "", "first name": "", "company": "", "last link to them": ""}
        n = screen_name(context)
        if n: out["name"], out["first name"] = n, n.split()[0]
        return out

    def display(self, pid):
        """A names id -> its display name ("" when unknown or private)."""
        e = self.names.reload().by_id.get(pid) if pid else None
        return display(e) if e is not None and not private(e) else ""

    def hint(self, req, task="type"):
        """The keyboard line for a Claude message; '' when there is none."""
        req = req or {}
        self.stats["asked"] += 1
        return kb_line(req.get("kb"), task)

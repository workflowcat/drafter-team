"""Instant replies (17 November 2026; Superhuman Instant Reply, Gmail Smart Reply): in an empty chat or mail box where
the last message is theirs, three one-line replies in three shapes - yes, no or decline, later or a question back - in
the language of that message and the user's style, from the local model. ⌥1-3 picks one, Tab takes the first; nothing is
sent.

Pure text here: the prompt, the parse, whose turn it is. engine/server.py tokenises and runs the model. No data/ reads.
"""
import re

import idle_prompt as idle

SHAPES = ("yes", "no", "later")
LABELS = {"uk": {"yes": "так", "no": "ні", "later": "пізніше / питання"},
          "en": {"yes": "yes", "no": "no", "later": "later / ask"}}
LINE_MAX = 160
CYR = re.compile(r"[а-яіїєґё]", re.I)
LAT = re.compile(r"[a-z]", re.I)
SHAPE_OF = {"y": "yes", "1": "yes", "yes": "yes", "так": "yes", "n": "no", "2": "no", "no": "no", "ні": "no",
            "l": "later", "3": "later", "later": "later", "пізніше": "later"}


def lang(text):
    """'uk' when the text has more Cyrillic letters than Latin ones, else 'en' (Russian lines get Ukrainian labels:
    the labels are the user's, the reply follows the message's own language)."""
    c, l = len(CYR.findall(text or "")), len(LAT.findall(text or ""))
    return "uk" if c > l else "en"


def last_theirs(context):
    """The last message on screen is theirs (not the user's, not an assistant's): (True, its text), else (False, "")."""
    ts = idle.chat_turns(context or "")
    if not ts: return False, ""
    who, name, text = ts[-1]
    theirs = who == "them" and name != "Асистент" and bool(text.strip())
    return theirs, text if theirs else ""


def messages(context, app="", who="", mine="", name=""):
    """Chat-template messages: one user turn asking for the three replies as three tagged lines."""
    ts = idle.chat_turns(context)
    me = name or "the user"
    last = ts[-1][2] if ts else ""
    u = (f"A chat in {app}. " if app else "") + f"Write three short replies {me} could send to the last message ({idle.ME} = {me}).\n"
    if who.strip(): u += "Who the chat is with: " + " ".join(who.split())[:600] + "\n"
    if mine.strip(): u += f"{me}'s earlier messages in this chat (how he writes):\n" + mine.strip() + "\n"
    if ts: u += "\nThe chat, oldest first:\n" + "\n".join(f"{nm}: {x}" for _, nm, x in ts) + "\n"
    u += ("\nThree replies, each one short line in the language of the last message, his casual words, no quotes, no name in front:\n"
          "Y: agree / say yes\nN: decline / say no, politely\nL: not now - later, or one short question back\n"
          "Answer with exactly the three lines Y:, N:, L: and nothing else.")
    if last: u += f"\nThe last message: {last}"
    return [{"role": "user", "content": u}]


def clean(t):
    t = " ".join((t or "").split()).strip().strip('"«»“”').strip()
    t = re.sub(r"^(?:" + re.escape(idle.ME) + r"|Me|Я)\s*:\s*", "", t)
    return t[:LINE_MAX].rstrip()


def parse(raw, language="en"):
    """[{label, text, shape}] in the order yes, no, later; a missing shape is left out, duplicates go."""
    found = {}
    for line in (raw or "").splitlines():
        line = line.strip()
        if not line: continue
        m = re.match(r"^\s*(?:[-*•]\s*)?(Y|N|L|1|2|3|yes|no|later|так|ні|пізніше)\s*[:).\]-]\s*(.*)$", line, re.I)
        if not m: continue
        shape = SHAPE_OF.get(m.group(1).lower())
        text = clean(m.group(2))
        if shape and text and shape not in found and text.lower() not in {v.lower() for v in found.values()}:
            found[shape] = text
    labels = LABELS.get(language, LABELS["en"])
    return [{"label": labels[s], "text": found[s], "shape": s} for s in SHAPES if s in found]

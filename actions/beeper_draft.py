"""Beeper draft, never sent: "напиши Саві що буду о 15", "напиши Мілі шо скинув драфт", "text Mila that I'm late".

Placed through Aleph (`beeper chats draft`, with undo). The earlier /v1/focus way also wrote the draft into the chat
that was open before (2026-10-18)."""
import json, os, re, subprocess
from _ask import fields
import _aleph

ID = "beeper.draft"
NEEDS = ("aleph", "beeper")   # engine/integrations.py: the chip is offered only when all of these are on and answer
TRIGGER = re.compile(r"(?i)(?:^|[\s,.])(напиши|напишіть|відпиши|скажи|text|message)\s+[\w'’-]+\s*,?\s*(що|шо|що\s+я|that|:)\s+\S")

LAT = dict(zip("абвгґдезиіїйклмнопрстуфхцчшщьюяєжʼ'", ["a","b","v","h","g","d","e","z","y","i","i","i","k","l","m","n","o","p","r","s","t","u","f","kh","ts","ch","sh","shch","","yu","ya","ye","zh","",""]))


def latin(s):
    return "".join(LAT.get(ch, ch) for ch in s.lower())


def chats(who):
    out = subprocess.run(["beeper", "chats", "search", who, "--json", "-q", "--read-only", "--limit", "10"],
                         capture_output=True, text=True, timeout=8, env={**os.environ, "BEEPER_READONLY": "1"}).stdout
    try: return json.loads(out)["data"]
    except Exception: return []


def extract(line, ask):
    f = fields(ask, "З команди написати комусь повідомлення витягни, кому (ім'я в називному відмінку) і сам текст повідомлення "
                    "від першої особи, так, як його треба надіслати, без слів «напиши X що».", line, ["who", "text"])
    return make(f.get("who", ""), f.get("text", ""))


def make(who, text):
    """The chip for a draft to `who` (the command line gives who and text directly)."""
    if not who or not text: return None
    found = chats(who)
    if latin(who) != who.lower():
        ids = {c.get("id") for c in found}
        found += [c for c in chats(latin(who)) if c.get("id") not in ids]
    # a direct chat whose title carries the name; never a group that only mentions it
    stems = {who.lower()[: max(3, len(who) - 2)], latin(who)[: max(3, len(latin(who)) - 2)]}
    # the name starts a word of the title ("Mila N."), never sits inside one ("Rolan")
    named = [c for c in found if any(re.search(r"(?<!\w)" + re.escape(st), (c.get("title") or "").lower()) for st in stems)]
    single = [c for c in named if c.get("type") == "single"]
    if not (single or named): return {"chip": f"Chat «{who}» was not found in Beeper", "run": {"kind": "none"}, "fields": {}}
    c = (single or named)[0]
    title = c.get("title") or who
    return {"chip": f"Draft in Beeper → {title}: «{text}» (not sent)",
            "run": {"kind": "python"}, "fields": {"chatID": c.get("id"), "title": title, "text": text}}


def run(fields):
    return _aleph.do({"type": "beeper_draft", "item": "chat:" + fields["chatID"], "text": fields["text"]}) + f": {fields['title']}"

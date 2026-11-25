"""The idle ghost's prompt for an empty chat box (round "earlier", step 7b, 2026-11-16).

Step 7 asked the local model with the typing prompt (the screen text, then his empty line): in 14 of 18 empty boxes it
wrote nothing a ghost could show, and the first word was right once in 24 made-up chats. An empty box needs the shape
the nextMessage path gives Claude: the chat as turns (theirs and his), who the chat is with, his earlier lines there,
then his turn. Two local forms (bench/idle.py measures them):
  turns  plain continuation: the typing head (how he writes), then the chat as "Name: text" lines and "Я: " last, so
         the model writes his line and stops at the line end
  chat   the model's chat template: one user turn asks for his next message, the answer is his message
  screen the typing prompt as in step 7 (kept for the comparison)
After a finished sentence the box is not empty: the typing prompt stays (plain continuation).
Pure text here; engine/server.py tokenises. No data/ reads.
"""
import re

import prompt as P

FORMS = ("screen", "turns", "chat")
FORM = "chat"             # set from bench/idle.py's numbers (docs/rounds/2026-11-16-earlier.md, step 7b)
TURNS = 8                 # the chat's last turns shown
TURN_MAX = 300            # characters per turn
ME, THEM = "Я", "Вони"
NAMED = re.compile(r"^([A-ZА-ЯІЇЄҐ][\w'’.-]{1,20}): ")


def chat_turns(context, n=TURNS):
    """[(who, name, text)] oldest first, the last n: who is "me" or "them". The app marks lines "Я: " / "Вони: " /
    "Асистент: "; a screen text with only names ("Олег: ...") counts each named line as theirs unless the name is Я."""
    ts = P.turns(context)
    if not any(w for w, _ in ts):
        # no app marks: name marks, or none at all
        out = []
        for _, line in ts:
            m = NAMED.match(line)
            if m: out.append(["me" if m.group(1) == ME else "them", m.group(1), line[m.end():].strip()])
            elif out: out[-1][2] += " " + line
            else: out.append(["them", THEM, line])
    else:
        out = [["me" if w == "me" else "them", ME if w == "me" else ("Асистент" if w == "ai" else THEM), t] for w, t in ts if w or t]
    return [(w, nm, " ".join(t.split())[:TURN_MAX]) for w, nm, t in out if t.strip()][-n:]


def turns_tail(context, app="", who="", mine=""):
    """The plain-continuation tail after the typing head: [app], who it is, his earlier lines, the chat, then "Я: "."""
    ts = chat_turns(context)
    t = f"[{app}]\n" if app else ""
    if who.strip(): t += "Хто це: " + " ".join(who.split())[:600] + "\n"
    if mine.strip(): t += "Мої раніші повідомлення в цьому чаті:\n" + mine.strip() + "\n"
    if ts: t += "Чат:\n" + "\n".join(f"{nm}: {x}" for _, nm, x in ts) + "\n"
    return t + f"{ME}: "


def chat_messages(context, app="", who="", mine="", name=""):
    """Chat-template messages: one user turn asking for his next message; the answer is the message itself."""
    ts = chat_turns(context)
    me = name or "the user"
    u = (f"A chat in {app}. " if app else "") + f"Write {me}'s next message in this chat ({ME} = {me}).\n"
    if who.strip(): u += "Who the chat is with: " + " ".join(who.split())[:600] + "\n"
    if mine.strip(): u += f"{me}'s earlier messages in this chat:\n" + mine.strip() + "\n"
    if ts: u += "\nThe chat, oldest first:\n" + "\n".join(f"{nm}: {x}" for _, nm, x in ts) + "\n"
    u += (f"\nReply with {me}'s next message only: short (one line), in the language of the chat, his casual words, "
          "no quotes, no name in front.")
    return [{"role": "user", "content": u}]


def form_for(req):
    f = str(req.get("idle_form") or FORM)
    return f if f in FORMS else FORM

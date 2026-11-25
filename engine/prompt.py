"""The prompt: a fixed head (how the user writes, their words, their messages) and a moving tail (where he types, what is typed)."""
import json, os, re, sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

ROOT = Path(__file__).resolve().parent.parent

import local
from writing_notes import normalize as normalize_notes


def rules():
    """How the user writes: `user.style_rules` in the local config (data/drafter.local.json), else a neutral line."""
    return local.style_rules()


def load_json(p, default):
    try: return json.loads(Path(p).read_text())
    except Exception: return default


def words():
    d = load_json(ROOT / "data" / "words.json", {})
    return [w["text"] if isinstance(w, dict) else w for w in d.get("words", [])]


def head(n_examples=12, n_words=40):
    style = load_json(ROOT / "data" / "style.json", {"examples": []})
    ex = style["examples"][:n_examples]
    w = words()[:n_words]
    parts = [rules()]
    if w: parts.append("Його слова й імена: " + ", ".join(w))
    parts.append("Його повідомлення:\n" + "\n###\n".join(ex))
    return "\n\n".join(parts) + "\n###\n"


# per-app voice (2026-10-20): how he writes where; the trained layer knows [Beeper] / [Claude] / [Voice Notes] already,
# this line adds the rest
STYLE = {"Beeper": "коротко, розмовно, як у чаті", "WhatsApp": "коротко, розмовно, як у чаті", "Telegram": "коротко, розмовно",
         "Slack": "коротко, по справі", "Mail": "повними реченнями, ввічливо, без води", "Outlook": "повними реченнями, ввічливо",
         "Claude": "чіткі інструкції для агента", "Notes": "нотатки для себе", "Obsidian": "нотатки для себе",
         "Google Docs": "повними реченнями", "Pages": "повними реченнями", "TextEdit": "повними реченнями"}


# Screen context as a conversation (2026-11-14, app/ScreenContext.swift): the app marks who wrote each message it read
# from the picture ("Я: " his, "Вони: " the other person, "Асистент: " an AI app's answer, one message per line; the
# bench replay sets mark the other side with a first name). The trained layer saw no screen text at all (bench/
# make_train.py: "[App]\n" + his line), so the default stays today's look until the context sweep measures the marks
# (bench/screen_context.py): CTX_FORM "plain" = the marks taken off, the last CTX_BUDGET characters.
#   plain   today's form: the app's marks removed, the last CTX_BUDGET characters (text without them: as before)
#   raw     exactly as it came (the bench's old baseline: replay sets keep their "Я:" / name marks)
#   tail    who said what kept, the tail picked by turns: the other side's last message whole, his last, then older
#   tail-plain  the same pick, marks taken off
CTX_FORM = os.environ.get("DRAFTER_CTX_FORM", "plain")
CTX_BUDGET = int(os.environ.get("DRAFTER_CTX_BUDGET", "1600"))
MARKS = {"Я": "me", "Вони": "them", "Асистент": "ai"}
APP_MARK = re.compile(r"^(Я|Вони|Асистент): ")
ANY_MARK = re.compile(r"^(Я|Вони|Асистент|[A-ZА-ЯІЇЄҐ][\w'’.-]{1,20}): ")


def turns(context):
    """[(who, text)] oldest first: who is "me", "them", "ai" or None (no mark: one turn per line). A line without a
    mark after a marked one continues it (a message the app could not split)."""
    out, marked = [], any(APP_MARK.match(l.strip()) for l in (context or "").splitlines())
    for line in (context or "").splitlines():
        line = line.strip()
        if not line: continue
        m = ANY_MARK.match(line) if marked else None
        if m:
            out.append([MARKS.get(m.group(1), "them"), line[m.end():].strip()])
        elif marked and out and out[-1][0] is not None:
            out[-1][1] += " " + line
        else:
            out.append([None, line])
    return [tuple(t) for t in out]


def pick_tail(ts, budget):
    """The turns the model reads, oldest first: the other side's last message whole when it fits (else its end), his
    own last message, then older ones from the newest back while `budget` characters last (app/ScreenContextRules.tail)."""
    if not ts or budget <= 0: return []
    size = lambda i: len(ts[i][1]) + 1 + (0 if ts[i][0] is None else 7)
    keep, used, out = set(), 0, list(ts)

    def take(i):
        nonlocal used
        if i in keep: return True
        if used + size(i) > budget: return False
        keep.add(i); used += size(i); return True

    other = next((i for i in range(len(ts) - 1, -1, -1) if ts[i][0] in ("them", "ai")), None)
    if other is not None and not take(other):
        out[other] = (ts[other][0], ts[other][1][-max(0, budget - 8):]); keep.add(other); used = budget
    mine = next((i for i in range(len(ts) - 1, -1, -1) if ts[i][0] == "me"), None)
    if mine is not None and (other is None or mine > other - 3): take(mine)
    for i in range(len(ts) - 1, -1, -1):
        if i not in keep and not take(i): break
    return [out[i] for i in sorted(keep)]


def render(ts, marks=True):
    names = {"me": "Я", "them": "Вони", "ai": "Асистент"}
    return "\n".join((f"{names[w]}: " if marks and w else "") + t for w, t in ts)


def screen_text(context, form=None, budget=None):
    """The screen text as the prompt shows it (see CTX_FORM)."""
    form, budget = form or CTX_FORM, CTX_BUDGET if budget is None else budget
    c = (context or "").strip()
    if not c or budget <= 0: return ""
    if form == "raw": return c[-budget:]
    if form in ("tail", "tail-plain"): return render(pick_tail(turns(c), budget), marks=form == "tail")
    lines = c.splitlines()
    # the app's marks come with "Вони: " or "Асистент: " beside "Я: "; a text with only "Я: " lines (the bench replay
    # sets, which name the other side) is left as it was
    if any(l.startswith(("Вони: ", "Асистент: ")) for l in lines): lines = [APP_MARK.sub("", l) for l in lines]
    return "\n".join(lines)[-budget:]


# Clipboard context (parity round, 2026-11-15): a copy from the last 2 minutes, sent by the app (Keys.requestBody,
# app/ClipContextRules.swift decides freshness and the sensitive checks; the engine never reads the clipboard). It goes
# after the cached head, in the part that stays put per screen, just above the screen text. clip_safe() is a second
# check here, so a key, card, IBAN or code never reaches the prompt even if the app missed it.
CLIP_CHARS = int(os.environ.get("DRAFTER_CLIP_CHARS", "300"))
CLIP_LABEL = "Скопійовано:"
SECRET = [re.compile(p) for p in (
    r"\b(sk|pk|rk)[-_](live|test|proj|ant)?[-_]?[A-Za-z0-9_-]{20,}", r"\b(ghp|gho|ghu|ghs|ghr)_[A-Za-z0-9]{30,}|\bgithub_pat_",
    r"\bxox[abprs]-[A-Za-z0-9-]{10,}|\bAKIA[0-9A-Z]{16}\b|\bAIza[0-9A-Za-z_-]{35}",
    r"(?i)\b(api[_ -]?key|secret|token|password|passwd|пароль)\s*[:=]\s*\S{6,}", r"-----BEGIN [A-Z ]*PRIVATE KEY-----",
    r"\beyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.", r"\b[A-Z]{2}\d{2}(?: ?[A-Z0-9]{4}){3,7}(?: ?[A-Z0-9]{1,4})?\b",   # IBAN
    r"^\s*(\d{6}|\d{3}[ -]\d{3}|\d{8})\s*$")]                                                          # a one-time code alone
CARD = re.compile(r"\b(?:\d[ -]?){12,18}\d\b")


def luhn(digits):
    d = [int(c) for c in digits if c.isdigit()]
    if not 13 <= len(d) <= 19: return False
    s = sum(x if i % 2 == 0 else (x * 2 - 9 if x * 2 > 9 else x * 2) for i, x in enumerate(reversed(d)))
    return s % 10 == 0


def entropic(word):
    """A long token mixing letters and digits (or case) with many distinct characters: a key, a hash, a password."""
    if len(word) < 20 or re.fullmatch(r"https?://\S+", word): return False
    kinds = sum(bool(re.search(p, word)) for p in (r"[a-z]", r"[A-Z]", r"\d", r"[^A-Za-z0-9]"))
    return kinds >= 3 or (kinds == 2 and bool(re.search(r"\d", word)) and len(set(word)) >= 14)


def clip_safe(text):
    """True when a copied text may go into the prompt: no key, token, card, IBAN, one-time code or password-like word."""
    t = (text or "").strip()
    if not t: return False
    if any(r.search(t) for r in SECRET): return False
    if any(luhn(m.group(0)) for m in CARD.finditer(t)): return False
    return not any(entropic(w.strip(".,;:()[]{}<>\"'")) for w in t.split())


def clip_text(clip, before="", budget=None):
    """The copy as the prompt shows it: one line, the first `budget` characters (the start of a copy says what it is),
    nothing when it is unsafe or already in the text he types (he pasted it)."""
    budget = CLIP_CHARS if budget is None else budget
    c = re.sub(r"\s+", " ", clip or "").strip()
    if not c or budget <= 0 or not clip_safe(c): return ""
    if c[:60] in re.sub(r"\s+", " ", before or ""): return ""
    return c if len(c) <= budget else c[:budget].rsplit(" ", 1)[0] + "…"


# Writing instructions (parity round): one global and one per app, his own words (Settings > Typing). The model is a
# completion model with his layer, not a chat model, so an instruction is shown as part of the place line: after the
# app's own style in brackets, which the prompt already had (STYLE). NOTES_FORM "line" puts it on its own line above,
# "near" in brackets right above his line.
NOTES_CHARS = 300
NOTES_FORM = os.environ.get("DRAFTER_NOTES_FORM", "paren")


def notes_text(notes):
    return normalize_notes(notes, NOTES_CHARS)


# Mid-line (fill in the middle, 2026-11-15, docs/rounds/2026-11-15-fim.md): the app sends the rest of the caret's line
# (and up to 2 lines after it) when the caret sits mid-line (setting midLine). The live model is a plain completion
# model with no FIM tokens. MID_FORM "after" shows the text after the caret as one line right above his text, after
# the screen text (it stays put while he types in the gap, so the cache keeps it). Default "none" (plain continuation,
# engine/fim.py ends it): on 2,065 mid-line keys "after" filled the gap no better (exact 25.2 vs 25.7 per 1,000 keys,
# first word 67.2 vs 68.0 % of shown) and cost 17 ms p50 (bench/fim.py). With no `after`, the prompt is as before.
MID_FORM = os.environ.get("DRAFTER_MID_FORM", "none")
MID_LABEL = "Після курсора:"
MID_CHARS = 400


def mid_text(after):
    """The text after the caret as the prompt shows it: one line (line breaks as " / "), at most MID_CHARS."""
    a = (after or "")[:MID_CHARS].rstrip()
    return re.sub(r"[ \t]*\n+[ \t]*", " / ", a).rstrip(" /")


def tail(before, app="", title="", context="", mine="", clip="", notes="", after=""):
    where = " · ".join(x for x in (app, title) if x)
    style = next((v for k, v in STYLE.items() if k.lower() in (app or "").lower()), "")
    notes = notes_text(notes)
    t = ""
    if notes and NOTES_FORM == "line": t += f"Нотатка: {notes}\n"
    elif notes and NOTES_FORM == "paren": style = f"{style}; {notes}" if style else notes
    t += (f"[{where}]" + (f" ({style})" if style else "") + "\n") if where else (f"({notes})\n" if notes and NOTES_FORM == "paren" else "")
    if mine:
        # his own older messages in this chat (people.People.earlier), above the screen and fixed per chat, so the cache keeps it
        t += "Мої раніші повідомлення в цьому чаті:\n" + mine.strip() + "\n"
    clip = clip_text(clip, before)
    if clip: t += f"{CLIP_LABEL} {clip}\n"
    if context:
        # the text on screen above the field (the message he answers); it changes rarely, so it stays in the cache
        # (the engine trims it to a window whose start stays put, up to 1.5 x 1,000 characters: server.window)
        shown = screen_text(context)
        if shown: t += "На екрані перед цим:\n" + shown + "\n---\n"
    # "near": the instruction right above his line, after the screen text (the closest place to what it steers)
    if notes and NOTES_FORM == "near": t += f"({notes})\n"
    after = mid_text(after) if MID_FORM == "after" else ""
    if after.strip(): t += f"{MID_LABEL} {after.lstrip()}\n"
    return t + before


class Builder:
    """Same head for every request, so the prompt cache keeps it warm."""
    def __init__(self, model, fmt="raw"):
        self.m, self.fmt = model, fmt
        self.refresh()

    def refresh(self):
        self.head = head()
        self.head_ids = self.m.bos() + self.m.encode(self._wrap_head(self.head))

    def _wrap_head(self, h):
        if self.fmt == "bare": return "\n"   # one token, so the engine still warms up on its own thread
        if self.fmt == "raw": return h
        # chat: the fixed part (how he writes, his messages) opens the user turn; chat_tail adds the rest
        return "<|im_start|>user\n" + h.rstrip("#\n") + "\n\n"

    def chat_tail(self, before, app="", title="", context=""):
        """Chat shape (Qwen template): the conversation goes in the user turn, his text starts the answer."""
        where = " · ".join(x for x in (app, title) if x)
        u = (f"Де він пише: {where}\n" if where else "") + (f"На екрані перед цим:\n{screen_text(context)}\n" if screen_text(context) else "")
        u += "Продовж його текст кількома словами, тією ж мовою."
        return u + "<|im_end|>\n<|im_start|>assistant\n" + before

    def ids(self, before, app="", title="", context="", mine="", clip="", notes="", after=""):
        """(prompt ids, heal): the half-typed word and trailing spaces are cut off and re-spelled by the model,
        so the prompt never ends on a token it would not have chosen itself."""
        ids, heal, _ = self.ids_stable(before, app, title, context, mine, clip, notes, after)
        return ids, heal

    def ids_stable(self, before, app="", title="", context="", mine="", clip="", notes="", after=""):
        """(prompt ids, heal, stable): as ids(), plus where the part that stays put while he types ends ([app ·
        title], his chat lines, the screen text): ids[:stable] are the same at every key of this screen, so a cache
        that cannot be cut back (Qwen3.5, Gemma 4) keeps a copy there and reads only the typed line at each key
        (big-model round, 2026-11-15). The ids are exactly those of ids(): `stable` is the shared start of the tail
        tokenised alone and the stable text tokenised alone, so a token that joins the two parts is never split."""
        if self.fmt in ("raw", "bare"):
            mid = {"after": after} if after else {}    # only when set: the bench's patched tails keep their arguments
            t, s = tail(before, app, title, context, mine, clip, notes, **mid), tail("", app, title, context, mine, clip, notes, **mid)
        else:
            t, s = self.chat_tail(before, app, title, context), ""
        heal = re.search(r"[ \t]*[\w'’-]*$", t).group(0)
        if len(heal) > 24: heal = ""
        if heal == t: heal = ""            # nothing left to stand on
        # the tail is tokenised on its own so the head ids never shift
        body = self.m.encode(t[: len(t) - len(heal)])
        k = 0
        if s and t.startswith(s):
            for a, b in zip(self.m.encode(s), body):
                if a != b: break
                k += 1
        ids = self.head_ids + body
        # one token short of the shared start, so even an empty line has a token to feed and the point is the same at
        # every key of the screen (the first letter of a line included)
        return ids, heal, min(len(self.head_ids) + max(0, k - 1), max(0, len(ids) - 1))

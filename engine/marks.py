"""Edit mode marks (roadmap item 8, "side cursors": proofread fixes as places; 17 November 2026,
docs/rounds/2026-11-17-editing.md). On a selected paragraph, or a field the user is editing rather than writing on, the app
asks `/marks` for the places where the text could improve. Each mark is one range with one concrete new text and a
one-line "why"; Tab (or a click) puts that text in, Esc puts the mark away (app/EditMarks.swift, app/EditRules.swift).

Local only, no model, no network: rules and the user's own word counts, a few milliseconds per paragraph.
- typo: engine/reader.py `slips` (a word the user never writes, one edit from one the user writes often, the other layout, two of
  their words run together), through the proofread's own filter, so their words stay.
- unclear: a doubled word ("the the"); a sentence over 30 words split at a conjunction after a comma (", але" ->
  ". Але"); a space before a comma, full stop or semicolon. Rules without a concrete new text (a word repeated a few
  words apart, a vague "це"/"it" at a sentence start) were left out: a mark must be one key to apply.
- tone for this person: only from the user's earlier lines to them on screen (the app marks the other side "Вони: ", see
  engine/prompt.py `turns`), and only with 2+ of them as evidence: ти/ви the other way from how the user writes to them,
  a greeting more or less formal than the user's usual one to them, "!" or emoji far above the user's usual lines to them.
- rank: typos first, then tone, then unclear; no overlapping ranges; at most 5.

    .venv/bin/python -B engine/marks.py "text" ["Я: earlier line\\nВони: their line"]
"""
import re, sys, time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

MAX_CHARS = 3000
LONG_WORDS = 30          # a sentence longer than this gets a split mark
MIN_PART = 6             # ...each part keeps at least this many words
EVIDENCE = 2             # earlier lines of the user's to them needed before a tone mark
ORDER = {"typo": 0, "tone": 1, "unclear": 2}

WORD = re.compile(r"[^\W\d_]+(?:['’ʼ-][^\W\d_]+)*", re.UNICODE)
EMOJI = re.compile("[\U0001F300-\U0001FAFF☀-➿\U0001F000-\U0001F2FF]+[️‍\U0001F3FB-\U0001F3FF]*")

TY_VY = {"ти": "ви", "тобі": "вам", "тебе": "вас", "тобою": "вами", "твій": "ваш", "твоя": "ваша", "твоє": "ваше",
         "твої": "ваші", "твого": "вашого", "твоєї": "вашої", "твоїм": "вашим", "твоїй": "вашій", "твою": "вашу",
         "твоїх": "ваших", "твоїми": "вашими"}
VY_TY = {v: k for k, v in TY_VY.items()}
FORMAL = ["добрий день", "доброго дня", "добрий вечір", "доброго ранку", "доброго вечора", "вітаю", "good morning",
          "good afternoon", "dear"]
CASUAL = ["привіт", "привітик", "прив", "хай", "здоров", "салют", "йо", "hi", "hey", "hello", "yo"]
GREET = re.compile(r"^\s*(" + "|".join(sorted((re.escape(g) for g in FORMAL + CASUAL), key=len, reverse=True)) + r")\b", re.I)
CONJ = re.compile(r",\s+(і|й|та|а|але|проте|тому|бо|тож|and|but|so|because|which|while)\b", re.I)


def u16(s): return len(s.encode("utf-16-le")) // 2


def _cased(like, new):
    if like[:1].isupper(): return new[:1].upper() + new[1:]
    return new


def _mark(at, old, new, kind, why, score):
    return {"at": at, "len": len(old), "old": old, "new": new, "kind": kind, "why": why[:60], "score": round(score, 2)}


# ---------- typo ----------

def typos(text, W, kept=None, sysw=None):
    if W is None or len(text.split()) < 2: return []
    import reader
    found, _ = reader.slips(text, W, kept, sysw)
    return [_mark(e["at"], e["old"], e["new"], "typo", f"you usually write «{e['new']}»"[:60], 0.9) for e in found]


# ---------- unclear ----------

def doubled(text):
    out = []
    for m in re.finditer(r"\b([^\W\d_]+)(\s+)\1\b", text, re.I | re.U):
        if m.group(1).lower() in ("ha", "ха", "так", "no", "ні", "дуже", "very", "ну"): continue   # "дуже дуже", "так так": the user's on purpose
        out.append(_mark(m.start(), m.group(0), m.group(1), "unclear", "the same word twice in a row", 0.7))
    return out


def sentences(text):
    """[(start, sentence)] split at . ! ? … and line breaks."""
    return [(m.start(), m.group()) for m in re.finditer(r"[^.!?…\n]+[.!?…]*", text)]


def long_splits(text):
    out = []
    for start, s in sentences(text):
        n = len(WORD.findall(s))
        if n <= LONG_WORDS: continue
        best = None
        for m in CONJ.finditer(s):
            left, right = len(WORD.findall(s[:m.start()])), len(WORD.findall(s[m.end():]))
            if left < MIN_PART or right < MIN_PART: continue
            bal = abs(left - right)
            if best is None or bal < best[0]: best = (bal, m)
        if not best: continue
        m = best[1]
        conj = m.group(1)
        # "і"/"and" opens nothing on its own: the new sentence starts at the next word; others keep their word
        if conj.lower() in ("і", "й", "та", "and"):
            nxt = re.match(r"\s*(\S)", s[m.end():])
            if not nxt: continue
            old = s[m.start():m.end() + nxt.end()]
            new = ". " + nxt.group(1).upper()
        else:
            old = m.group(0)
            new = ". " + conj[:1].upper() + conj[1:]
        out.append(_mark(start + m.start(), old, new, "unclear", f"a long sentence ({n} words): split it here", 0.5))
    return out


def space_before(text):
    out = []
    for m in re.finditer(r"(?<=[^\W_])([ \t]+)([,.;])(?=\s|$)", text):
        if text[m.end(2):m.end(2) + 2] == "..": continue
        out.append(_mark(m.start(), m.group(0), m.group(2), "unclear", "a space before the punctuation mark", 0.55))
    return out


# ---------- tone for this person ----------

def his_lines(context):
    """The user's earlier lines to them: lines not marked as theirs (or an AI's), only when the screen text has marks."""
    import prompt
    ts = prompt.turns(context or "")
    if not any(w is not None for w, _ in ts): return []
    return [t for w, t in ts if w in ("me", None) and t.strip()]


def _who(person): return f"to {person}" if person else "to them"


def ty_vy(text, lines, person=None):
    def hits(s, forms): return [w for w in WORD.findall(s) if w.lower() in forms]
    vy = [l for l in lines if hits(l, VY_TY)]
    ty = [l for l in lines if hits(l, TY_VY)]
    out = []
    if len(vy) >= EVIDENCE and not ty:
        cap = sum(1 for l in vy for w in hits(l, VY_TY) if w[0].isupper() and not l.lstrip().startswith(w)) > 0
        for m in WORD.finditer(text):
            w = m.group()
            if w.lower() not in TY_VY: continue
            new = TY_VY[w.lower()]
            new = new[:1].upper() + new[1:] if cap or w[:1].isupper() else new
            out.append(_mark(m.start(), w, new, "tone", f"you write «ви» {_who(person)} ({len(vy)} lines)", 0.8))
    elif len(ty) >= EVIDENCE and not vy:
        for m in WORD.finditer(text):
            w = m.group()
            if w.lower() not in VY_TY: continue
            out.append(_mark(m.start(), w, _cased(w, VY_TY[w.lower()]), "tone", f"you write «ти» {_who(person)} ({len(ty)} lines)", 0.8))
    return out


def greeting(text, lines, person=None):
    m = GREET.match(text)
    if not m: return []
    g = m.group(1).lower()
    seen = [GREET.match(l).group(1).lower() for l in lines if GREET.match(l)]
    if len(seen) < EVIDENCE: return []
    formal = [x for x in seen if x in FORMAL]
    casual = [x for x in seen if x in CASUAL]
    if g in CASUAL and formal and not casual: pick, why = max(set(formal), key=formal.count), "you greet them formally"
    elif g in FORMAL and casual and not formal: pick, why = max(set(casual), key=casual.count), "you greet them casually"
    else: return []
    if person: why = why.replace("them", person)
    return [_mark(m.start(1), m.group(1), _cased(m.group(1), pick), "tone", f"{why} («{pick}»)", 0.75)]


def loudness(text, lines, person=None):
    if len(lines) < max(EVIDENCE, 3): return []
    out = []
    bangs = sum(l.count("!") for l in lines)
    runs = any("!!" in l for l in lines)
    for m in re.finditer(r"!{2,}", text):
        if not runs: out.append(_mark(m.start(), m.group(), "!", "tone", f"you rarely use «!!» {_who(person)}", 0.6))
    if bangs == 0 and text.count("!") >= 2:
        for m in re.finditer(r"(?<!!)!(?!!)", text):
            out.append(_mark(m.start(), "!", ".", "tone", f"you write no «!» {_who(person)}", 0.55))
    if not any(EMOJI.search(l) for l in lines) and len(EMOJI.findall(text)) >= 2:
        for m in re.finditer(r"[ \t]?" + EMOJI.pattern, text):
            out.append(_mark(m.start(), m.group(), "", "tone", f"you send no emoji {_who(person)}", 0.5))
    return out


# ---------- ranking and the route ----------

def rank(found, limit=5):
    """Typos first, then tone, then unclear (higher score first, then by place); no overlapping ranges; at most `limit`."""
    out = []
    for m in sorted(found, key=lambda m: (ORDER.get(m["kind"], 9), -m.get("score", 0), m["at"])):
        a, b = m["at"], m["at"] + max(m["len"], 1)
        if any(a < o["at"] + max(o["len"], 1) and o["at"] < b for o in out): continue
        out.append(m)
        if len(out) >= limit: break
    return out


def marks(text, context="", person=None, W=None, kept=None, sysw=None, limit=5):
    """-> {"marks": [{at, len (UTF-16 offsets into `text`), old, new, kind, why, score}], "ms"}, ranked."""
    t0 = time.perf_counter()
    text = (text or "")[:MAX_CHARS]
    found = typos(text, W, kept, sysw) + doubled(text) + long_splits(text) + space_before(text)
    lines = his_lines(context)
    if lines:
        found += ty_vy(text, lines, person) + greeting(text, lines, person) + loudness(text, lines, person)
    found = [m for m in found if m["old"] != m["new"] and text[m["at"]:m["at"] + m["len"]] == m["old"]]
    ranked = rank(found, limit)
    out = [dict(m, at=u16(text[:m["at"]]), len=u16(m["old"])) for m in ranked]
    return {"marks": out, "ms": round((time.perf_counter() - t0) * 1000, 2)}


if __name__ == "__main__":
    import words
    W = words.Words(); W.load()
    print(marks(sys.argv[1] if len(sys.argv) > 1 else "", sys.argv[2] if len(sys.argv) > 2 else "", W=W))

"""Mid-line ghosts: fill in the middle with a plain completion model (2026-11-15, docs/rounds/2026-11-15-fim.md).

The live model (Qwen3 1.7B base with his layer) has no fill-in-the-middle tokens. With the caret mid-line, the app sends
the rest of the caret's line (`after_line`); the engine shows it above his text (engine/prompt.py MID_FORM) and writes
a plain continuation, and these rules end the ghost where the gap is filled:

- the model would now write the rest of the line: at a word boundary, the probability of the rest's first token
  (`rests`, read from the same distribution the next token came from, so it costs nothing) reaches `stop`;
  before the first word (nothing typed in a half word) that means nothing is missing: no ghost;
- its text runs into the rest of the line (the same words again): cut there;
- one line only; never ends with the start of the rest; no sentence end or doubled punctuation before a rest that
  goes on; no trailing space before a rest that starts with one.

Pure functions, shared by the engine (engine/model.py complete_gated, engine/server.py) and the bench (bench/fim.py)."""
import re
from gatecore import next_word, word_ps

END = re.compile(r"[.!?…\n]")
WORD = re.compile(r"\s*\S+\s?")
TOKEN = re.compile(r"[\w'’-]+|[^\w\s]")
STOP = 0.3        # p of the rest's first token that ends the ghost (bench/fim.py sweep)
MORE = 0.5        # words after the first while each token is at least this sure (the end-of-line bar)
WORDS = 4         # at most this many words (the gaps that matter are 1-4 words)
TOKENS = 12       # model tokens for one mid-line ghost


def rest_at(toks, rests, lo, heal=""):
    """p of the rest of the line coming right after raw[:lo] (a word boundary), or 0.0 when no step starts there.
    The step that wrote the first token past `lo` saw exactly raw[:lo]; it counts only when the token before it ended
    at `lo` (and, at the very start, when no half word was being spelled: the healer's mask decides those steps)."""
    for j, t in enumerate(toks):
        if len(t[0]) > lo:
            prev = len(toks[j - 1][0]) if j else 0
            if j == 0 and heal.strip(): return 0.0
            if prev != lo: return 0.0
            return rests[j] if j < len(rests) and rests[j] is not None else 0.0
    return 0.0


def shape(toks, rests, rest, heal="", more=MORE, words=WORDS, stop=STOP, closed=False):
    """The mid-line ghost the recorded tokens make now. toks: [[text after the half word, p, ...], ...]; rests[j]: p of
    the rest's first token at the step that wrote toks[j]. closed: the model stopped (end of text or token cap), so the
    last word counts as whole. -> (ghost, why): why "open" while more tokens could change it, else what ended it
    ("none" nothing missing, "rest", "bar", "words", "end", "line")."""
    if not toks: return "", "open"
    if stop is not None and not heal.strip() and rests and rests[0] is not None and rests[0] >= stop: return "", "none"
    raw = toks[-1][0]
    if not raw: return "", "open"
    first = next_word(raw)
    if not first.strip(): return "", "open"
    whole = lambda end: end < len(raw) or closed
    if not whole(len(first.rstrip())) and not END.search(first): return "", "open"
    out, pos, n, why = first, len(first), 1, "open"
    if "\n" in first.strip(" ") or END.search(first.strip()):
        why = "line" if "\n" in first else "end"
    else:
        for ww in WORD.findall(raw[pos:]):
            lo = len(raw[:pos].rstrip())
            if stop is not None and rest_at(toks, rests, lo, heal) >= stop: why = "rest"; break
            if n >= words: why = "words"; break
            end = pos + len(ww.rstrip())
            if not whole(end) and not END.search(ww): break
            if "\n" in ww.rstrip(" ") and not ww.strip(): why = "line"; break
            span = word_ps(toks, pos, end)
            if not span or min(span) < more: why = "bar"; break
            out += ww; pos += len(ww); n += 1
            if "\n" in ww: why = "line"; break
            if END.search(ww): why = "end"; break
        else:
            # every whole word taken: the next step may still be the rest of the line
            lo = len(raw[:pos].rstrip())
            if stop is not None and pos >= len(raw) and rest_at(toks, rests, lo, heal) >= stop: why = "rest"
            elif closed: why = "end"
    return cut(out, rest), why


def tokens(s):
    return [(m.start(), m.group(0)) for m in TOKEN.finditer(s)]


def cut(ghost, rest):
    """The ghost as it may go between the caret and `rest` (the rest of the caret's line). "" = nothing fits."""
    g = re.split(r"[\r\n]", ghost or "", maxsplit=1)[0]
    if not rest or not rest.strip():
        return g if g.strip() else ""
    rt = [t for _, t in tokens(rest)]
    # runs into the rest: from the earliest word start where the ghost says the rest's own words again
    for i, t in tokens(g):
        if i and not (g[i - 1].isspace() or not t[0].isalnum()): continue
        tt = [x for _, x in tokens(g[i:])]
        k = min(len(tt), len(rt))
        if k and tt[:k] == rt[:k] and sum(len(x) for x in tt[:k]) >= 2:
            g = g[:i]; break
    # the app's own rule (GhostRules.midText): never ends with 2-40 characters the rest starts with
    for k in range(min(len(g), len(rest), 40), 1, -1):
        if g.endswith(rest[:k]): g = g[:-k]; break
    r = rest.lstrip()
    if r[:1] in ",.;:!?…)" or r[:1].islower():
        # the line goes on: no sentence end, no doubled punctuation before it
        g = re.sub(r"[ \t]*[.!?…,;:]+$", "", g) if r[:1] in ",.;:!?…)" or re.search(r"[.!?…]$", g.rstrip()) else g
    if rest[:1].isspace(): g = g.rstrip()
    return g if g.strip() else ""

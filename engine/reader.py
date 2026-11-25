"""Reader check before sending (roadmap item 4, 17 November 2026; docs/rounds/2026-11-17-reader.md). In a chat box, once
the message looks finished (a sentence end, or a rest of about 1 s after 3+ words), the app asks `/reader` for a last
look: slips in his message and a question from the other person his draft does not touch. One quiet chip; Tab puts
the fixes in through the Fix chip's path (app/Proof.swift), any other key drops it. Enter is never held.

Local only, no model, no network: well under a millisecond per message.
- Slips: a word he never wrote (fewer than 2 times in his writing, not in his kept words, not in the system English
  word list) that is one edit (a missed, extra, wrong or swapped letter, a missing apostrophe) away from one word he
  writes often (5+ times, 3x more than the next candidate), the same keys in the other layout of a word he writes, or
  two words he writes together run into one. The result goes through the fix filter (engine/word_fixes.py edits),
  so his words (word_fixes.keep_words) stay and only small one-word fixes survive. The app also drops a fix when the Mac's
  spellchecker knows his word (as app/Fixer.swift does).
- An unanswered question: only from the screen text the app already reads for suggestions (app/ScreenContext.swift
  marks the other person's messages "Вони: "). When their last message, with nothing of his after it, asks a question
  and his draft shares no content word with it (a "yes"/"no" word answers a yes/no question): "they asked about X".
  Without the marks nothing is said: whose question it is cannot be told.
- Tone: not checked. No cheap local signal was good enough (round doc).

    .venv/bin/python -B engine/reader.py "message" ["Вони: their message"]
"""
import re, sys, threading, time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

MAX_CHARS = 800
MIN_LEN = 4              # shorter words: too many real words one letter apart
MIN_COUNT = 5            # a fix target is a word he wrote this many times
MARGIN = 3               # ...and this many times more than the next candidate
MAX_EDITS = 3            # more slips than this in one message: likely a language or style he rarely writes; say nothing

WORD = re.compile(r"[^\W\d_]+(?:['’ʼ-][^\W\d_]+)*", re.UNICODE)
RUSSIAN = re.compile(r"[ыэъёЫЭЪЁ]")
UK = "абвгґдеєжзиіїйклмнопрстуфхцчшщьюя'’ʼ"
EN = "abcdefghijklmnopqrstuvwxyz'"
EN_KEYS = "`qwertyuiop[]asdfghjkl;'zxcvbnm,./"
UK_KEYS = "'йцукенгшщзхїфівапролджєячсмитьбю."
TO_UK = dict(zip(EN_KEYS, UK_KEYS))
TO_EN = {b: a for a, b in TO_UK.items()}


# ---------- his words ----------

_sys = {"words": None}


def system_words():
    """The macOS English word list, lowercase (empty when missing)."""
    if _sys["words"] is None:
        try: _sys["words"] = set(Path("/usr/share/dict/words").read_text().lower().splitlines())
        except OSError: _sys["words"] = set()
    return _sys["words"]


_kept = {"at": 0.0, "words": set()}


def keep(ttl=60.0):
    """The never-fix words (word_fixes.keep_words), read at most once a minute."""
    if time.time() - _kept["at"] > ttl:
        import word_fixes
        _kept.update(at=time.time(), words=word_fixes.keep_words())
    return _kept["words"]


def _count(W, w): return W.uni.get(w, 0)


def known(low, W, kept, sysw):
    return low in kept or _count(W, low) >= 2 or (low.isascii() and low in sysw)


def edits1(low):
    """Every string one edit from `low`, in its own alphabet (Norvig's spell corrector, plus swaps)."""
    alpha = EN if low.isascii() else UK
    splits = [(low[:i], low[i:]) for i in range(len(low) + 1)]
    out = {a + b[1:] for a, b in splits if b}
    out |= {a + b[1] + b[0] + b[2:] for a, b in splits if len(b) > 1}
    out |= {a + c + b[1:] for a, b in splits if b for c in alpha}
    out |= {a + c + b for a, b in splits for c in alpha}
    out.discard(low)
    return out


def _cased(word, new):
    if word.isupper() and len(word) > 1: return new.upper()
    return new[0].upper() + new[1:] if word[0].isupper() else new


def fix_word(word, W, kept, sysw=None):
    """-> the word he most likely meant, or None. `W` is engine/words.py Words (his counts)."""
    sysw = system_words() if sysw is None else sysw
    low = word.lower()
    if len(low) < MIN_LEN or RUSSIAN.search(low) or known(low, W, kept, sysw): return None
    ascii_ = low.isascii()
    if not ascii_ and any(c.isascii() for c in low.replace("'", "")): return None   # mixed scripts: a name, a code
    with W.lock:
        # the other layout: ghbdsn -> привіт, руддщ -> hello (the whole word, one he writes)
        conv = "".join((TO_UK if ascii_ else TO_EN).get(c, c) for c in low)
        if conv != low and _count(W, conv) >= 3: return _cased(word, conv)
        # two words he writes together, run into one: незнаю -> не знаю
        best = None
        for i in range(1, len(low)):
            a, b = low[:i], low[i:]
            n = W.bi[a][b] if a in W.bi else 0
            if n >= 2 and _count(W, a) >= MIN_COUNT and _count(W, b) >= MIN_COUNT and (best is None or n > best[0]):
                best = (n, a + " " + b)
        if best: return _cased(word, best[1])
        cands = sorted(((c, _count(W, c)) for c in edits1(low)), key=lambda x: -x[1])
        cands = [(c, n) for c, n in cands if n >= MIN_COUNT and not RUSSIAN.search(c)]
    if not cands: return None
    if len(cands) > 1 and cands[1][1] * MARGIN > cands[0][1]: return None
    return _cased(word, cands[0][0])


def slips(text, W, kept=None, sysw=None):
    """-> (edits [{at, len (Python offsets), old, new}], fixed text) after the fix filter (engine/word_fixes.py)."""
    import word_fixes
    kept = keep() if kept is None else kept
    fixed, shift = text, 0
    for m in WORD.finditer(text):
        new = fix_word(m.group(), W, kept, sysw)
        if not new: continue
        a, b = m.start() + shift, m.end() + shift
        fixed = fixed[:a] + new + fixed[b:]
        shift += len(new) - (m.end() - m.start())
    if fixed == text: return [], text
    found = word_fixes.edits(text, fixed, kept)
    if len(found) > MAX_EDITS: return [], text
    out = text
    for e in sorted(found, key=lambda e: -e["at"]): out = out[:e["at"]] + e["new"] + out[e["at"] + e["len"]:]
    return found, out


# ---------- a question left open ----------

STOP = set("""
а або але аж б би бо був була були було бути в вам вас ваш весь вже ви від він вона вони воно все всі де для до досі
є ж з за знову і із й к коли куди ми мене мені мій моя мої на нам нас не нею ні нього них ну о от по при про раз
так там тебе теж тобі то тоді треба ти тут у уже усе хто це цей ця ці цього чи чим що щоб як який яка яке які
його її їх ще скільки навіщо чому звідки ось тільки можна можеш можете можемо будеш буде будемо будете есть
a an and are as at be been but by can could did do does for from had has have he her him his how i if in is it its
me my no not of on or our she so than that the their them then there they this to us was we were what when where
which who why will with would you your yes ok okay please pls just also any some
""".split())
WH = re.compile(r"^\W*(коли|де|куди|звідки|скільки|хто|що|шо|який|яка|яке|які|якого|якої|чому|навіщо|як|"
                r"when|where|what|who|whom|whose|why|how|which)\b", re.I)
YESNO = re.compile(r"^\W*(так|ні|нє|не|ага|угу|ок|окей|ok|okay|yes|yeah|yep|no|nope|sure|звісно|звичайно|канєшно|"
                   r"давай|можу|можна|буде|будемо|згоден|згодна|точно|норм)\b", re.I)


def last_them(context):
    """Their last message when it is the last one on screen (nothing of his after it), else ''."""
    import prompt
    ts = prompt.turns(context or "")
    if not ts or not any(w is not None for w, _ in ts): return ""
    who, text = ts[-1]
    return text if who == "them" else ""


def questions(msg):
    """The question sentences of a message, last first."""
    parts = re.findall(r"[^.!?…\n]*\?", msg or "")
    return [p.strip() for p in reversed(parts) if len(WORD.findall(p)) >= 2]


def content(s):
    return [w for w in WORD.findall(s) if len(w) >= 3 and w.lower() not in STOP]


def _stem(w):
    w = w.lower().replace("’", "'").replace("ʼ", "'")
    return w[:max(4, len(w) - 2)] if len(w) > 4 else w


def touches(draft, words):
    have = {_stem(w) for w in WORD.findall(draft or "")}
    return any(_stem(w) in have for w in words)


def unanswered(context, draft):
    """-> "they asked about X" when their last message asks something the draft does not touch, else ''."""
    msg = last_them(context)
    if not msg: return ""
    for q in questions(msg)[:2]:
        words = content(q)
        if not words: continue
        if touches(draft, words): continue
        if not WH.search(q) and YESNO.search(draft or ""): continue     # "so tomorrow?" "так" answers it
        return "they asked about " + " ".join(words[:3])
    return ""


# ---------- the route ----------

_stats = {"asked": 0, "edits": 0, "asks": 0}
_lock = threading.Lock()


def check(text, context, W, kept=None, sysw=None):
    """-> {"edits": [{at, len (UTF-16), old, new}], "fixed", "ask", "ms"}."""
    t0 = time.perf_counter()
    text = (text or "")[-MAX_CHARS:]
    found, fixed = (slips(text, W, kept, sysw) if len(text.split()) >= 3 else ([], text))
    ask = unanswered(context, text)
    u16 = lambda x: len(x.encode("utf-16-le")) // 2
    with _lock:
        _stats["asked"] += 1; _stats["edits"] += len(found); _stats["asks"] += bool(ask)
    return {"edits": [{"at": u16(text[:e["at"]]), "len": u16(e["old"]), "old": e["old"], "new": e["new"]} for e in found],
            "fixed": fixed, "ask": ask, "ms": round((time.perf_counter() - t0) * 1000, 2)}


def stats(): return dict(_stats)


if __name__ == "__main__":
    import words
    W = words.Words(); W.load()
    print(check(sys.argv[1] if len(sys.argv) > 1 else "", sys.argv[2] if len(sys.argv) > 2 else "", W))

"""Which word fixes stay (from the Claude proofread of 1 November 2026, whose Claude part went on 2026-11-17): the local
reader check (engine/reader.py) runs its slips through `edits`, so only small word fixes survive: one word for one
word, a few letters apart or the same word typed in the other keyboard layout, or a word split or joined. The user's slang,
punctuation, case and missing full stops stay. Words the user took back before (data/autocorrect-keep.*) and their own words
(`keep_words`) are never fixed. Local only, nothing leaves the Mac.
"""
import difflib, json, re
from pathlib import Path

DATA = Path(__file__).resolve().parent.parent / "data"
RUSSIAN = re.compile(r"[ыэъёЫЭЪЁ]")
EDGE = "\"'«»“”„()[]{}<>.,:;!?…-–—*_~`"
EN = "`qwertyuiop[]asdfghjkl;'zxcvbnm,./"
UK = "'йцукенгшщзхїфівапролджєячсмитьбю."
TO_UK = {a: b for a, b in zip(EN, UK)} | {a.upper(): b.upper() for a, b in zip(EN, UK) if a.isalpha()}
TO_EN = {b: a for a, b in TO_UK.items()}


def keep_words():
    """Words never fixed: ones the user took back (autocorrect-keep.txt) and their own words, used 3+ times (mywords.txt; the
    bench "fixed" тіма, the user's word for team)."""
    out = set()
    for f in ("mywords.txt", "known-words.txt"):
        try: out |= {l.strip().lower() for l in (DATA / f).read_text().splitlines() if l.strip()}
        except Exception: pass
    try: counts = json.loads((DATA / "autocorrect-keep.json").read_text())
    except (OSError, ValueError): counts = {}
    if not isinstance(counts, dict): counts = {}
    counts = {w.lower(): n for w, n in counts.items() if isinstance(n, int) and n >= 0}
    # The old list counts as one, never an unconditional keep. JSON stores total counts.
    try:
        for word in (DATA / "autocorrect-keep.txt").read_text().splitlines():
            word = word.strip().lower()
            counts[word] = max(counts.get(word, 0), 1)
    except OSError: pass
    out |= {w.lower() for w, n in counts.items() if isinstance(n, int) and n >= 2}
    return out


def _core(tok):
    """A token without the punctuation around it: (lead, core, trail)."""
    i, j = 0, len(tok)
    while i < j and tok[i] in EDGE: i += 1
    while j > i and tok[j - 1] in EDGE: j -= 1
    return tok[:i], tok[i:j], tok[j:]


def _dist(a, b):
    """Edit distance with swaps (Damerau, optimal string alignment)."""
    d = [[0] * (len(b) + 1) for _ in range(len(a) + 1)]
    for i in range(len(a) + 1): d[i][0] = i
    for j in range(len(b) + 1): d[0][j] = j
    for i in range(1, len(a) + 1):
        for j in range(1, len(b) + 1):
            c = 0 if a[i - 1] == b[j - 1] else 1
            d[i][j] = min(d[i - 1][j] + 1, d[i][j - 1] + 1, d[i - 1][j - 1] + c)
            if i > 1 and j > 1 and a[i - 1] == b[j - 2] and a[i - 2] == b[j - 1]: d[i][j] = min(d[i][j], d[i - 2][j - 2] + 1)
    return d[-1][-1]


def _layout(old, new):
    """The same keys in the other layout?"""
    return "".join(TO_UK.get(c, c) for c in old) == new or "".join(TO_EN.get(c, c) for c in old) == new


def _close(old, new):
    a, b = old.lower(), new.lower()
    if a == b: return False                       # case only: the user's lowercase stays
    # English without the apostrophe (lets, dont, im) is how the user writes; a Ukrainian one missing is a mistake (мясо)
    if a.isascii() and a.replace("'", "").replace("’", "") == b.replace("'", "").replace("’", ""): return False
    if _layout(old, new): return True
    if len(a) < 3 or not b: return False          # "it" -> "I" in the bench: too short to tell a typo
    if any(c.isdigit() for c in a + b) or "/" in a or "@" in a: return False
    n = max(len(a), len(b))
    allowed = 1 if n <= 5 else 2 if n <= 9 else 3
    if a[0] != b[0] and _dist(a[1:], b[1:]) > 0 and n <= 5: return False
    return _dist(a, b) <= allowed


_SYSTEM_WORDS = None

def joined_word(word, keep):
    global _SYSTEM_WORDS
    if word.lower() in keep: return True
    if _SYSTEM_WORDS is None:
        try: _SYSTEM_WORDS = set(Path('/usr/share/dict/words').read_text().lower().splitlines())
        except OSError: _SYSTEM_WORDS = set()
    return word.lower() in _SYSTEM_WORDS


def edits(text, fixed, keep=None):
    """-> list of {at, len, old, new} (Python str offsets) for the small word fixes between text and fixed."""
    keep = keep_words() if keep is None else keep
    ta = [(m.start(), m.group()) for m in re.finditer(r"\S+", text)]
    tb = [m.group() for m in re.finditer(r"\S+", fixed)]
    out = []
    sm = difflib.SequenceMatcher(a=[t for _, t in ta], b=tb, autojunk=False)
    for op, i1, i2, j1, j2 in sm.get_opcodes():
        if op != "replace": continue
        if i2 - i1 == j2 - j1:
            for (at, old), new in zip(ta[i1:i2], tb[j1:j2]):
                lo, oc, tr = _core(old)
                _, nc, _ = _core(new)
                if not oc or not nc or oc.lower() in keep or RUSSIAN.search(nc) or not _close(oc, nc): continue
                out.append({"at": at + len(lo), "len": len(oc), "old": oc, "new": nc})
        elif "".join(t for _, t in ta[i1:i2]) == "".join(tb[j1:j2]) and (i2 - i1) + (j2 - j1) <= 4:
            # split or joined words ("незнаю" -> "не знаю"): same letters, other spaces
            at, end = ta[i1][0], ta[i2 - 1][0] + len(ta[i2 - 1][1])
            old, new = text[at:end], " ".join(tb[j1:j2])
            protected = any(_core(t)[1].lower() in keep for t in old.split())
            joined = ''.join(_core(t)[1] for t in old.split())
            # Existing unprotected split repairs stay; protected pieces may join/split
            # only if the combined spelling is independently known as a word.
            valid = joined_word(joined, keep)
            if not RUSSIAN.search(new) and (valid or (not protected and i2 - i1 == 1)):
                out.append({"at": at, "len": end - at, "old": old, "new": new})
    return out

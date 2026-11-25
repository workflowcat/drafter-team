"""Offline synonyms for a selected word or a 2-3 word phrase (2026-11-15; Cotypist Pro parity). ⌥Tab on a short
selection shows up to 6 of them above the rework commands; nothing leaves the Mac.

Source: LibreOffice's thesaurus files (MyThes format), downloaded by `scripts/download_thesaurus.py` into
models/thesaurus/ (not in git): th_en_US_v2.dat (WordNet, Princeton licence) and th_uk_UA.dat (Andriy Rysin, after
Derkach's dictionary of synonyms; GPL/LGPL/MPL). A file that is missing means no synonyms in that language.

The Ukrainian file lists base forms. A selected form ("швидкого") is matched to its base form by a small table of
endings, and each synonym gets the same ending back when the result is a word he has written himself (data/mywords.txt)
or the class is regular (adjectives in -ий/-ій); otherwise the synonym comes in its base form and says so (`form`).
English: a few regular endings (-s, -es, -ies, -ed, -ing, -ly) the same way.

Rank: the word he uses more first (data/myword-counts.json), then the thesaurus order; marked old, regional or
"compare" words go last; antonyms never show. An optional `score(before, candidate, after) -> float` callback (the warm
local model) reranks the first candidates; the server passes it only when it is cheap.

    .venv/bin/python engine/synonyms.py "швидкого" "дай мені"
"""
import json, math, os, re, sys, threading, time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
DATA = ROOT / "data"
THES = Path(os.environ.get("DRAFTER_THESAURUS", ROOT / "models" / "thesaurus"))
FILES = {"en": "th_en_US_v2.dat", "uk": "th_uk_UA.dat"}
MAX = 6
MAX_WORDS = 3
MAX_CHARS = 40
CYR = re.compile(r"[а-яіїєґА-ЯІЇЄҐ]")
RUSSIAN = re.compile(r"[ыэъёЫЭЪЁ]")
WORDISH = re.compile(r"^[\w'’ -]+$")
LABEL = re.compile(r"^\s*\(([^()]*)\)\s*")
# labels that push a synonym down (old, regional, poetic, rare, "compare") or out (antonyms)
LOW = ("заст", "обл", "поет", "рідко", "рідше", "пор", "діал", "книжн", "зневаж", "лайл", "вульг", "жарт", "ірон",
       "generic term", "related term", "obsolete", "archaic")
DROP = ("antonym",)

# Ukrainian endings: (ending of the form, ending of the base form). Longer first; tried only when the form itself is
# not a headword. Adjectives (-ий, -ій) are regular, so their synonyms take the ending even when he never wrote it.
UK_ENDINGS = [
    # adjectives, hard
    ("ого", "ий"), ("ому", "ий"), ("ими", "ий"), ("им", "ий"), ("ім", "ий"), ("ою", "ий"), ("ій", "ий"), ("их", "ий"),
    ("а", "ий"), ("у", "ий"), ("е", "ий"), ("і", "ий"), ("о", "ий"),        # "важливо" -> "важливий", "значно"
    # adjectives, soft
    ("ього", "ій"), ("ьому", "ій"), ("ьою", "ій"), ("ім", "ій"), ("ими", "ій"), ("их", "ій"), ("я", "ій"), ("ю", "ій"),
    ("є", "ій"), ("і", "ій"),
    # verbs: -ати, -ити, -іти, -увати (present, past)
    ("уємо", "увати"), ("уєте", "увати"), ("ують", "увати"), ("уєш", "увати"), ("ує", "увати"), ("ую", "увати"),
    ("аємо", "ати"), ("аєте", "ати"), ("ають", "ати"), ("аєш", "ати"), ("ає", "ати"), ("аю", "ати"),
    ("ала", "ати"), ("ало", "ати"), ("али", "ати"), ("ав", "ати"),
    ("имо", "ити"), ("ите", "ити"), ("ять", "ити"), ("иш", "ити"), ("ить", "ити"), ("ю", "ити"), ("у", "ити"),
    ("ила", "ити"), ("ило", "ити"), ("или", "ити"), ("ив", "ити"),
    ("іла", "іти"), ("іло", "іти"), ("іли", "іти"), ("ів", "іти"),
    # nouns: feminine -а/-я, neuter -о/-е, masculine with no ending
    ("ами", "а"), ("ою", "а"), ("ам", "а"), ("ах", "а"), ("и", "а"), ("і", "а"), ("у", "а"),
    ("ями", "я"), ("ею", "я"), ("ям", "я"), ("ях", "я"), ("ю", "я"), ("і", "я"),
    ("ом", "о"), ("ові", "о"), ("а", "о"), ("у", "о"), ("і", "о"),
    ("ами", ""), ("ові", ""), ("ом", ""), ("ам", ""), ("ах", ""), ("ів", ""), ("а", ""), ("у", ""), ("і", ""), ("и", ""),
]
UK_REGULAR = {"ий", "ій"}
# English: (ending of the form, ending of the base form, which ending a synonym gets)
EN_ENDINGS = [("ies", "y"), ("es", ""), ("s", ""), ("ied", "y"), ("ed", "e"), ("ed", ""), ("ing", "e"), ("ing", ""),
              ("ily", "y"), ("ly", "")]

_lock = threading.Lock()
_index = {}       # lang -> {headword: byte offset}
_vocab = {"mtime": None, "words": set(), "counts": {}}
_stats = {"asked": 0, "found": 0, "shown": 0, "load_ms": {}}


# ---------- thesaurus files ----------

def path(lang): return THES / FILES[lang]


def available(lang): return lang in FILES and path(lang).exists()


def _load(lang):
    """{headword (lowercase): offset of its line} for one file, built once (en ~145k heads, a fraction of a second)."""
    with _lock:
        if lang in _index: return _index[lang]
        idx, t0 = {}, time.perf_counter()
        if available(lang):
            with open(path(lang), "rb") as f:
                f.readline()                                 # the encoding line
                while True:
                    at = f.tell(); line = f.readline()
                    if not line: break
                    if line[:1] in (b"(", b"|"): continue      # a synonym line, not a headword
                    head, sep, n = line.rstrip(b"\n").rpartition(b"|")
                    if not sep or not n.isdigit(): continue
                    idx.setdefault(head.decode("utf-8", "replace").lower(), at)
        _index[lang] = idx
        _stats["load_ms"][lang] = round((time.perf_counter() - t0) * 1000)
        return idx


def entry(lang, word):
    """[(label, synonym), ...] in the file's order for one headword, or []."""
    at = _load(lang).get(word.lower())
    if at is None: return []
    out = []
    with open(path(lang), "rb") as f:
        f.seek(at)
        head = f.readline().decode("utf-8", "replace").rstrip("\n")
        n = int(head.rpartition("|")[2] or 0)
        for _ in range(n):
            parts = f.readline().decode("utf-8", "replace").rstrip("\n").split("|")
            for p in parts[1:]:                             # parts[0] is the part of speech, "(adj)" or empty
                labels, s = [], p
                while (m := LABEL.match(s)): labels.append(m.group(1).strip()); s = s[m.end():]
                # labels at the end, "(similar term)"
                while (m := re.search(r"\s*\(([^()]*)\)\s*$", s)): labels.append(m.group(1).strip()); s = s[:m.start()]
                s = s.strip()
                # a label without its brackets in the file ("розм побалакати")
                if (m := re.match(r"^(розм|заст|обл|поет|діал|книжн)\.?\s+(?=\S)", s)): labels.append(m.group(1)); s = s[m.end():]
                if s: out.append((" ".join(labels), s))
    return out


def lookup(lang, word, depth=0):
    """Synonyms of one headword with "(див.) X" (see X) followed once: [(label, synonym)]."""
    out = []
    for label, s in entry(lang, word):
        if label.startswith("див") and depth == 0:
            out.append(("", s))
            out += [(l, x) for l, x in lookup(lang, s, 1) if x.lower() != word.lower()]
        else:
            out.append((label, s))
    return out


# ---------- his words ----------

def vocab():
    """His words: data/mywords.txt (3+ times) as the set, data/myword-counts.json (5+ times) as counts. Re-read when
    the export changes (the engine rewrites them as he writes)."""
    f, c = DATA / "mywords.txt", DATA / "myword-counts.json"
    try: mt = (f.stat().st_mtime if f.exists() else 0, c.stat().st_mtime if c.exists() else 0)
    except OSError: mt = (0, 0)
    if _vocab["mtime"] != mt:
        words, counts = set(), {}
        try: words = set(f.read_text().split()) if f.exists() else set()
        except OSError: pass
        try: counts = json.loads(c.read_text()) if c.exists() else {}
        except (OSError, ValueError): pass
        _vocab.update(mtime=mt, words=words, counts=counts)
    return _vocab["words"], _vocab["counts"]


# ---------- forms ----------

def lang_of(text, hint=""):
    if CYR.search(text or ""): return "uk"
    if re.search(r"[A-Za-z]", text or ""): return "en"
    return hint if hint in FILES else ""


def bases(lang, word):
    """[(base form, form ending, base ending)]: the word itself when it is a headword, else the first base form the
    endings table finds (one only: "гарна" is "гарний", not also the adverb "гарно")."""
    w = word.lower()
    idx = _load(lang)
    if w in idx: return [(w, "", "")]
    out = []
    if lang == "uk":
        refl = ""
        if w.endswith(("ся", "сь")) and len(w) > 4: refl, w = w[-2:], w[:-2]
        for fe, be in UK_ENDINGS:
            if w.endswith(fe) and len(w) - len(fe) >= 2:
                b = w[: len(w) - len(fe)] + be
                for cand in ((b + "ся",) if refl else ()) + (b,):
                    if cand in idx and not any(cand == x[0] for x in out):
                        return [(cand, fe + refl, be + ("ся" if cand.endswith("ся") and refl else ""))]
    elif lang == "en":
        for fe, be in EN_ENDINGS:
            if w.endswith(fe) and len(w) - len(fe) >= 2:
                b = w[: len(w) - len(fe)] + be
                if b in idx: return [(b, fe, be)]
    return out


def inflect(lang, syn, fe, be, words):
    """syn (a base form) in the selected word's form -> (text, form): "matched" when he wrote that form himself,
    "guessed" for a regular class, else (syn, "base")."""
    if not fe and not be: return syn, "same"
    if " " in syn: return syn, "base"
    if syn.lower().endswith(be):
        out = syn[: len(syn) - len(be)] + fe if be else syn + fe
        if out.lower() in words: return out, "matched"
    else:
        out = ""
    # another class ("говорю" <- -ити, "розмовляти" is -яти): cut as many letters as the base ending or one fewer, add
    # the form's ending, and keep it only when he has written that word himself
    for cut in (len(be) - 1, len(be)):
        if cut < 1 or len(syn) - cut < 3: continue
        guess = syn[: len(syn) - cut] + fe
        if guess.lower() in words and guess.lower() != syn.lower(): return guess, "matched"
    if not out: return syn, "base"
    if lang == "uk" and be.removesuffix("ся") in UK_REGULAR: return out, "guessed"
    if lang == "en" and fe == "s" and not be and re.search(r"[^sxzy]$", syn) and not syn.endswith(("ch", "sh")):
        return out, "guessed"                            # a regular plural: "cars" -> "autos"
    return syn, "base"


def cased(like, s):
    """The selection's case on a synonym: Title, UPPER or as it is."""
    if like.isupper() and len(like) > 1: return s.upper()
    if like[:1].isupper(): return s[:1].upper() + s[1:]
    return s


# ---------- the request ----------

def candidates(sel, lang, words, counts):
    """-> (base form, [{"text", "base", "form", "label", "rank"}]) for a clean selection."""
    found = bases(lang, sel)
    if not found: return "", []
    seen, out = {sel.lower()}, []
    for k, (base, fe, be) in enumerate(found):
        seen.add(base)
        for i, (label, syn) in enumerate(lookup(lang, base)):
            low = label.lower()
            if any(d in low for d in DROP) or RUSSIAN.search(syn) or not WORDISH.match(syn): continue
            if len(syn.split()) > MAX_WORDS + 1: continue
            text, form = inflect(lang, syn, fe, be, words)
            key = text.lower()
            if key in seen: continue
            seen.add(key)
            own = counts.get(key, 0) or counts.get(syn.lower(), 0)
            rank = math.log1p(own) * 2 - i * 0.05 - k * 0.5 - (3 if any(x in low for x in LOW) else 0) \
                - (1 if "similar term" in low else 0) \
                - (0.5 if form == "base" and (fe or be) else 0)
            out.append({"text": text, "base": syn, "form": form, "label": label, "rank": round(rank, 3)})
    out.sort(key=lambda c: -c["rank"])
    return found[0][0], out


def handle(req, score=None):
    """{"text": the selection, "before"/"after": text around it, "lang": hint} ->
    {"items": [{"text", "base", "form"}], "lang", "base", "ms", "base_forms"}; {"items": []} when there are none.
    `score(before, candidate, after) -> float` (optional, higher is likelier) reranks the first candidates."""
    t0 = time.perf_counter()
    _stats["asked"] += 1
    raw = str(req.get("text") or "")
    lead = raw[: len(raw) - len(raw.lstrip())]
    tail = raw[len(raw.rstrip()):]
    core = raw.strip()
    # trailing punctuation stays his: "швидко," -> the synonym gets the comma back
    m = re.search(r"[.,;:!?…)»\"]+$", core)
    punct = m.group(0) if m else ""
    sel = core[: len(core) - len(punct)] if punct else core
    empty = {"items": [], "ms": 0}
    if not sel or len(sel) > MAX_CHARS or len(sel.split()) > MAX_WORDS or not WORDISH.match(sel) or any(ch.isdigit() for ch in sel):
        return empty
    lang = lang_of(sel, str(req.get("lang") or ""))
    if not lang or not available(lang): return empty
    words, counts = vocab()
    base, cands = candidates(" ".join(sel.split()), lang, words, counts)
    rerank_ms = None
    if score and cands:
        r0 = time.perf_counter()
        top = cands[: MAX + 2]
        before, after = str(req.get("before") or "")[-300:], str(req.get("after") or "")[:80]
        try:
            for c in top: c["lm"] = float(score(before, cased(sel, c["text"]), after))
            top.sort(key=lambda c: -(c["lm"] + c["rank"] * 0.5))
            cands = top + cands[MAX + 2:]
        except Exception as e: print("synonyms score:", e, flush=True)
        rerank_ms = round((time.perf_counter() - r0) * 1000, 1)
    items = [{"text": lead + cased(sel, c["text"]) + punct + tail, "base": c["base"], "form": c["form"]} for c in cands[:MAX]]
    if items: _stats["found"] += 1; _stats["shown"] += len(items)
    res = {"items": items, "lang": lang, "base": base, "base_forms": any(i["form"] == "base" for i in items),
           "ms": round((time.perf_counter() - t0) * 1000, 1)}
    if rerank_ms is not None: res["rerank_ms"] = rerank_ms
    return res


def warm():
    """Build both indexes off the request path (the server may call it at start)."""
    for lang in FILES:
        if available(lang): threading.Thread(target=_load, args=(lang,), daemon=True).start()


def stats(): return dict(_stats)


if __name__ == "__main__":
    t = sys.argv[1] if len(sys.argv) > 1 else "швидкого"
    print(json.dumps(handle({"text": t, "before": sys.argv[2] if len(sys.argv) > 2 else ""}), ensure_ascii=False, indent=1), stats())

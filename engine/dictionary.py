"""The dictionary: data/words.json (untracked), read by the typing engine and the voice engine (engine/voice.py).

It holds the user's contacts and projects, so it lives in `data/`, never in git. `dictionary/words.example.json` is
the tracked seed with made-up entries. `ensure()` moves an older `dictionary/words.json` into `data/` once (and leaves a
link at the old place for apps that still read it there), or starts a new install from the seed.

`words` is the source of truth: [{text, lang, kind, heard?, source}]. `terms`, `heard` and `keep` are written from it on
every save in the shape the voice engine reads (terms = spelling, heard = mishearing -> meant, keep = left alone).

    .venv/bin/python engine/dictionary.py seed     # words the user accepted from Drafter at least twice
    .venv/bin/python engine/dictionary.py add "Харбінджер" uk
"""
import json, re, sys, time
from collections import Counter
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(Path(__file__).resolve().parent))
from data_dir import data_dir  # noqa: E402
FILE = data_dir() / "words.json"
OLD = ROOT / "dictionary" / "words.json"              # tracked until 2026-11-14 (open-source round)
SEED = ROOT / "dictionary" / "words.example.json"
ABOUT = ("The user's own words: completions lean towards them, and voice uses them (Whisper hint, spelling fixes). "
         "Edit `words`; `terms`, `heard` and `keep` are rebuilt from it by Drafter on every save.")


def _common():
    try: return {w for w in Path("/usr/share/dict/words").read_text().split() if w.islower()}
    except Exception: return set()


COMMON = _common()
# tiny words that are never a name, even when a source has them as someone's short name ("The", 2026-10-19)
STOP = {"the", "and", "for", "you", "all", "new", "one", "two", "who", "his", "her", "our", "out", "not", "but", "are"}


def spelling(w):
    """Voice rewrites every term case-insensitively, so a plain English word ("Cases", "Grant") would capitalise
    ordinary speech. Those stay in `words` for Drafter but are left out of `terms`."""
    t = w["text"]
    if w.get("kind") == "phrase": return False
    return not (" " not in t and t.lower() in COMMON)


def lang_of(t):
    return "uk" if re.search(r"[Ѐ-ӿ]", t) else "en"


def _from_git():
    """The last committed dictionary/words.json, when a merge removed the tracked file before ensure() could move it."""
    import subprocess
    try:
        run = lambda *a: subprocess.run(["git", "-C", str(ROOT), *a], capture_output=True, text=True, timeout=5)
        rev = run("rev-list", "-n1", "HEAD", "--", "dictionary/words.json").stdout.strip()
        if not rev: return None
        out = run("show", f"{rev}^:dictionary/words.json")
        return out.stdout if out.returncode == 0 and out.stdout.strip().startswith("{") else None
    except Exception:
        return None


def ensure(file=None, old=None, seed=None, git=True):
    """Make sure the live dictionary exists in data/. Only ever creates it: an existing file is never touched.
    old file, new missing -> move it (a link stays at the old place); neither -> last committed copy, else the seed."""
    file, old, seed = Path(file or FILE), Path(old or OLD), Path(seed or SEED)
    if file.exists(): return file
    file.parent.mkdir(parents=True, exist_ok=True)
    if old.exists() and not old.is_symlink():
        old.replace(file)
        # relative when data/ sits in the checkout, else the full path (DRAFTER_DATA elsewhere)
        rel = file.parent.resolve() == (old.parent.parent / file.parent.name).resolve()
        try: old.symlink_to(Path("..") / file.parent.name / file.name if rel else file.resolve())
        except OSError: pass
        return file
    text = _from_git() if git else None
    if text is None and seed.exists(): text = seed.read_text()
    if text is not None:
        tmp = file.with_suffix(".tmp"); tmp.write_text(text); tmp.replace(file)
    return file


def load(file=None):
    file = Path(file) if file else ensure()
    try: d = json.loads(file.read_text())
    except Exception: d = {}
    d.setdefault("words", []); d.setdefault("keep", []); d.setdefault("loose_heard", {})
    return d


def save(d, file=None, store=None):
    """Writes `words` and the shape the voice engine reads. With the names reference (data/names.json, engine/names.py) beside
    it: terms in order of use (Whisper takes the first 60), the user's Names-page spellings and mishearings in, hidden names out."""
    file = Path(file or FILE)
    # the Whisper hint takes the first 60 terms: the words the user added themselves go first
    order = {"menu": 1, "typing": 2}
    d["words"].sort(key=lambda w: order.get(w.get("source"), 9))
    heard = dict(d.get("loose_heard", {}))
    for w in d["words"]:
        for h in w.get("heard", []): heard[h] = w["text"]
    terms = [w["text"] for w in d["words"] if spelling(w)]
    if store is None:
        try: store = json.loads(file.with_name("names.json").read_text())
        except (OSError, ValueError): store = None
    if store:
        import names
        terms, heard = names.words_view({"terms": terms, "heard": heard}, store)
    out = {"about": ABOUT, "updated": time.strftime("%Y-%m-%d"),
           "terms": terms,
           "heard": heard, "keep": d.get("keep", []), "words": d["words"], "loose_heard": d.get("loose_heard", {})}
    file.parent.mkdir(parents=True, exist_ok=True)
    tmp = file.with_suffix(".tmp"); tmp.write_text(json.dumps(out, ensure_ascii=False, indent=1)); tmp.replace(file)
    return out


def add(text, lang=None, kind="term", source="menu", heard=None, d=None):
    text = (text or "").strip()
    if not text or len(text) > 60: return None
    own = d is None
    d = d or load()
    for w in d["words"]:
        if w["text"].lower() == text.lower():
            if heard: w.setdefault("heard", []).extend(h for h in heard if h not in w.get("heard", []))
            if own: save(d)
            return w
    w = {"text": text, "lang": lang or lang_of(text), "kind": kind, "source": source}
    if heard: w["heard"] = heard
    d["words"].append(w)
    if own: save(d)
    return w


def _heard(hs, text):
    """Heard forms as the dictionary keeps them: lower case, trimmed, once each, never the word itself."""
    out = []
    for h in hs or []:
        h = re.sub(r"\s+", " ", str(h)).strip().lower()
        if h and h != text.lower() and h not in out and len(h) <= 60: out.append(h)
    return out


def edit(old, text, heard=None, d=None):
    """The Dictionary page (app/Dictionary.swift): one word's spelling and heard forms. `old` is matched without case;
    a word not there yet is added (undo of a removal). `heard` replaces its heard forms. Returns the word, or None."""
    text = (text or "").strip()
    if not text or len(text) > 60: return None
    own = d is None
    d = d or load()
    w = next((w for w in d["words"] if w["text"].lower() == (old or text).strip().lower()), None)
    other = next((x for x in d["words"] if x is not w and x["text"].lower() == text.lower()), None)
    if other is not None: return None                       # would make two words of one
    if w is None:
        w = {"text": text, "lang": lang_of(text), "kind": "term" if " " not in text else "phrase", "source": "menu"}
        d["words"].append(w)
    w["text"] = text
    hs = _heard(heard, text)
    if hs: w["heard"] = hs
    else: w.pop("heard", None)
    for h in hs: d["loose_heard"].pop(h, None)              # a pair moves onto its word
    if own: save(d)
    return w


def loose(old, heard, meant, d=None):
    """A heard -> meant pair with no word of its own. Empty `meant` removes it."""
    own = d is None
    d = d or load()
    d["loose_heard"].pop((old or "").strip().lower(), None)
    h, m = (heard or "").strip().lower(), (meant or "").strip()
    if h and m and h != m.lower(): d["loose_heard"][h] = m
    if own: save(d)
    return {"heard": h, "meant": m}


def _own():
    """The user's own names (local config user.own_names): never a contact in the dictionary."""
    try:
        sys.path.insert(0, str(Path(__file__).resolve().parent)); import local
        return "".join("|^" + re.escape(n) + r"\b" for n in local.user("own_names") or [] if n)
    except Exception:
        return ""


SKIP = re.compile(r"^[+\d\s()-]+$" + _own() + r"|📚|^_|^\.")


def seed():
    d = load()
    # accepted typing: words the user took from Drafter at least twice that look like names or terms
    acc = data_dir() / "accepted.jsonl"
    if acc.exists():
        c = Counter()
        for line in acc.read_text().splitlines():
            try: t = json.loads(line)["text"]
            except Exception: continue
            c.update(w for w in re.findall(r"[\w'’&-]{4,}", t) if w[0].isupper() or re.search(r"[a-z][A-Z]", w))
        for w, k in c.items():
            if k >= 2 and not SKIP.search(w): add(w, kind="term", source="typing", d=d)   # never the user's own name
    out = save(d)
    print(f"{len(out['words'])} words, {len(out['terms'])} terms, {len(out['heard'])} heard, {len(out['keep'])} keep -> {FILE}")


if __name__ == "__main__":
    if sys.argv[1:2] == ["seed"]: seed()
    elif sys.argv[1:2] == ["add"]: print(add(sys.argv[2], sys.argv[3] if len(sys.argv) > 3 else None))
    else: print(__doc__)

"""Rework a selection (1 November 2026; Apple Writing Tools, Raycast AI, Grammarly's rewrite; item 7 in
docs/typing-models-research.md "Third round"). Andrii selects text, presses ⌥Tab and picks what to do: shorter, fix,
clearer, warmer, formal, a list, the other language, or types his own instruction. Claude (his signed-in `claude` CLI,
its own kept-running worker) writes the new text in his voice; the app shows it and Tab puts it in place.

A result is kept only when it is not empty, differs from the text, has no Russian letters where Ukrainian is wanted,
keeps every link and email (and every number, except for "shorter" and his own instruction), and "shorter" is shorter.
Offline, or when Claude gives nothing: the local model (base, his-writing layer off) through the `local` callback.

What leaves the Mac: the selected text and the app name, only when he picks a command.

    .venv/bin/python engine/rework.py shorter "the text"
"""
import hashlib, json, re, sys, threading, time
from collections import Counter
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import claude_type as ct
import local
from writing_notes import normalize as notes_text
from worker_pool import get_or_create

SYSTEM = """You rework a piece of text {name} selected, so it reads as if he wrote it himself.
Keep his voice: plain words, short sentences, no corporate filler, no exclamation marks he did not use, no emoji he did not use. Keep the language of the text unless told to translate. Ukrainian means Ukrainian, never Russian.
Keep names, links, emails, numbers, times (15:00 stays 15:00), @mentions, code and markdown as they are. Keep line breaks unless the task changes the shape.
Add nothing he did not say: no greetings, sign-offs, notes or quotes around the text.
Reply with the new text only."""


def system():
    """SYSTEM with the user's name from the local config (data/drafter.local.json); "the user" without it."""
    return SYSTEM.replace("{name}", local.name())


COMMANDS = {
    "shorter": "Make it shorter: about half as long, same meaning, same language and tone.",
    "fix": "Fix typos, wrong letters, text typed in the wrong keyboard layout, wrong word endings and grammar. Change nothing else: keep his wording, slang, punctuation style and a lowercase start.",
    "clearer": "Make it clearer and easier to read: plain words, short sentences, the point first. Same language and tone.",
    "warmer": "Make it warmer and friendlier, still short and natural, the way he talks to people he likes. Same language.",
    "formal": "Make it more formal and polite for a business message. Same language; in Ukrainian address the reader as «ви».",
    "list": "Turn it into a short list: one point per line, each line starting with \"- \". Same language.",
    "translate": "Translate it into {lang}, keeping his tone.",
    # the pause rewrite (engine/pause_rewrite.py, setting pauseRewrite): offered after a pause, never picked by him
    "polish": "Rewrite it the way he would send it after one more read: fix typos, wrong endings and clumsy wording. Keep his voice, language, length, line breaks and every name, number, time and link. Change as few words as you can. If it is already fine, reply with ✓ only.",
}
NAMES = {"shorter": "Shorter", "fix": "Fix", "clearer": "Clearer", "warmer": "Warmer", "formal": "Formal",
         "list": "List", "translate": "Translate", "polish": "Polish"}
MAX_CHARS = 3000
TOKENS = re.compile(r"https?://\S+|[\w.+-]+@[\w-]+\.[\w.]+|\d+")
LINKS = re.compile(r"https?://\S+|[\w.+-]+@[\w-]+\.[\w.]+")

_lock = threading.Lock()
_workers = {}
_cache = {}
_stats = {"asked": 0, "kept": 0, "dropped": 0, "local": 0}


NAMES = {"en": "English", "uk": "Ukrainian"}
LAT = re.compile(r"[A-Za-z]")
CYR = re.compile(r"[А-Яа-яІіЇїЄєҐґ]")


def lang(text, share=0.8):
    """"uk", "en" or None: which letters most of the text is written in (at least 12 letters; Russian is never "uk")."""
    lat, cyr = len(LAT.findall(text or "")), len(CYR.findall(text or ""))
    n = lat + cyr
    if n < 12: return None
    if cyr / n >= share: return None if len(ct.RUSSIAN.findall(text)) > 2 else "uk"
    if lat / n >= share: return "en"
    return None


def target(text):
    """The other language for "translate": English for Ukrainian, Ukrainian otherwise."""
    return "en" if lang(text, 0.6) == "uk" else "uk"


def _count(rx, t): return Counter(x.rstrip(".,;:!?)") for x in rx.findall(t))


def kept(text, out, cmd):
    """Is `out` a rework of `text` worth showing?"""
    out, text = (out or "").strip(), (text or "").strip()
    if not out or out == text or out == "✓": return False
    if ct.RUSSIAN.search(out) and not ct.RUSSIAN.search(text): return False
    if cmd == "shorter" and len(out) >= 0.9 * len(text): return False
    if cmd != "custom" and not 0.2 <= len(out) / max(1, len(text)) <= 3.0: return False
    need, have = _count(TOKENS if cmd not in ("shorter", "custom") else LINKS, text), _count(TOKENS, out)
    return all(have[k] >= n for k, n in need.items())


def instruction(cmd, text, custom=""):
    if cmd == "custom": return custom.strip()[:400]
    if cmd == "translate": return COMMANDS[cmd].format(lang=NAMES[target(text)])
    return COMMANDS.get(cmd, "")


def _worker(model):
    with _lock:
        return get_or_create(_workers, model, ct.Worker, system, max_tokens=3000)


# idle processes are stopped by claude_type's one reaper (10 idle minutes, or at once when memory is low)


def warm(model="sonnet"):
    """Start the worker when the menu opens, so the first pick does not wait for the CLI to start."""
    if Path(ct.CLI).exists(): threading.Thread(target=_worker, args=(model,), daemon=True).start()


def rework(text, cmd, custom="", app="", model="sonnet", online=True, local=None, cancelled=lambda: False, notes="", hint=""):
    """-> {"text", "cmd", "by", "ms"} or {} (nothing kept). `notes`: his writing instructions (Settings > Typing), added
    to the Claude and the local prompt only when there are some."""
    notes = notes_text(notes)
    text = (text or "").strip("\n")
    if not text.strip() or len(text) > MAX_CHARS or (cmd not in COMMANDS and cmd != "custom"): return {}
    what = instruction(cmd, text, custom)
    if not what: return {}
    key = hashlib.sha1(json.dumps([text, cmd, what, model] + ([notes] if notes else []) + ([hint] if hint else [])).encode()).hexdigest()
    if key in _cache: return dict(_cache[key], cached=True)
    t0 = time.time()
    res = {}
    if online and Path(ct.CLI).exists():
        _stats["asked"] += 1
        user = (f"App: {app}\n\n" if app else "") + (hint + "\n" if hint else "") + (f"His writing instructions (follow them unless the task says otherwise): {notes}\n\n" if notes else "") + f"Task: {what}\n\nText:\n{text}"
        r = _worker(model).ask(user, cancelled, wait=1.0, deadline=20.0, whole=True)
        if r is not None:
            out = r[0].strip()
            if kept(text, out, cmd): res = {"text": out, "by": model}; _stats["kept"] += 1
            else: _stats["dropped"] += 1
    if not res and local:
        out = ((local(text, what, notes) if notes else local(text, what)) or "").strip()
        if kept(text, out, cmd): res = {"text": out, "by": "local"}; _stats["local"] += 1
    if res:
        res.update(cmd=cmd, ms=round((time.time() - t0) * 1000))
        if len(_cache) > 40: _cache.pop(next(iter(_cache)))
        _cache[key] = res
    return res


def stats(): return dict(_stats)


if __name__ == "__main__":
    c = sys.argv[1] if len(sys.argv) > 1 else "shorter"
    t = sys.argv[2] if len(sys.argv) > 2 else ("привіт, я подивився документи і там є кілька питань по оплаті, давай завтра о 15:00 "
                                               "зідзвонимось і пройдемось по них, бо я не впевнений що ми все правильно порахували")
    s = time.time()
    print(rework(t, c, custom=sys.argv[3] if len(sys.argv) > 3 else ""), f"{time.time() - s:.1f}s", stats())

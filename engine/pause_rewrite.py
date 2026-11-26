"""Pause rewrite (17 November 2026, the user's design; docs/research/2026-11-17-claude-writer.md "Build: the pause rewrite").

After a typing pause in a field that holds at least one finished sentence, the app sends the paragraph before the caret
(app/PauseRewrite.swift). Claude rewrites it the way the user would send it after one more read, through the ⌥Tab rework
path (engine/rework.py, command "polish") with the same context: the person card and the user's last lines for the chat on
screen (engine/whom.py), their writing notes and the keyboard language. The app shows the rewrite as a chip with the
changed words marked; Tab puts it in, Backspace right after takes it back. Nothing is sent and Return is never pressed.

Setting `pauseRewrite` (off, the cloud mark; engine/cloud.py). Under the daily Claude cap (`backOfficeCap`, USD):
one ledger with the voice cleanup (data/backoffice/spend.json, engine/voice_claude.py room/charge), so one cap counts
both. Not one Claude process with the voice cleanup: that one runs the call-notes
worker on its own prompt, this one the rework worker on rework's system prompt.

Model: Haiku. From the research numbers (bench/claude_writer, made-up lines): voice cleanup, the same shape of job
(rewrite 10-25 words keeping every fact), took 763 ms p50 on Haiku against 1,226 ms on Sonnet, fixed as many errors
(17 vs 16) and broke fewer words (3 vs 4; Opus 8). About 0.0002 USD a call: the default 0.50 USD cap allows ~2,000.
"""
import difflib, re, time
import sys
from pathlib import Path

import voice_claude as ledger   # the shared spend ledger and cap check (spend.json)

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(Path(__file__).resolve().parent))
from data_dir import data_dir  # noqa: E402
DATA = data_dir()
MODEL = "haiku"
MIN_WORDS = 6            # shorter than this there is little to rewrite and the chip would only cover the field
MAX_CHARS = 800          # the app's span (app/Proof.swift span): the paragraph before the caret, at most 800 characters
SIMILAR = 0.5            # a rewrite that keeps fewer than half the user's words is a new message, not their after one more read
PRICE = (0.10, 0.50)     # Haiku, USD per million tokens in / out (checked 2026-11-17)
PROMPT_CHARS = 2600      # the rework system prompt, the task line and the person block, roughly
FINISHED = re.compile(r"\S[.!?…](?=[\s\"'»”)]|$)")


def words(text): return len((text or "").split())


def ready(text):
    """'' when `text` is worth a rewrite, else why not: too short, no finished sentence yet, too long."""
    t = (text or "").strip()
    if words(t) < MIN_WORDS: return "short"
    if len(t) > MAX_CHARS: return "long"
    start = 0
    for m in FINISHED.finditer(t):           # a finished sentence of its own of 3+ words ("Ok. Fine. Sure." is not one)
        if words(t[start:m.end()]) >= 3: break
        start = m.end()
    else: return "no sentence"
    return ""


def u16(s): return len(s.encode("utf-16-le")) // 2


def marks(old, new):
    """The changed words in `new`, as [start, length] in UTF-16 units (the app's NSString ranges), neighbours merged."""
    a = [m.group() for m in re.finditer(r"\S+", old)]
    spans = [(m.start(), m.end()) for m in re.finditer(r"\S+", new)]
    b = [new[s:e] for s, e in spans]
    out = []
    for op, _, _, j1, j2 in difflib.SequenceMatcher(a=a, b=b, autojunk=False).get_opcodes():
        if op in ("replace", "insert") and j2 > j1:
            s, e = spans[j1][0], spans[j2 - 1][1]
            out.append([u16(new[:s]), u16(new[s:e])])
    return out


def similar(old, new):
    return difflib.SequenceMatcher(a=old.split(), b=new.split(), autojunk=False).ratio() >= SIMILAR


def estimate(text, extra=""):
    """USD for one call: the prompt (rework's system, task, the person block, the user's notes) in, about the text again out."""
    tin = (PROMPT_CHARS + len(extra) + len(text)) / 3.5
    tout = len(text) * 1.2 / 3.5
    return (tin * PRICE[0] + tout * PRICE[1]) / 1e6


def run(text, cap, ask, data=DATA, now=None, extra=""):
    """-> {"text", "marks", "usd", "ms", "by"} or {"skip": why}. `ask(text)` is the rework call (engine/server.py
    pause_rewrite: rework.rework(text, "polish", ...)); the caller has already checked the setting and the network."""
    text = (text or "").strip("\n")
    why = ready(text)
    if why: return {"skip": why}
    usd = estimate(text, extra)
    if not ledger.room(data, cap, usd, now): return {"skip": "cap"}
    t0 = time.time()
    r = ask(text) or {}
    if not r.get("cached"): ledger.charge(data, usd, now)
    new = (r.get("text") or "").strip()
    if not new or r.get("by") == "local": return {"skip": "none"}
    if new == text.strip() or not similar(text, new): return {"skip": "same" if new == text.strip() else "far"}
    return {"text": new, "marks": marks(text, new), "usd": round(usd, 6), "ms": r.get("ms", round((time.time() - t0) * 1000)),
            "by": r.get("by", MODEL)}

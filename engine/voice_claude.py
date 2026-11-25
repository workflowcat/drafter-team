"""Claude cleanup after a voice take (`voiceClaude`, off by default, 17 November 2026).

Parakeet's text goes into the field at once; then Claude Haiku edits it with context (names from engine/whom.py and
the chat's person card, the text on screen around the field, his writing note for the app, his mode's prompt) and the
app swaps it in place only if he has not typed since. Raw never comes here (the app does not ask). Offline, off, over
the cap, slow (DEADLINE) or a bad answer: '' and the app keeps Parakeet's text quietly.

Cost goes under the back office cap (`backOfficeCap`, USD a day): one shared ledger, data/backoffice/spend.json.
Pure functions here; server.voice_claude() asks claude_on("voice_claude") before anything is built.
"""
import json, re, threading, time
from datetime import datetime, timedelta
from pathlib import Path

DEADLINE = 2.4            # seconds for the Claude answer; the app gives up at 2.5 s and keeps Parakeet's text
MAX_TEXT = 1500           # a take longer than this stays as Parakeet wrote it (a long dictation is not a quick fix)
MAX_SCREEN = 800          # characters of the field's text before the caret
OUT_RATIO = (0.6, 1.6)    # the answer's length against the take's: outside, Claude rewrote more than it fixed
DEFAULT_CAP = 0.50        # engine/backoffice.py DEFAULT_CAP: the same cap, the same default
PRICE = (0.10, 0.50)      # Haiku, USD per million tokens (in, out); engine/backoffice.py PRICE["haiku"]
_lock = threading.Lock()


def tokens(text):
    return max(1, int(len(text) / 3.5))


def estimate(prompt, text):
    """USD for one call: the prompt in, about the take's size out (+40 tokens)."""
    return (tokens(prompt) * PRICE[0] + (tokens(text) + 40) * PRICE[1]) / 1e6


def build(text, level="clean", mode="", note="", hint="", screen="", names=()):
    """The one message to Claude. `hint`: whom.hint (keyboard line and the chat's person). Nothing else of his goes."""
    names = [n for n in names if isinstance(n, str) and n.strip()][:30]
    how = ("Fix only what speech recognition got wrong: names, terms, punctuation, capitals, obvious misheard words. "
           "Keep his words, order and language.") if level != "polished" else (
           "Make it read as written text: fix recognition errors, drop fillers and false starts, keep his meaning, "
           "language and tone. Do not add facts.")
    parts = ["You clean up one voice dictation before it stays in a text field. " + how,
             "Reply with the corrected text only: no quotes, no notes. If nothing needs fixing, reply with the text unchanged."]
    if mode.strip(): parts.append("His mode for this text: " + mode.strip()[:200])
    if note.strip(): parts.append("His note for this app: " + note.strip()[:300])
    if hint.strip(): parts.append(hint.strip())
    if names: parts.append("Names as they are spelled: " + ", ".join(names))
    if screen.strip(): parts.append("Text before it in the field (context only, do not repeat it):\n" + screen.strip()[-MAX_SCREEN:])
    parts.append("Dictation:\n" + text)
    return "\n".join(parts)


def accept(out, text):
    """Claude's answer as it may go in, or '' to keep Parakeet's text: empty, the same, a different length class,
    new line breaks the take did not have, or a reply that talks about the text instead of being it."""
    out = (out or "").strip().strip('"«»“”').strip()
    t = text.strip()
    if not out or not t or out == t: return ""
    r = len(out) / max(1, len(t))
    if not OUT_RATIO[0] <= r <= OUT_RATIO[1]: return ""
    if "\n" in out and "\n" not in t: return ""
    if re.match(r"(?i)^(here is|here's|sure|the corrected|corrected text|ось|виправлений)\b", out): return ""
    return out


def _day(now): return datetime.fromtimestamp(now).strftime("%Y-%m-%d")


def spent(data, now=None):
    try: d = json.loads((Path(data) / "backoffice" / "spend.json").read_text())
    except Exception: d = {}
    return float(d.get(_day(now or time.time()), 0.0)) if isinstance(d, dict) else 0.0


def room(data, cap, usd, now=None):
    """True while today's spend plus this call stays under the back office cap."""
    return spent(data, now) + usd <= float(cap)


def charge(data, usd, now=None):
    """Add this call to today's spend in the shared ledger (read just before the write, kept 60 days)."""
    now = now or time.time()
    p = Path(data) / "backoffice" / "spend.json"
    with _lock:
        try: d = json.loads(p.read_text())
        except Exception: d = {}
        if not isinstance(d, dict): d = {}
        day = _day(now)
        d[day] = round(float(d.get(day, 0.0)) + usd, 6)
        keep = (datetime.fromtimestamp(now) - timedelta(days=60)).strftime("%Y-%m-%d")
        d = {k: v for k, v in d.items() if k >= keep}
        p.parent.mkdir(parents=True, exist_ok=True)
        tmp = p.with_name(p.name + ".vc.tmp")
        tmp.write_text(json.dumps(d, ensure_ascii=False, indent=1)); tmp.replace(p)

"""Drafter engine: one warm model on localhost, used only by the Drafter menu-bar app.

    .venv/bin/python engine/server.py            # 127.0.0.1:8798
Env: DRAFTER_MODEL (hf repo), DRAFTER_CAP_GB (default 3.2), DRAFTER_PORT (8798).

POST /complete {before, app, title, context?, max_tokens?} -> {text, ms, more, src?, action?, ahead?} (ahead: worked out while the last one showed)
POST /accept   {text, before, app}       -> remembers what was taken (data/accepted.jsonl, local only)
POST /words    {text, lang?, kind?}       -> adds a word to data/words.json and re-warms the head
POST /outline  {text, call?}              -> {title, points, todos}: live outline of a long note or call
POST /note     {text, audio?}             -> long note: title, people and projects named, follow-ups; saved in data/notes
POST /rewrite  {text, instruction}         -> {text}: the selection rewritten (speak over a selection)
POST /voice/claude {text, level, mode, note, app, context, kb, names} -> {text}: Claude's cleanup of a voice take, or "" (voiceClaude)
POST /free     {from, to, minutes, title?, earliest?, latest?, count?} -> {slots: [{start, end, chip}]} from the user's calendars
POST /command  {text}                     -> up to 3 runnable options for a typed direction (⌃⌥Space)
POST /snippet  {key, text}                -> save a snippet (data/snippets.json)
POST /ask      {text}                     -> answer from the user's notes and takes (Claude Haiku), for the strip
POST /instant  {app, context}             -> {options}: three local one-line replies (yes, no, later) to their last message
POST /fields   {app, context}             -> {name, first name, company, last link to them}: from the name on the screen's last line, local
POST /chip     {before}                   -> {action?} for the line being typed (the app asks after a pause)
POST /prefill  {before, app, title, context}  -> reads it into the cache (on focus), no suggestion
POST /typed    {text, app, context?}      -> a line the user sent; kept in data/typed.jsonl (with the chat above) for the phrase memory and benches
POST /act      {id, fields}               -> runs an action; app-side ones (EventKit) go to the app via /pending
GET  /settings, POST /settings {paused?, skip?, actions_off?, model?, callNotes?, ...}   -> for local tools
POST /words/remove {text}
GET  /edits, POST /edits {heard, fixed, accept}   -> words the user changed after dictating; accepted ones join the dictionary
POST /sleep {secs}, POST /wake  -> text model off / on while a long call is read again (memory budget)
GET  /health                -> {ok, instance, model, ...}: the one route open without the token
GET  /models -> {models: [catalog entry + downloaded, download {state, pct}, speed, quality], current, recommended, why,
                 machine {total_gb, free_gb, budget_gb}, switching}   (model catalog, 2026-11-15)
POST /model {id}            -> {ok, current, error?, seconds}: unload the current model, load this one (live on a failure)
POST /models/download {id}  -> {state, pct}: the weights the user asked for, in their own process; /models/cancel {id} stops it

Only local programs (the app, local scripts) may call it, never a web page: a request with Origin or Sec-Fetch-*
headers, a Host other than 127.0.0.1/localhost, or a POST that is not application/json gets 403.
Every route but GET /health also needs the header X-Drafter-Token: the app makes a fresh token at each engine start
and passes it in DRAFTER_ENGINE_TOKEN (never argv, never logged); a run by hand makes its own. The active token is
kept in data/engine.token (0600) for local scripts. /health answers DRAFTER_ENGINE_INSTANCE so the app can tell its
own engine from another process on the port before it hands over an API key.
"""
import hmac, json, math, os, queue, re, secrets, shutil, subprocess, sys, threading, time, urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from collections import OrderedDict
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent
sys.path.insert(0, str(HERE)); sys.path.insert(0, str(ROOT))
import guard
CAP = float(os.environ.get("DRAFTER_CAP_GB", "3.6"))
guard.start(CAP)
from model import Model
import model as model_mod
import catalog
import cadence
from prompt import Builder
import prompt as prompt_mod
import dictionary
import actions
import memory
import edits
import snippets
import notes
import claude_worker
import cloud
import router
import words as words_mod
import idle_prompt as idle_mod
import instant as instant_mod
import know as know_mod
import gatecore
import fim
import claude_type
import whom
import voice_claude as vclaude
import promises as promises_mod
import local
import integrations
import provider
from chat_template import encode as chat_ids

REPO = os.environ.get("DRAFTER_MODEL", "mlx-community/Qwen3-1.7B-4bit")
FMT = os.environ.get("DRAFTER_FMT", "raw")
PORT = int(os.environ.get("DRAFTER_PORT", "8798"))
MAX_TOKENS = int(os.environ.get("DRAFTER_MAX_TOKENS", "8"))
MIN_P = float(os.environ.get("DRAFTER_MIN_P", "0.6"))
MAX_WORDS = int(os.environ.get("DRAFTER_MAX_WORDS", "3"))
DATA = Path(os.environ.get("DRAFTER_DATA") or ROOT / "data").resolve(); DATA.mkdir(parents=True, exist_ok=True)
# the shared secret every route but /health needs; popped so helper processes started from here never inherit it
TOKEN = os.environ.pop("DRAFTER_ENGINE_TOKEN", "") or secrets.token_hex(32)
INSTANCE = os.environ.get("DRAFTER_ENGINE_INSTANCE") or secrets.token_hex(16)
dictionary.ensure()   # the live dictionary lives in data/ since 2026-11-14 (moved once from dictionary/)
local.seed_snippets(DATA / "snippets.json")   # a new install only: never touches an existing file
cloud.migrate(DATA / "settings.json")        # once: an existing file keeps its Claude switches before the defaults went off

phrases = memory.Memory()
knowledge = know_mod.Pack(DATA / "know.json")
_entities = []


def entity_store():
    """data/entities.json, read again only when the file changed (engine/entities.py Store)."""
    if not _entities:
        import entities
        _entities.append(entities.Store(DATA / "entities.json"))
    return _entities[0]
finisher = words_mod.Words()
print(f"drafter engine: word finisher from {finisher.load()} lines, {finisher.export(DATA / 'mywords.txt')} known words", flush=True)
GATE_LOCK = threading.Lock()
GATE = {"g": gatecore.load(), "mtime": 0}
who = whom.Who(DATA / "names.json")   # the keyboard line for Claude and the screen-name smart fields (engine/whom.py)
promise_book = promises_mod.Book(DATA / "promises.json")   # promises in lines the user sent (engine/promises.py), local only
import journal_db
# typed, takes and clipboard JSONL copied row by row into data/journal.sqlite (engine/journal_db.py, phase 1 of the
# move to SQLite): the files stay as they are; started in __main__ only
JOURNAL = None


def promise_typed(req, text):
    """/typed: a sent line's promises join data/promises.json (learn on, never test rows)."""
    ctx = req.get("context") or ""
    if not settings_load().get("learn", True) or promises_mod.TEST in text or promises_mod.TEST in ctx: return
    found = promises_mod.detect(text)
    if not found: return
    promise_book.add(found, app=req.get("app", ""))


DEFAULTS = Path(__file__).resolve().parent / "defaults"


def fitted(name):
    """data/<name>, else the shipped default in engine/defaults/ (numbers only, fitted on the author's typing), so a
    new install has a gate and a selector before its own fit."""
    p = DATA / name
    return p if p.exists() or not (DEFAULTS / name).exists() else DEFAULTS / name


def gate_file():
    """The gate for the model loaded now (model catalog): live, or a model outside the catalog, uses data/gate.json;
    another catalog model its own fit (engine/defaults/gates/, bench/catalog_gates.py), else the shipped default."""
    e = globals().get("CURRENT", {}).get("entry")
    if e is None or e.get("gate", "live") == "live": return fitted("gate.json")
    m = globals().get("model")
    name = catalog.gate_name(globals().get("CATALOG", []), e, bool(getattr(m, "adapter", None)) if m is not None else True)
    if name == "live": return fitted("gate.json")
    p = DEFAULTS / name if name else None
    return p if p is not None and p.exists() else DEFAULTS / "gate.json"


def gate():
    """data/gate.json (bench/gate.py --save), read again when it changes; per model since the catalog (gate_file)."""
    with GATE_LOCK:
        p = gate_file()
        try: mt = p.stat().st_mtime
        except Exception: return None
        if (mt, p) != GATE["mtime"]: GATE["g"], GATE["mtime"] = gatecore.load(p), (mt, p)
        return GATE["g"]


JSONS = {}


def kept_json(name, names):
    """data/<name> read again when it changes; None when missing or made for other features."""
    with GATE_LOCK:
        p = fitted(name)
        try: mt = p.stat().st_mtime
        except Exception: return None
        old = JSONS.get(name)
        if not old or old[0] != mt or old[2] != p:
            try:
                w = json.loads(p.read_text())
                w = w if w.get("names") == names else None
            except Exception: w = None
            JSONS[name] = old = (mt, w, p)
        return old[1]


def wordgate():
    """data/wordgate.json (bench/wordgate.py --save): when the user's own finish of the word being typed answers first."""
    return kept_json("wordgate.json", gatecore.WORD_NAMES)


def selector():
    """data/selector.json (bench/selector.py --save): one chance per offer from memory, the user's word or the model."""
    s = kept_json("selector.json", gatecore.SEL_NAMES)
    return s if s and (s.get("wordgate") or {}).get("names") == gatecore.WORD_NAMES else None


def offers_now(sel, before, ai, mid):
    """The selector's instant offers (phrase memory, the user's word): the best (p, text, kind) that clears its bar, or None."""
    best, low = None, sel.get("min", {})
    said, hits = phrases.suggest(before)
    said = clean(before, said) if said else ""
    cands = []
    if said and gatecore.letters(said) >= int(low.get("memory", 5)):
        cands.append(("memory", said, {"mem_hits": math.log1p(hits or 1)}))
    if mid:
        c = finisher.candidate(before)
        f = gatecore.word_features(c, before, ai)
        if f and gatecore.letters(c["rest"]) >= int(low.get("words", 3)):
            cands.append(("words", c["rest"], {"word_p": gatecore.score(sel["wordgate"]["w"], f)}))
    for kind, text, f in cands:
        p = gatecore.score(sel["w"], gatecore.sel_features(kind, text, before, ai, **f))
        if p >= sel["th"] and (best is None or p > best[0]): best = (p, text, kind)
    return best


def word_first(before, ai):
    """The user's own word, when the word gate approves it (round four): the rest of the word, or ''."""
    wg = wordgate()
    if not wg: return ""
    c = finisher.candidate(before)
    f = gatecore.word_features(c, before, ai)
    if f is None or gatecore.score(wg["w"], f) < wg["th"] or gatecore.letters(c["rest"]) < int(wg.get("min_letters", 3)): return ""
    return c["rest"]


AI_APPS = ("claude", "chatgpt", "codex", "perplexity")
ADAPTER = os.environ.get("DRAFTER_ADAPTER") or None


def strength_setting(st=None):
    """Settings > Typing "Personal style" (parity round): 0-100 % of the user's layer, default 100."""
    if st is None:   # read here: settings_load() is defined further down, after the model loads
        try: st = json.loads((DATA / "settings.json").read_text())
        except Exception: st = {}
    try: return min(100, max(0, int(st.get("personalStrength", 100)))) / 100
    except (TypeError, ValueError, AttributeError): return 1.0


# Model catalog (2026-11-15, engine/catalog.py): the model the user picked in Settings > Typing > Model (settings
# "typingModel"), when its weights are here; DRAFTER_MODEL (benches) wins; else live. The user's layer: live's data/adapters,
# or an entry's own folder under data/layers/ (catalog.adapter_for; 16 November 2026), merged at Personal style.
CATALOG = catalog.load()
LIVE_ENTRY = catalog.entry(CATALOG, catalog.LIVE)
try: _st0 = json.loads((DATA / "settings.json").read_text())
except Exception: _st0 = {}
_pick, _why = catalog.start_pick(CATALOG, _st0, DATA, os.environ.get("DRAFTER_MODEL"))
CURRENT = {"entry": _pick}     # None: a repo from DRAFTER_MODEL that is not in the catalog (a bench run)
if _pick is not None and _pick["id"] != catalog.LIVE:
    REPO = _pick["repo"]
    guard._cap[0] = max(CAP, _pick["cap_gb"]); model_mod.set_limit(guard._cap[0])
    catalog.marker_path(DATA).parent.mkdir(parents=True, exist_ok=True)
    catalog.marker_path(DATA).write_text(json.dumps({"id": _pick["id"]}))   # the guard may stop this load: next start is live
    try:
        model = Model(REPO, catalog.adapter_for(_pick, ADAPTER, DATA), strength=strength_setting(), src=str(catalog.local_path(_pick)))
    except Exception as e:
        print(f"drafter engine: {_pick['id']} did not load ({type(e).__name__}), live instead", flush=True)
        REPO, CURRENT["entry"] = LIVE_ENTRY["repo"], LIVE_ENTRY
        guard._cap[0] = CAP; model_mod.set_limit(CAP)
        model = Model(REPO, ADAPTER, strength=strength_setting())
    catalog.marker_path(DATA).unlink(missing_ok=True)
else:
    model = Model(REPO, catalog.adapter_for(_pick, ADAPTER, DATA) if _pick else ADAPTER, strength=strength_setting())
builder = Builder(model, FMT)
model.warm(builder.head_ids)
model.pieces()
print(f"drafter engine: {REPO} ({(CURRENT['entry'] or {}).get('id', 'not in the catalog')}, {_why}) loaded in {model.load_s:.1f}s, head {len(builder.head_ids)} tokens, port {PORT}", flush=True)

# Cadence round (2026-11-17, engine/cadence.py): the fast model (the live 1.7B + the user's layer) beside the picked bigger
# one, loaded when a request asks for it (setting comboModels) and memory allows, dropped when the switch goes off, on
# sleep and on a model switch. Same worker, same queue: one model answers each key. Its own gate is live's.
FAST = {"m": None, "b": None, "loading": False, "used": 0, "loads": 0, "refused": 0, "gate": None, "mtime": None}


def fast_ready():
    return FAST["m"] is not None and not FAST["loading"] and not FAST["m"].asleep


def slot_for(req):
    """"fast" or "big" for this request (engine/cadence.py)."""
    return cadence.route(req, fast_ready(), ((globals().get("CURRENT") or {}).get("entry") or {}).get("id"))


def fast_gate():
    """data/gate.json (live's gate, fitted on the 1.7B), read again when it changes."""
    with GATE_LOCK:
        p = fitted("gate.json")
        try: mt = p.stat().st_mtime
        except Exception: return None
        if (mt, p) != FAST["mtime"]: FAST["gate"], FAST["mtime"] = gatecore.load(p), (mt, p)
        return FAST["gate"]


def fast_load(cancelled=None):
    """On the worker: load the fast slot when memory allows; the guard's cap grows by cadence.FAST_GB."""
    try:
        if FAST["m"] is not None or model.asleep or model.loading: return {"fast": FAST["m"] is not None}
        free = catalog.machine()["free_gb"]
        if free is not None and free < cadence.FAST_GB + catalog.MARGIN_GB:
            FAST["refused"] += 1; print(f"combo: not loaded, free {free} GB", flush=True); return {"fast": False}
        t = time.time()
        set_cap(guard._cap[0] + cadence.FAST_GB)
        try:
            m = Model(LIVE_ENTRY["repo"], catalog.adapter_for(LIVE_ENTRY, ADAPTER, DATA), strength=strength_setting())
            fb = Builder(m, FMT); m.warm(fb.head_ids); m.pieces()
        except Exception as e:
            set_cap(max(CAP, guard._cap[0] - cadence.FAST_GB))
            FAST["refused"] += 1; print(f"combo: fast model did not load ({type(e).__name__})", flush=True); return {"fast": False}
        FAST["m"], FAST["b"] = m, fb; FAST["loads"] += 1
        print(f"combo: fast model loaded in {time.time() - t:.1f} s, footprint {guard.footprint_gb():.2f} GB, cap {guard._cap[0]} GB", flush=True)
        return {"fast": True}
    finally:
        FAST["loading"] = False


def fast_drop(cancelled=None):
    """On the worker: the fast slot goes, the cap comes back."""
    m = FAST["m"]
    if m is None: return {"fast": False}
    FAST["m"] = FAST["b"] = None
    m.unload(); del m
    set_cap(max(CAP, guard._cap[0] - cadence.FAST_GB))
    print("combo: fast model dropped", flush=True)
    return {"fast": False}


def fast_tend(req):
    """A typing request: load the fast slot when combo is asked and missing, drop it when combo is off."""
    cur = ((globals().get("CURRENT") or {}).get("entry") or {}).get("id")
    if cadence.wanted(req, cur):
        if FAST["m"] is None and not FAST["loading"] and not model.asleep and not model.loading and FAST["refused"] < 3:
            FAST["loading"] = True
            # behind typing (low), never dropped as stale; loading clears even when the job never ran
            def go():
                try: run(fast_load, low=True, cancel=lambda: False, timeout=120)
                finally: FAST["loading"] = False
            threading.Thread(target=go, daemon=True).start()
    elif FAST["m"] is not None and not FAST["loading"] and "combo" in req:
        threading.Thread(target=lambda: run(fast_drop, newest=False, timeout=30), daemon=True).start()


# One worker owns the model. Only the newest request matters: older ones still waiting are answered empty,
# and a running one stops at the next token when a newer one arrives.
# one model, one worker: a typing request goes before look-ahead work already waiting (low), each kind in arrival
# order (round four cleanup, Codex review: the queue was plain FIFO)
jobs = queue.PriorityQueue()
JOB_ORDER = iter(range(1 << 62))
latest = [0]
LATEST_LOCK = threading.Lock()


def request_seq():
    with LATEST_LOCK:
        latest[0] += 1
        return latest[0]


def stale(seq):
    with LATEST_LOCK:
        return seq is not None and seq < latest[0]


# keep in flight (earlier round step 2): the typing request running now, and the ones a newer key let run on
RUNNING = [None]          # (seq, before, identity) while a typing request with keep_on runs
KEPT = set()
WRITTEN = {"seq": None, "text": ""}   # the running streamed answer's raw text so far (short-ghost round, gatecore.keeps)


def keep_running(req):
    """A new /complete: the running typing request runs on when this one only adds a few letters to its text
    (gatecore.keeps); both must have asked for it (setting keepTyping, sent as keep_on)."""
    r = RUNNING[0]
    if r is None or not req.get("keep_on"): return False
    # the same field and model too (Codex review 2026-11-16): the text after the caret, the mid-line state, the field,
    # and the model, adapter and strength the answer was asked of; a change in any of them stops the old answer
    if r[2] != keep_ident(req): return False
    written = WRITTEN["text"] if WRITTEN["seq"] == r[0] else ""
    if gatecore.keeps(r[1], normal_space(req.get("before") or "")[-4000:], written=written):
        KEPT.add(r[0])
        while len(KEPT) > 16: KEPT.discard(min(KEPT))
        return True
    return False


def keep_ident(req):
    """What must stay the same for a running answer to run on: the text after the caret, mid-line, the field, and
    the loaded model with its adapter and strength."""
    m = globals().get("model")
    return (normal_space(str(req.get("after") or ""))[:400], str(req.get("after_line") or ""), bool(req.get("mid")),
            req.get("field"), id(m), getattr(m, "repo", None), getattr(m, "adapter", None), getattr(m, "strength", None),
            ((globals().get("CURRENT") or {}).get("entry") or {}).get("id"),
            globals().get("slot_for", lambda r: "big")(req))


def worker():
    while True:
        _, _, seq, fn, box = jobs.get()
        gone = box.get("cancel") or (lambda: stale(seq) and seq not in KEPT)
        if gone():
            box["out"] = {"text": "", "stale": True}; box["done"].set(); continue
        if box.get("before") is not None: RUNNING[0] = (seq, box["before"], box.get("ident")); WRITTEN.update(seq=seq, text="")
        try:
            box["out"] = fn(gone)
        except Exception as e:  # never let one bad request kill the warm model
            box["out"] = {"error": str(e)}
        finally:
            RUNNING[0] = None; KEPT.discard(seq)
        box["done"].set()


threading.Thread(target=worker, daemon=True).start()


def orphan_watch():
    # the app owns the engine; when the app is gone, so is the engine (and its memory)
    parent = os.getppid()
    while True:
        time.sleep(2)
        if os.getppid() != parent: os._exit(0)


if os.environ.get("DRAFTER_OWNED", "1") == "1": threading.Thread(target=orphan_watch, daemon=True).start()


def run(fn, newest=True, timeout=10, low=False, seq=None, cancel=None, before=None, ident=None):
    if seq is None:
        if low:
            with LATEST_LOCK: seq = latest[0]
        elif newest:
            seq = request_seq()
    # None is uncancellable; zero is a valid startup look-ahead generation.
    box = {"done": threading.Event()}
    if cancel is not None: box["cancel"] = cancel
    if before is not None: box["before"] = before; box["ident"] = ident
    jobs.put((1 if low else 0, next(JOB_ORDER), seq, fn, box))
    box["done"].wait(timeout)
    return box.get("out", {"error": "timeout"})


def ask(prompt, max_tokens=90, cancelled=lambda: False):
    """Field extraction for actions: a chat turn, greedy, stops at the closing brace."""
    msgs = [{"role": "user", "content": prompt}]
    ids = chat_ids(model, msgs)
    out = model.oneshot(ids, max_tokens=max_tokens, stop=re.compile(r"\}\s*$"), cancelled=cancelled)
    if (DATA / "debug").exists(): print("ask:", repr(out[:300]), flush=True)
    return out


SETTINGS_LOCK = threading.Lock()
SETTINGS_CACHE = {"key": None, "val": {}}


def settings_load():
    """data/settings.json, cached by (path, inode, mtime_ns, size); returns a fresh copy so callers may mutate it."""
    p = DATA / "settings.json"
    try:
        st = p.stat()
        key = (str(p), st.st_ino, st.st_mtime_ns, st.st_size)
    except OSError:
        return {}
    with SETTINGS_LOCK:
        if SETTINGS_CACHE["key"] == key:
            return dict(SETTINGS_CACHE["val"])
    try:
        val = json.loads(p.read_text())
        if not isinstance(val, dict): val = {}
    except Exception:
        return {}
    with SETTINGS_LOCK:
        SETTINGS_CACHE["key"], SETTINGS_CACHE["val"] = key, val
        return dict(val)


def refresh_cli():
    """After "Connect a model" picks or drops the claude CLI: every place that starts it sees the new path."""
    path = (integrations.claude_bin() if integrations.available("claude") else "") or "/nonexistent/claude"
    claude_type.CLI = path; claude_worker.CMD[0] = path; notes.CLAUDE = path
    if "_claude" in sys.modules: sys.modules["_claude"].CLAUDE = path


def claude_on(feature, st=None):
    """The one check before the engine sends the user's text to a Claude worker: the setting that owns `feature` is on
    (engine/cloud.py) and the Mac is online. tests/test_cloud_gate.py fails on a Claude call site that skips it."""
    return cloud.allowed(feature, settings_load() if st is None else st) and router.online()


def clean(before, text):
    """Keep a suggestion only if it adds something and does not repeat the line just typed."""
    if not text.strip(): return ""
    text = re.sub(r"[ \t]{2,}", " ", text)                 # never two spaces in a row
    if before.endswith((" ", "\n")): text = text.lstrip(" ")
    text = re.split(r"###|\[", text)[0]
    text = text.rstrip("\n")
    last = before.splitlines()[-1] if before.splitlines() else ""
    m = re.search(r"\d{3,}", text)
    if m and not re.search(r"\d", last): text = text[: m.start()].rstrip()   # made-up numbers ("invoice 1234567")
    if len(text.strip()) >= 4 and text.strip() in last: return ""
    return text


def rewrite(req):
    """Speak over a selection (idea 1; voice edit round, 17 November 2026: Wispr's command mode): the selected text
    rewritten as the spoken instruction says. Local model only: Claude is not at the caret any more. `names`: names on
    screen and in the user's dictionary, for "fix the names"."""
    text, instr = (req.get("text") or "")[:3000], (req.get("instruction") or "")[:900]   # 900: a voice mode's prompt and the user's app note (VoiceModeRules.instruction)
    if not text.strip() or not instr.strip(): return {"text": ""}
    names = [n for n in (req.get("names") or []) if isinstance(n, str)][:30]
    known = ("Імена, як вони пишуться / names as they are spelled: " + ", ".join(names) + "\n") if names else ""
    prompt = ("Перепиши текст за вказівкою. Відповідай лише новим текстом, без пояснень і без лапок. Мова та сама, що в "
              "тексті, якщо вказівка не каже інакше. Rewrite the text as the instruction says; reply with the new text only.\n"
              f"Вказівка / instruction: {instr}\n{known}\nТекст / text:\n{text}")
    msgs = [{"role": "user", "content": prompt}]
    ids = chat_ids(model, msgs)
    n = min(600, int(len(model.tok.encode(text)) * 2) + 40)

    def job(cancelled):
        t = time.perf_counter()
        out = model.oneshot(ids, max_tokens=n)
        out = out.strip().strip('"«»').strip()
        return {"text": out, "ms": round((time.perf_counter() - t) * 1000), "by": "local"}
    return run(job, newest=False, timeout=30)


def voice_claude(req):
    """Claude cleans a voice take that already went in (Clean or Polished; Raw never asks). '' keeps Parakeet's text:
    off, offline, over the daily Claude cap, slower than vclaude.DEADLINE or a bad answer. engine/voice_claude.py."""
    st = settings_load()
    if not claude_on("voice_claude", st): return {"text": "", "why": "off"}
    text = str(req.get("text") or "").strip()
    level = str(req.get("level") or "clean")
    if not text or level == "raw" or len(text) > vclaude.MAX_TEXT: return {"text": "", "why": "skip"}
    prompt = vclaude.build(text, level, str(req.get("mode") or ""), str(req.get("note") or ""), who.hint(req, "voice"),
                           str(req.get("context") or ""), req.get("names") or ())
    usd = vclaude.estimate(prompt, text)
    cap = float(st.get("backOfficeCap") or vclaude.DEFAULT_CAP)
    if not vclaude.room(DATA, cap, usd): return {"text": "", "why": "cap"}
    t = time.perf_counter()
    out = claude_worker.ask(prompt, vclaude.DEADLINE) or ""
    ms = round((time.perf_counter() - t) * 1000)
    if out: vclaude.charge(DATA, usd)
    return {"text": vclaude.accept(out, text), "ms": ms, "by": "claude", "why": "" if out else "slow"}


def outline(req):
    """Live outline of a long note or a call still running (Granola-style): a title, main points, to-dos with names.
    Claude Haiku when `callNotes` is on and online (engine/cloud.py), else the base model (the user's-writing layer off); the newest
    ~6,000 characters."""
    text = (req.get("text") or "")[-6000:]
    if len(text.split()) < 12: return {}
    kind = "розмови (дзвінка)" if req.get("call") else "нотатки"
    prompt = (f"Ось текст {kind}, який ще триває. Мовою тексту дай JSON з ключами: title (3-7 слів), points (до 5 "
              "головних пунктів, до 12 слів кожен), todos (до 4 справ: хто що робить). Лише JSON.\nТекст:\n" + text)
    msgs = [{"role": "user", "content": prompt}]
    ids = chat_ids(model, msgs)

    def job(cancelled):
        t = time.perf_counter()
        out = model.oneshot(ids, max_tokens=320)
        m = re.search(r"\{.*\}", out, re.S)
        try: d = json.loads(m.group(0)) if m else {}
        except Exception: d = {}
        return {"title": str(d.get("title") or "")[:80], "points": [str(x)[:120] for x in (d.get("points") or [])][:5],
                "todos": [str(x)[:120] for x in (d.get("todos") or [])][:4], "ms": round((time.perf_counter() - t) * 1000), "by": "local"}
    if claude_on("call_notes"):
        t = time.perf_counter()
        out = claude_worker.ask(prompt, 30) or ""
        m = re.search(r"\{.*\}", out, re.S)
        try:
            d = json.loads(m.group(0)) if m else None
            if d: return {"title": str(d.get("title") or "")[:80], "points": [str(x)[:120] for x in (d.get("points") or [])][:5],
                          "todos": [str(x)[:120] for x in (d.get("todos") or [])][:4], "ms": round((time.perf_counter() - t) * 1000), "by": "haiku"}
        except Exception: pass
    return run(job, newest=False, timeout=60)


INSTANT_CACHE = OrderedDict()
TYPED = [0]      # /complete requests for a typed key (not the idle ghost)


def instant(req):
    """Instant replies (engine/instant.py): an empty chat or mail box whose last message is theirs gets three one-line
    replies - yes, no, later or a question - from the local model (base, the user's-writing layer off), in the language of
    that message. Nothing leaves the Mac; nothing is typed (the app shows a card, ⌥1-3 or Tab put one in).
    Setting `instantReplies` (on by default). Same screen -> the same answer from the cache."""
    st = settings_load()
    if not st.get("instantReplies", True): return {"options": [], "src": "off"}
    ctx = (req.get("context") or "")[-2500:]
    theirs, last = instant_mod.last_theirs(ctx)
    if not theirs: return {"options": [], "why": "not theirs"}
    key = ctx[-1200:]
    if key in INSTANT_CACHE: return {**INSTANT_CACHE[key], "cached": True}
    if model.asleep or model.loading: return {"options": [], "why": "model"}
    app = str(req.get("app") or "")[:40]
    ids = chat_ids(model, instant_mod.messages(ctx, app, "", "", local.short_name()))
    t = time.perf_counter()
    start = TYPED[0]
    stop = lambda: TYPED[0] != start
    r = run(lambda cancelled: {"raw": model.oneshot(ids, max_tokens=140, stop=re.compile(r"\n\s*L\s*:[^\n]{3,}\n"), cancelled=stop)},
            newest=False, timeout=25, low=True, cancel=stop)
    raw = (r or {}).get("raw", "")
    opts = instant_mod.parse(raw, instant_mod.lang(last))
    out = {"options": opts, "text": opts[0]["text"] if opts else "", "ms": round((time.perf_counter() - t) * 1000), "src": "local"}
    if opts:
        INSTANT_CACHE[key] = out
        while len(INSTANT_CACHE) > 40: INSTANT_CACHE.popitem(last=False)
    return out


def chip(req):
    """Only the chip for the line being typed, or nothing. Asked by the app after a pause in typing."""
    if model.asleep or model.loading: return {}
    before = (req.get("before") or "")[-800:]
    act = actions.detect(before)
    if not act: return {}

    def job(cancelled):
        if model.asleep or model.loading: return {}
        t = time.perf_counter()
        found = actions.cached(act, before, lambda p, max_tokens=90: ask(p, max_tokens, cancelled))
        return {"action": found, "ms": round((time.perf_counter() - t) * 1000)} if found else {}
    return run(job)


BEFORE_CHARS = int(os.environ.get("DRAFTER_BEFORE_CHARS", "800"))
CTX_CHARS = int(os.environ.get("DRAFTER_CTX_CHARS", "1000"))
WINDOWS_LOCK = threading.Lock()
WINDOWS = {}   # (app, title, part) -> the first characters of the window used last time


def window(key, text, size, remember=True):
    """The last `size` characters of `text`, with a start that stays put while the text only grows at the end (a new
    message came in, the user typed on), so the prompt cache keeps all before it. It jumps forward when the window gets half
    again as long (2026-11-01: a shifting window made the engine read the whole chat again, 230-360 ms on one key)."""
    with WINDOWS_LOCK:
        if len(text) <= size: return text
        a = WINDOWS.get(key)
        if a:
            # the place of the anchor nearest to where the window started last time, inside the allowed 1.5 x (Codex
            # round 4: the last place of a repeated anchor cut the window to a sliver and the prompt changed every key)
            anchor, was = a
            # Speculation keeps the current anchor even beyond the jump threshold;
            # only a real key advances it, so the next unaccepted key reuses its prefix.
            lo, best, i = (max(0, len(text) - int(size * 1.5)) if remember else 0), -1, -1
            while True:
                i = text.find(anchor, i + 1 if i >= 0 else lo)
                if i < 0: break
                if best < 0 or abs(i - was) < abs(best - was): best = i
            if best >= 0:
                if remember: WINDOWS[key] = (anchor, best)
                return text[best:]
        w = text[-size:]
        nl = w.find("\n")
        if 0 <= nl < size // 4: w = w[nl + 1:]                 # start at a line, else at a word
        elif 0 <= w.find(" ") < 40: w = w[w.find(" ") + 1:]
        if remember:
            WINDOWS.pop(key, None); WINDOWS[key] = (w[:48], len(text) - len(w))
            while len(WINDOWS) > 200: WINDOWS.pop(next(iter(WINDOWS)))
        return w


def parts(req, remember=True):
    """(before, app, title, context, screen) as every local prompt reads them, so /prefill, /complete and the
    Claude gate's scoring build the same prompt and share one warm cache per screen."""
    app, title = req.get("app", ""), (req.get("title") or "")[:80]
    before = window((app, title, "before"), normal_space(req.get("before") or ""), int(req.get("before_chars") or BEFORE_CHARS), remember=remember)
    context = window((app, title, "ctx"), normal_space(req.get("context") or "").strip(), int(req.get("ctx_chars") or CTX_CHARS), remember=remember)
    return before, app, title, context, f"{app} · {title}"
def extras(req):
    """(clip, notes) a request carries for the local prompt (parity round): the fresh copy the app judged safe
    (prompt.clip_text checks again) and the user's writing instructions for this app. Empty = the prompt as before."""
    return str(req.get("clip") or "")[:2000], str(req.get("notes") or "")[:600]


def mid_line(req):
    """(after, after_line) for a mid-line ask (the app's setting midLine: `mid`, `after`, `after_line`), else ("", ""):
    the text after the caret goes into the prompt (prompt.MID_FORM) and the ghost must fit before `after_line`
    (engine/fim.py). A request without `mid` reads exactly as before."""
    line = str(req.get("after_line") or "")[:120] if req.get("mid") else ""
    if not line.strip(): return "", ""
    return str(req.get("after") or line)[:prompt_mod.MID_CHARS], line


def mid_result(req, res):
    """A mid-line answer from any source (memory, the user's word, the model): one line that fits before the rest of the
    line, never repeating it (engine/fim.py cut); no lighter tail, no "more"."""
    _, line = mid_line(req)
    if not line or not isinstance(res, dict) or not res.get("text"): return res
    text = fim.cut(res["text"], line)
    if res.get("replace"): return res     # a "→ word" fix: the app drops it mid-line
    out = dict(res, text=text, more=False)
    if not text or not text.endswith(out.get("unsure") or "\x00"): out.pop("unsure", None)
    return out


BUILDERS_LOCK = threading.Lock()
builders = {FMT: builder}


def builder_for(fmt):
    """Test switch (bench/replay.py): another prompt shape on the same model, built and warmed on first use."""
    with BUILDERS_LOCK:
        if fmt not in builders:
            builders[fmt] = Builder(model, fmt)
        return builders[fmt]


AHEAD, AHEAD_LOCK, AHEAD_TTL = OrderedDict(), threading.Lock(), 30.0
AHEAD_STATS = {"made": 0, "hit": 0}
AHEAD_KIND = {}   # key -> "next" (the rest after the user takes the ghost) or "branch" (a next letter), for the day counts


def ahead_stats():
    with AHEAD_LOCK: return dict(AHEAD_STATS)


# Look-ahead per day (2026-11-14, efficiency round two; accounting only): data/ahead-days.json, local day ->
# {asked, started, made, used, next_made, next_used, branch_made, branch_used}. asked = typing requests (round five). started = model runs begun for look-ahead
# (a newer key may stop one), made = answers kept, used = answers a later request took. Written at most once a
# minute; the typing track reads it to cut what rarely hits.
AHEAD_DAYS_FILE = DATA / "ahead-days.json"
_ahead_days, _ahead_saved = None, [0.0]


def ahead_count(**add):
    """Under AHEAD_LOCK: add to today's counts; save now and then."""
    global _ahead_days
    if _ahead_days is None:
        try: _ahead_days = json.loads(AHEAD_DAYS_FILE.read_text())
        except Exception: _ahead_days = {}
    day = _ahead_days.setdefault(time.strftime("%Y-%m-%d"), {})
    for k, v in add.items(): day[k] = day.get(k, 0) + v
    if time.time() - _ahead_saved[0] > 60:
        _ahead_saved[0] = time.time()
        for old in sorted(_ahead_days)[:-60]: _ahead_days.pop(old)   # two months
        try:
            tmp = AHEAD_DAYS_FILE.with_suffix(".tmp"); tmp.write_text(json.dumps(_ahead_days, indent=1, sort_keys=True)); tmp.replace(AHEAD_DAYS_FILE)
        except OSError: pass


def normal_space(text):
    """Chromium represents typed spaces as NBSP; use one form for prompts and keys."""
    return text.replace("\u00a0", " ")


def ahead_key(req, pack=None):
    """What makes two suggestion requests the same one (the text before the caret, the screen and the settings; not
    the text after the caret, context provenance, streaming transport, keystroke cadence gap_ms, or Claude flags)."""
    if pack is None: pack = knowledge.snapshot()
    rest = {k: v for k, v in req.items() if k not in ("before", "early", "after", "field", "ahead", "context_fresh", "gap_ms", "stream")}
    rest["_know_stamp"] = pack.stamp
    if "context" in rest: rest["context"] = normal_space(rest["context"] or "")
    return normal_space(req.get("before") or "")[-4000:] + "\x00" + json.dumps(rest, sort_keys=True, ensure_ascii=False)


BRANCHES = int(os.environ.get("DRAFTER_BRANCHES", "2"))
# Futures (long round, 2026-11-14, the user: "run like parallel realities ... so that the model watches a few ideas about
# what might be coming"): after the shown ghost, the gap before the user's next key prepares the answers for up to FUTURES
# other next letters, the likeliest first (the model's own next word, the other likely starts in its first-step
# distribution, the user's own next words), each run to the same sentence length. How many fit is read from the user's own key
# gaps and the engine's own answer time (futures_k); none on a low battery or near the memory cap.
# Cap 2: replay of the held set with the user's 1,443 key gaps (bench/long_ghosts.py futures): answered at 0 ms or joined
# K 0 3% · K 1 31% · K 2 38% · K 3 39% · K 4 39%; K 3-4 cost 0.6 more prepared tokens per ask for about one point.
FUTURES = int(os.environ.get("DRAFTER_FUTURES", "2"))
GAPS, COSTS = [], []          # ms between the user's typing requests (under 1.5 s), ms per prepared answer: the last 200 of each
FUT_INDEX = OrderedDict()     # ahead_key of a shown request -> [(letter, ahead_key of its future)], for /futures
WANT = [""]                   # ahead_key of the newest typing request: a look-ahead for exactly it is not cancelled
INFLIGHT = {}                 # ahead_key -> Event while a look-ahead for it runs (the request for it waits instead)
LAST_ASK = [0.0]
POWER = {"low": False, "at": 0.0}


def note_gap():
    now = time.time()
    if LAST_ASK[0] and now - LAST_ASK[0] < 1.5: GAPS.append((now - LAST_ASK[0]) * 1000); del GAPS[:-200]
    LAST_ASK[0] = now


def power_low():
    """On battery under 30 %: no futures (checked once a minute; `pmset` is cheap but not free)."""
    if time.time() - POWER["at"] > 60:
        POWER["at"] = time.time()
        try:
            out = subprocess.run(["pmset", "-g", "batt"], capture_output=True, text=True, timeout=2).stdout
            m = re.search(r"(\d+)%", out)
            POWER["low"] = "discharging" in out and bool(m) and int(m.group(1)) < 30
        except Exception: POWER["low"] = False
    return POWER["low"]


def futures_k(cap=None):
    """How many futures fit in the user's usual gap: the median gap less the look-ahead for the shown ghost, over the median
    answer time; between 1 and FUTURES (2 before any numbers), 0 on a low battery or near the memory cap."""
    cap = FUTURES if cap is None else cap
    if cap <= 0 or power_low(): return 0
    try:
        cap_now = getattr(globals().get("guard"), "_cap", [float(os.environ.get("DRAFTER_CAP_GB", "3.6"))])[0]   # the loaded model's cap
        if model.memory_gb()[0] > cap_now * 0.85: return 0
    except Exception: pass
    if len(GAPS) < 20 or len(COSTS) < 10: return min(cap, BRANCHES)
    gap, cost = sorted(GAPS)[len(GAPS) // 2], max(5.0, sorted(COSTS)[len(COSTS) // 2])
    return max(1, min(cap, int((gap - cost) // cost)))


def branch_letters(before, raw, ghost, n=BRANCHES, alts=()):
    """The next letter of the word branches (round four, bench/branches.py; long round: more of them): the model's own
    next word (what it wrote, shown or not), the other likely starts of the model's first step (`alts`), the user's own
    likely next words (Words.dist); none that the shown ghost already starts with (typing it keeps the ghost)."""
    out = []
    t = raw.lstrip(" ") if before.endswith((" ", "\n")) else (raw or "")
    if t[:1].strip(): out.append(t[0])
    mine = []
    try: mine = [rest[0] for rest, _ in finisher.dist(before, 3) if rest[:1]]
    except Exception: pass
    for ch in [x for pair in zip(list(alts) + [""] * len(mine), mine + [""] * len(alts)) for x in pair]:
        if ch and ch not in out: out.append(ch)
    return [c for c in out if not (ghost and ghost.startswith(c))][:n]


def look_ahead(req, text, seq=None, raw="", alts=()):
    """A suggestion went out: the one for when the user takes it (Tab, or types it through) is worked out now, behind any
    newer key (which stops it), so Tab, Tab, Tab never waits for the model (2026-11-01). Then, in the same gap, the
    answers for the next letter of two word branches (round four): when the user's key is one of them, the answer is ready
    (bench/branches.py: in chats 75% of new ghosts ready, in AI apps 43-48%, against 1-2% before)."""
    before = req.get("before") or ""
    next_req = {k: v for k, v in req.items() if k != "gap_ms"}
    todo = ([dict(next_req, before=(before + text)[-4000:], ahead=False, early=False)] if text else [])
    k = futures_k(int(req["futures"]) if req.get("futures") is not None else None)
    letters = branch_letters(before, raw, text, k, alts) if req.get("branches", True) and k and not re.search(r"[\n]$", before) else []
    # from next_req (no gap_ms) too: ahead_key ignores gap_ms, so a fast-model branch answer must not be served to a slow key
    todo += [dict(next_req, before=(before + ch)[-4000:], ahead=False, early=False) for ch in letters]
    if not todo: return
    base = ahead_key(req)
    with AHEAD_LOCK:
        FUT_INDEX[base] = [(ch, ahead_key(t)) for ch, t in zip(letters, todo[1 if text else 0:])]
        while len(FUT_INDEX) > 16: FUT_INDEX.popitem(last=False)

    if seq is None:
        with LATEST_LOCK: seq = latest[0]

    def go():
        for k, nxt in enumerate(todo):
            if stale(seq): return
            key = ahead_key(nxt)
            kind = "branch" if k or not text else "next"
            with AHEAD_LOCK: ahead_count(started=1)
            ev = INFLIGHT[key] = threading.Event()
            t0 = time.perf_counter()
            try:
                # long round: a newer key for exactly this text does not stop it (the request waits for it instead);
                # before, the very answer the user was about to need was cancelled at their key and worked out again
                res = complete(nxt, low=True, seq=seq, keep=key)
            finally:
                INFLIGHT.pop(key, None)
            res.pop("next", None); res.pop("alts", None)
            if not res.get("stale"): COSTS.append((time.perf_counter() - t0) * 1000); del COSTS[:-200]
            if key != ahead_key(nxt): ev.set(); return  # pack changed while the model was working
            with LATEST_LOCK:
                # kept even when a newer key came meanwhile (it is the exact answer for its text; before, a branch that
                # ended a moment after the user's key was thrown away)
                if res.get("stale") or res.get("error"): ev.set(); return
                with AHEAD_LOCK:
                    AHEAD[key] = (time.time(), res); AHEAD_STATS["made"] += 1
                    if k or not text: AHEAD_STATS["branch"] = AHEAD_STATS.get("branch", 0) + 1
                    AHEAD_KIND[key] = kind; ahead_count(made=1, **{kind + "_made": 1})
                    while len(AHEAD) > 12: AHEAD_KIND.pop(AHEAD.popitem(last=False)[0], None)
            ev.set()
    threading.Thread(target=go, daemon=True, name="ahead").start()


def complete(req, low=False, seq=None, on_part=None, keep=None):
    """/complete: a suggestion worked out ahead (look_ahead) when the user took the last one, else _complete; every
    suggestion with text then starts the next one ahead."""
    # mid-line (engine/fim.py): every answer, the ones worked out ahead too, is cut to fit before the rest of the line
    if low and req.get("mid"): return mid_result(req, _complete(req, low=True, seq=seq, **({"keep": keep} if keep else {})))
    if low: return _complete(req, low=True, seq=seq, **({"keep": keep} if keep else {}))
    if seq is None: seq = request_seq()  # before any cache, snippet or word-only return
    globals().get("fast_tend", lambda r: None)(req)
    pack = knowledge.snapshot()
    if req.get("ahead", True):
        note_gap()
        hk = ahead_key(req, pack)
        ev = INFLIGHT.get(hk)
        if ev is not None and ev.wait(0.6):
            with AHEAD_LOCK: ahead_count(joined=1)   # long round: answered by the look-ahead already running for it
        with AHEAD_LOCK:
            ahead_count(asked=1)   # round five: typing requests, so used/asked is the share of keys answered at once
            hit = AHEAD.pop(hk, None); kind = AHEAD_KIND.pop(hk, "next")
            if hit and time.time() - hit[0] < AHEAD_TTL: AHEAD_STATS["hit"] += 1; ahead_count(used=1, **{kind + "_used": 1})
        if hit and time.time() - hit[0] < AHEAD_TTL:
            res = dict(hit[1], ahead=True, ms=0)
            raw = res.pop("next", ""); alts = res.pop("alts", ())
            if not res.get("action") and not res.get("replace"): look_ahead(req, res.get("text", ""), seq, raw, alts)
            return res
    res = _complete(req, seq=seq, pack=pack, **({"on_part": on_part} if on_part and not req.get("mid") else {}))
    if req.get("mid"): res = mid_result(req, res)
    raw = res.pop("next", ""); alts = res.pop("alts", ())
    if (req.get("ahead", True) and not res.get("action") and not res.get("replace") and not res.get("src") == "snippet"
            and not res.get("stale") and not res.get("error") and not model.asleep and not model.loading):
        look_ahead(req, res.get("text", ""), seq, raw, alts)
    return res


def futures(req):
    """/futures (long round): the answers prepared for the other next letters after the ghost asked with this very
    request, as other ideas for the same spot: [{"letter", "text", "unsure"}], nothing computed here."""
    with AHEAD_LOCK:
        out = []
        for ch, key in FUT_INDEX.get(ahead_key(req), []):
            hit = AHEAD.get(key)
            if hit and time.time() - hit[0] < AHEAD_TTL and hit[1].get("text") and not hit[1].get("action") and not hit[1].get("replace"):
                out.append({"letter": ch, "text": hit[1]["text"], "unsure": hit[1].get("unsure", "")})
        return {"futures": out, "k": futures_k()}


# Short ghosts (2026-11-13, app.log 6-13 November: under 5 letters the user took 3%, 5-9 letters 30%; bench/lengths.py):
# the app sends min_letters (setting minGhost); a gated suggestion that adds fewer letters goes on past its sure words
# while each token stays >= GROW, up to GROW_WORDS words, and what is still short is not offered.
# Held set (137 lines after the 8 November cutoff), letters saved by ghosts of 5+ letters, AI apps / chats:
# hide only 16.3% / 8.1%, grow 0.2 23.4% / 9.4%, grow 0.05 30.9% / 16.6%, grow 0 31.8% / 16.6% (live today 16.2% / 8.1%).
GROW = float(os.environ.get("DRAFTER_GROW", "0.05"))
GROW_WORDS = int(os.environ.get("DRAFTER_GROW_WORDS", "6"))


def short(req, text):
    n = int(req.get("min_letters") or 0)
    return bool(n) and bool(text) and gatecore.letters(text) < n


# ghost p90 round (2026-11-17, docs/rounds/2026-11-17-ghostp90.md): the idle ghost and look-ahead read their prompt in
# chunks of this many tokens and stop between chunks when a key comes; a typing request keeps one 512 chunk
YIELD_STEP = int(os.environ.get("DRAFTER_YIELD_STEP", "64"))
IDLE_SCREEN = "· idle chat ·"     # one cache slot for every screen's idle chat prompt


def idle_ids(form, b, app, context):
    """(ids, heal, stable) for the idle ghost in an empty box (engine/idle_prompt.py): "turns" after the typing head, "chat" in
    the model's chat template. Nothing the user types is in it, so all but the last token stays put per screen."""
    if form == "chat":
        ids, heal = chat_ids(model, idle_mod.chat_messages(context, app, "", "", local.short_name())), ""
    else:
        t = idle_mod.turns_tail(context, app, "", "")
        heal = re.search(r"[ \t]*$", t).group(0)
        ids = b.head_ids + model.encode(t[: len(t) - len(heal)])
    return ids, heal, max(0, len(ids) - 1)


def _complete(req, low=False, seq=None, pack=None, on_part=None, keep=None):
    before, app, title, context, screen = parts(req, remember=not low)
    # the idle ghost (step 7): the caret rests in a chat box, empty or after a finished sentence; local model only
    idle = bool(req.get("idle"))
    if idle and (req.get("mid") or not gatecore.idle_spot(before)): return {"text": "", "src": "idle", "skipped": True, "ms": 0}
    idle_form = None
    if idle:
        # step 7b: an empty box gets a reply-shaped prompt (engine/idle_prompt.py); after a sentence, the typing prompt
        idle_form = idle_mod.form_for(req) if not before.strip() else "screen"
        # the chat form shares no start with the typing prompt: its own parked cache, so the user's first key after it does
        # not read the typing head again (bench/idle.py: 1.7-2.1 s once, on the shared cache)
        if idle_form == "chat": screen = IDLE_SCREEN
    after, after_line = mid_line(req) if req.get("mid") else ("", "")
    b = builder_for(req.get("fmt") or FMT)
    bars = tuple(req["bars"]) if req.get("bars") else None
    # chips: the Drafter app asks for them separately (/chip, after a pause) so typing never waits for a chip read;
    # other local callers still get them here
    chips = req.get("chips", True)
    # a quick insert: ";m" -> the user's email, "my email is" -> the same (engine/snippets.py), before anything else
    snip = snippets.offer(before)
    if snip:
        return {"text": "", "action": snip, "src": "snippet", "ms": 0}
    sel = selector() if req.get("selector", True) and req.get("gate", True) else None
    if sel:   # more-bold round (2026-11-17): the user's Bolder / Careful setting moves the selector's bar with the guess bar
        sel = dict(sel, th=gatecore.bolder_sel(sel["th"], gatecore.guess_bar(gate(), "live", os.environ.get("DRAFTER_GUESS"), req.get("guess_bar"))))
    if req.get("memory", True) and not sel:
        # the user's own phrase, said before: answer at once, the model is not asked (bench/memory_eval.py)
        t = time.perf_counter()
        said, hits = phrases.suggest(before)
        if said and not short(req, clean(before, said)) and not (chips and actions.detect(before)):
            return {"text": clean(before, said), "more": False, "src": "memory", "hits": hits,
                    "ms": round((time.perf_counter() - t) * 1000, 1)}

    line = before.split("\n")[-1]
    mid = bool(re.search(r"[\w'’-]$", line))
    g = gate() if req.get("gate", True) else None
    ai = any(k in (app or "").lower() for k in AI_APPS)
    if mid and req.get("fix"):
        # the word being typed is no word the user writes, but one the user writes often is a letter (or a layout) away: a ghost
        # that replaces (engine/words.py Words.fix; the app shows "→ word" and Tab swaps it)
        t = time.perf_counter()
        fx = finisher.fix(before)
        if fx:
            return {"text": fx["new"], "replace": fx["old"], "kind": fx["kind"], "src": "fix", "ms": round((time.perf_counter() - t) * 1000, 1)}
    if pack is None: pack = knowledge.snapshot()  # one check for this request's finisher and booster
    if mid and req.get("words", True) and (g or {}).get("words_first", req.get("words_first", False)):
        # the instant word finisher: the user's own words, no model (engine/words.py)
        t = time.perf_counter()
        f, source = words_mod.finish_with_source(finisher, before, (g or {}).get("words", (2, 0.6, 1)), pack)
        if f and not short(req, f):
            if source == "know": knowledge.offered += 1
            return {"text": f, "src": source, "ms": round((time.perf_counter() - t) * 1000, 1)}
    # the user's own word first (round four, Codex review "personal word path first"): when the word gate approves, the word
    # shows at once; the model runs only to extend it (bench/wordgate.py, before/after on held-out lines)
    if sel and g:
        # one calibrated selector (round four, bench/selector.py): memory and the user's word answer at once when their chance
        # clears the bar; else the model, whose first word must clear the same bar
        t = time.perf_counter()
        best = offers_now(sel, before, ai, mid) if req.get("words", True) and req.get("memory", True) else None
        if best:          # each source's own minimum length is in offers_now (memory 5 letters, the user's word 3)
            return {"text": best[1], "src": best[2], "sel": round(best[0], 3), "ms": round((time.perf_counter() - t) * 1000, 1)}
        # a name from the names / knowledge pack (2026-11-16): offers_now reads the user's own words only, and the name paths
        # below are closed with the selector, so /health know.offered stayed 0. Pack.finish offers a capitalised word
        # only when one name fits and the user's own words with those letters do not compete (engine/know.py).
        kf = words_mod.know_only(finisher, before, pack) if mid and req.get("words", True) and req.get("know", True) else ""
        if kf and not short(req, kf):
            knowledge.offered += 1
            return {"text": kf, "src": "know", "ms": round((time.perf_counter() - t) * 1000, 1)}
    first_word = word_first(before, ai) if mid and req.get("words", True) and req.get("word_first", True) and g and not sel else ""
    if first_word and (on_part is None or model.asleep or model.loading):
        return {"text": first_word, "src": "words", "first": True, "ms": 0}
    if first_word: on_part({"part": first_word, "src": "words", "ms": 0})
    if model.asleep or model.loading:
        # the text model steps aside while a call is read (or is loading back): the user's own words only, at once, never
        # queued behind the reload
        f, source = words_mod.finish_with_source(finisher, before, (g or {}).get("words", (2, 0.6, 1)), pack) if mid and req.get("words", True) else ("", "")
        if short(req, f): f = ""
        if f and source == "know": knowledge.offered += 1
        return {"text": f, "src": source if f else "asleep", "ms": 0}

    t_in = time.perf_counter()
    # cadence round (engine/cadence.py): the fast model answers this key when the user types fast and comboModels is on
    slot = globals().get("slot_for", lambda r: "big")(req)
    used = {}

    def job(cancelled):
        m, bb, gg = model, b, g
        if slot == "fast" and FAST["m"] is not None and not FAST["m"].asleep:   # cadence round: the user types fast
            m, bb, gg = FAST["m"], FAST["b"], (fast_gate() or g) if g else None
            used["slot"] = "fast"; FAST["used"] += 1
        t = time.perf_counter()
        act = actions.detect(before) if chips else None
        if act:
            found = actions.cached(act, before, lambda p, max_tokens=90: ask(p, max_tokens, cancelled))
            if found:
                return {"text": "", "action": found, "ms": round((time.perf_counter() - t) * 1000)}
        # /complete may carry Keys.contextFor's previous screen while a fresh read runs.
        # complete() tracks fresh context before any fast return; this job never moves it.
        if idle_form in ("turns", "chat"): ids, heal, stable = idle_ids(idle_form, b, app, context)
        else: ids, heal, stable = bb.ids_stable(before, app, title, context, "", *extras(req), after)
        prep = round((time.perf_counter() - t) * 1000, 1)
        n = max(1, min(int(req.get("max_tokens") or MAX_TOKENS), 16))
        if gg:
            # the decision gate decides on the first word, then sure words follow (engine/gatecore.py)
            th = gg["th"]["ai" if ai else "chat"]
            finish = finisher.finish(before, 2, 0.5, 1) if mid else ""   # a gate feature, as bench/gate.py reads it
            seen = {}

            # the lower gate (earlier round, 2026-11-16): a first word the gate does not pass but scores at least
            # `guess` still shows, as a guess (drawn lighter when the app asks for it); Tab takes it the same
            low = gatecore.guess_bar(gg, cadence.FAST_ID if m is not model else ((globals().get("CURRENT") or {}).get("entry") or {}).get("id", "live"), os.environ.get("DRAFTER_GUESS"), req.get("guess_bar")) if req.get("guess") else None
            low = gatecore.early_bar(low, before, bool(req.get("early_start")))   # step 6: one notch lower, lower after a space
            if idle: low = gatecore.idle_bar(low, req.get("idle_bar"))           # step 7: the idle ghost's own bar

            def decide(toks):
                f, _ = gatecore.features(toks, before, ai, finish)
                p = gatecore.score(gg["w"], f) if f else 0.0
                seen["p"] = p
                if sel and f:
                    ps = gatecore.score(sel["w"], gatecore.sel_features("model", toks[-1][0], before, ai, model_p=p, model_low=float(p < th)))
                    seen["sel"] = ps
                    if ps >= sel["th"]: return ps
                elif p >= th: return p
                if low is not None and f and p >= low:
                    seen["guess"] = True
                    return p
                return None
            # the word booster (2026-11-01): the user's own next words mixed into the model's guess, at the share the gate was
            # fit with (data/gate.json "boost"; 0 = off). The user's words update with every line the user sends (/typed).
            lam = float(gg.get("boost", 0) or 0) if req.get("boost", True) else 0.0
            boost = words_mod.boost_targets(finisher, before, heal, knowledge=pack, context=context, title=title) if lam else None
            min_letters = int(req.get("min_letters") or 0)
            # the lighter tail (round two): the app's per-app length (Keys.length: "tail" bar and "tail_words")
            tail = float(req["tail"]) if req.get("tail") is not None else None
            tail_words = int(req.get("tail_words") or 8)
            # sentence-length ghosts (long round): the app's ghostLength "phrase" / "sentence" (Keys.length)
            length = req.get("length") or "word"
            run_mode = None
            if length in gatecore.RUN_MODES:
                run_mode = {"mode": length, "floor": float(req.get("floor", gatecore.RUN_FLOOR)), "kind": req.get("floor_kind", "prod"),
                            "likely": float(req.get("likely", gatecore.RUN_LIKELY))}
                if length == "words": run_mode.update(gatecore.ghost_words(req))
                tail = None
            part_fn = None
            if on_part is not None:
                def part_fn(raw, sure):
                    if WRITTEN["seq"] == seq: WRITTEN["text"] = raw.replace("\ufffd", "")   # the user may type it through
                    o = clean(before, raw.replace("\ufffd", ""))
                    if not o or short(req, o) or cancelled(): return
                    if first_word and not gatecore.extends(o, first_word): return
                    msg = {"part": o, "src": "gate", "ms": round((time.perf_counter() - t) * 1000, 1)}
                    rest = raw[sure:]
                    if seen.get("guess"): msg["guess"] = True
                    if seen.get("guess") and req.get("guess_shade", True): msg["unsure"] = o
                    elif rest.strip() and o.endswith(rest): msg["unsure"] = rest
                    on_part(msg)
            seen["raw"] = ""
            cap = max(4, min(32, int(req.get("cap") or gatecore.RUN_CAP))) if run_mode else None
            fill = None
            if after_line:
                # mid-line (engine/fim.py): word mode, the ghost ends where the gap is filled
                rest = m.encode(after_line)
                fill = {"rest": rest[0] if rest else None, "text": after_line}
                run_mode, tail, cap, min_letters, n = None, None, None, 0, fim.TOKENS
            text, gp, first, total = m.complete_gated(ids, heal, decide, more=gg.get("more", 0.5), max_words=int(gg.get("max_words", 3)),
                                                          max_tokens=cap if run_mode else (max(n, min(24, 2 * tail_words + 2)) if tail is not None else n), cancelled=cancelled,
                                                          screen=screen, boost=boost, lam=lam, min_letters=min_letters,
                                                          grow=GROW if min_letters and not run_mode else None, grow_words=GROW_WORDS,
                                                          tail=tail, tail_words=tail_words, on_part=part_fn, run=run_mode, alts=FUTURES if req.get("ahead", True) else 0,
                                                          stable=stable, prefill_step=YIELD_STEP if (idle or low) else 512,
                                                          **({"mid": fill} if fill else {}))
            sure = getattr(m, "last_sure", None)
            if run_mode: tail = -1.0     # the sure part / lighter split below applies to the run too
            seen["alts"] = list(getattr(m, "last_alts", []) or [])
            seen["conf"] = list(getattr(m, "last_conf", []) or [])
            seen["raw"] = getattr(m, "last_raw", "") or ""
            out = clean(before, text.replace("\ufffd", ""))
            if short(req, out): out = ""
            if first_word:
                if not gatecore.extends(out, first_word):
                    return {"text": first_word, "src": "words", "first": True, "gate": round(seen.get("p", 0), 3), "next": seen["raw"], "ms": round(total)}
                res = {"text": out, "src": "gate", "first": True, "gate": round(seen.get("p", 0), 3), "next": seen["raw"], "alts": seen["alts"], "first_ms": 0, "ms": round(total)}
                rest = text[getattr(m, "last_sure", 0) or 0:] if tail is not None else ""
                if rest.strip() and out.endswith(rest) and len(out) - len(rest) >= len(first_word): res["unsure"] = rest
                return res
            fall, source = words_mod.finish_with_source(finisher, before, gg.get("words", (2, 0.6, 1)), pack) if mid and not out and req.get("words", True) and not sel else ("", "")
            if short(req, fall): fall = ""
            if fall:
                # the gate said no: the word being typed, from the user's own words, when that is clear (bench/gate.py
                # policy_from, as measured: first three words of a line saved 4.5% -> 8.6% in Beeper, 16.5 -> 21% in Claude)
                if source == "know": knowledge.offered += 1
                return {"text": fall, "src": source, "gate": round(seen.get("p", 0), 3), "next": seen["raw"], "ms": round(total)}
            res = {"text": out, "src": "gate", "gate": round(seen.get("p", 0), 3), "next": seen["raw"], "alts": seen["alts"], "first_ms": round(first), "ms": round(total),
                   "t": dict(getattr(m, "timing", {}) or {}, prep=prep, queue=round((t - t_in) * 1000, 1))}
            if run_mode and out:
                res["conf"] = seen["conf"]; res["why"] = getattr(m, "last_why", None)
            rest = text[sure:] if sure is not None and tail is not None else ""
            if out and rest.strip() and out.endswith(rest): res["unsure"] = rest
            if idle: res["idle"] = True; res["idle_form"] = idle_form
            if out and seen.get("guess"):
                res["guess"] = True
                if req.get("guess_shade", True): res["unsure"] = out
            return res
        # short and sure (the user, 2026-10-19): at most 3 words, and only the words the model gives >= 50% to
        # (bench: shown on 9/30 cut messages instead of 29, wrong on 3 instead of 19)
        soft = float(req.get("soft", 0) or 0)
        text, first, total = m.complete(None, raw_ids=ids, max_tokens=n, cancelled=cancelled, heal=heal,
                                            min_p=MIN_P, max_words=int(req.get("max_words") or MAX_WORDS), bars=bars, soft=soft, soft_from=int(req.get("soft_from", 2)), screen=screen,
                                            stable=stable)
        text = text.replace("\ufffd", "")
        out = clean(before, text)
        if short(req, out): out = ""
        res = {"text": out, "more": bool(m.hit_limit and out and "\n" not in text), "first_ms": round(first), "ms": round(total)}
        # the lighter tail: the words after the sure part (the app draws them lighter; Tab still takes one word)
        if soft and m.sure_len is not None:
            tail = text[m.sure_len:].strip()
            if tail and out.rstrip().endswith(tail): res["unsure"] = tail
        return res
    cancel = (lambda: stale(seq) and WANT[0] != keep) if keep else None
    on = {"before": normal_space(req.get("before") or "")[-4000:], "ident": keep_ident(req)} if req.get("keep_on") and not low else {}   # keep in flight
    res = run(job, low=low, seq=seq, cancel=cancel, **on)
    if used.get("slot") and isinstance(res, dict): res["slot"] = used["slot"]
    return res


# ---- model catalog (2026-11-15, engine/catalog.py) ----
DOWNLOADS = catalog.Downloads()
SWITCH = {"busy": False}


def set_cap(gb):
    """The guard and MLX's limit for the model about to load (never under the engine's own DRAFTER_CAP_GB)."""
    guard._cap[0] = max(CAP, float(gb))
    model_mod.set_limit(guard._cap[0])


def rebuild_head():
    """After a switch: the head in the new tokenizer, read in (from its file when there), token pieces again."""
    with BUILDERS_LOCK:
        for b in builders.values(): b.refresh()
    model.warm(builder.head_ids)
    model.pieces()
    with AHEAD_LOCK: AHEAD.clear(); AHEAD_KIND.clear(); FUT_INDEX.clear()


def models_view():
    """GET /models: the catalog, what is here, what downloads, which is loaded and which suits this Mac."""
    mac = catalog.machine()
    cur = CURRENT["entry"]
    cur_gb = model.loaded_gb() if cur else 0.0
    shown = catalog.here(CATALOG, ADAPTER, DATA)
    rec, why = catalog.recommend(catalog.ranked(shown) or CATALOG, mac["total_gb"], mac["free_gb"], cur_gb)
    rows = []
    for m in shown:
        d = DOWNLOADS.state(m)
        # "layer" goes out as true/false (the app reads a bool): the user's layer is here for this model
        rows.append({**m, "layer": catalog.has_layer(m, ADAPTER, DATA), "downloaded": d["state"] == "done", "download": d,
                     "speed": catalog.speed_mark(m), "quality": catalog.quality_mark(CATALOG, m)})
    return {"models": rows, "current": cur["id"] if cur else None, "recommended": rec, "why": why,
            "best_quality": catalog.best_quality(CATALOG),
            "machine": {**mac, "budget_gb": catalog.budget_gb(mac["total_gb"], mac["free_gb"], cur_gb)},
            "switching": SWITCH["busy"] or model.loading}


def switch_to(target):
    """On the worker thread: unload, load `target` (live when it fails), head again. Numbers only in the log."""
    try:
        fast_drop()   # cadence round: never two models plus a third loading
        got, err, secs = catalog.switch(model, target, LIVE_ENTRY, ADAPTER, rebuild=rebuild_head, set_cap=set_cap,
                                        data=DATA, free_gb=catalog.machine()["free_gb"])
        if got is not None: CURRENT["entry"] = got
        cur = (CURRENT["entry"] or {}).get("id")
        print(f"model switch: {target['id']} -> {cur} in {secs:.1f} s, mlx {model.memory_gb()[0]:.2f} GB, cap {guard._cap[0]} GB"
              + (f", {err}" if err else ""), flush=True)
        return {"ok": err is None, "current": cur, "error": err, "seconds": round(secs, 1)}
    finally:
        SWITCH["busy"] = False


def reader_check(req):
    """A last look before the user sends a chat message (engine/reader.py): slips and a question left open. Local only, no
    model, nothing sent; off unless `readerCheck`."""
    st = settings_load()
    if not st.get("readerCheck"): return {"edits": [], "ask": "", "src": "off"}
    import reader
    r = reader.check(str(req.get("text") or ""), str(req.get("context") or "")[-3000:], finisher)
    if (DATA / "debug").exists(): print("reader:", r["ms"], len(r["edits"]), bool(r["ask"]), flush=True)
    return r


def edit_marks(req):
    """Edit mode (engine/marks.py): places in a paragraph where the text could improve, each with one new text and a
    one-line why. Local only, no model, nothing sent; setting `editMarks` (on unless the user turned it off)."""
    st = settings_load()
    if not st.get("editMarks", True): return {"marks": [], "src": "off"}
    import marks as marks_mod, reader
    r = marks_mod.marks(str(req.get("text") or ""), str(req.get("context") or "")[-3000:], str(req.get("person") or "")[:40] or None,
                        finisher, reader.keep())
    if (DATA / "debug").exists(): print("marks:", r["ms"], len(r["marks"]), flush=True)
    return r


def my_style(req):
    """Edit mode's "Rewrite in my style": the text in the user's own words, by the LOCAL model only (local_rewrite), with their
    writing note and up to 4 of the user's earlier lines to this person as the example of the user's voice. Never Claude."""
    st = settings_load()
    if not st.get("editMarks", True): return {"text": "", "src": "off"}
    text = str(req.get("text") or "")[:3000]
    if not text.strip(): return {"text": ""}
    import marks as marks_mod
    mine = [l[:160] for l in marks_mod.his_lines(str(req.get("context") or "")[-3000:])][-4:]
    instr = ("Перепиши його власними словами і в його стилі: як він сам пише, коротко і просто; зміст той самий, мова та сама. "
             "Rewrite it in his own words and style; keep the meaning and the language.")
    if mine: instr += " Як він пише цій людині / how he writes to this person: " + " | ".join(mine)
    t = time.perf_counter()
    # the user's-writing layer on: the same prompt keeps its shape with it (3 of 3 made-up lines, docs/rounds/2026-11-17-editing.md)
    out = local_rewrite(text, instr, str(st.get("writingNote") or "")[:300], layer=True)
    return {"text": out, "ms": round((time.perf_counter() - t) * 1000), "by": "local"}


def local_rewrite(text, instr, notes="", layer=False):
    """The selection rewritten by the local model (base, the user's-writing layer off): the offline way for /rework. `notes`:
    the user's writing instructions, one line when there are some."""
    prompt = ("Перепиши текст за вказівкою. Відповідай лише новим текстом, без пояснень і без лапок. Мова та сама, що в "
              "тексті, якщо вказівка не каже інакше. Rewrite the text as the instruction says; reply with the new text only.\n"
              + (f"Як він пише / his writing instructions: {notes}\n" if notes else "")
              + f"Вказівка / instruction: {instr}\n\nТекст / text:\n{text}")
    ids = chat_ids(model, [{"role": "user", "content": prompt}])
    n = min(900, int(len(model.tok.encode(text)) * 2) + 40)
    # stops when the user types again (a newer suggestion) or the request gave up, so the one model is free for typing
    # (Codex review 2026-11-01: a dismissed rework held it for up to 900 tokens)
    start, gone = latest[0], threading.Event()
    stop = lambda: gone.is_set() or latest[0] != start
    r = run(lambda cancelled: {"text": model.oneshot(ids, max_tokens=n, cancelled=stop, **({"layer": True} if layer else {})).strip().strip('"«»').strip()}, newest=False, timeout=40)
    gone.set()
    return (r or {}).get("text", "")


def rework(req):
    """⌥Tab on a selection (engine/rework.py): shorter, fix, clearer, warmer, formal, list, the other language, or the user's
    own words. Claude when online, else the local model. Only when the user picks a command; setting `rework`.
    From the Quick panel (`from: quick`, app/Quick.swift) with `rework` off: the local model only, nothing sent."""
    st = settings_load()
    if not cloud.allowed("rework", st) and (req.get("from") != "quick" or req.get("warm")): return {}
    import rework as rework_mod
    m = req.get("model") or st.get("claudeModel", "sonnet")
    if req.get("warm"):
        if claude_on("rework", st): rework_mod.warm(m)
        return {"ok": True}
    r = rework_mod.rework(str(req.get("text") or ""), str(req.get("cmd") or ""), str(req.get("custom") or ""),
                          str(req.get("app") or "")[:40], model=m, online=claude_on("rework", st), local=local_rewrite, hint=who.hint(req, "rework") if claude_on("rework", st) else "",
                          **({"notes": str(req["notes"])} if (req.get("notes") or "").strip() else {}))
    if (DATA / "debug").exists(): print("rework:", r, flush=True)
    return r


def pause_rewrite(req):
    """A typing pause (app/PauseRewrite.swift, setting `pauseRewrite`, off): the paragraph before the caret goes
    through the ⌥Tab rework path (command "polish", Haiku) with the same context, under the daily Claude cap.
    Offline, off or capped: nothing is sent and the app shows nothing (engine/pause_rewrite.py)."""
    st = settings_load()
    if not claude_on("pause_rewrite", st): return {"skip": "off"}
    import pause_rewrite as pr, rework as rework_mod
    hint = who.hint(req, "rework")
    notes = str(req.get("notes") or "")
    r = pr.run(str(req.get("text") or ""), st.get("backOfficeCap", 0.5),
               lambda t: rework_mod.rework(t, "polish", "", str(req.get("app") or "")[:40], model=pr.MODEL, online=True, local=None, hint=hint,
                                           **({"notes": notes} if notes.strip() else {})),
               data=DATA, extra=hint + notes)
    if (DATA / "debug").exists(): print("pause rewrite:", {k: v for k, v in r.items() if k != "text"}, flush=True)
    return r


LOCAL_HOSTS = {f"127.0.0.1:{PORT}", f"localhost:{PORT}", f"[::1]:{PORT}"}


def write_token(path, token):
    """The active token for local scripts, 0600 from the first byte, swapped in whole (no half-written file)."""
    path = Path(path); tmp = path.with_name(f".{path.name}.{os.getpid()}.tmp")
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC | getattr(os, "O_NOFOLLOW", 0), 0o600)
    try:
        os.fchmod(fd, 0o600)
        os.write(fd, token.encode()); os.fsync(fd)
    finally: os.close(fd)
    os.replace(tmp, path)


class H(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    token = None   # set to TOKEN below the class; a handler without one lets nothing but /health through
    timeout = 3600  # longer than the app keeps an idle connection, so the app never sends on a closed one

    def log_message(self, *a): pass

    def send(self, obj, code=200):
        b = json.dumps(obj, ensure_ascii=False).encode()
        self.send_response(code); self.send_header("Content-Type", "application/json"); self.send_header("Content-Length", str(len(b)))
        self.end_headers(); self.wfile.write(b)

    def stream(self, work):
        """Two-step ghost (round two, 2026-11-13): one JSON object per line, the first words as soon as they exist
        ({"part": ...}), then the whole answer as usual with "final": true. The model writes the parts from its worker
        thread while this one waits; a gone reader only stops the parts. HTTP/1.1 clients get chunked NDJSON so the
        keep-alive socket is reused across keystrokes."""
        chunked = getattr(self, "request_version", "") == "HTTP/1.1"
        self.send_response(200); self.send_header("Content-Type", "application/x-ndjson")
        if chunked: self.send_header("Transfer-Encoding", "chunked")
        else: self.send_header("Connection", "close")
        self.end_headers()
        lock, alive = threading.Lock(), [True]

        def line(obj):
            with lock:
                if not alive[0]: return
                try:
                    b = json.dumps(obj, ensure_ascii=False).encode() + b"\n"
                    self.wfile.write((f"{len(b):x}\r\n".encode() + b + b"\r\n") if chunked else b)
                    self.wfile.flush()
                except OSError: alive[0] = False
        line(dict(work(line), final=True))
        if chunked:
            with lock:
                if alive[0]:
                    try: self.wfile.write(b"0\r\n\r\n"); self.wfile.flush()
                    except OSError: alive[0] = False
                if not alive[0]: self.close_connection = True
        else:
            self.close_connection = True

    def foreign(self, post=False):
        """A web page open in any browser reaches 127.0.0.1 too, so the address alone proves nothing. Browsers mark
        their requests (Origin, Sec-Fetch-*), a page under another name that points here (DNS rebinding) shows its own
        Host, and a page can only POST application/json after a preflight this server never answers. The app
        (URLSession) and local scripts (urllib) send none of those marks and always send application/json."""
        h = self.headers
        if self.client_address[0] not in ("127.0.0.1", "::1"): return True
        if h.get("Origin") or h.get("Sec-Fetch-Site") or h.get("Sec-Fetch-Mode"): return True
        if (h.get("Host") or "").lower() not in LOCAL_HOSTS: return True
        return post and (h.get("Content-Type") or "").split(";")[0].strip().lower() != "application/json"

    def authorized(self):
        """X-Drafter-Token equals this run's token (constant time). No token set: nothing is authorized."""
        want, got = self.token, self.headers.get("X-Drafter-Token") or ""
        return bool(want) and hmac.compare_digest(got.encode(), want.encode())

    def do_GET(self):
        if self.foreign(): self.close_connection = True; return self.send({"error": "forbidden"}, 403)
        if self.path != "/health" and not self.authorized():
            self.close_connection = True; return self.send({"error": "forbidden"}, 403)
        if self.path.split("?", 1)[0] == "/people":
            from urllib.parse import urlsplit, parse_qs
            q = parse_qs(urlsplit(self.path).query).get("q", [""])[0]
            return self.send({"people": knowledge.people(q)})
        if self.path.split("?", 1)[0] in ("/context", "/entity", "/context/brief"):
            # a thing's context from data/entities.json (engine/entities.py): /context?q=&level=1..3, /context/brief?q=,
            # /entity?q=. Local only (the check above), built from stored records, nothing leaves the Mac
            from urllib.parse import urlsplit, parse_qs
            qs = parse_qs(urlsplit(self.path).query)
            q = qs.get("q", [""])[0]
            if not settings_load().get("contextPacks", True): return self.send({"error": "context packs are off"}, 403)
            route = self.path.split("?", 1)[0]
            if route == "/entity": return self.send(entity_store().entity(q))
            if route == "/context/brief": return self.send(entity_store().brief(q))
            try: level = int(qs.get("level", ["2"])[0])
            except ValueError: level = 2
            return self.send(entity_store().context(q, level))
        if self.path == "/settings":
            st = settings_load()
            return self.send({"paused": st.get("paused", False), "voice": st.get("voice", False), "skip": st.get("skip", []), "model": st.get("model") or model.repo,
                              "voiceFast": st.get("voiceFast"), "voiceCareful": st.get("voiceCareful"),
                              "actions": [{"id": a.ID, "on": a.ID not in set(st.get("actions_off", [])),
                                           "about": (a.__doc__ or "").strip().splitlines()[0]} for a in actions.ALL],
                              "words": len(dictionary.load()["words"])})
        if self.path == "/edits":
            return self.send({"edits": edits.waiting()})
        if self.path.split("?", 1)[0] == "/pending":
            # ?wait=N (the app, 2026-11-14): held up to N s (max 30) until a job comes, in place of a request every second
            from urllib.parse import urlsplit, parse_qs
            try: wait = min(max(float(parse_qs(urlsplit(self.path).query).get("wait", ["0"])[0]), 0.0), 30.0)
            except ValueError: wait = 0.0
            return self.send({"jobs": actions.take_pending(wait)})
        if self.path == "/models": return self.send(models_view())
        if self.path == "/health":
            act, peak = model.memory_gb()
            return self.send({"ok": True, "instance": INSTANCE, "model": model.repo, "catalog": (CURRENT["entry"] or {}).get("id"), "adapter": model.adapter, "lora_merged": len(getattr(model, "fused", []) or []), "strength": round(getattr(model, "strength", 1.0) * 100), "fmt": FMT, "pid": os.getpid(), "head_tokens": len(builder.head_ids), "head_file": getattr(model, "head_file", None), "mark_hits": getattr(model, "mark_hits", 0), "rss_gb": round(guard.rss_gb(), 2),
                              "mlx_active_gb": round(act, 2), "mlx_peak_gb": round(peak, 2), "cap_gb": guard._cap[0],
                              "kv_gb": {"big": model.kv_gb(), "fast": FAST["m"].kv_gb() if FAST["m"] is not None else {}},
                              "asleep": model.asleep, "sleeps": model.sleeps, "dist_used": getattr(model, "dist_used", 0), "word_gate": bool(wordgate()), "combo": {"fast": FAST["m"] is not None, "used": FAST["used"], "loads": FAST["loads"], "refused": FAST["refused"]}, "boost": (gate() or {}).get("boost", 0), "ahead": ahead_stats(), "know": knowledge.stats(), "whom": who.stats,
                              "words": len(dictionary.load()["words"]), "actions": [a.ID for a in actions.ALL],
                              "model_link": {"provider": provider.kind(), "connected": provider.connected(), "error": provider.state["last_error"]},
                              "reader": sys.modules["reader"].stats() if "reader" in sys.modules else {},
                              "rework": sys.modules["rework"].stats() if "rework" in sys.modules else {}})
        if self.path == "/promises":
            # open promises, newest first (engine/promises.py); `who` is the matched person's display name, local only
            return self.send({"promises": [dict(r, who=who.display(r.get("person"))) for r in promise_book.open()]})
        self.send({"error": "not found"}, 404)

    def do_POST(self):
        if self.foreign(post=True) or not self.authorized():
            # Close the keep-alive socket so an unread foreign POST body cannot bleed into a later request.
            self.close_connection = True
            return self.send({"error": "forbidden"}, 403)
        try: n = max(0, int(self.headers.get("Content-Length") or 0))
        except ValueError:
            self.close_connection = True
            return self.send({"error": "bad content-length"}, 400)
        try: req = json.loads(self.rfile.read(n) or b"{}")
        except Exception: return self.send({"error": "bad json"}, 400)
        if self.path == "/futures": return self.send(futures(req))
        if self.path == "/complete":
            try: WANT[0] = ahead_key(req)   # long round: a look-ahead for exactly this text keeps running
            except Exception: WANT[0] = ""
            keep_running(req)    # earlier round: the running request for a few letters back runs on
            seq = request_seq()  # cancel before the new answer starts
            if not req.get("idle"): TYPED[0] += 1   # instant replies stop on a real key, not on the idle ghost
            t_recv = time.perf_counter()

            def timed(res):
                # round three: the whole stay in the engine
                if isinstance(res.get("t"), dict): res["t"].update(all=round((time.perf_counter() - t_recv) * 1000, 1))
                return res
            if req.get("stream"): return self.stream(lambda part: timed(complete(req, seq=seq, on_part=part)))
            return self.send(timed(complete(req, seq=seq)))
        if self.path == "/reader": return self.send(reader_check(req))
        if self.path == "/pause_rewrite": return self.send(pause_rewrite(req))
        if self.path == "/marks": return self.send(edit_marks(req))
        if self.path == "/mystyle": return self.send(my_style(req))
        if self.path == "/rework": return self.send(rework(req))
        if self.path == "/synonyms":
            import synonyms
            return self.send(synonyms.handle(req))
        if self.path == "/chip": return self.send(chip(req))
        if self.path == "/instant": return self.send(instant(req))
        if self.path == "/fields":   # smart snippet fields for the chat on screen (engine/whom.py Who.fields), local only
            try: return self.send(who.fields(str(req.get("app") or "")[:40], str(req.get("context") or "")[-2500:]))
            except Exception as e: return self.send({"error": str(e)})
        if self.path == "/command":
            import command
            return self.send(command.plan(str(req.get("text") or ""), lambda p, max_tokens=90: ask(p, max_tokens)))
        if self.path == "/snippet":
            import command
            return self.send({"done": command.save_snippet(str(req.get("key") or ""), str(req.get("text") or ""))})
        if self.path == "/ask":
            import ask as notes_ask
            return self.send(notes_ask.answer(str(req.get("text") or "")))
        if self.path == "/rewrite": return self.send(rewrite(req))
        if self.path == "/voice/claude": return self.send(voice_claude(req))
        if self.path == "/outline": return self.send(outline(req))
        if self.path == "/note":
            text = (req.get("text") or "").strip()
            if not text: return self.send({"error": "empty"})
            event = req.get("event") if isinstance(req.get("event"), dict) else None
            cloud = bool(req.get("call")) and claude_on("call_notes")   # the call summary: `callNotes` and online
            return self.send(run(lambda c: notes.make(text, lambda p, n=60: ask(p, n), req.get("audio", ""), bool(req.get("call")), bool(req.get("dry")), event,
                                                      cloud=cloud), newest=False, timeout=110))
        if self.path == "/sleep":
            # a long call is read again (Voice.transcribe): the text model gives its memory back and idle `claude`
            # helpers stop; it loads back on /wake, or by itself after `secs` (a reading that never ends)
            # idle (the app, 2026-11-14): no typing for `textIdleMin` minutes; no timer, the app's /wake (focus in a
            # field or a typing request) brings it back; one-off prompts (oneshot) still load it on demand
            idle = bool(req.get("idle"))
            secs = 86400.0 if idle else max(10.0, min(float(req.get("secs", 600) or 600), 3600.0))
            r = run(lambda c: {"slept": model.sleep(secs, retrain=bool(req.get("retrain"))), **fast_drop()}, newest=False, timeout=15)
            r["claude_stopped"] = claude_type.reap(0)
            if not idle:
                threading.Timer(secs + 1, lambda: run(lambda c: {"woke": model.wake(force=False)}, newest=False, timeout=30)).start()
            gb = model.memory_gb()[0]
            print(f"sleep {'idle' if idle else f'{secs:.0f}s'}: mlx {gb:.2f} GB, claude stopped {r['claude_stopped']}", flush=True)
            return self.send({**r, "mlx_active_gb": round(gb, 2)})
        if self.path == "/wake":
            was, t = model.asleep, time.time()
            r = run(lambda c: {"woke": model.wake()}, newest=False, timeout=30)
            if was: r["load_s"] = round(time.time() - t, 2); print(f"wake: loaded in {r['load_s']}s (head included)", flush=True)
            return self.send({**r, "mlx_active_gb": round(model.memory_gb()[0], 2)})
        if self.path == "/strength":
            # the app saved a new "Personal style" (0-100): the user's layer is merged again at that scale, in the one model
            # (a few seconds, typing answers from the user's words meanwhile); answers prepared at the old strength go
            want = strength_setting({"personalStrength": req.get("value", 100)})
            r = run(lambda c: {"seconds": round(model.set_strength(want) + (FAST["m"].set_strength(want) if FAST["m"] is not None else 0), 2)}, newest=False, timeout=60)
            with AHEAD_LOCK: AHEAD.clear(); AHEAD_KIND.clear(); FUT_INDEX.clear()
            print(f"strength {round(want * 100)}%: {r.get('seconds')} s", flush=True)
            return self.send({**r, "strength": round(model.strength * 100)})
        if self.path == "/model":
            # Settings > Typing > Model: the app saves "typingModel" only after this answers ok
            target = catalog.entry(CATALOG, req.get("id"))
            if target is None: return self.send({"ok": False, "error": "unknown model"}, 404)
            if (CURRENT["entry"] or {}).get("id") == target["id"] and not model.asleep:
                return self.send({"ok": True, "current": target["id"], "seconds": 0})
            if SWITCH["busy"]: return self.send({"ok": False, "error": "busy", "current": (CURRENT["entry"] or {}).get("id")})
            SWITCH["busy"] = True
            return self.send(run(lambda c: switch_to(target), newest=False, timeout=300))
        if self.path in ("/models/download", "/models/cancel"):
            # only on the user's press in Settings: the one network use besides what AGENTS.md lists
            target = catalog.entry(CATALOG, req.get("id"))
            if target is None: return self.send({"ok": False, "error": "unknown model"}, 404)
            if self.path == "/models/cancel": return self.send({"ok": DOWNLOADS.cancel(target["id"]), **DOWNLOADS.state(target)})
            return self.send({"ok": True, **DOWNLOADS.start(target)})
        if self.path == "/prefill":
            before, app, title, context, screen = parts(req)
            ids, _, stable = builder.ids_stable(before, app, title, context, "", *extras(req))   # builder_for(FMT) is this one
            r = run(lambda c: {"fed": model.prefill(ids, screen=screen, stable=stable)}, newest=False, timeout=5)
            return self.send(r)
        if self.path == "/typed":
            # a line the user sent or finished (Return), from a field Drafter may read: kept locally for the phrase memory
            text = (req.get("text") or "").strip()
            if len(text.split()) >= 3 and len(text) <= 600:
                with open(DATA / "typed.jsonl", "a") as f:
                    row = {"t": time.time(), "app": req.get("app", ""), "text": text}
                    if (req.get("context") or "").strip(): row["context"] = req["context"][-1500:]   # the chat above, for benches
                    f.write(json.dumps(row, ensure_ascii=False) + "\n")
                if globals().get("JOURNAL") is not None: JOURNAL.poke()   # the new line goes into data/journal.sqlite now
                phrases.add(text)
                finisher.add(text)
                with GATE_LOCK:
                    export_words = time.time() - GATE.get("exported", 0) > 600
                    if export_words: GATE["exported"] = time.time()
                if export_words: finisher.export(DATA / "mywords.txt")
                try: edits.sent(text)          # words the user changed in a voice take become "heard -> fixed" candidates
                except Exception as e: print("edits:", e, flush=True)
            if 0 < len(text) <= 600:
                try: promise_typed(req, text)
                except Exception as e: print("promises:", e, flush=True)
            return self.send({"ok": True})
        if self.path == "/accept":
            with open(DATA / "accepted.jsonl", "a") as f:
                row = {"t": time.time(), "app": req.get("app", ""), "text": req.get("text", ""), "before": (req.get("before") or "")[-120:]}
                for k in ("ghost_len", "src"):     # bench/kept.py: kept letters per ghost length and source (2026-11-13)
                    if req.get(k) not in (None, ""): row[k] = req[k]
                f.write(json.dumps(row, ensure_ascii=False) + "\n")
            return self.send({"ok": True})
        if self.path == "/words":
            w = dictionary.add(req.get("text", ""), lang=req.get("lang"), kind=req.get("kind", "term"), source="menu")
            run(lambda c: (builder.refresh(), model.warm(builder.head_ids)) and {}, newest=False, timeout=30)
            return self.send({"ok": bool(w), "word": w})
        if self.path == "/model-key":
            # "Connect a model" (app/Connect.swift): the app hands over the key from the Keychain after each engine start
            # and on connect; empty forgets it. Kept in memory only; never logged, never written.
            way = str(req.get("provider") or "")
            if way == "": provider.forget_all(); ok = True                      # Disconnect
            elif way == "cli": provider.forget_all(); ok = True                 # the CLI needs no key; fresh workers
            else: ok = provider.set_key(way, str(req.get("key") or ""))
            integrations._seen.pop("claude", None); router._state["at"] = 0
            refresh_cli()
            return self.send({"ok": bool(ok), "connected": provider.connected()})
        if self.path == "/settings":
            # a local tool changes Drafter here; the app picks the file up within a second
            st = settings_load() or {cloud.MARK: "off"}   # a file made here is a new install's: never migrated
            for k in ("paused", "skip", "actions_off", "model", "voice", "voiceFast", "voiceCareful", "learn", "adapter", "fmt", "minGhost", "predictKeys",
                      "readerCheck", "editMarks", "rework", "callNotes", "backOfficeCap", "voiceClaude",
                      "streamGhost", "longGhostsAI", "longGhostsChats", "autocorrectMode"):
                if k in req: st[k] = req[k]
            tmp = DATA / "settings.tmp"; tmp.write_text(json.dumps(st, ensure_ascii=False, indent=2)); tmp.replace(DATA / "settings.json")
            return self.send({"ok": True})
        if self.path == "/edits":
            edits.decide(req.get("heard", ""), req.get("fixed", ""), bool(req.get("accept")))
            return self.send({"ok": True})
        if self.path == "/words/edit":
            # the Dictionary page: one word's spelling and heard forms (adds it when missing: undo of a removal)
            w = dictionary.edit(req.get("old", ""), req.get("text", ""), req.get("heard") or [])
            if w: run(lambda c: (builder.refresh(), model.warm(builder.head_ids)) and {}, newest=False, timeout=30)
            return self.send({"ok": bool(w), "word": w})
        if self.path == "/words/loose":
            return self.send({"ok": True, "pair": dictionary.loose(req.get("old", ""), req.get("heard", ""), req.get("meant", ""))})
        if self.path == "/words/remove":
            d = dictionary.load(); n = len(d["words"])
            d["words"] = [w for w in d["words"] if w["text"].lower() != (req.get("text") or "").lower()]
            dictionary.save(d)
            return self.send({"ok": len(d["words"]) < n})
        if self.path == "/done":
            actions.finish(req.get("job", ""), req.get("result") or {})
            return self.send({"ok": True})
        if self.path == "/free":
            # free slots from the user's own calendars, read by the Drafter app (EventKit) (2026-10-21)
            job = {"kind": "eventkit.free", **{k: req[k] for k in ("from", "to", "minutes", "title", "earliest", "latest", "count") if k in req}}
            return self.send(actions.queue_app(job))
        if self.path == "/act":
            return self.send(actions.run_python(req.get("id"), req.get("fields") or {}))
        if self.path == "/promises/done": return self.send({"ok": promise_book.done(str(req.get("id") or ""))})
        if self.path == "/promises/drop": return self.send({"ok": promise_book.drop(str(req.get("id") or ""))})
        self.send({"error": "not found"}, 404)


H.token = TOKEN


if __name__ == "__main__":
    JOURNAL = journal_db.Follower(DATA).start()
    httpd = ThreadingHTTPServer(("127.0.0.1", PORT), H)
    write_token(DATA / "engine.token", TOKEN)   # only once the port is ours: a run that lost the port keeps the old file
    httpd.serve_forever()

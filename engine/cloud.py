"""Which setting owns each thing that sends his text to Claude (2026-11-14, bugs round, Argon review findings 1 and 2).

The engine asks `allowed(feature, settings)` before any Claude worker (claude_type.Worker, claude_worker)
gets text; server.claude_on() adds the online check. Defaults are the app's own (app/Main.swift Settings), so a
missing key means the same here as in the app. tests/test_cloud_gate.py walks every Claude call site and fails when
one is not in this table or its server function does not ask first.

A feature with no owner is sent on his own action (AGENTS.md "What leaves the Mac"): the command line after he picks,
asking his notes. Call notes (the live outline and the final call summary) belong to `callNotes` since 2026-11-14;
off, they take the same local-model path as offline (`data/offline`, router.online() false).
"""

OWNERS = {
    "rework": ("rework",),                           # ⌥Tab on a selection
    "rewrite": ("rework",),                          # speak over a selection: the same selection, the same switch
    "command": (),                                   # ⌘K line, after he picks
    "ask": (),                                       # he asked his notes by voice
    "call_notes": ("callNotes",),                    # the live outline and the final call summary (transcript to Haiku)
    "entities": ("entityClassify",),                 # a kind for a leftover name: only the name goes (engine/entities.py)
    "voice_claude": ("voiceClaude",),                # Claude cleans a Clean or Polished voice take after it went in (engine/voice_claude.py)
    "pause_rewrite": ("pauseRewrite",),              # a typing pause: the paragraph before the caret (engine/pause_rewrite.py)
}
# Removed 2026-11-17 (Claude out of the live typing path): pause, early, proofread, sentence, facts, translate, reply.
# Their keys (claudeTyping, claudePause, proofread, sentenceProof, facts, translate, nextMessage) may still sit in an
# old settings file: nothing reads them.

# Off for a new install since 2026-11-14 (open-source round): nothing goes to Claude until the user turns it on.
DEFAULTS = {"rework": False, "callNotes": False, "entityClassify": False, "voiceClaude": False, "pauseRewrite": False}
# What a missing key meant before that day. migrate() writes these into a settings file written before the change, once,
# so an existing user keeps exactly what he had. MARK in the file says it is done (or that the file is new).
# entityClassify (kinds for leftover names, engine/entities.py) came on that day and was never on: it stays off.
NEVER_ON = {"entityClassify", "voiceClaude", "pauseRewrite"}   # voiceClaude, pauseRewrite: new on 2026-11-17, never on before
OLD_DEFAULTS = {k: k not in NEVER_ON for k in DEFAULTS}
MARK = "cloudDefaults"


def migrate(path):
    """One-time: an existing settings file without MARK gets today's effective value of every cloud switch it does
    not name (the old default, on), then MARK. A missing file is left alone (a new install starts all local).
    Returns the keys it wrote."""
    import json
    from pathlib import Path
    path = Path(path)
    try: st = json.loads(path.read_text())
    except FileNotFoundError: return []
    except Exception: return []           # unreadable: the app starts from its defaults and never writes this file over
    if not isinstance(st, dict) or MARK in st: return []
    wrote = [k for k in OLD_DEFAULTS if k not in st]
    for k in wrote: st[k] = OLD_DEFAULTS[k]
    if "connect" not in st:      # before "Connect a model" the signed-in claude CLI was the one way: it stays connected
        st["connect"] = {"provider": "cli"}; wrote.append("connect")
    st[MARK] = "off"
    tmp = path.with_name(path.name + ".migrate.tmp")
    tmp.write_text(json.dumps(st, ensure_ascii=False, indent=2)); tmp.replace(path)
    return wrote


def allowed(feature, settings):
    """True when a model is connected (engine/provider.py) and every setting that owns `feature` is on. An unknown
    feature is never allowed; a feature with no owner still needs the connection."""
    if feature not in OWNERS: return False
    st = settings if isinstance(settings, dict) else {}
    import provider
    if not provider.connected(st): return False         # nothing connected: fully local ("Connect a model")
    return all(st.get(k, DEFAULTS[k]) is True for k in OWNERS[feature])

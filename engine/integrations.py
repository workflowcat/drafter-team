"""Private integrations, each optional and quiet (open-source round, 2026-11-14). Like engine/cloud.py does for Claude
features, this table says what each one is and how to tell that its tool answers.

An integration is on only when the local config turns it on (data/drafter.local.json, `integrations.<name>.enabled`)
AND its tool answers. Off, its chips and actions are not offered at all; code that reads it gets nothing and goes on.
app/LocalConfig.swift asks the same question for the app's own chips (the Google lookups).

    .venv/bin/python engine/integrations.py     # the table, with each one's state on this Mac
"""
import os, shutil, sys, time, urllib.request
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import local

# name: (what it is, what uses it)
TABLE = {
    "aleph": ("the owner's local knowledge app (HTTP on 127.0.0.1:8797, its SQLite file)",
              "Beeper draft, follow-up and thread actions; person links in long notes; call prep; asking your notes; the knowledge pack and dictionary names"),
    "inbox": ("the owner's local inbox app (a folder of JSON files)", "thread reply action; follow-ups in call prep"),
    "beeper": ("the `beeper` CLI (Beeper chat app)", "per-person memory, example messages (style.py), Beeper draft action"),
    "gam": ("GAM, the Google Workspace admin CLI", ";docs / ;meetings / ;free lookups, Google contacts for the knowledge pack"),
    "vault": ("a notes folder (an Obsidian vault) and the `claude` skill that files into it", "vault note action, training corpus source"),
    "voice_notes": ("the owner's older dictation app (its folder)", "its words seed the dictionary; its takes feed phrase memory and the corpus"),
    "claude": ("a signed-in `claude` CLI", "every Claude feature (each also behind its own switch in engine/cloud.py) and the Claude actions"),
    "voice_guide": ("a text file that describes the user's voice", "the next-message prompt (else the style rules)"),
    "server": ("a Linux box you control, reached by `ssh <host>` with Docker on it", "background jobs (bench/jobs.py): careful re-transcribe of calls, the journal index"),
}

_seen = {}   # name -> (at, answer): a tool's answer is kept 60 s


def _aleph():
    try:
        urllib.request.urlopen(local.setting("aleph", "url") or "http://127.0.0.1:8797", timeout=0.4)
        return True
    except urllib.error.HTTPError:
        return True          # it answered, just not on "/"
    except Exception:
        return Path(local.setting("aleph", "db") or "/nonexistent").is_file()


def claude_bin():
    """The `claude` CLI: the config's path, else PATH, else ~/.local/bin/claude. '' when none exists."""
    p = local.setting("claude", "bin")
    if p and Path(p).is_file(): return p
    return shutil.which("claude") or (str(Path.home() / ".local/bin/claude") if (Path.home() / ".local/bin/claude").is_file() else "")


def beeper_bin():
    p = local.setting("beeper", "bin")
    if p and Path(p).is_file(): return p
    import people
    found = people.beeper_bin()
    return found if os.path.isabs(found) else ""


CHECKS = {
    "aleph": _aleph,
    "inbox": lambda: Path(local.setting("inbox", "path") or "/nonexistent").is_dir(),
    "beeper": lambda: bool(beeper_bin()),
    "gam": lambda: Path(local.setting("gam", "bin") or "/nonexistent").is_file(),
    "vault": lambda: Path(local.setting("vault", "path") or "/nonexistent").is_dir(),
    "voice_notes": lambda: Path(local.setting("voice_notes", "path") or "/nonexistent").is_dir(),
    "claude": lambda: bool(claude_bin()),
    "voice_guide": lambda: Path(local.setting("voice_guide", "path") or "/nonexistent").is_file(),
    "server": lambda: bool(str(local.setting("server", "host") or "").strip()),
}


def available(name):
    """On in the local config and its tool answers. An unknown name is never available."""
    if name not in TABLE: return False
    if not local.enabled(name) and not (name == "claude" and _cli_connected()): return False
    at, ok = _seen.get(name, (0, False))
    if time.time() - at > 60:
        try: ok = bool(CHECKS[name]())
        except Exception: ok = False
        _seen[name] = (time.time(), ok)
    return ok


def _cli_connected():
    """The user picked the signed-in claude CLI in Settings ("Connect a model"): that turns this integration on too."""
    import provider
    return provider.kind() == "cli"


def all_available(names):
    return all(available(n) for n in names)


def state():
    return {n: {"enabled": local.enabled(n), "available": available(n)} for n in TABLE}


if __name__ == "__main__":
    for n, (what, uses) in TABLE.items():
        s = state()[n]
        print(f"{n:12} {'on ' if s['available'] else ('off (no answer)' if s['enabled'] else 'off')}  {what}\n{'':14}used by: {uses}")

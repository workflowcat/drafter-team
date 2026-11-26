"""The user's local config: who the user is and which private tools this Mac has (open-source round, 2026-11-14).

One untracked file, `data/drafter.local.json` in the data folder (engine/data_dir.py; DRAFTER_LOCAL points elsewhere, for tests). The tracked
`drafter.local.example.json` at the repo root shows every key. With no file every Claude prompt is neutral ("the user")
and every private integration is off. The app reads the same file (app/LocalConfig.swift).

    .venv/bin/python engine/local.py            # what this Mac has: the config in effect and each integration's state
"""
import copy, json, os, shutil, sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(Path(__file__).resolve().parent))
from data_dir import data_dir  # noqa: E402
EXAMPLE = ROOT / "drafter.local.example.json"

DEFAULTS = {
    "user": {
        "name": "",            # full name, opens the Claude system prompts ("You finish what <name> is typing")
        "short_name": "",      # first name in shorter prompts ("Answer <short_name>'s question"), the call speaker line
        "own_names": [],       # names that are the user, never a contact ("Marta" in the user's address book)
        "own_stems": [],       # lower-case Latin stems of the user's name in case forms (notes: "mart" for Марта/Marta)
        "about": "",           # one or two sentences after the name in the typing prompt: work, who they write to
        "languages": ["en"],
        "style_rules": "",     # how the user writes: the local model's prompt head and Claude's writing rules
        "timezone": "",        # IANA zone, e.g. Europe/Kyiv; empty = this Mac's zone
        "city": "",            # shown after today's date in the typing prompt
        "email": "",
    },
    "snippets": {},            # defaults for a new data/snippets.json; an existing one is never changed
    "social": {"facebook_archive": ""},   # a Facebook posts export (combined_posts.json) for the training corpus
    # training corpus sources (bench/corpus.py); Beeper and the vault follow their integrations
    "corpus": {"typed": True, "takes": True, "claude_code": False, "codex": False, "folders": []},
    "integrations": {
        "beeper":      {"enabled": False, "bin": ""},
        "gam":         {"enabled": False, "bin": ""},
        "vault":       {"enabled": False, "path": "", "name": "", "origin": ""},
        "claude":      {"enabled": False, "bin": ""},
    },
    # folders whose subfolders are the user's code projects: a project or tool name gets a "Repo" or "Code" pointer
    # (engine/entities.py); none by default
    "projects": {"roots": []},
    # build-time ids (app/build.sh): changing them on an installed Mac resets its macOS permissions, so an owner keeps the user's.
    # codesign_identity: a Developer ID to sign with (empty = ad-hoc); data_dir: a data folder baked into the app (empty = none)
    "build": {"bundle_id": "", "launchd_label": "", "nightly_label": "", "codesign_identity": "", "data_dir": ""},
}
PUBLIC_BUNDLE_ID = "io.github.workflowcat.drafter"   # the one place the default id lives

NEUTRAL_ABOUT = "They type in chats, to coding agents and in documents."
NEUTRAL_RULES = ("Write like the user's own messages below: the same languages, length, tone, spelling and punctuation. "
                 "Each message stays in the language it started in.")

_cache = {"key": None, "cfg": None}


def path():
    return Path(os.environ.get("DRAFTER_LOCAL") or data_dir() / "drafter.local.json")


def _merge(base, over):
    out = copy.deepcopy(base)
    for k, v in (over or {}).items():
        if isinstance(v, dict) and isinstance(out.get(k), dict): out[k] = _merge(out[k], v)
        elif not k.startswith("_"): out[k] = v
    return out


def config():
    """The config in effect: the local file over DEFAULTS. Read again when the file changes."""
    p = path()
    try: key = (str(p), p.stat().st_mtime_ns)
    except OSError: key = (str(p), None)
    if _cache["key"] != key:
        try: own = json.loads(p.read_text()) if key[1] is not None else {}
        except Exception: own = {}
        _cache["key"], _cache["cfg"] = key, _merge(DEFAULTS, own if isinstance(own, dict) else {})
    return _cache["cfg"]


def user(key):
    return config()["user"].get(key, DEFAULTS["user"].get(key))


def name():
    return (user("name") or "").strip() or "the user"


def short_name():
    return (user("short_name") or "").strip() or (user("name") or "").strip().split(" ")[0] or "the user"


def possessive(short=True):
    n = short_name() if short else name()
    return "the user's" if n == "the user" else n + "'s"


def about():
    return (user("about") or "").strip() or NEUTRAL_ABOUT


def style_rules():
    return (user("style_rules") or "").strip() or NEUTRAL_RULES


def timezone():
    z = (user("timezone") or "").strip()
    if z: return z
    try:
        link = os.readlink("/etc/localtime")
        return link.split("zoneinfo/", 1)[1] if "zoneinfo/" in link else "UTC"
    except OSError:
        return "UTC"


def expand(p):
    return str(Path(os.path.expanduser(p))) if p else ""


def setting(integration, key, default=""):
    v = config()["integrations"].get(integration, {}).get(key, default)
    return expand(v) if isinstance(v, str) and (v.startswith("~") or v.startswith("/")) else v


def enabled(integration):
    """The config turns it on. Whether its tool answers is integrations.available()."""
    return config()["integrations"].get(integration, {}).get("enabled") is True


def seed_snippets(file):
    """A new install's data/snippets.json from the config's `snippets` (and ";mail" from user.email). An existing file is
    never changed. Returns True when it wrote one."""
    file = Path(file)
    if file.exists(): return False
    snips = {k: v for k, v in (config().get("snippets") or {}).items() if isinstance(v, str) and v}
    if user("email") and ";mail" not in snips: snips[";mail"] = user("email")
    if not snips: return False
    file.parent.mkdir(parents=True, exist_ok=True)
    tmp = file.with_suffix(".tmp"); tmp.write_text(json.dumps(snips, ensure_ascii=False, indent=1)); tmp.replace(file)
    return True


def bundle_id():
    return (config()["build"].get("bundle_id") or "").strip() or PUBLIC_BUNDLE_ID


def launchd_label():
    return (config()["build"].get("launchd_label") or "").strip() or bundle_id()


def nightly_label():
    return (config()["build"].get("nightly_label") or "").strip() or launchd_label() + "-nightly"


def codesign_identity():
    """The signing identity for app/build.sh: empty = ad-hoc ("-")."""
    v = config()["build"].get("codesign_identity")
    return v.strip() if isinstance(v, str) else ""


def build_data_dir():
    """A data folder baked into the app's Info.plist (DrafterData) by app/build.sh: empty = none."""
    v = config()["build"].get("data_dir")
    return expand(v.strip()) if isinstance(v, str) and v.strip() else ""


GETS = {"bundle_id": bundle_id, "launchd_label": launchd_label, "nightly_label": nightly_label,
        "codesign_identity": codesign_identity, "data_dir": build_data_dir}


if __name__ == "__main__":
    if sys.argv[1:2] == ["--get"]:     # app/build.sh, scripts: `python3 engine/local.py --get bundle_id`
        if len(sys.argv) < 3 or sys.argv[2] not in GETS:
            print("usage: local.py --get " + "|".join(GETS), file=sys.stderr); sys.exit(2)
        print(GETS[sys.argv[2]]()); sys.exit(0)
    print(path(), "(present)" if path().exists() else "(missing: neutral prompts, integrations off)")
    print(json.dumps(config(), ensure_ascii=False, indent=1))

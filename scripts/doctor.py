"""Where this Mac is in setting up Drafter, and the next command for each missing step (team round, 25 November 2026).

    .venv/bin/python -B scripts/doctor.py          # a checklist; or: python3 scripts/doctor.py before .venv exists
    .venv/bin/python -B scripts/doctor.py --json   # the same as JSON (the drafter-setup Claude skill reads it)

Reads only: no network, no model load, nothing started, nothing written. Prints counts about data/, never its text.
"""
import json, os, platform, shutil, subprocess, sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
DATA = ROOT / "data"
APP = Path.home() / "Applications" / "Drafter.app"
VOICE = ["mlx-community/parakeet-tdt-0.6b-v3", "mlx-community/whisper-large-v3-turbo"]
TYPING_GB, VOICE_GB = 3, 8      # free disk scripts/setup.sh asks for: typing only, typing and voice
checks = []


def add(group, name, ok, detail="", next_cmd="", optional=False):
    checks.append({"group": group, "name": name, "ok": bool(ok), "optional": optional, "detail": detail, "next": next_cmd})


def run(cmd, timeout=10):
    try: return subprocess.run(cmd, capture_output=True, text=True, timeout=timeout).stdout.strip()
    except Exception: return ""


def hub_has(repo):
    cache = Path(os.environ.get("HF_HUB_CACHE") or os.environ.get("HF_HOME", Path.home() / ".cache/huggingface") + "/hub"
                 if os.environ.get("HF_HOME") else Path.home() / ".cache/huggingface/hub")
    d = Path(cache) / ("models--" + repo.replace("/", "--"))
    try: rev = (d / "refs" / "main").read_text().strip()
    except OSError: return False
    snap = d / "snapshots" / rev
    return (snap / "config.json").exists() or any(snap.glob("*.safetensors")) or any(snap.glob("*.npz"))


def mac():
    arm = platform.machine() == "arm64"
    ver = platform.mac_ver()[0] or "0"
    major = int(ver.split(".")[0] or 0)
    ram = int(run(["sysctl", "-n", "hw.memsize"]) or 0) / 2**30
    free = shutil.disk_usage(ROOT).free / 2**30
    add("mac", "Apple silicon", arm, platform.machine(), "Drafter needs an M1 or newer Mac")
    add("mac", "macOS 15 or newer", major >= 15, ver, "Update macOS in System Settings > General > Software Update")
    add("mac", "memory", ram >= 16, f"{ram:.0f} GB" + ("" if ram >= 16 else ": typing may fit, voice and training may not"),
        "", optional=True)
    # the same numbers as scripts/setup.sh: about 3 GB for typing only, about 8 GB with voice
    voice_here = all(hub_has(r) for r in VOICE)
    add("mac", "free disk for typing", free >= TYPING_GB, f"{free:.0f} GB free (typing needs about {TYPING_GB} GB)", "Free some disk space")
    add("mac", "free disk for voice", voice_here or free >= VOICE_GB,
        "voice models already here" if voice_here else f"{free:.0f} GB free (typing and voice need about {VOICE_GB} GB)",
        "Free some disk space before scripts/setup.sh --voice", optional=True)
    return ram


def tools():
    add("tools", "uv", shutil.which("uv"), "", "curl -LsSf https://astral.sh/uv/install.sh | sh")
    add("tools", "Command Line Tools (swiftc)", run(["xcrun", "--find", "swiftc"]), "", "xcode-select --install")
    add("tools", "ffmpeg", shutil.which("ffmpeg"), "reads audio files that are not WAV", "brew install ffmpeg", optional=True)
    claude = shutil.which("claude") or (Path.home() / ".local/bin/claude").is_file()
    add("tools", "claude CLI", claude, "only for the optional cloud helpers (Settings > Cloud > Connect a model)",
        "npm install -g @anthropic-ai/claude-code", optional=True)


def env():
    py = ROOT / ".venv/bin/python"
    ok = py.exists() and "3.12.12" in run([str(py), "--version"])
    add("python", "environment (.venv, Python 3.12.12)", ok, "", "scripts/setup.sh --models --app")
    return ok


def config():
    p = DATA / "drafter.local.json"
    add("you", "your config (data/drafter.local.json)", p.exists(), "", "scripts/setup.sh --models --app  (writes it from drafter.local.example.json)")
    if not p.exists(): return
    try: c = json.loads(p.read_text())
    except Exception: add("you", "config is valid JSON", False, "", "Fix the JSON in data/drafter.local.json"); return
    u = c.get("user") or {}
    has = bool((u.get("name") or "").strip())
    add("you", "your name", has, "" if has else "the prompts say \"the user\" without it",
        'Put your name in data/drafter.local.json: "user": {"name": ...}', optional=True)
    langs = u.get("languages") or ["en"]
    add("you", "your languages", True, ", ".join(langs))


def models(ram, have_env):
    try:
        sys.path.insert(0, str(ROOT / "engine"))
        import catalog
        ms = catalog.load()["models"] if isinstance(catalog.load(), dict) else catalog.load()
    except Exception:
        ms = []
    live = next((m for m in ms if m.get("id") == "live"), {"repo": "mlx-community/Qwen3-1.7B-4bit", "name": "Qwen3 1.7B"})
    add("models", "typing model", hub_has(live["repo"]), live["repo"], "scripts/setup.sh --models --app")
    if ms and ram:
        adapters = DATA / "adapters"
        plain = catalog.ranked(catalog.here(ms, str(adapters) if adapters.is_dir() else None, DATA))
        try:
            mid, why = catalog.recommend(plain, ram)
            m = next(x for x in plain if x["id"] == mid)
            add("models", "suggested for this Mac", True, f"{m.get('name', mid)} (id {mid}, {m['repo']}): {why}",
                "Pick it in Drafter: Settings > Typing > Model, then Download", optional=True)
        except Exception:
            pass
    have = all(hub_has(r) for r in VOICE)
    add("models", "voice models (dictation, calls)", have, ", ".join(VOICE), "scripts/setup.sh --models --app --voice", optional=True)


def app():
    ok = (APP / "Contents/MacOS/Drafter").exists()
    home = run(["/usr/libexec/PlistBuddy", "-c", "Print :DrafterHome", str(APP / "Contents/Info.plist")]) if ok else ""
    add("app", "Drafter.app built", ok, str(APP), "scripts/setup.sh --app")
    if ok:
        add("app", "built from this folder", Path(home).resolve() == ROOT if home else False, home or "unknown",
            "scripts/setup.sh --app  (from this folder)")
    label = run([sys.executable, str(ROOT / "engine/local.py"), "--get", "launchd_label"]) or ""
    plist = Path.home() / "Library/LaunchAgents" / f"{label}.plist"
    add("app", "starts at login", label and plist.exists(), label, "scripts/install-login.sh  (then the command it prints)", optional=True)
    running = run(["pgrep", "-f", "Drafter.app/Contents/MacOS/Drafter"])
    add("app", "running", bool(running), "", "open ~/Applications/Drafter.app")
    health = run(["curl", "-s", "-m", "2", "127.0.0.1:8798/health"], timeout=4)
    add("app", "engine answers", bool(health), "127.0.0.1:8798/health" if health else "no answer (it loads for up to a minute after start)",
        "Open Drafter; if it stays silent: tail data/engine.log")


def writing():
    def lines(p):
        try:
            with open(p, "rb") as f: return sum(1 for _ in f)
        except OSError: return 0
    typed, takes = lines(DATA / "typed.jsonl"), lines(DATA / "takes.jsonl")
    imp = DATA / "import"
    files = sum(1 for p in imp.rglob("*") if p.is_file()) if imp.is_dir() else 0
    add("training", "your writing so far", typed + takes > 0, f"{typed} typed lines, {takes} voice takes, {files} files in data/import",
        "Use Drafter for a week, or put your own writing in data/import (docs/your-data.md)", optional=True)
    layer = (DATA / "adapters" / "adapters.safetensors").exists()
    add("training", "your own layer", layer, "", "scripts/train.sh --check, then scripts/train.sh", optional=True)


def main():
    as_json = "--json" in sys.argv
    ram = mac(); tools(); have = env(); config(); models(ram, have); app(); writing()
    if as_json:
        print(json.dumps({"root": str(ROOT), "checks": checks}, indent=1)); return 0
    group = ""
    for c in checks:
        if c["group"] != group: group = c["group"]; print(f"\n{group}")
        mark = "ok  " if c["ok"] else ("--  " if c["optional"] else "MISS")
        print(f"  {mark} {c['name']}" + (f": {c['detail']}" if c["detail"] else ""))
        if not c["ok"] and c["next"]: print(f"       next: {c['next']}")
    need = [c for c in checks if not c["ok"] and not c["optional"]]
    print(f"\n{'Ready.' if not need else str(len(need)) + ' required step(s) left.'}")
    return 0


if __name__ == "__main__":
    sys.exit(main())

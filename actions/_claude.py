"""Actions Aleph cannot do run the logged-in `claude` CLI headless with one skill, after Andrii presses the chip.

The run goes to the background (it can take minutes); the result line lands in data/actions.jsonl and in a macOS
notification. DRAFTER_DRY=1 only writes the command it would run."""
import json, os, subprocess, threading, time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
import sys
sys.path.insert(0, str(ROOT / "engine"))
import integrations
CLAUDE = (integrations.claude_bin() if integrations.available("claude") else "") or "/nonexistent/claude"   # off: the run fails at once
ENV = {**os.environ, "PATH": f"{Path.home()}/.local/bin:/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin"}


def note(line):
    with open(ROOT / "data" / "actions.jsonl", "a") as f:
        f.write(json.dumps({"t": time.time(), **line}, ensure_ascii=False) + "\n")


def notify(title, text):
    subprocess.run(["osascript", "-e", f"display notification {json.dumps(text[:200])} with title {json.dumps(title)}"],
                   capture_output=True, timeout=5)


def command(skill, prompt, tools):
    """-> (argv, stdin). The prompt carries his text, so it goes on stdin (`claude -p` reads it there when no prompt
    argument is given); argv holds flags only, as any process can read it through `ps` (2026-11-14)."""
    full = f"Use the {skill} skill. {prompt}\nWork without asking questions; at the end reply with one short line: what you made and where."
    return [CLAUDE, "-p", "--output-format", "json", "--allowedTools", ",".join(tools)], full


def run(action_id, skill, prompt, tools, cwd=None, minutes=10):
    """Start `claude -p` with the skill named in the prompt and only the listed tools. Returns at once."""
    cmd, full = command(skill, prompt, tools)
    if os.environ.get("DRAFTER_DRY"):
        note({"id": action_id, "dry": cmd}); return "dry run: " + skill

    def go():
        t0 = time.time()
        try:
            r = subprocess.run(cmd, input=full, capture_output=True, text=True, timeout=minutes * 60, env=ENV, cwd=cwd or str(Path.home()))
            out = json.loads(r.stdout or "{}")
            line = (out.get("result") or r.stderr or "no answer").strip().splitlines()[-1][:300]
            ok = r.returncode == 0 and not out.get("is_error")
        except Exception as e:
            line, ok = str(e)[:300], False
        note({"id": action_id, "skill": skill, "ok": ok, "result": line, "s": round(time.time() - t0)})
        notify("Drafter" if ok else "Drafter: failed", line)

    threading.Thread(target=go, daemon=True).start()
    return f"Claude is working: {skill} (a notification will show the result)"

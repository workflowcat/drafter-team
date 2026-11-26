"""Online or offline (2026-10-21, the user: "if my Claude is on, use Haiku for cleanup and speed; offline, local models").
Text tasks off the typing hot path (rewrite a selection, the live outline, a note's title, the command line) go to
Claude Haiku through the kept-running `claude` worker when the Mac is online and the CLI is there; otherwise, or when
Haiku fails or is slow, the local model does it. Ghost text while typing always stays local (it needs ~40 ms).
`DRAFTER_OFFLINE=1` or data/offline forces local."""
import os, shutil, socket, time
from pathlib import Path
import integrations
from data_dir import data_dir

ROOT = Path(__file__).resolve().parent.parent
_state = {"at": 0.0, "up": False}


def online():
    if os.environ.get("DRAFTER_OFFLINE") or (data_dir() / "offline").exists(): return False
    if time.time() - _state["at"] < 30: return _state["up"]
    up = False
    import provider
    k = provider.kind()
    if k == "cli" and integrations.available("claude"):   # the CLI is the connected way and it is there
        try:
            socket.create_connection(("api.anthropic.com", 443), timeout=1.5).close(); up = True
        except OSError:
            up = False
    elif k in ("anthropic", "openai"):
        up = provider.connected() and provider.reachable()
    _state.update(at=time.time(), up=up)
    return up


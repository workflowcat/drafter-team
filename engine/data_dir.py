"""Where the user's data lives: one answer for the engine, the scripts and the tests.

1. DRAFTER_DATA, when set (the app passes it to the engine and the voice process);
2. else `data/` in this checkout, when it exists (every clone set up with scripts/setup.sh);
3. else ~/Library/Application Support/Drafter, when DRAFTER_APP_SUPPORT=1 (a packaged app with no clone data);
4. else `data/` in this checkout, so tests and repo workflows behave as before.

    python3 engine/data_dir.py      # prints the folder in effect
"""
import os
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent


def app_support():
    return Path.home() / "Library" / "Application Support" / "Drafter"


def data_dir(root=ROOT):
    root = Path(root)
    env = (os.environ.get("DRAFTER_DATA") or "").strip()
    if env: return Path(os.path.expanduser(env)).resolve()
    own = root / "data"
    if own.exists(): return own.resolve()
    if os.environ.get("DRAFTER_APP_SUPPORT") == "1": return app_support().resolve()
    return own.resolve()


if __name__ == "__main__":
    print(data_dir())

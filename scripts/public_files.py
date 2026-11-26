"""The files the repository checks: every tracked file, and the docs written for readers.

    python3 scripts/public_files.py           # one tracked path per line

tests/test_no_private.py scans every file this lists; tests/test_public_docs.py checks the pages in PUBLIC_DOCS.
"""
import subprocess, sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

# docs written for readers: every path and link they name must exist, and README.md links each one
PUBLIC_DOCS = {"docs/architecture.md", "docs/typing.md", "docs/training.md", "docs/voice-and-calls.md", "docs/privacy.md",
               "docs/look.md", "docs/building-with-agents.md", "docs/contributing.md", "docs/features.md",
               "docs/onboarding.md", "docs/customize.md", "docs/your-data.md"}
# tables of common first names and their short forms (the knowledge pack's name matching): a deny-list of people's
# names would match them by design, so only the deny-list check skips these two; every other check covers them
NAME_TABLES = {"engine/know.py", "tests/test_know.py"}


def files(root=ROOT):
    """Tracked files that exist on disk, sorted."""
    out = subprocess.run(["git", "-C", str(root), "ls-files", "-z"], capture_output=True, check=True).stdout.decode()
    return [p for p in sorted(out.split("\0")) if p and not p.startswith(".worktrees/") and (Path(root) / p).exists()]


if __name__ == "__main__":
    for path in files(Path(sys.argv[1]) if len(sys.argv) > 1 else ROOT):
        print(path)

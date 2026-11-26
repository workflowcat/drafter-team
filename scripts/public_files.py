"""Which tracked files go into the public repository, and under what name (open-source round, 2026-11-14).

    python3 scripts/public_files.py           # one line per file: <tracked path>\t<path in the public copy>

The owner's working notes (docs/history, docs/rounds, docs/reviews, research with his numbers), his agent workflow
(AGENTS.md, replaced by AGENTS.public.md) and one-off scripts stay in the private repo. tests/test_no_private.py checks
every file this list publishes; scripts/export-public.sh copies them.
"""
import subprocess, sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

# docs written for strangers: the only docs that are published
PUBLIC_DOCS = {"docs/architecture.md", "docs/typing.md", "docs/training.md", "docs/voice-and-calls.md", "docs/privacy.md",
               "docs/look.md", "docs/building-with-agents.md", "docs/contributing.md",
               "docs/onboarding.md", "docs/customize.md", "docs/your-data.md"}
RENAME = {"AGENTS.public.md": "AGENTS.md"}
DROP = {"AGENTS.md"}
# tables of common first names and their short forms (the knowledge pack's name matching): a deny-list of people's
# names would match them by design, so only the deny-list check skips these two; every other check covers them
NAME_TABLES = {"engine/know.py", "tests/test_know.py"}


def keep(path):
    if path in DROP: return False
    if path.startswith("docs/"): return path in PUBLIC_DOCS
    if path.startswith(".claude/"): return path.startswith((".claude/agents/", ".claude/skills/"))
    if path.startswith(".worktrees/"): return False
    if path.startswith("bench/claude_writer/"): return False   # the Claude writer research bench (2026-11-17): his key item names and numbers
    return True


def files(root=ROOT):
    out = subprocess.run(["git", "-C", str(root), "ls-files", "-z"], capture_output=True, check=True).stdout.decode()
    return [(p, RENAME.get(p, p)) for p in sorted(out.split("\0")) if p and keep(p) and (Path(root) / p).exists()]


if __name__ == "__main__":
    for src, dst in files(Path(sys.argv[1]) if len(sys.argv) > 1 else ROOT):
        print(f"{src}\t{dst}")

#!/bin/bash
# The public copy: tracked files minus the owner's notes, scanned, tested, in a new git folder. No remote, no push.
#   DRAFTER_DENY=<names file> scripts/export-public.sh <new-folder> [--commit "Name <email>"]
# Details: scripts/export_public.py.
set -euo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
py="$here/.venv/bin/python"
[[ -x $py ]] || py="$here/../../.venv/bin/python"      # a worktree under .worktrees/ uses the main checkout's venv
[[ -x $py ]] || { echo 'export-public: run scripts/setup.sh first (no .venv)' >&2; exit 1; }
exec "$py" -B "$here/scripts/export_public.py" "$@"

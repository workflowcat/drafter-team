#!/bin/bash
# For maintainers and CI: does requirements-lock.txt still match requirements.txt + requirements-overrides.txt?
# Resolves against live PyPI (network), so it is kept out of scripts/setup.sh, which installs the lock as it is.
#   scripts/check_lock.sh            exit 0 = the lock matches, 1 = it changed (the diff is printed)
#   scripts/check_lock.sh --write    rewrite requirements-lock.txt from the new resolve (review the diff, then commit)
set -euo pipefail
cd "$(dirname "$0")/.."
write=0
case "${1:-}" in
  --write) write=1 ;;
  --help|-h) sed -n '2,5p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
  "") ;;
  *) echo "Unknown argument: $1" >&2; exit 2 ;;
esac
command -v uv >/dev/null || { echo 'Install uv first: https://docs.astral.sh/uv/getting-started/installation/' >&2; exit 1; }
py=.venv/bin/python
[[ -x "$py" ]] || py=3.12.12
tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT
resolved="$tmpdir/lock.txt"
uv pip compile requirements.txt --overrides requirements-overrides.txt \
  --python "$py" --no-header --no-annotate -o "$resolved" >/dev/null
if cmp -s requirements-lock.txt "$resolved"; then
  echo 'requirements-lock.txt matches requirements.txt.'
  exit 0
fi
if (( write )); then
  cp "$resolved" requirements-lock.txt
  echo 'Rewrote requirements-lock.txt: review git diff, run the tests, then commit.'
  exit 0
fi
diff -u requirements-lock.txt "$resolved" || true
echo 'Dependency closure changed: review the diff above, then scripts/check_lock.sh --write.' >&2
exit 1

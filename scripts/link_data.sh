#!/bin/bash
# One data folder for everything. With DRAFTER_DATA (or the folder given here) outside this clone, data/ in the clone
# becomes a link to it, so the app, the engine, training (scripts/train.sh), the nightly job and every bench script that
# writes data/... use that one folder. scripts/setup.sh runs it. It never moves or deletes a file.
#   scripts/link_data.sh [<folder>]     default: $DRAFTER_DATA; without one, nothing changes
set -euo pipefail
cd "$(dirname "$0")/.."
target=${1:-${DRAFTER_DATA:-}}
[[ -n "$target" ]] || exit 0
target=${target/#\~/$HOME}
mkdir -p "$target"
target=$(cd "$target" && pwd -P)
here=$(pwd -P)
[[ "$target" == "$here/data" ]] && exit 0          # the folder is data/ in this clone: nothing to link
if [[ -L data ]]; then
  old=$(readlink data)
  [[ "$old" == "$target" ]] && exit 0
  ln -sfn "$target" data                            # only the link changes; the old folder keeps its files
  echo "data/ now links to $target (before: $old, whose files stay where they are)."
  exit 0
fi
if [[ -e data && ! -d data ]]; then
  echo "data in this clone is a file, not a folder: move it aside, then run scripts/link_data.sh again." >&2; exit 1
fi
if [[ -d data ]]; then
  if [[ -n "$(ls -A data)" ]]; then
    echo "data/ in this clone holds files. Move them into $target yourself (nothing was moved), then run" >&2
    echo "scripts/link_data.sh again, so the app, training and the nightly job use one folder." >&2
    exit 1
  fi
  rmdir data
fi
ln -s "$target" data
echo "data/ links to $target: the app, the engine, training and the nightly job use that folder."

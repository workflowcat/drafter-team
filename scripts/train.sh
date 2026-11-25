#!/bin/bash
# Train on my writing: a small LoRA layer on your own lines, local only. Nothing leaves this Mac.
#
#   scripts/train.sh            build the corpus from the sources your config allows, then train
#   scripts/train.sh --check    build the corpus and say whether there is enough text; train nothing
#   scripts/train.sh --new      train a new layer from scratch even when one exists (the old one goes to data/adapters-prev)
#
# Sources: bench/corpus.py (typed lines and voice takes by default; more in data/drafter.local.json, "corpus").
# First layer: bench/make_train.py, then bench/train.py under the memory guard, into data/adapters.
# A layer exists: bench/retrain.py --force trains a new one and keeps it only if it beats the old one on your
# newest lines (that test needs chat and AI-app lines; without them, use --new).
# Quit Drafter first: training needs the memory the typing model uses. Restart Drafter after it to load the layer.
set -euo pipefail
cd "$(dirname "$0")/.."
PY=.venv/bin/python
MIN_LINES=${DRAFTER_MIN_LINES:-2000}
ITERS=${DRAFTER_TRAIN_ITERS:-1500}
check=0; new=0
for arg in "$@"; do
  case "$arg" in
    --check) check=1 ;;
    --new) new=1 ;;
    --help|-h) sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "Unknown argument: $arg (try --help)" >&2; exit 2 ;;
  esac
done
[[ -x $PY ]] || { echo 'Run scripts/setup.sh first (no .venv here).' >&2; exit 1; }
mkdir -p data

echo "Sources this Mac's config allows: $($PY -B bench/corpus.py --sources)"
$PY -B bench/corpus.py --no-beeper >/dev/null
lines=$(wc -l < data/corpus.jsonl | tr -d ' ')
echo "Your corpus: $lines lines (needs about $MIN_LINES)."
if (( lines < MIN_LINES )); then
  cat >&2 <<EOF
Too little of your own text to train on yet: $lines lines, and a layer needs about $MIN_LINES.
Drafter collects what you type while it runs (data/typed.jsonl) and your voice takes. Use it for a week or two,
or turn on more sources in data/drafter.local.json ("corpus": Claude Code and Codex sessions, a notes folder),
then run scripts/train.sh again. Drafter works without a layer: the base model already writes in your languages.
EOF
  exit 1
fi
(( check )) && { echo 'Enough text to train. Run scripts/train.sh without --check.'; exit 0; }

if curl -s -m 1 127.0.0.1:8798/health >/dev/null 2>&1; then
  echo 'Drafter is running. Quit it from the menu bar first (training needs its memory), then run this again.' >&2
  exit 1
fi

if [[ -d data/adapters && $new == 0 ]]; then
  echo 'A layer exists: training a new one and keeping it only if it does better on your newest lines.'
  exec $PY -B bench/retrain.py --force
fi

echo "Building the training set and training ($ITERS steps, 15 to 40 minutes on an M-series Mac)."
$PY -B bench/make_train.py --corpus data/corpus.jsonl
rm -rf data/adapters-new
$PY -B bench/train.py "$ITERS" --adapter-path data/adapters-new
[[ -f data/adapters-new/adapters.safetensors ]] || { echo 'Training did not finish; your old layer (if any) is untouched.' >&2; exit 1; }
if [[ -d data/adapters ]]; then rm -rf data/adapters-prev; mv data/adapters data/adapters-prev; fi
mv data/adapters-new data/adapters
echo 'Done: the new layer is in data/adapters (the previous one, if any, in data/adapters-prev). Open Drafter to use it.'

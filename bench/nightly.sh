#!/bin/zsh
# Nightly (launchd job, label from engine/local.py nightly_label; 04:30): review of yesterday's logs, then the weekly retrain if it is due
# and the Mac is idle and on power (bench/retrain.py decides). Output in data/review/nightly.log.
cd "${0:A:h:h}"
# launchd gives PATH=/usr/bin:/bin:/usr/sbin:/sbin; beeper (npm), gam and claude live outside it (8 November: no Beeper lines)
export PATH="$HOME/.npm-global/bin:$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"
y=$(date -u -v-1d +%Y-%m-%d)
# Logs: app.log keeps 14 days, older lines and big engine logs go gzipped to data/logs/ (8 weeks)
.venv/bin/python scripts/rotate_logs.py
# the journal in SQLite (phase 1): typed, takes and clipboard JSONL against data/journal.sqlite, numbers only; a
# difference shows here in the nightly log (scripts/journal_compare.py, exit 1)
mkdir -p data/review && { .venv/bin/python -B scripts/journal_compare.py || echo "journal compare: DIFFERENCE"; } >> data/review/nightly.log 2>&1
# Call audio older than 14 days with a transcript beside it moves to the Trash; text and notes stay
.venv/bin/python scripts/prune_audio.py
# Includes the optional daily Contacts refresh; missing/slow GAM keeps its cached snapshot.
# his writing as one dated corpus (typed, takes, Claude Code and Codex prompts, Beeper): training lines,
# phrase memory and the word finisher read it (bench/corpus.py)
.venv/bin/python bench/corpus.py > /dev/null
# his working sources into local stores, read-only and incremental (engine/sources.py): mail, the whole Beeper history,
# Docs and Drive; whom.py and the attach finder read them. Never style or training input.
.venv/bin/python engine/sources.py run
.venv/bin/python engine/know.py build
# the names reference from the pack, the entity store and his lines (data/names.json), then its derived files:
# known-words.txt for autocorrect, words.json terms order and mishearings for voice (engine/names.py)
.venv/bin/python engine/names.py build
# the ranked typo fix: word pairs he writes (data/typo-bigrams.tsv) and its gate refit on his offers (data/typo-gate.json)
.venv/bin/python -B engine/typos.py > /dev/null
.venv/bin/python bench/review.py "$y" > /dev/null
.venv/bin/python bench/retrain.py
# Fridays: the weekly page (data/review/week-*.md)
[[ $(date +%u) == 5 ]] && .venv/bin/python bench/week.py > /dev/null

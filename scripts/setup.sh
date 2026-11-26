#!/bin/bash
# Prepare locally; never launch Drafter, its engines or login services.
set -euo pipefail
cd "$(dirname "$0")/.."
models=0
voice=0
app=0
venv=.venv
usage() {
  cat <<'EOF_USAGE'
Usage: scripts/setup.sh [--models] [--voice] [--app] [--lean]

  The usual first run:  scripts/setup.sh --models --app     (add --voice for dictation and calls)

  (no flag)  check this Mac, make the Python environment, write data/drafter.local.json from the example
  --models   download the text model for typing (about 1 GB), the thesaurus for synonyms (about 20 MB) and the
             speaker model that tells voices apart in a call (about 40 MB)
  --voice    also download the two voice readers for dictation and calls (about 4.1 GB; implies --models)
  --app      build ~/Applications/Drafter.app (needs Apple Command Line Tools)
  --lean     a second environment (.venv-lean) only to check the install; not for the app

Free disk it asks for: about 3 GB for typing only, about 8 GB with --voice.
Nothing is started. Afterwards: open Drafter, grant the permissions printed at the end, and if you want it at login
run scripts/install-login.sh yourself. Train on your own writing later with scripts/train.sh.
EOF_USAGE
}
for arg in "$@"; do
  case "$arg" in
    --models) models=1 ;;
    --voice) voice=1; models=1 ;;
    --app) app=1 ;;
    --lean) venv=.venv-lean ;;
    --help|-h) usage; exit 0 ;;
    *) echo "Unknown argument: $arg" >&2; usage >&2; exit 2 ;;
  esac
done
if [[ "$venv" == .venv-lean ]] && (( app )); then
  echo "--lean is for environment validation; the installed app uses .venv. Do not combine --lean and --app." >&2
  exit 2
fi
[[ $(uname -s) == Darwin && $(uname -m) == arm64 ]] || { echo 'Requires native Apple-silicon macOS (not Rosetta).' >&2; exit 1; }
major=$(sw_vers -productVersion | cut -d. -f1)
(( major >= 15 )) || { echo 'Requires macOS 15 or newer (Swift app deployment target).' >&2; exit 1; }
# Room and memory: typing only about 3 GB (environment, text model, thesaurus), with voice about 8 GB (4.1 GB more,
# plus room to unpack). scripts/doctor.py checks the same two numbers.
need_gb=3; (( voice )) && need_gb=8
free_gb=$(df -g . | awk 'NR==2 {print $4}')
(( free_gb >= need_gb )) || { echo "Needs about $need_gb GB free on this disk; $free_gb GB is free." >&2; exit 1; }
ram_gb=$(( $(sysctl -n hw.memsize) / 1073741824 ))
if (( ram_gb < 16 )); then
  echo "Note: this Mac has $ram_gb GB of memory. Drafter is tested with 16 GB or more; typing alone may fit, voice and training may not."
fi
command -v uv >/dev/null || { echo 'Install uv first, then rerun this command: https://docs.astral.sh/uv/getting-started/installation/' >&2; exit 1; }
if (( app )); then
  xcrun --find swiftc >/dev/null || { echo 'Install Apple Command Line Tools first: xcode-select --install' >&2; exit 1; }
fi
export HF_HUB_DISABLE_TELEMETRY=1
export HF_HUB_DISABLE_IMPLICIT_TOKEN=1
if [[ ! -d "$venv" ]]; then
  uv venv --python 3.12.12 "$venv"
fi
"$venv/bin/python" -c 'import sys; assert sys.version_info[:3] == (3,12,12), "Existing .venv must use Python 3.12.12; move it aside first"'
# Resolve with explicit exclusions, then demand the checked-in closure unchanged.
# This catches upstream metadata drift instead of installing unreviewed packages.
tmpdir=$(mktemp -d)
resolved="$tmpdir/lock.txt"
trap 'rm -rf "$tmpdir"' EXIT
uv pip compile requirements.txt --overrides requirements-overrides.txt \
  --python "$venv/bin/python" --no-header --no-annotate -o "$resolved" >/dev/null
cmp requirements-lock.txt "$resolved" || { echo 'Dependency closure changed; review and regenerate the lock.' >&2; exit 1; }
uv pip sync --python "$venv/bin/python" "$resolved"
"$venv/bin/python" scripts/check_install.py
# First-run config: your name, languages and optional integrations, all in one untracked file (never in git).
mkdir -p data
if [[ ! -f data/drafter.local.json ]]; then
  cp drafter.local.example.json data/drafter.local.json
  echo 'Wrote data/drafter.local.json from the example: put your name and languages in "user". Integrations stay off.'
fi
if (( models )); then
  if (( voice )); then "$venv/bin/python" scripts/download_models.py --voice
  else "$venv/bin/python" scripts/download_models.py; fi
  # offline synonyms for ⌥Tab (about 20 MB, LibreOffice thesaurus files; their licences in the script)
  "$venv/bin/python" scripts/download_thesaurus.py || echo 'Thesaurus download failed: ⌥Tab shows no synonyms until it is rerun.'
  # who said what in a call (engine/speakers.py, about 40 MB)
  "$venv/bin/python" scripts/download_speakers.py || echo 'Speaker model download failed: call lines keep Я / Вони until it is rerun.'
fi
if (( app )); then
  ./app/build.sh
fi
if ! command -v ffmpeg >/dev/null; then
  echo 'ffmpeg is absent: install it for non-PCM audio file decoding. Native recorded WAVs need no decoder.'
fi
if command -v claude >/dev/null || [[ -x "$HOME/.local/bin/claude" ]]; then
  echo 'Found a claude CLI. It is not used until you pick it under Settings > Cloud > Connect a model.'
fi
cat <<'EOF_NEXT'
Environment ready. Nothing was started.

Next steps (docs/onboarding.md has them in full):
  1. Open ~/Applications/Drafter.app (build it with --app). A pen appears in the menu bar.
  2. Accessibility (System Settings > Privacy & Security): required. Drafter reads the field you type in, puts the
     ghost text there and sees Tab and Right Option. Quit and reopen Drafter after you turn it on.
  3. Put your name and languages in data/drafter.local.json ("user").
  4. Voice starts off: turn on "Voice on Right Option" in the menu bar pen, then allow the Microphone (needs --voice).
  5. Optional: Screen & System Audio Recording, for the other side of a call and for text above the caret when an
     app gives none. While a call or long note records, Drafter keeps screenshots of your screen in
     data/calls/<time>/shots/ (on this Mac only). Turn that off in Settings: "Screenshots while recording".
     Screen video of a call is off unless you turn it on.
  6. Optional: Calendars, for meeting notes before a calendar event and for the event and reminder chips.
  7. Optional: Settings > Cloud > Connect a model. Nothing leaves this Mac until you connect one and turn on a switch.
  8. Optional: start at login with scripts/install-login.sh, then the one command it prints.
Then run python3 scripts/doctor.py again.
EOF_NEXT

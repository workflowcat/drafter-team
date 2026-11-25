#!/bin/bash
# Start Drafter at login (a launchd agent in ~/Library/LaunchAgents). You run this yourself; setup.sh never does.
#
#   scripts/install-login.sh             write the agent and print the one command that loads it
#   scripts/install-login.sh --nightly   also the optional 04:30 job (logs, review, weekly retrain)
#   scripts/install-login.sh --remove    print the commands that unload and delete both
#
# The label comes from data/drafter.local.json (build.launchd_label, build.nightly_label).
set -euo pipefail
cd "$(dirname "$0")/.."
here=$(pwd)
nightly=0; remove=0
for arg in "$@"; do
  case "$arg" in
    --nightly) nightly=1 ;;
    --remove) remove=1 ;;
    --help|-h) sed -n '2,8p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "Unknown argument: $arg (try --help)" >&2; exit 2 ;;
  esac
done
label=$(/usr/bin/python3 engine/local.py --get launchd_label)
nlabel=$(/usr/bin/python3 engine/local.py --get nightly_label)
agents="$HOME/Library/LaunchAgents"
if (( remove )); then
  for l in "$label" "$nlabel"; do
    if [[ -f "$agents/$l.plist" ]]; then echo "launchctl bootout gui/$(id -u)/$l; rm '$agents/$l.plist'"; fi
  done
  exit 0
fi
app="$HOME/Applications/Drafter.app"
[[ -x "$app/Contents/MacOS/Drafter" ]] || { echo "Build the app first: scripts/setup.sh --app (no $app yet)." >&2; exit 1; }
mkdir -p "$agents" data/review
fill() { sed -e "s|@LABEL@|$2|g" -e "s|@APP@|$app|g" -e "s|@HOME_DIR@|$here|g" "scripts/launchd/$1.plist.template" > "$agents/$2.plist"; }
fill app "$label"
echo "Wrote $agents/$label.plist. To start Drafter now and at every login, run:"
echo "  launchctl bootstrap gui/\$(id -u) '$agents/$label.plist'"
if (( nightly )); then
  fill nightly "$nlabel"
  echo "Wrote $agents/$nlabel.plist. To turn on the nightly job, run:"
  echo "  launchctl bootstrap gui/\$(id -u) '$agents/$nlabel.plist'"
fi

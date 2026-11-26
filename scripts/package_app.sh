#!/bin/bash
# A prebuilt Drafter.app for teammates who have no Xcode or Command Line Tools. Never touches ~/Applications/Drafter.app
# and never opens or starts the app it builds.
set -euo pipefail
cd "$(dirname "$0")/.."
root=$(pwd)
home='~/drafter-team'
dry=0
usage() {
  cat <<'EOF_USAGE'
Usage: scripts/package_app.sh [--home <folder>] [--dry-run]

Builds build/dist/Drafter.app and packs it as build/dist/Drafter-macos-arm64.zip (build/ is not in git).

  --home <folder>   the clone the app runs its engine from on a teammate's Mac (default: ~/drafter-team). They clone
                    the repo there and run scripts/setup.sh --models (no --app), then unzip the app into ~/Applications.
  --dry-run         print the steps, build nothing

Environment:
  DRAFTER_CODESIGN_IDENTITY   Developer ID Application identity (else build.codesign_identity in the local config;
                              empty = ad-hoc, which only runs on the Mac that built it without a Gatekeeper prompt)
  DRAFTER_NOTARY_PROFILE      a notarytool keychain profile (xcrun notarytool store-credentials); when set the app is
                              notarized and stapled. Needs a Developer ID identity.
  DRAFTER_DATA                a data folder to bake into the app (else build.data_dir; empty = <home>/data)
EOF_USAGE
}
while (( $# )); do
  case "$1" in
    --home) [[ $# -ge 2 ]] || { usage >&2; exit 2; }; home=$2; shift ;;
    --dry-run) dry=1 ;;
    --help|-h) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done
dist="$root/build/dist"
app="$dist/Drafter.app"
zip="$dist/Drafter-macos-arm64.zip"
profile=${DRAFTER_NOTARY_PROFILE:-}
if (( dry )); then
  echo "build:    DRAFTER_APP_OUT=$app DRAFTER_APP_HOME=$home app/build.sh"
  [[ -n "$profile" ]] && echo "notarize: xcrun notarytool submit --wait --keychain-profile $profile, then xcrun stapler staple"
  echo "pack:     ditto -c -k --keepParent $app $zip"
  exit 0
fi
[[ $(uname -s) == Darwin && $(uname -m) == arm64 ]] || { echo 'Requires native Apple-silicon macOS.' >&2; exit 1; }
xcrun --find swiftc >/dev/null || { echo 'Install Apple Command Line Tools first: xcode-select --install' >&2; exit 1; }
mkdir -p "$dist"
rm -rf "$app" "$zip"
DRAFTER_APP_OUT="$app" DRAFTER_APP_HOME="$home" zsh app/build.sh
if [[ -n "$profile" ]]; then
  if codesign -dv "$app" 2>&1 | grep -q 'Signature=adhoc'; then
    echo 'Notarizing needs a Developer ID: set DRAFTER_CODESIGN_IDENTITY or build.codesign_identity.' >&2; exit 1
  fi
  tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
  ditto -c -k --keepParent "$app" "$tmp/Drafter.zip"
  xcrun notarytool submit "$tmp/Drafter.zip" --wait --keychain-profile "$profile"
  xcrun stapler staple "$app"
  xcrun stapler validate "$app"
fi
ditto -c -k --keepParent "$app" "$zip"
echo "Packed $zip"
echo "On a teammate's Mac: clone to $home, scripts/setup.sh --models (add --voice), unzip into ~/Applications, open it."

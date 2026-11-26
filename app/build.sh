#!/bin/zsh
# Builds ~/Applications/Drafter.app (Command Line Tools only, no Xcode). Never opens or starts the app.
#   DRAFTER_APP_OUT=<path>.app          build there instead (scripts/package_app.sh: build/dist/Drafter.app)
#   DRAFTER_APP_HOME=<folder>           the clone the app runs its engine from (default: this clone; "~/…" allowed)
#   DRAFTER_CODESIGN_IDENTITY=<id>      sign with a Developer ID (else build.codesign_identity in the local config;
#                                       empty or "-" = ad-hoc)
#   DRAFTER_DATA=<folder>               bake a data folder into Info.plist (else build.data_dir; empty = none)
set -e
APP=${DRAFTER_APP_OUT:-~/Applications/Drafter.app}
APP=${APP:a}          # a relative DRAFTER_APP_OUT is from the folder you ran this in
cd "${0:A:h}"
HOME_DIR=${DRAFTER_APP_HOME:-${PWD:h}}
# The bundle id comes from the local config (build.bundle_id), else the public default in engine/local.py. Changing it on a
# Mac that already granted Accessibility, Microphone etc. resets those grants.
ID=$(/usr/bin/python3 ../engine/local.py --get bundle_id)
SIGN_ID=${DRAFTER_CODESIGN_IDENTITY:-$(/usr/bin/python3 ../engine/local.py --get codesign_identity)}
DATA_DIR=${DRAFTER_DATA:-$(/usr/bin/python3 ../engine/local.py --get data_dir)}
mkdir -p build
# whole-module, on every core (review 25 November 2026, Gemini: 144 s once; the plain -O build took about 4 min, not a clean comparison)
swiftc -swift-version 5 -O -wmo -num-threads $(sysctl -n hw.ncpu) -parse-as-library -target arm64-apple-macosx15.0 *.swift -o build/Drafter
# Built and signed beside the installed app, then swapped in (review 25 November 2026: removing it first left no
# app at all when a later step failed). The running copy keeps its open binary through the move.
NEW="$APP.new"; OLD="$APP.old"
rm -rf "$NEW" "$OLD"
mkdir -p "$NEW/Contents/MacOS" "$NEW/Contents/Resources"
cp build/Drafter "$NEW/Contents/MacOS/"
cp Info.plist "$NEW/Contents/"
cp icon/Drafter.icns "$NEW/Contents/Resources/"
/usr/libexec/PlistBuddy -c "Add :DrafterHome string $HOME_DIR" "$NEW/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $ID" "$NEW/Contents/Info.plist"
if [[ -n "$DATA_DIR" ]]; then
  /usr/libexec/PlistBuddy -c "Add :DrafterData string $DATA_DIR" "$NEW/Contents/Info.plist"
  # training, the nightly job and the bench scripts use data/ in the clone: it must be (a link to) the same folder
  if [[ -z "$DRAFTER_APP_OUT" && "$(cd "${DATA_DIR/#\~/$HOME}" 2>/dev/null && pwd -P)" != "$(cd ../data 2>/dev/null && pwd -P)" ]]; then
    echo "Note: the app keeps data in $DATA_DIR but data/ in this clone is another folder. Run" >&2
    echo "  scripts/link_data.sh $DATA_DIR" >&2
    echo "so training and the nightly job use the same folder." >&2
  fi
fi
if [[ -n "$SIGN_ID" && "$SIGN_ID" != "-" ]]; then
  # Developer ID with the hardened runtime (needed for notarization); the entitlements keep the microphone and calendar
  # prompts working under it.
  ENT=build/Drafter.entitlements
  cat > "$ENT" <<'EOF_ENT'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>com.apple.security.device.audio-input</key><true/>
  <key>com.apple.security.personal-information.calendars</key><true/>
  <key>com.apple.security.automation.apple-events</key><true/>
</dict>
</plist>
EOF_ENT
  codesign --force --options runtime --timestamp --entitlements "$ENT" -s "$SIGN_ID" "$NEW"
else
  # Ad-hoc with a fixed requirement, so macOS keeps the Accessibility and Calendar grants across rebuilds.
  codesign --force -s - -r="designated => identifier \"$ID\"" "$NEW"
fi
codesign --verify "$NEW"
[ -d "$APP" ] && mv "$APP" "$OLD"
mv "$NEW" "$APP"
rm -rf "$OLD"
# Only the installed copy is registered with Launch Services; a packaged copy (DRAFTER_APP_OUT) stays out of it.
if [[ -z "$DRAFTER_APP_OUT" ]]; then
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP"
fi
echo "Built $APP"

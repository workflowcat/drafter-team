#!/bin/zsh
# Builds ~/Applications/Drafter.app (Command Line Tools only, no Xcode).
set -e
cd "${0:A:h}"
APP=~/Applications/Drafter.app
# The bundle id comes from the local config (build.bundle_id), else the public default in engine/local.py. Changing it on a
# Mac that already granted Accessibility, Microphone etc. resets those grants.
ID=$(/usr/bin/python3 ../engine/local.py --get bundle_id)
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
/usr/libexec/PlistBuddy -c "Add :DrafterHome string ${PWD:h}" "$NEW/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $ID" "$NEW/Contents/Info.plist"
# Fixed requirement, so macOS keeps the Accessibility and Calendar grants across rebuilds.
codesign --force -s - -r="designated => identifier \"$ID\"" "$NEW"
codesign --verify "$NEW"
[ -d "$APP" ] && mv "$APP" "$OLD"
mv "$NEW" "$APP"
rm -rf "$OLD"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP"
echo "Built $APP"

#!/bin/zsh
# Renders the recording window (notes, transcript, paused) and the small notch, light and dark, into <out>
# (default docs/look/2026-11-17-record). A preview copy in app/build/RecordPreview.app whose DrafterHome is an empty
# temp folder: made-up text only, never installs, never starts or stops the live app, never reads data/.
# Usage: zsh scripts/record-preview.sh [out]
set -e
root=${0:A:h:h}; out=${1:-$root/docs/look/2026-11-17-record}; out=${out:A}
app=$root/app/build/RecordPreview.app; tmp=$(mktemp -d -t drafter-record)
rm -rf $app; mkdir -p $tmp/data $app/Contents/MacOS $app/Contents/Resources $out
swiftc -swift-version 5 -parse-as-library -target arm64-apple-macosx15.0 $root/app/*.swift -o $app/Contents/MacOS/Drafter
cp $root/app/Info.plist $app/Contents/
/usr/libexec/PlistBuddy -c "Add :DrafterHome string $tmp" $app/Contents/Info.plist
PREVIEW_ONLY=record $app/Contents/MacOS/Drafter --ui-preview $out
PREVIEW_ONLY=record $app/Contents/MacOS/Drafter --ui-preview $out --dark
[[ -n $WITH_WINDOW ]] && PREVIEW_ONLY=window $app/Contents/MacOS/Drafter --ui-preview $out/window
[[ -n $WITH_WINDOW ]] && PREVIEW_ONLY=window $app/Contents/MacOS/Drafter --ui-preview $out/window-dark --dark
[[ -n $(ls $tmp/data) ]] && echo "scratch data written: $(ls $tmp/data | tr '\n' ' ')"
rm -rf $tmp

#!/bin/zsh
# Renders both strip styles (Settings > Look > Strip) in every state, light and dark, housing and external display, and
# one contact sheet per style and theme into <out> (default docs/look/2026-11-14-strip). Builds a preview copy in app/build/StripPreview.app whose DrafterHome is
# an empty temp folder: made-up text only, never installs, never starts or stops the live app, never reads data/.
# Usage: zsh scripts/strip-preview.sh [out]
set -e
root=${0:A:h:h}; out=${1:-$root/docs/look/2026-11-14-strip}; out=${out:A}
app=$root/app/build/StripPreview.app; tmp=$(mktemp -d -t drafter-strip)
rm -rf $app; mkdir -p $tmp/data $app/Contents/MacOS $app/Contents/Resources $out
swiftc -swift-version 5 -parse-as-library -target arm64-apple-macosx15.0 $root/app/*.swift -o $app/Contents/MacOS/Drafter
cp $root/app/Info.plist $app/Contents/
/usr/libexec/PlistBuddy -c "Add :DrafterHome string $tmp" $app/Contents/Info.plist
PREVIEW_ONLY=strips STRIP_ONLY=${STRIP_ONLY:-} $app/Contents/MacOS/Drafter --ui-preview $out
[[ -n $(ls $tmp/data) ]] && echo "scratch data written: $(ls $tmp/data | tr '\n' ' ')"
rm -rf $tmp

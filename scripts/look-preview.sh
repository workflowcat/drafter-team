#!/bin/zsh
# Renders the app's own preview pictures (window pages, strip, ghost and chips) in both appearances into <out>/light and
# <out>/dark, from a scratch copy built in a temp folder whose DrafterHome is an empty temp folder: made-up records only.
# Never installs, never starts or stops the live app, never reads data/. Usage: zsh scripts/look-preview.sh <out>
set -e
root=${0:A:h:h}; out=${1:?usage: look-preview.sh <out>}; out=${out:A}
tmp=$(mktemp -d -t drafter-look)
app=$tmp/Drafter.app
mkdir -p $tmp/home/data $app/Contents/MacOS $app/Contents/Resources
# the incremental -Onone build (scripts/swift_fast_check.sh): seconds after a small change instead of a full compile
zsh $root/scripts/swift_fast_check.sh --link >/dev/null
cp $root/app/build/incremental/Drafter $app/Contents/MacOS/Drafter
cp $root/app/Info.plist $app/Contents/
/usr/libexec/PlistBuddy -c "Add :DrafterHome string $tmp/home" $app/Contents/Info.plist
for theme in light dark; do
  mkdir -p $out/$theme
  $app/Contents/MacOS/Drafter --ui-preview $out/$theme ${${theme:#light}:+--dark}
done
[[ -n $(ls $tmp/home/data) ]] && echo "scratch data written: $(ls $tmp/home/data | tr '\n' ' ')"
rm -rf $tmp

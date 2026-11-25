#!/bin/zsh
# Transcribe-file test (17 November 2026): made-up speech from `say` into an m4a, handed to the running Drafter as if
# dropped on it (the .filetest hook). The new folder is data/calls/<time>-file; delete it after the check.
# Usage: zsh bench/file_test.sh [m4a|mov|wav]   prints the source path
kind=${1:-m4a}
dir=$(mktemp -d /tmp/drafter-file.XXXX)
src=$dir/drafter-test-file.$kind
say -o $dir/s.aiff "Hello, this is a test of reading a file. We agree on the plan for Friday. Anna will send the draft by noon, and I will check the numbers."
case $kind in
  wav) afconvert -f WAVE -d LEI16@44100 $dir/s.aiff $src ;;
  mov) afconvert -f 'mp4f' -d aac $dir/s.aiff $dir/a.m4a && cp $dir/a.m4a $src ;;
  *)   afconvert -f m4af -d aac $dir/s.aiff $src ;;
esac
osascript -l JavaScript -e "ObjC.import('Foundation'); \$.NSDistributedNotificationCenter.defaultCenter.postNotificationNameObjectUserInfoDeliverImmediately('$(/usr/bin/python3 ${0:A:h:h}/engine/local.py --get bundle_id).filetest', '$src', \$(), true)" >/dev/null
echo $src

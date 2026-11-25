#!/bin/zsh
# Feeds a 16 kHz 16-bit wav through Drafter's running voice path, as if spoken into the focused field.
# bench/voice_test.sh <file under the repo folder>
osascript -l JavaScript -e "ObjC.import('Foundation'); \$.NSDistributedNotificationCenter.defaultCenter.postNotificationNameObjectUserInfoDeliverImmediately('$(/usr/bin/python3 ${0:A:h:h}/engine/local.py --get bundle_id).voicetest', '${1:A}', \$(), true)"

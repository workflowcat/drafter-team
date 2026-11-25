#!/bin/zsh
# Shows Drafter's voice strip ("strip", default) or the recording bar ("rec") for a few seconds and takes a picture of
# the top of the screen into data/strip.png.
osascript -l JavaScript -e "ObjC.import('Foundation'); \$.NSDistributedNotificationCenter.defaultCenter.postNotificationNameObjectUserInfoDeliverImmediately('$(/usr/bin/python3 ${0:A:h:h}/engine/local.py --get bundle_id).${1:-strip}test', \$(), \$(), true)"
sleep 1.6
open -n -W -a ~/Applications/Drafter.app --args --shot "${0:A:h:h}/data/strip.png"

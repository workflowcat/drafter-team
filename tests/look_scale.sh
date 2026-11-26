#!/bin/zsh
# The look's one type scale (app/Look.swift, Native.scale): every text size in app/ is one of 10 11 12 13 14 15 17 22.
# Usage: zsh tests/look_scale.sh
cd ${0:A:h:h}/app
bad=$(grep -noE "(NativeFont|Native)\.(text|mono|num|body|display)\([0-9.]+" *.swift | grep -v "^Preview" \
      | grep -vE "\((10|11|12|13|14|15|17|22)$")
if [[ -n $bad ]]; then echo "sizes off the scale:"; echo $bad; exit 1; fi
echo "look scale: ok"

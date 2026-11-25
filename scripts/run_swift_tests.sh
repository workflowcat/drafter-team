#!/bin/zsh
# Every Swift test in tests/, each by the compile line at the top of its file (`// swiftc ... && app/build/x-test`),
# several at once. Prints one line per file and exits 1 if any failed. A failure keeps its whole output in
# app/build/test-logs/<name>.log (review 25 November 2026: one cut line was not enough to fix a release), and a
# "cannot find X in scope" names the app file that defines X, the usual cause (a new app file not in the line).
# A test built by another runner says so in its first lines: `// swift-runner: skip (why)`. Neither line: fail.
#   zsh scripts/run_swift_tests.sh [name-part ...]     # no argument = all
#   JOBS=1 zsh scripts/run_swift_tests.sh               # one at a time
cd "${0:A:h:h}" || exit 1
mkdir -p app/build
LOGS=app/build/test-logs; rm -rf $LOGS; mkdir -p $LOGS
JOBS=${JOBS:-$(( $(sysctl -n hw.ncpu) / 2 ))}; (( JOBS < 1 )) && JOBS=1
files=()
for f in tests/*.swift; do
  if (( $# )); then hit=0; for p in "$@"; do [[ $f == *$p* ]] && hit=1; done; (( hit )) || continue; fi
  files+=$f
done
run_one() {
  local f=$1 name=${1:t:r} line
  line=$(head -12 "$f" | grep -m1 -E '^// *swiftc ' | sed -E 's|^// *||')
  if [[ -z $line ]]; then
    if head -3 "$f" | grep -q '^// swift-runner: skip'; then print "skip  ${f:t}" > $LOGS/$name.res; return; fi
    print "FAIL  ${f:t}: no compile line and no '// swift-runner: skip' line" > $LOGS/$name.res; return
  fi
  local out
  if out=$(eval "$line" 2>&1); then print "ok    ${f:t}" > $LOGS/$name.res; return; fi
  print -r -- "$out" > $LOGS/$name.log
  local hint="" sym
  for sym in $(print -r -- "$out" | grep -oE "cannot find (type )?'[A-Za-z_][A-Za-z0-9_]*' in scope" | sed -E "s/.*'(.*)'.*/\1/" | sort -u | head -3); do
    local def=$(grep -lE "^(public |private |fileprivate )?(final )?(enum|struct|class|typealias|protocol|func|let|var) $sym\\b" app/*.swift | head -1)
    [[ -n $def ]] && hint="$hint; add $def ($sym)"
  done
  print "FAIL  ${f:t}: $(print -r -- "$out" | grep -m1 -E 'error:|FAIL|failed' | cut -c1-160)$hint -> $LOGS/$name.log" > $LOGS/$name.res
}
zmodload zsh/parameter
for f in $files; do
  while (( ${#jobstates} >= JOBS )); do sleep 0.05; done
  run_one $f &
done
wait
ran=0; fail=()
for f in $files; do
  r=$(cat $LOGS/${f:t:r}.res 2>/dev/null || echo "FAIL  ${f:t}: no result")
  print -r -- "$r"
  [[ $r == skip* ]] || ran=$((ran+1))
  [[ $r == FAIL* ]] && fail+=(${f:t})
done
rm -f $LOGS/*.res
echo "swift tests: ran $ran; failed: ${fail[*]}"
(( ${#fail} == 0 ))

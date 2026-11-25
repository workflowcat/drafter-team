#!/bin/zsh
# Every Python test file in its own process, from the repo root; prints the failures and exits 1 on any.
#   zsh scripts/run_tests.sh [python]      (default: .venv/bin/python next to this repo)
cd "${0:A:h:h}"
PY=${1:-.venv/bin/python}
[[ -x $PY ]] || PY=${0:A:h:h:h:h}/.venv/bin/python   # a worktree under .worktrees/ uses the main checkout's venv
fail=0; n=0
for t in tests/test_*.py; do
  n=$((n+1))
  if ! out=$($PY -B $t 2>&1); then fail=$((fail+1)); print -r -- "FAIL $t"; print -r -- "$out" | tail -15; fi
done
print "$((n-fail))/$n test files pass"
(( fail == 0 ))

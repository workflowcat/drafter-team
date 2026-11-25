#!/bin/zsh
# Fast incremental Swift check/compile for app/*.swift (Command Line Tools only, no Xcode).
# Uses swiftc -incremental + parallel jobs + output-file-map cached under app/build/incremental/.
#
# Usage:
#   zsh scripts/swift_fast_check.sh [--clean] [--link] [-v|--verbose] [-j N]
#
# Options:
#   --clean      Remove app/build/incremental/ before compiling (forces a cold build).
#   --link       Also link a debug binary at app/build/incremental/Drafter (checks symbols & @main).
#   -v,--verbose Pass -driver-show-incremental to swiftc to log recompiled files.
#   -j N         Parallel jobs (default: all logical CPUs via sysctl -n hw.ncpu).
set -euo pipefail
zmodload zsh/datetime

ROOT="${0:A:h:h}"
APP_DIR="$ROOT/app"
CACHE="$APP_DIR/build/incremental"
JOBS=$(sysctl -n hw.ncpu 2>/dev/null || echo 8)
CLEAN=0
LINK=0
VERBOSE=0

while (( $# > 0 )); do
  case "$1" in
    --clean) CLEAN=1 ;;
    --link) LINK=1 ;;
    -v|--verbose) VERBOSE=1 ;;
    -j)
      shift
      if (( $# == 0 )); then echo "swift_fast_check: -j requires a number" >&2; exit 2; fi
      JOBS="$1"
      ;;
    -h|--help)
      sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *)
      echo "swift_fast_check: unknown option: $1" >&2
      exit 2
      ;;
  esac
  shift
done

if (( CLEAN )); then
  rm -rf "$CACHE"
fi

MODE="warm"
[[ -f "$CACHE/build.priors" || -f "$CACHE/build.swiftdeps" ]] || MODE="cold"

mkdir -p "$CACHE/obj" "$CACHE/deps"

typeset -a SOURCES
SOURCES=("$APP_DIR"/*.swift(N))
if (( ${#SOURCES} == 0 )); then
  echo "swift_fast_check: no Swift sources found in $APP_DIR" >&2
  exit 1
fi

MAP="$CACHE/output-file-map.json"
/usr/bin/python3 - "$CACHE" "$MAP" "${SOURCES[@]}" <<'PY'
import json, os, sys
from pathlib import Path

cache = Path(sys.argv[1])
out_map = Path(sys.argv[2])
sources = sys.argv[3:]

data = {"": {"swift-dependencies": str(cache / "build.swiftdeps")}}
for src in sources:
    stem = Path(src).stem
    data[src] = {
        "object": str(cache / "obj" / f"{stem}.o"),
        "swift-dependencies": str(cache / "deps" / f"{stem}.swiftdeps"),
        "dependencies": str(cache / "deps" / f"{stem}.d"),
    }

encoded = json.dumps(data, indent=2, sort_keys=True) + "\n"
if not out_map.exists() or out_map.read_text() != encoded:
    tmp = out_map.with_suffix(".tmp")
    tmp.write_text(encoded)
    os.replace(tmp, out_map)
PY

typeset -a CMD
CMD=(
  swiftc
  -swift-version 5
  -Onone
  -parse-as-library
  -target arm64-apple-macosx15.0
  -module-name Drafter
  -incremental
  -j "$JOBS"
  -output-file-map "$MAP"
)

if (( VERBOSE )); then
  CMD+=(-driver-show-incremental)
fi

if (( LINK )); then
  CMD+=(-o "$CACHE/Drafter")
  ACTION="build+link"
else
  CMD+=(-c)
  ACTION="check"
fi

CMD+=("${SOURCES[@]}")

T0=$EPOCHREALTIME
"${CMD[@]}"
T1=$EPOCHREALTIME
ELAPSED=$(printf '%.2f' $(( T1 - T0 )))

echo "swift_fast_check: OK ($ACTION, ${#SOURCES} files, $JOBS jobs, $MODE) in ${ELAPSED}s"

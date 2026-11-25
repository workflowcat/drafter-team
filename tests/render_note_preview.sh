#!/bin/zsh
# Render Track 7A with synthetic fixtures. Never install, start the app delegate, or read the live data folder.
set -euo pipefail
cd "${0:A:h:h}"
mkdir -p app/build
python3 - <<'PY'
from pathlib import Path
import plistlib
root = Path.cwd()
build = root / 'app/build'
bundle = build / 'Wave7Preview.app'
home = build / 'wave7-preview-home'
(bundle / 'Contents/MacOS').mkdir(parents=True, exist_ok=True)
(bundle / 'Contents/Resources').mkdir(parents=True, exist_ok=True)
(home / 'data').mkdir(parents=True, exist_ok=True)
info = {'CFBundleIdentifier': 'local.drafter.wave7-preview', 'CFBundleName': 'Wave7Preview',
        'CFBundleExecutable': 'Wave7Preview', 'DrafterHome': str(home)}
(bundle / 'Contents/Info.plist').write_bytes(plistlib.dumps(info))
(build / 'Main-preview.swift').write_text((root / 'app/Main.swift').read_text().replace('@main\nstruct Main', 'struct Main'))
PY
sources=(app/*.swift)
sources=(${sources:#app/Main.swift})
swiftc -swift-version 5 -parse-as-library -target arm64-apple-macosx15.0 -j 2 \
  "${sources[@]}" app/build/Main-preview.swift tests/note_preview_visual.swift \
  -o app/build/Wave7Preview.app/Contents/MacOS/Wave7Preview
app/build/Wave7Preview.app/Contents/MacOS/Wave7Preview
app/build/Wave7Preview.app/Contents/MacOS/Wave7Preview --dark

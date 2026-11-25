"""Download the two offline thesaurus files for ⌥Tab synonyms (engine/synonyms.py) into models/thesaurus/.
Never in git: models/ is ignored, and the files keep their own licences.

    .venv/bin/python scripts/download_thesaurus.py

From LibreOffice's official dictionaries repository (GitHub mirror of git.libreoffice.org/dictionaries), pinned to one
commit and checked by SHA-256:
  th_en_US_v2.dat  18.6 MB  WordNet 2.1 thesaurus, Princeton WordNet licence (en/WordNet_license.txt)
  th_uk_UA.dat      1.0 MB  Ukrainian thesaurus 1.6.0, Andriy Rysin, GPL / LGPL / MPL (uk_UA/README_th_uk_UA.txt)
A missing file only means no synonyms in that language.
"""
import hashlib, sys, urllib.request
from pathlib import Path

COMMIT = "c0865a85eb67dc377f2cf8e8fe2c4fa9e53f0dcb"
BASE = f"https://raw.githubusercontent.com/LibreOffice/dictionaries/{COMMIT}/"
FILES = [
    ("en/th_en_US_v2.dat", "8a3e4637450b7277428da248f0a604b5c92942bc30507220c051181462340f39"),
    ("uk_UA/th_uk_UA.dat", "2b03a9db86edd727ae1328a54b94d448db1eacf8a877642f0b38fba300141fbb"),
]
OUT = Path(__file__).resolve().parent.parent / "models" / "thesaurus"

if __name__ == "__main__":
    OUT.mkdir(parents=True, exist_ok=True)
    bad = 0
    for src, sha in FILES:
        dest = OUT / Path(src).name
        if dest.exists() and hashlib.sha256(dest.read_bytes()).hexdigest() == sha:
            print(f"  {dest.name}: present", flush=True); continue
        data = urllib.request.urlopen(BASE + src, timeout=60).read()
        if hashlib.sha256(data).hexdigest() != sha:
            print(f"  {dest.name}: checksum differs, not saved", file=sys.stderr); bad += 1; continue
        tmp = dest.with_suffix(".tmp"); tmp.write_bytes(data); tmp.replace(dest)
        print(f"  {dest.name}: {len(data) / 1e6:.1f} MB", flush=True)
    sys.exit(1 if bad else 0)

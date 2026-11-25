"""Download the speaker-embedding model engine/speakers.py uses to tell voices apart in a call, into models/speakers/.
Never in git: models/ is ignored.

    .venv/bin/python scripts/download_speakers.py

3D-Speaker ERes2Net base (16 kHz, 512-number voice vectors, 39.6 MB, Apache-2.0), the ONNX export from the official
sherpa-onnx releases, checked by SHA-256. Without it, call lines keep their track labels (Я / Вони).
"""
import hashlib, sys, urllib.request
from pathlib import Path

NAME = "3dspeaker_speech_eres2net_base_sv_zh-cn_3dspeaker_16k.onnx"
URL = "https://github.com/k2-fsa/sherpa-onnx/releases/download/speaker-recongition-models/" + NAME
SHA = "1a331345f04805badbb495c775a6ddffcdd1a732567d5ec8b3d5749e3c7a5e4b"
OUT = Path(__file__).resolve().parent.parent / "models" / "speakers"

if __name__ == "__main__":
    OUT.mkdir(parents=True, exist_ok=True)
    dest = OUT / NAME
    if dest.exists() and hashlib.sha256(dest.read_bytes()).hexdigest() == SHA:
        print(f"  {NAME}: present"); sys.exit(0)
    data = urllib.request.urlopen(URL, timeout=120).read()
    if hashlib.sha256(data).hexdigest() != SHA:
        print(f"  {NAME}: checksum differs, not saved", file=sys.stderr); sys.exit(1)
    dest.write_bytes(data)
    print(f"  {NAME}: {len(data) / 1e6:.1f} MB")

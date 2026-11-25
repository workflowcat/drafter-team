"""How long after the press he starts to speak, on saved takes (data/audio/*.wav), numbers only, no model.

The saved take starts with the 0.6 s pre-roll when "Keep the microphone ready" is on, so speech start after the press
is the SpeechClock start minus --preroll. With the log's "first words" (counted from the press) this splits that
number into his pause and the engine's part. .venv/bin/python -B bench/speech_start.py --audio <data/audio> [--takes 300]
"""
import argparse, glob, os, sys, wave
from pathlib import Path
import numpy as np
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "engine"))
from voice_timing import SpeechClock, RATE

ap = argparse.ArgumentParser()
ap.add_argument("--audio", type=Path, required=True); ap.add_argument("--takes", type=int, default=300)
ap.add_argument("--preroll", type=float, default=0.6)
a = ap.parse_args()
starts = []
for f in sorted(glob.glob(str(a.audio / "*.wav")), key=os.path.getmtime)[-a.takes:]:
    with wave.open(f) as w:
        if w.getframerate() != RATE or w.getnchannels() != 1: continue
        x = np.frombuffer(w.readframes(w.getnframes()), dtype=np.int16).astype(np.float32) / 32768
    if not 1.5 * RATE <= x.size <= 30 * RATE: continue
    c = SpeechClock(); c.add(x)
    if c.at is not None: starts.append(c.at / RATE - a.preroll)
s = sorted(starts)
q = lambda p: round(s[int((len(s) - 1) * p)] * 1000)
print({"takes": len(s), "speech_after_press_p50_ms": q(.5), "p90_ms": q(.9), "before_press": sum(v < 0 for v in s)})

"""Voice engine end to end on saved takes: fast read, then a careful read, with times and memory.

    .venv/bin/python bench/voice_check.py <take.wav> [...]     (at most a few takes per run)
"""
import json, struct, subprocess, sys, time, wave
from pathlib import Path
import numpy as np
ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "engine"))
import guard


def wav(path):
    with wave.open(path) as w:
        a = np.frombuffer(w.readframes(w.getnframes()), dtype={2: np.int16, 4: np.float32}[w.getsampwidth()])
        if a.dtype == np.int16: a = a.astype(np.float32) / 32768
        assert w.getframerate() == 16000, w.getframerate()
        return a.astype(np.float32)


p = subprocess.Popen([str(ROOT / ".venv/bin/python"), str(ROOT / "engine/voice.py")], stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=False)
def send(kind, data=None):
    if data is None: p.stdin.write(bytes([kind]) + struct.pack("<I", 0))
    else: p.stdin.write(bytes([0]) + struct.pack("<I", data.size) + data.tobytes())
    p.stdin.flush()
def until(key):
    while True:
        m = json.loads(p.stdout.readline())
        if key in m: return m
print(until("ready"))
for f in sys.argv[1:]:
    a = wav(f); t = time.time()
    send(250); print(" ", until("loaded"))
    for i in range(0, a.size, 1600): send(0, a[i:i + 1600])
    send(255); m = until("text"); print(f"{a.size/16000:.1f}s fast {time.time()-t:.2f}s total, read {m['took']}s loud={m['loud']} mem={guard.footprint_gb(p.pid):.2f}GB:", m["text"][:120])
    t = time.time(); send(249); m = until("careful"); print(f"   careful {m['took']}s mem={guard.footprint_gb(p.pid):.2f}GB:", m["careful"][:120])
time.sleep(1.5); print("after", round(guard.footprint_gb(p.pid), 2), "GB")
p.stdin.close(); p.wait(5)

"""Live typing, offline: feeds saved takes to engine/voice.py in real time and applies the app's rule (words that
came out the same in two drafts in a row, minus the last two, are typed; at the end what differs is backspaced and
retyped). Prints what would appear in the field step by step. .venv/bin/python bench/live_sim.py <wav>..."""
import json, struct, subprocess, sys, threading, time, wave
from pathlib import Path
import numpy as np
ROOT = Path(__file__).resolve().parent.parent


def wav(p):
    with wave.open(p) as w:
        return np.frombuffer(w.readframes(w.getnframes()), dtype=np.int16).astype(np.float32) / 32768


p = subprocess.Popen([str(ROOT / ".venv/bin/python"), str(ROOT / "engine/voice.py")], stdin=subprocess.PIPE, stdout=subprocess.PIPE)
lines = []
threading.Thread(target=lambda: [lines.append(json.loads(l)) for l in p.stdout], daemon=True).start()
def send(kind, data=None):
    p.stdin.write(bytes([kind]) + struct.pack("<I", 0 if data is None else data.size) + (b"" if data is None else data.tobytes())); p.stdin.flush()
def wait(key):
    while not any(key in m for m in lines): time.sleep(0.02)
    m = [m for m in lines if key in m][-1]; lines.clear(); return m
wait("ready")
for f in sys.argv[1:]:
    a = wav(f); send(250); wait("loaded"); lines.clear()
    typed, hist, events, field = "", [], 0, ""
    STABLE = int(__import__("os").environ.get("STABLE", "2"))
    t0 = time.time()
    for i in range(0, a.size, 1600):
        send(0, a[i:i + 1600]); time.sleep(0.1)
        for m in [m for m in lines if "draft" in m]:
            words = m["draft"].split()
            hist = (hist + [words])[-STABLE:]
            n = 0
            if len(hist) == STABLE:
                while n < min(len(h) for h in hist) and all(h[n] == words[n] for h in hist): n += 1
            n = min(n, len(words) - 2)
            if n > 0:
                settled = " ".join(words[:n])
                if len(settled) > len(typed) and settled.startswith(typed):
                    field += settled[len(typed):] if typed else settled; typed = settled; events += 1
                    print(f"  {time.time() - t0:4.1f}s  {field}")
        lines[:] = [m for m in lines if "draft" not in m]
    send(255); final = wait("text")["text"]
    if final.startswith(typed): fix = 0
    else:
        common = next((k for k, (x, y) in enumerate(zip(typed, final)) if x != y), min(len(typed), len(final)))
        fix = len(typed) - common
    print(f"{Path(f).name[:8]} {a.size / 16000:.1f}s: typed in {events} steps while talking, {fix} chars corrected at the end")
    print("  final:", final)
p.stdin.close()

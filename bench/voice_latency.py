"""Voice latency on saved takes, fed in real time (100 ms chunks, as the microphone does) through engine/voice.py.

    .venv/bin/python bench/voice_latency.py [n=6]            (picks n saved takes with text, short to long)
    .venv/bin/python bench/voice_latency.py <a.wav> [...]
    DRAFTER_VOICE_PY=<other voice.py> ...                  (the same on another copy of the engine, to compare)

Per take: first words (first non-empty draft) after the first sample and after speech starts, the gap between drafts,
and end of take -> final text. Parakeet only (no Whisper pass), so it fits beside the running app.
"""
import json, os, struct, subprocess, sys, threading, time, wave
from pathlib import Path
import numpy as np
ROOT = Path(__file__).resolve().parent.parent
RATE = 16000


def wav(path):
    with wave.open(str(path)) as w:
        a = np.frombuffer(w.readframes(w.getnframes()), dtype={2: np.int16, 4: np.float32}[w.getsampwidth()])
        return (a.astype(np.float32) / 32768 if a.dtype == np.int16 else a).astype(np.float32)


def onset(a):
    """First 25 ms window above -42 dB: where speech starts."""
    win = RATE // 40
    n = a.size // win
    e = 10 * np.log10((a[:n * win].reshape(n, win) ** 2).mean(axis=1) + 1e-10)
    hit = np.nonzero(e > -42)[0]
    return (hit[0] * win / RATE) if hit.size else 0.0


def pick(n):
    rows = [json.loads(l) for l in open(ROOT / "data/takes.jsonl")]
    rows = [r for r in rows if r.get("text") and r.get("audio") and os.path.exists(r["audio"]) and 2 <= r.get("secs", 0) <= 40]
    rows.sort(key=lambda r: r["secs"])
    step = max(1, len(rows) // n)
    return [r["audio"] for r in rows[::step][:n]]


files = sys.argv[1:] if len(sys.argv) > 1 and not sys.argv[1].isdigit() else pick(int(sys.argv[1]) if len(sys.argv) > 1 else 6)
ENGINE = os.environ.get("DRAFTER_VOICE_PY") or str(ROOT / "engine/voice.py")   # another copy, to compare
p = subprocess.Popen([str(ROOT / ".venv/bin/python"), ENGINE], stdin=subprocess.PIPE,
                     stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, env={**os.environ, "DRAFTER_WORDS": str(ROOT / "data/words.json")})
lines = []
cv = threading.Condition()
def reader():
    for l in p.stdout:
        with cv: lines.append((time.perf_counter(), json.loads(l))); cv.notify_all()
threading.Thread(target=reader, daemon=True).start()
def send(kind, data=None):
    p.stdin.write(bytes([kind]) + struct.pack("<I", 0 if data is None else data.size) + (b"" if data is None else data.tobytes()))
    p.stdin.flush()
def wait(key, since):
    with cv:
        while True:
            for t, m in lines[since:]:
                if key in m: return t, m
            cv.wait(30)

wait("ready", 0)
send(250); wait("loaded", 0)
out = []
for f in files:
    a = wav(f); on = onset(a)
    mark = len(lines)
    send(250)
    t0 = time.perf_counter()
    for i in range(0, a.size, 1600):
        due = t0 + i / RATE
        time.sleep(max(0, due - time.perf_counter()))
        send(0, a[i:i + 1600])
    time.sleep(max(0, t0 + a.size / RATE - time.perf_counter()))
    tend = time.perf_counter()
    send(255)
    te, m = wait("text", mark)
    drafts = [(t, d["draft"]) for t, d in lines[mark:] if "draft" in d and t <= tend + 0.01]
    first = next((t - t0 for t, d in drafts if d.strip()), None)
    gaps = np.diff([t for t, _ in drafts]) if len(drafts) > 1 else np.array([0])
    r = dict(file=Path(f).name[:8], secs=round(a.size / RATE, 1), onset=round(on, 2),
             first=round(first, 2) if first else None, after_speech=round(first - on, 2) if first else None,
             gap_p50=round(float(np.median(gaps)), 2), end_ms=int((te - tend) * 1000), engine_ms=int(m["took"] * 1000),
             drafts=len(drafts), chars=len(m["text"]))
    out.append(r); print(r, flush=True)
    time.sleep(1)
p.stdin.close(); p.wait(10)
fs = [r["after_speech"] for r in out if r["after_speech"] is not None]
print("SUMMARY first words after speech p50 %.2f s (max %.2f), end->text p50 %d ms (max %d), draft gap p50 %.2f s" % (
    np.median(fs), max(fs), np.median([r["end_ms"] for r in out]), max(r["end_ms"] for r in out), np.median([r["gap_p50"] for r in out])))

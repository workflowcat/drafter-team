"""Records the voice engine's drafts for made-up takes, in real time, so live typing rules can be replayed on them
(bench/live_replay.swift). Only made-up speech: `--say` makes the takes with macOS `say` (English and Ukrainian, each
starting with 0.7 s of silence, the English one past the 28 s piece cut). One Parakeet load, then it exits.

  .venv/bin/python -B bench/live_drafts.py --say OUT.json          # make the takes and record them
  .venv/bin/python -B bench/live_drafts.py OUT.json a.wav b.wav    # record made-up wavs you already have
  .venv/bin/python -B bench/live_drafts.py --wavs DIR               # only write the made-up takes (for bench/voice_test.sh)

OUT.json: [{"name", "secs", "speech" (s, first 30 ms over -40 dB), "drafts": [[t, text, ms]], "final", "end"}]."""
import json, os, struct, subprocess, sys, tempfile, threading, time, wave
from pathlib import Path
import numpy as np
ROOT = Path(__file__).resolve().parent.parent

MADE_UP = [
    ("en", "Samantha", "[[slnc 700]] So the plan for the garden this spring is fairly simple. We dig the two long beds by the fence "
     "first, then we put the tomatoes on the sunny side and the beans along the back. If the weather holds, we can plant the "
     "first seeds next weekend, and the herbs can wait until May. [[slnc 1500]] One more thing, the old water barrel leaks, "
     "so we should buy a new one before the rain starts, and maybe a second hose for the far corner of the yard. "
     "After that we can think about the little path of flat stones, but honestly that is a job for the summer."),
    ("uk", "Lesya", "[[slnc 700]] Привіт, я подивився твій план на завтра. Думаю, що зустріч о другій краще перенести на третю, "
     "бо до обіду я буду в дорозі. [[slnc 1200]] Ще одне: візьми, будь ласка, ключі від складу і список того, що треба "
     "забрати, бо минулого разу ми забули дві коробки. Якщо щось зміниться, напиши мені ввечері."),
]


def make_takes(folder):
    out = []
    for lang, voice, text in MADE_UP:
        p = os.path.join(folder, f"made-up-{lang}.wav")
        subprocess.run(["say", "-v", voice, "-o", p, "--data-format=LEI16@16000", "--file-format=WAVE", text], check=True)
        with wave.open(p) as w: frames = w.readframes(w.getnframes())
        with wave.open(p, "wb") as w:   # a plain 44-byte header: Talk.test skips exactly that much
            w.setnchannels(1); w.setsampwidth(2); w.setframerate(16000); w.writeframes(frames)
        out.append(p)
    return out


def wav(p):
    with wave.open(p) as w:
        assert w.getframerate() == 16000 and w.getnchannels() == 1
        return np.frombuffer(w.readframes(w.getnframes()), dtype=np.int16).astype(np.float32) / 32768


def onset(a):
    n = a.size // 480
    fr = a[: n * 480].reshape(n, 480)
    hit = np.nonzero(np.sqrt((fr * fr).mean(axis=1)) > 0.010)[0]
    return float(hit[0] * 480 / 16000) if hit.size else None


def main():
    args = sys.argv[1:]
    if args[:1] == ["--wavs"]:
        os.makedirs(args[1], exist_ok=True)
        print("\n".join(make_takes(args[1]))); return
    say = "--say" in args
    args = [a for a in args if a != "--say"]
    out_path, wavs = args[0], args[1:]
    tmp = tempfile.mkdtemp(prefix="live-drafts-")
    if say: wavs = make_takes(tmp)
    p = subprocess.Popen([sys.executable, str(ROOT / "engine/voice.py")], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                         env={**os.environ, "HF_HUB_OFFLINE": "1"})
    lines, lock = [], threading.Lock()

    def reader():
        for l in p.stdout:
            m = json.loads(l); m["_t"] = time.time()
            with lock: lines.append(m)
    threading.Thread(target=reader, daemon=True).start()

    def send(kind, data=None):
        p.stdin.write(bytes([kind]) + struct.pack("<I", 0 if data is None else data.size) + (b"" if data is None else data.tobytes()))
        p.stdin.flush()

    def wait(key, timeout=60):
        t = time.time()
        while time.time() - t < timeout:
            with lock:
                for i, m in enumerate(lines):
                    if key in m: return lines.pop(i)
            time.sleep(0.01)
        raise SystemExit(f"no {key} from the engine")

    wait("ready")
    results = []
    for f in wavs:
        a = wav(f)
        send(250)
        if not results: wait("loaded", 120)   # loaded once; later takes find it warm
        else: time.sleep(0.5)
        with lock: lines.clear()
        t0 = time.time()
        for i in range(0, a.size, 1600):   # 0.1 s chunks in real time, as the microphone gives them
            send(0, a[i:i + 1600])
            time.sleep(max(0, t0 + (i + 1600) / 16000 - time.time()))
        t_end = time.time()
        send(255)
        final = wait("text")
        with lock:
            drafts = [[round(m["_t"] - t0, 3), m["draft"], m.get("ms")] for m in lines if "draft" in m]
            lines.clear()
        results.append({"name": Path(f).stem, "secs": round(a.size / 16000, 2), "speech": onset(a), "drafts": drafts,
                        "final": final["text"], "end": round(t_end - t0, 3), "final_at": round(final["_t"] - t0, 3)})
        print(f"{Path(f).stem}: {a.size / 16000:.1f} s, {len(drafts)} drafts, final {len(final['text'])} chars")
    p.stdin.close(); p.wait(timeout=30)
    Path(out_path).write_text(json.dumps(results, ensure_ascii=False, indent=1))


if __name__ == "__main__":
    main()

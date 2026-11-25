"""engine/speakers.py on a made-up two-track call: who said each line. Never reads data/.

The "voices" are tones (his at 200 Hz, two people of the other side at 330 and 520 Hz), and a stand-in embedder
turns a stretch into a vector by its main pitch, so the test checks the labelling, not the model. One more check
loads the real model when models/speakers/ has it.

Run: .venv/bin/python -B tests/test_speakers.py
"""
import json, sys, tempfile, unittest, wave
from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "engine"))
import speakers as S  # noqa: E402

RATE = 16000
HIM, ANA, BOB = 200.0, 330.0, 520.0
PITCHES = [HIM, ANA, BOB]


def tone(f, secs, amp=0.3):
    t = np.arange(int(secs * RATE)) / RATE
    return (amp * np.sin(2 * np.pi * f * t)).astype(np.float32)


def place(track, at, x):
    i = int(at * RATE)
    track[i:i + x.size] += x


def write(path, x):
    with wave.open(str(path), "wb") as w:
        w.setnchannels(1); w.setsampwidth(2); w.setframerate(RATE)
        w.writeframes((np.clip(x, -1, 1) * 32767).astype("<i2").tobytes())


def fake_embed(x):
    """A vector by the stretch's main pitch: near one of three made-up voices, a little apart from the others."""
    spec = np.abs(np.fft.rfft(x[: RATE * 4]))
    f = float(np.argmax(spec)) * RATE / (2 * (spec.size - 1))
    v = np.array([np.exp(-((f - p) / 40) ** 2) for p in PITCHES] + [0.05], dtype=np.float32)
    return v / np.linalg.norm(v)


def call(dir_, dead_after=60.0):
    """me.wav: him at 0-6 and 20-26, after them.wav dies Ana through the laptop speakers at 70-76 and him at 90-96, a
    0.3 s blip at 100. them.wav: Ana at 8-14 and 50-55, Bob at 30-36 and 40-44, a 0.4 s "yes" from Bob at 44.5,
    exact zeros from 60 s."""
    me, them = np.zeros(110 * RATE, np.float32), np.zeros(110 * RATE, np.float32)
    them[: int(dead_after * RATE)] += np.random.default_rng(1).normal(0, 0.001, int(dead_after * RATE)).astype(np.float32)
    for at in (0, 20, 90): place(me, at, tone(HIM, 6))
    place(me, 70, tone(ANA, 6, 0.15))
    place(me, 100, tone(HIM, 0.3))
    place(me, 9, tone(ANA, 3, 0.05))          # his mic hears Ana faintly while she talks (the echo line below)
    for at, f, secs in ((8, ANA, 6), (50, ANA, 5), (30, BOB, 6), (40, BOB, 4), (44.5, BOB, 0.4)): place(them, at, tone(f, secs))
    write(dir_ / "me.wav", me); write(dir_ / "them.wav", them)
    rows = [
        {"who": "Я", "start": 0, "end": 6, "text": "his first words", "track": "me"},
        {"who": "Вони", "start": 8, "end": 14, "text": "ana opens the demo now", "track": "them"},
        {"who": "Я", "start": 9, "end": 12, "text": "ana opens the demo now", "track": "me"},
        {"who": "Я", "start": 20, "end": 26, "text": "his question", "track": "me"},
        {"who": "Вони", "start": 30, "end": 36, "text": "bob answers", "track": "them"},
        {"who": "Вони", "start": 40, "end": 44, "text": "bob goes on", "track": "them"},
        {"who": "Вони", "start": 44.5, "end": 44.9, "text": "yes", "track": "them"},
        {"who": "Вони", "start": 50, "end": 55, "text": "ana again", "track": "them"},
        {"who": "Я", "start": 70, "end": 76, "text": "ana through the speakers", "track": "me"},
        {"who": "Я", "start": 90, "end": 96, "text": "his closing words", "track": "me"},
        {"who": "Я", "start": 100, "end": 100.3, "text": "mm", "track": "me"},
    ]
    (dir_ / "lines.json").write_text(json.dumps(rows))
    (dir_ / "meta.json").write_text(json.dumps({"call": True, "event": {"people": ["Andrii", "Ana", "Bob"]}}))
    return rows


def takes(dir_, n=6):
    """His made-up dictation takes, a day old."""
    import os, time
    dir_.mkdir(parents=True, exist_ok=True)
    for i in range(n):
        write(dir_ / f"take{i}.wav", tone(HIM, 5))
        os.utime(dir_ / f"take{i}.wav", (time.time() - 86400 - i, time.time() - 86400 - i))


class Speakers(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.d = Path(self.tmp.name) / "call"; self.d.mkdir()

    def tearDown(self):
        self.tmp.cleanup()

    def run_it(self, **kw):
        a = Path(self.tmp.name) / "audio"; takes(a)
        return S.run(self.d, print_path=Path(self.tmp.name) / "voiceprint.json", audio_dir=a, calls_dir=None,
                     log=lambda *_: None, embed=fake_embed, **kw)

    def test_two_tracks(self):
        call(self.d)
        stats = self.run_it()
        out = json.loads((self.d / "lines.json").read_text())
        by = {r["text"]: r for r in out}
        # his lines: his voice, on the mic
        for t in ("his first words", "his question", "his closing words"):
            self.assertEqual(by[t]["who"], "Я", t); self.assertEqual(by[t]["track"], "me")
        # the other side: two people, numbered by first appearance, never Я
        self.assertEqual(by["ana opens the demo now"]["who"], "Speaker 2")
        self.assertEqual(by["ana again"]["who"], "Speaker 2")
        self.assertEqual(by["bob answers"]["who"], "Speaker 3")
        self.assertEqual(by["bob goes on"]["who"], "Speaker 3")
        # after them.wav died, the mic heard Ana through the speakers: hers, not his
        self.assertEqual(by["ana through the speakers"]["who"], "Speaker 2")
        self.assertEqual(by["ana through the speakers"]["track"], "me")
        # a short them line takes its neighbour's voice; a short mic line no one can place is unknown
        self.assertEqual(by["yes"]["who"], "Speaker 3")
        self.assertEqual(by["mm"]["who"], "unknown")
        # the mic's echo of Ana's line is dropped (the them.wav line stays)
        self.assertEqual([r["track"] for r in out if r["text"] == "ana opens the demo now"], ["them"])
        self.assertEqual(stats["echo_dropped"], 1)
        self.assertEqual(stats["counts"], {"Speaker 2": 3, "Я": 3, "Speaker 3": 3, "unknown": 1})
        self.assertNotIn("Я", [r["who"] for r in out if r["track"] == "them"])
        # two people on the other side, three in the meeting minus him: no names guessed
        self.assertEqual(stats["named"], {})
        self.assertAlmostEqual(stats["them_alive_min"], 1.0)
        # files: transcript, counts, and the lines before
        self.assertIn("Speaker 3: bob answers", (self.d / "transcript.txt").read_text())
        self.assertTrue((self.d / "lines.before-speakers.json").exists())
        self.assertEqual(json.loads((self.d / "speakers.json").read_text())["lines"], 10)

    def test_named_when_clear(self):
        call(self.d)
        rows = [r for r in json.loads((self.d / "lines.json").read_text()) if "bob" not in r["text"] and r["text"] != "yes"]
        (self.d / "lines.json").write_text(json.dumps(rows))
        (self.d / "meta.json").write_text(json.dumps({"call": True, "event": {"people": ["Andrii", "Ana"]}}))
        stats = self.run_it()
        out = json.loads((self.d / "lines.json").read_text())
        self.assertEqual({r["who"] for r in out if r["track"] == "them"}, {"Ana"})
        self.assertEqual(stats["named"], {"Speaker 2": "Ana"})

    def test_no_print_track_only(self):
        """No takes to build a print from: mic lines are his only while the other side was alive and read apart."""
        call(self.d)
        stats = S.run(self.d, print_path=None, log=lambda *_: None, embed=fake_embed)
        by = {r["text"]: r for r in json.loads((self.d / "lines.json").read_text())}
        self.assertEqual(by["his first words"]["who"], "Я")
        self.assertEqual(by["his closing words"]["who"], "unknown")   # them.wav dead by then: cannot tell
        self.assertEqual(by["ana through the speakers"]["who"], "unknown")
        self.assertFalse(stats["print"])

    def test_long_take_line(self):
        """A voice take merged into a call (minutes long, no track label yet): placed window by window."""
        me = np.zeros(80 * RATE, np.float32)
        place(me, 0, tone(HIM, 40)); place(me, 40, tone(HIM, 30)); place(me, 70, tone(ANA, 8))
        write(self.d / "me.wav", me)
        rows = [{"who": "unknown", "start": 0, "end": 78, "text": "a long take", "track": "me"}]
        (self.d / "lines.json").write_text(json.dumps(rows)); (self.d / "meta.json").write_text(json.dumps({"call": True}))
        self.run_it()
        self.assertEqual(json.loads((self.d / "lines.json").read_text())[0]["who"], "Я")   # 7 of 8 windows his
        place(me, 0, tone(ANA, 40, 0.0)); me[: 40 * RATE] = tone(ANA, 40)
        write(self.d / "me.wav", me); (self.d / "lines.json").write_text(json.dumps(rows))
        self.run_it()
        self.assertEqual(json.loads((self.d / "lines.json").read_text())[0]["who"], "unknown")   # half and half

    def test_print_skips_call_takes(self):
        a = Path(self.tmp.name) / "audio"; takes(a)
        calls = Path(self.tmp.name) / "calls" / "c1"; calls.mkdir(parents=True)
        write(a / "during.wav", tone(BOB, 5))
        t = (a / "during.wav").stat().st_mtime
        (calls / "meta.json").write_text(json.dumps({"call": True, "started": t - 30}))
        write(calls / "me.wav", tone(HIM, 60))
        vec, n = S.build_print(fake_embed, a, calls.parent, log=lambda *_: None)
        self.assertEqual(n, 6)
        self.assertGreater(float(vec @ fake_embed(tone(HIM, 2))), 0.99)

    def test_cluster(self):
        v = [fake_embed(tone(f, 1)) for f in (ANA, ANA, BOB, ANA, BOB, BOB)]
        self.assertEqual(S.cluster(v), [0, 0, 1, 0, 1, 1])
        self.assertEqual(S.cluster([]), [])

    def test_dead_blocks(self):
        them = np.zeros(40 * RATE, np.int16); them[: 20 * RATE] = 5
        self.assertEqual(S.alive_blocks(them).tolist(), [True, True, False, False])

    @unittest.skipUnless(S.MODEL.exists(), "speaker model not downloaded")
    def test_real_model_loads(self):
        e = S.Embedder()
        v = e(tone(HIM, 2) + np.random.default_rng(0).normal(0, 0.01, 2 * RATE).astype(np.float32))
        self.assertEqual(v.shape, (512,))
        self.assertAlmostEqual(float(np.linalg.norm(v)), 1.0, places=4)


if __name__ == "__main__":
    unittest.main()

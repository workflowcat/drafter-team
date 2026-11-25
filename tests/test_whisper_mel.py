"""engine/whisper_mel.py: the block-by-block log-Mel spectrogram gives mlx_whisper's own numbers, with less memory.
Made-up audio (noise and tones), no model.

    .venv/bin/python -B tests/test_whisper_mel.py
"""
import gc, sys, unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "engine"))
import numpy as np
import mlx.core as mx
from stand_ins import install as install_stand_ins
install_stand_ins()
from mlx_whisper.audio import log_mel_spectrogram as whole, N_SAMPLES
import whisper_mel


def made_up(seconds, seed=1):
    rng = np.random.default_rng(seed)
    t = np.arange(int(seconds * 16000)) / 16000
    a = 0.05 * rng.standard_normal(t.size) + 0.2 * np.sin(2 * np.pi * 220 * t) * (np.sin(2 * np.pi * 0.3 * t) > 0)
    return a.astype(np.float32)


class Mel(unittest.TestCase):
    def test_same_numbers(self):
        for secs, frames, mels in ((7.3, 6000, 128), (95.0, 1000, 128), (95.01, 1000, 128), (61.0, 6000, 80), (0.5, 7, 128), (3.0, 2, 128)):
            a = made_up(secs)
            for pad in (0, N_SAMPLES):
                want = whole(a, n_mels=mels, padding=pad)
                got = whisper_mel.log_mel_spectrogram(a, n_mels=mels, padding=pad, frames=frames)
                mx.eval(want, got)
                self.assertEqual(got.shape, want.shape)
                self.assertTrue(mx.array_equal(got, want).item(), f"{secs}s, {frames} frames, padding {pad}")

    def test_same_numbers_random_lengths(self):
        rng = np.random.default_rng(7)
        for _ in range(8):
            secs = float(rng.uniform(5, 200))
            a = made_up(secs, seed=int(rng.integers(1000)))
            want, got = whole(a, n_mels=128, padding=N_SAMPLES), whisper_mel.log_mel_spectrogram(a, n_mels=128, padding=N_SAMPLES)
            self.assertTrue(mx.array_equal(got, want).item(), f"{secs:.2f}s")

    def test_peak_memory_lower(self):
        a = made_up(600)
        peaks = []
        for fn in (whole, whisper_mel.log_mel_spectrogram):
            gc.collect(); mx.clear_cache(); mx.reset_peak_memory()
            base = mx.get_active_memory()
            r = fn(a, n_mels=128, padding=N_SAMPLES); mx.eval(r); del r
            peaks.append((mx.get_peak_memory() - base) / 2**20)
        print(f"\n10 min of made-up audio, MLX peak over start: whole {peaks[0]:.0f} MB, blocks {peaks[1]:.0f} MB")
        self.assertLess(peaks[1], peaks[0] / 2)

    def test_install(self):
        import mlx_whisper  # noqa: F401
        wt = sys.modules["mlx_whisper.transcribe"]
        old = wt.log_mel_spectrogram
        try:
            self.assertTrue(whisper_mel.install())
            self.assertIs(wt.log_mel_spectrogram, whisper_mel.log_mel_spectrogram)
        finally:
            wt.log_mel_spectrogram = old


if __name__ == "__main__":
    unittest.main()

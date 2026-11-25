"""When speech starts in a take, for the "words after speech" number (17 November 2026, research instant #7/#8).

The app's own stamp missed in 370 of 425 takes (it saw 64 ms buffers on the main queue), so "first words" was counted
from the press, his pause before he speaks included. The engine sees every sample: it marks the first 30 ms frame
above rms 0.010 (the same frames has_speech counts) and, with the first draft that has words, says how long after that
frame the words went out. Pure numpy, no model."""
import numpy as np

RATE, FRAME, LEVEL = 16000, 480, 0.010


class SpeechClock:
    """Fed every frame of a take in order. `at`: sample index where speech starts (None: not yet)."""

    def __init__(self):
        self.got, self.at, self.said, self.rest = 0, None, False, np.zeros(0, np.float32)

    def add(self, data):
        if self.at is None:
            buf = np.concatenate([self.rest, data]) if self.rest.size else data
            n = buf.size // FRAME
            if n:
                rms = np.sqrt((buf[: n * FRAME].reshape(n, FRAME) ** 2).mean(axis=1))
                hit = np.flatnonzero(rms > LEVEL)
                if hit.size:
                    self.at = self.got - self.rest.size + int(hit[0]) * FRAME
            self.rest = buf[n * FRAME:] if self.at is None else np.zeros(0, np.float32)
        self.got += data.size

    def first_words(self, read_ms, words):
        """ms from speech start to these words going out (the audio since it, plus the read); once per take."""
        if self.said or not words or self.at is None: return None
        self.said = True
        return int((self.got - self.at) * 1000 / RATE + read_ms)

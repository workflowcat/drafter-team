"""The final reading of a recording and its note, without models, Aleph or personal data."""
import ast
import types
import os
import sys
import tempfile
import unittest
import wave
from pathlib import Path
from unittest.mock import patch

import numpy as np

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "engine"))


class Pieces(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        from test_voice_guard import fake_voice
        fixture = fake_voice()
        cls.voice, _ = fixture.__enter__()
        cls.addClassCleanup(fixture.__exit__, None, None, None)

    def test_long_recording_is_cut_at_quiet_spots_within_limit(self):
        R = self.voice.RATE
        rng = np.random.default_rng(1)
        a = (rng.standard_normal(R * 600) * 0.1).astype(np.float32)        # 10 minutes of loud sound
        a[R * 235:R * 236] = 0                                              # one quiet second near the 4-minute mark
        parts = self.voice.pieces(a)
        self.assertEqual(parts[0][0], 0)
        self.assertEqual(parts[-1][1], a.size)
        for (s, e), (s2, _) in zip(parts, parts[1:]):
            self.assertEqual(e, s2)                                         # no gap, no overlap
        self.assertTrue(all(e - s <= self.voice.FILE_PIECE for s, e in parts))
        self.assertTrue(R * 235 <= parts[0][1] <= R * 236, parts[0])       # the cut lands in the quiet second

    def test_short_recording_is_one_piece(self):
        a = np.zeros(self.voice.RATE * 30, np.float32)
        self.assertEqual(self.voice.pieces(a), [(0, a.size)])

    def test_own_wav_reads_as_int16(self):
        with tempfile.TemporaryDirectory() as d:
            path = os.path.join(d, "me.wav")
            with wave.open(path, "wb") as w:
                w.setnchannels(1); w.setsampwidth(2); w.setframerate(16000)
                w.writeframes(np.array([0, 1000, -1000], np.int16).tobytes())
            pcm = self.voice.load_pcm16(path)
            self.assertEqual(pcm.dtype, np.int16)
            self.assertEqual(pcm.tolist(), [0, 1000, -1000])

    def test_file_job_gets_more_memory_only_while_it_runs(self):
        from test_voice_guard import load
        guard = load('recording_guard_fixture', 'engine/guard.py')
        before = guard._cap[0]
        with guard.allow(before + 0.6):
            self.assertAlmostEqual(guard._cap[0], before + 0.6)
        self.assertEqual(guard._cap[0], before)


class NoteFromEvent(unittest.TestCase):
    def test_event_title_names_the_note_and_people_are_looked_up(self):
        import notes
        asked, looked = [], []
        with patch.object(notes, "names", return_value=[("Mila Synthetic", True)]), \
             patch.object(notes, "aleph", side_effect=lambda path, body=None: looked.append(path) or [
                 {"id": "p1", "name": "Mila Synthetic", "kind": "person", "scope": "work"}]):
            r = notes.make("We agreed on the plan.", lambda p, n=60: asked.append(p) or '{"title": "Model title"}',
                           call=False, dry=True, event={"title": "Weekly sync", "people": ["Mila Synthetic"]})
        self.assertEqual(r["title"], "Weekly sync")
        self.assertEqual(asked, [])                                          # no model call for a title
        self.assertEqual([l["name"] for l in r["links"]], ["Mila Synthetic"])

    def test_first_name_guesses_need_one_clear_person(self):
        import notes
        people = [("Andrew Synthetic", True), ("Andrés Synthetic", True), ("Andy Synthetic", True), ("Марта", True),
                  ("Marko Synthetic", True), ("Sava Synthetic", True), ("Mila Synthetic", True), ("Mila Other", True),
                  ("Till Synthetic", True)]
        hit = lambda path, body=None: [{"id": path, "name": __import__("urllib.parse").parse.unquote(path.split("q=")[1].split("&")[0]),
                                        "kind": "person", "scope": "work"}]
        text = "Скажи, будь ласка, Андрій, де ми. Марта не підтвердила. Я говорив з Савою. Мілі теж написав. Тільки це, тільки то."
        with patch.object(notes, "names", return_value=people), patch.object(notes, "aleph", side_effect=hit):
            got = [l["name"] for l in notes.links(text)]
        self.assertEqual(sorted(got), ["Sava Synthetic", "Марта"])   # not his own name, not Marko, not one of two Lanas

    def test_without_event_the_model_names_it(self):
        import notes
        with patch.object(notes, "names", return_value=[]):
            r = notes.make("We agreed on the plan.", lambda p, n=60: '{"title": "Model title"}', dry=True)
        self.assertEqual(r["title"], "Model title")


if __name__ == "__main__":
    unittest.main()

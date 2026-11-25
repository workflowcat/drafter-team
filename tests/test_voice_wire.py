"""Speed round 2026-11-17: Parakeet stays wired while loaded and a press touches it. Inert mlx, no model loads."""
import sys
import unittest
from pathlib import Path
from unittest.mock import Mock, patch

sys.path.insert(0, str(Path(__file__).resolve().parent))
from test_voice_guard import fake_voice  # noqa: E402

MB = 1024 * 1024


class WireTests(unittest.TestCase):
    def setUp(self):
        self.voice, _ = self.enterContext(fake_voice())
        self.voice.mx.set_wired_limit = Mock()
        self.out = []
        self.enterContext(patch.object(self.voice, 'emit', self.out.append))

    def test_limit_is_weights_plus_margin_and_zero_for_nothing(self):
        self.assertEqual(self.voice.wire_limit(0), 0)
        self.assertEqual(self.voice.wire_limit(-5), 0)
        self.assertEqual(self.voice.wire_limit(1200 * MB), int(1200 * MB * 1.05) + 64 * MB)

    def test_wire_on_and_off_follow_the_loaded_model(self):
        r = self.voice.Readers()
        r.fast = object()
        with patch.object(self.voice, 'model_bytes', lambda m: 1000 * MB):
            r.wire(True)
            r.wire(False)
        calls = [c.args[0] for c in self.voice.mx.set_wired_limit.call_args_list]
        self.assertEqual(calls, [int(1000 * MB * 1.05) + 64 * MB, 0])
        self.assertEqual(self.out, [{"wired": 1114}, {"wired": 0}])

    def test_wire_off_by_setting_and_safe_without_the_call(self):
        r = self.voice.Readers(); r.fast = object()
        with patch.object(self.voice, 'WIRE', False):
            r.wire(True)
        self.voice.mx.set_wired_limit.assert_not_called()
        del self.voice.mx.set_wired_limit
        r.wire(True)                         # older MLX: no call, no crash
        self.assertEqual(self.out, [])

    def test_touch_reads_a_quarter_second_ungated_and_reports_ms(self):
        r = self.voice.Readers()
        r.touch()                            # nothing loaded: nothing read
        self.assertEqual(self.out, [])
        r.fast = object()
        seen = []
        with patch.object(self.voice, 'read', lambda m, a, gate=True: seen.append((m, len(a), gate))):
            r.touch()
        self.assertEqual(seen, [(r.fast, self.voice.RATE // 4, False)])
        self.assertIn("touched", self.out[0])

    def test_background_touch_marks_itself_and_counts_cpu(self):
        r = self.voice.Readers(); r.fast = object()
        with patch.object(self.voice, 'read', lambda m, a, gate=True: None):
            r.touch(bg=True)
            r.touch()
        self.assertTrue(self.out[0]["bg"]); self.assertGreaterEqual(self.out[0]["cpu"], 0)
        self.assertNotIn("bg", self.out[1])          # a press touch stays as it was: the take's timing reads it

    def test_background_touch_frame_never_loads_and_keeps_the_idle_clock(self):
        src = (Path(__file__).resolve().parents[1] / 'engine/voice.py').read_text()
        self.assertIn("TOUCH = 251", src)
        a = src.index("if kind == TOUCH:"); b = src.index("since = time.time()", a - 400)
        self.assertLess(a, b, "the touch frame is handled before the idle clock is reset")
        self.assertIn("if take is None and r.fast is not None: r.touch(bg=True)", src)

    def test_warm_press_touches_a_loaded_model_and_loads_a_cold_one(self):
        src = (Path(__file__).resolve().parents[1] / 'engine/voice.py').read_text()
        self.assertIn("if r.fast is None: r.warm()\n                else: r.touch()", src)


if __name__ == '__main__':
    unittest.main()

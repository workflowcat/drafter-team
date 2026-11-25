"""bench/ghost_quality.py on made-up log lines (never the live log)."""
import sys
import unittest
from datetime import datetime, timezone
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "bench"))
import ghost_quality as gq  # noqa: E402

LINES = [
    "2026-11-17T10:00:00Z ghost com.example.chat words len 6 word 6 taken 6 typed 0",
    "2026-11-17T10:00:05Z ghost com.example.chat words len 8 word 4 taken 0 typed 3",
    "2026-11-17T10:00:09Z ghost com.example.ai gate len 10 word 5 taken 4 typed 1",
    "2026-11-17T10:00:10Z ghost hold typo len=5 at=word",
    "2026-11-17T10:09:59Z screen context: 30 reads + 14 looks in 2 typing min (15.0/min) · capture p50 39",
    "2026-11-17T12:00:00Z ghost com.example.chat words len 4 word 4 taken 4 typed 0",
]


class GhostQuality(unittest.TestCase):
    def test_counts_and_rates(self):
        r = gq.measure(LINES)
        self.assertEqual((r["shown"], r["taken"]), (4, 3))
        self.assertEqual(r["taken_rate"], 0.75)
        self.assertEqual(r["char_rate"], round((6 + 4 + 4) / (6 + 8 + 10 + 4), 3))
        self.assertEqual(r["by_source"]["words"], {"shown": 3, "taken": 2})
        self.assertEqual((r["screen_reads"], r["screen_looks"], r["typing_min"], r["reads_per_min"]), (30, 14, 2, 15.0))

    def test_window(self):
        r = gq.measure(LINES, since=datetime(2026, 11, 17, 11, tzinfo=timezone.utc))
        self.assertEqual((r["shown"], r["taken"], r["screen_reads"]), (1, 1, 0))
        r = gq.measure(LINES, until=datetime(2026, 11, 17, 10, 0, 6, tzinfo=timezone.utc))
        self.assertEqual(r["shown"], 2)

    def test_empty(self):
        r = gq.measure([])
        self.assertIsNone(r["taken_rate"]); self.assertIsNone(r["reads_per_min"])


if __name__ == "__main__":
    unittest.main()

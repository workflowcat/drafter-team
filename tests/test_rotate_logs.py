"""Log rotation (scripts/rotate_logs.py) on made-up log lines in a scratch folder: app.log keeps its last 14 days,
nothing is lost, a held log is copied and truncated only for appending writers, old archives go after 8 weeks."""
import gzip, importlib.util, os, sys, tempfile, threading, time, unittest
from datetime import datetime, timedelta, timezone
from pathlib import Path

spec = importlib.util.spec_from_file_location("rotate_logs", Path(__file__).resolve().parents[1] / "scripts/rotate_logs.py")
rl = importlib.util.module_from_spec(spec); spec.loader.exec_module(rl)

NOW = datetime(2026, 11, 20, 4, 30, tzinfo=timezone.utc)


def app_lines(days_back):
    out = []
    for d in days_back:
        day = (NOW - timedelta(days=d)).strftime("%Y-%m-%d")
        out.append(f"{day}T10:00:00Z ghost TestApp gate len 7 word 5 taken 1 typed 0\n")
        out.append(f"{day}T11:00:00Z engine exited 0\n")
    return out


class Dated(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(); self.dir = Path(self.tmp.name)
        self.log = self.dir / "app.log"; self.logs = self.dir / "logs"

    def tearDown(self): self.tmp.cleanup()

    def archives(self): return sorted(self.logs.glob("*.log.gz")) if self.logs.exists() else []

    def test_keeps_last_14_days_and_loses_nothing(self):
        lines = app_lines(range(40, -1, -1))
        lines.insert(3, "  a continuation line with no stamp\n")
        original = "".join(lines).encode()
        self.log.write_bytes(original)
        msg = rl.rotate_dated(self.log, self.logs, NOW, dry=False, settle=0)
        self.assertIn("moved", msg)
        live = self.log.read_bytes()
        cutoff = (NOW - timedelta(days=14)).strftime("%Y-%m-%d")
        days = {l[:10] for l in live.decode().splitlines()}
        self.assertEqual(min(days), cutoff)  # day 14 back is kept whole
        for d in range(15):
            self.assertIn((NOW - timedelta(days=d)).strftime("%Y-%m-%d"), days)
        [arc] = self.archives()
        old = gzip.decompress(arc.read_bytes())
        self.assertEqual(old + live, original)
        self.assertTrue(arc.name.startswith("app-2026-10-11_2026-11-05"))
        # a second run the same night has nothing to move
        self.assertIn("nothing older", rl.rotate_dated(self.log, self.logs, NOW, dry=False, settle=0))

    def test_line_written_to_the_old_file_during_rotation_is_kept(self):
        self.log.write_text("".join(app_lines([30, 20, 1])))
        fd = os.open(self.log, os.O_WRONLY | os.O_APPEND)  # a writer that opened the file before the rename
        late = "2026-11-20T04:30:01Z written while rotating\n"
        t = threading.Timer(0.2, lambda: os.write(fd, late.encode()))
        t.start()
        try: rl.rotate_dated(self.log, self.logs, NOW, dry=False, settle=0.6)
        finally: t.join(); os.close(fd)
        self.assertTrue(self.log.read_text().endswith(late))

    def test_dry_run_changes_nothing(self):
        text = "".join(app_lines([30, 1]))
        self.log.write_text(text)
        self.assertIn("would move", rl.rotate_dated(self.log, self.logs, NOW, dry=True))
        self.assertEqual(self.log.read_text(), text); self.assertEqual(self.archives(), [])

    def test_all_recent_or_half_written_line_stays(self):
        self.log.write_text("".join(app_lines([3, 2, 1])))
        self.assertIn("nothing older", rl.rotate_dated(self.log, self.logs, NOW, dry=False, settle=0))
        day = (NOW - timedelta(days=30)).strftime("%Y-%m-%d")
        self.log.write_text(f"{day}T10:00:00Z only an old line, no newline yet")
        rl.rotate_dated(self.log, self.logs, NOW, dry=False, settle=0)
        self.assertEqual(self.archives(), [])


class Held(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(); self.dir = Path(self.tmp.name)
        self.log = self.dir / "engine.log"; self.logs = self.dir / "logs"
        self.log.write_text("Traceback (most recent call last):\n  made-up frame\nValueError: test\n" * 50)

    def tearDown(self): self.tmp.cleanup()

    def test_small_file_left_alone(self):
        self.assertIn("under", rl.rotate_held(self.log, self.logs, NOW, dry=False, max_mb=5))

    def test_writer_without_append_blocks_rotation(self):
        before = self.log.read_bytes()
        msg = rl.rotate_held(self.log, self.logs, NOW, dry=False, max_mb=0.001, hold=[("17754", "python3.12", "W,0x10000;SH")])
        self.assertIn("without O_APPEND", msg)
        self.assertEqual(self.log.read_bytes(), before)

    def test_appending_writer_copy_truncate_with_real_lsof(self):
        before = self.log.read_bytes()
        fd = os.open(self.log, os.O_WRONLY | os.O_APPEND)
        try:
            hold = rl.holders(self.log)
            self.assertTrue(any(p == str(os.getpid()) and "AP" in g for p, _, g in hold), hold)
            msg = rl.rotate_held(self.log, self.logs, NOW, dry=False, max_mb=0.001)
            self.assertIn("truncated", msg)
            os.write(fd, b"next line after rotation\n")
        finally: os.close(fd)
        self.assertEqual(self.log.read_bytes(), b"next line after rotation\n")  # no hole of zeros
        [arc] = sorted(self.logs.glob("*.log.gz"))
        self.assertEqual(gzip.decompress(arc.read_bytes()), before)

    def test_real_lsof_sees_a_writer_without_append(self):
        fd = os.open(self.log, os.O_WRONLY)
        try:
            msg = rl.rotate_held(self.log, self.logs, NOW, dry=False, max_mb=0.001)
        finally: os.close(fd)
        self.assertIn("without O_APPEND", msg)

    def test_real_lsof_sees_a_read_write_writer_without_append(self):
        # Argon 24: lsof marks O_RDWR as "RW", which the check missed; truncating under it leaves a hole of zeros
        fd = os.open(self.log, os.O_RDWR)
        try:
            msg = rl.rotate_held(self.log, self.logs, NOW, dry=False, max_mb=0.001)
        finally: os.close(fd)
        self.assertIn("without O_APPEND", msg)
        self.assertIn("without O_APPEND", rl.rotate_held(self.log, self.logs, NOW, dry=True, max_mb=0.001,
                                                       hold=[("1", "x", "RW,0x10000;SH")]))


class Prune(unittest.TestCase):
    def test_archives_older_than_8_weeks_go(self):
        with tempfile.TemporaryDirectory() as t:
            logs = Path(t)
            names = {"app-2026-09-01_2026-09-10.log.gz": 60, "engine-2026-09-30.log.gz": 50, "notes.txt": 90,
                     "voice-engine-2026-09-01.log.gz": 57}
            for n, age in names.items():
                p = logs / n; p.write_bytes(b"x")
                ts = NOW.timestamp() - age * 86400; os.utime(p, (ts, ts))
            gone = rl.prune(logs, NOW, dry=False)
            self.assertEqual(sorted(gone), ["app-2026-09-01_2026-09-10.log.gz", "voice-engine-2026-09-01.log.gz"])
            self.assertEqual(sorted(p.name for p in logs.iterdir()), ["engine-2026-09-30.log.gz", "notes.txt"])


if __name__ == "__main__":
    unittest.main()

"""No text of his on any `claude` command line: argv is readable by every process through `ps` (2026-11-14: the kept
workers carried his recent lines and chat messages in --system-prompt). Each spawn's argv is built with made-up text
and must not hold it; the text goes through stdin or a 0600 file that is deleted once read.
.venv/bin/python -B tests/test_claude_argv.py"""
import os, stat, sys, time, unittest
from pathlib import Path
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "engine"))
sys.path.insert(0, str(ROOT / "actions"))

SECRET = "made-up line about the zebra invoice 4471"   # never real text


class FakeProc:
    """Stands in for the `claude` process: records argv, answers one line, nothing leaves the Mac."""
    spawned = []

    def __init__(self, argv, **kw):
        FakeProc.spawned.append(argv)
        self.stdin = open(os.devnull, "w")
        self.stdout = iter(['{"type": "system", "subtype": "init"}\n'])
        self.returncode = None

    def poll(self): return None
    def kill(self): pass


def argv_text(argv):
    return " ".join(str(a) for a in argv)


class ClaudeArgv(unittest.TestCase):
    def setUp(self):
        FakeProc.spawned = []

    def test_typing_worker_system_prompt_goes_in_a_file(self):
        import claude_type as ct
        with patch.object(ct.subprocess, "Popen", FakeProc), patch.object(ct.Worker, "make_room", classmethod(lambda c: None)):
            path = ct.prompt_file(SECRET)
            mode = stat.S_IMODE(os.stat(path).st_mode)
            self.assertEqual(mode, 0o600)
            self.assertEqual(stat.S_IMODE(os.stat(ct.PROMPT_DIR).st_mode), 0o700)
            os.unlink(path)
            w = ct.Worker("haiku", "How he writes: " + SECRET)
            argv = FakeProc.spawned[-1]
            f = argv[argv.index("--system-prompt-file") + 1]
            for _ in range(100):             # the fake answers at once; the pump drops the file
                if not os.path.exists(f): break
                time.sleep(0.01)
            self.assertNotIn(SECRET, argv_text(argv))
            self.assertIn("--system-prompt-file", argv)
            self.assertNotIn("--system-prompt", argv)
            self.assertFalse(os.path.exists(f), "prompt file left after the process answered")
            with ct.Worker._reg: ct.Worker.live.clear()

    def test_every_feature_worker_goes_through_worker_argv(self):
        # rework builds ct.Worker; none spawns its own `claude`
        for name in ("rework", "claude_type", "notes", "claude_worker"):
            src = (ROOT / "engine" / f"{name}.py").read_text()
            self.assertNotIn("--system-prompt\"", src, name)
            self.assertNotIn("\"--system-prompt\",", src, name)
            self.assertNotIn("--append-system-prompt", src, name)

    def test_haiku_worker_argv_is_flags_only(self):
        import claude_worker
        self.assertNotIn(SECRET, argv_text(claude_worker.CMD))
        for a in claude_worker.CMD[1:]:
            self.assertTrue(a.startswith("-") or len(a) < 40, a)   # flags and short values, no prompt

    def test_action_prompt_goes_on_stdin(self):
        import _claude
        argv, stdin = _claude.command("notes-skill", "File this note: " + SECRET, ["Read", "Write"])
        self.assertNotIn(SECRET, argv_text(argv))
        self.assertIn(SECRET, stdin)

    def test_no_other_claude_spawn_in_the_code(self):
        # a new spawn site must be added here (and keep text off argv)
        known = {"engine/claude_type.py", "engine/claude_worker.py", "actions/_claude.py"}
        found = set()
        for d in ("engine", "actions"):
            for p in (ROOT / d).glob("*.py"):
                s = p.read_text()
                if ("local/bin/claude" in s or "ct.CLI" in s or "CLI," in s) and ("Popen(" in s or "subprocess.run(" in s):
                    found.add(f"{d}/{p.name}")
        for p in (ROOT / "app").glob("*.swift"):
            self.assertNotIn("bin/claude", p.read_text(), p.name)
        self.assertLessEqual(found, known | {"engine/notes.py"}, found - known)


if __name__ == "__main__":
    unittest.main()

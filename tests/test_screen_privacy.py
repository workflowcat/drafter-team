"""Screen text never reaches a log line or a file (2026-11-14, app/ScreenContext.swift): the picture's text lives in
memory for the request only. Grep-style checks on the code paths, like tests/test_claude_argv.py for prompts.
.venv/bin/python -B tests/test_screen_privacy.py"""
import re, unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SC = (ROOT / "app/ScreenContext.swift").read_text()
SCREEN = (ROOT / "app/Screen.swift").read_text()
RULES = (ROOT / "app/ScreenContextRules.swift").read_text()
KEYS = (ROOT / "app/Keys.swift").read_text()
# names that hold screen text in these files
TEXT_NAMES = r"\b(text|ax|lines|typing|c\.text|e\.text|txt|seen|kept|context|title)\b"


def log_calls(src):
    """Every log(...) call's argument text, balanced parentheses."""
    out, i = [], 0
    while (i := src.find("log(", i)) >= 0:
        if src[i - 1].isalnum() or src[i - 1] == "_": i += 4; continue
        depth, j = 0, i + 3
        while j < len(src):
            depth += src[j] == "("; depth -= src[j] == ")"
            if depth == 0: break
            j += 1
        out.append(src[i:j + 1]); i = j
    return out


class NoText(unittest.TestCase):
    def test_logs_carry_numbers_only(self):
        for name, src in (("ScreenContext", SC), ("Screen", SCREEN)):
            for call in log_calls(src):
                for interp in re.findall(r"\\\((.*?)\)", call):
                    self.assertIsNone(re.search(TEXT_NAMES, interp), f"{name}: text in a log line: {call[:120]}")
        # the stats line is built from parts: none of them interpolates text
        for part in re.findall(r'let s\d: String = (.*)', SC):
            self.assertIsNone(re.search(r"\\\((text|ax|lines|e\.text)\b", part), part)

    def test_rules_never_log(self):
        self.assertNotIn("log(", RULES)
        self.assertNotIn("print(", RULES)

    def test_no_files(self):
        for name, src in (("ScreenContext", SC), ("Rules", RULES)):
            for bad in ("FileManager", ".write(", "Data(contentsOf", "appendHandle", "createFile", "CGImageDestination", "UserDefaults"):
                self.assertNotIn(bad, src, f"{name} writes somewhere: {bad}")
        self.assertNotIn("print(", SC)

    def test_journal_gets_accessibility_text(self):
        line = next(l for l in KEYS.splitlines() if '"/typed"' in l and "Engine.shared.post" in l)
        self.assertIn("ScreenContext.shared.journal(", line, "data/typed.jsonl must get the Accessibility text, never picture text")

    def test_privacy_guards(self):
        g = SC[SC.index("static func mayCapture"):SC.index("// MARK: when")]
        for need in ("IsSecureEventInputEnabled", "settings.skip", "Screen.locked", "CGDisplayIsAsleep", "AXSecureTextField", "getpid()"):
            self.assertIn(need, g, f"no capture without the {need} check")
        self.assertIn("settings.screenContext", SC[SC.index("func read("):SC.index("func touch(")])

    def test_inspector_copy_is_concealed_and_skipped(self):
        iv = (ROOT / "app/InspectorView.swift").read_text()
        copy_fn = iv[iv.index("private func copyContext()"):iv.index("private func openPrivacyPane")]
        for need in ("History.ownType", "org.nspasteboard.ConcealedType", "History.skipChange"):
            self.assertIn(need, copy_fn, f"InspectorView.copyContext must mark pasteboard with {need}")
        self.assertIn("InspectorRules.redact(", KEYS, "liveSnapshot must enforce InspectorRules.redact privacy invariants")

    def test_screen_video_privacy_boundary(self):
        recorder = (ROOT / "app/ScreenVideoRecorder.swift").read_text()
        writer = (ROOT / "app/ScreenVideoWriter.swift").read_text()
        for guard in ("ScreenVideoRules.shouldSkipFrame", "IsSecureEventInputEnabled", "settings.skip", "Screen.locked",
                      "CGDisplayIsAsleep", "Talk.shared.paused", "settings.callScreenVideo", "currentToken() == token"):
            self.assertIn(guard, recorder)
        self.assertNotIn("DispatchQueue.main.sync", recorder, "writer queue must never block on main")
        self.assertIn("ScreenVideoRecorder.mayCaptureFrontApp()", (ROOT / "app/Shots.swift").read_text(),
                      "call screenshots must share the same skip/locked/secure-input privacy check")
        self.assertIn("excludingApplications", recorder, "new own/private app windows must also stay excluded")
        self.assertNotIn("windowTitle", recorder)
        for call in log_calls(recorder):
            for interp in re.findall(r"\\\((.*?)\)", call):
                self.assertIsNone(re.search(TEXT_NAMES + r"|localizedDescription|bundleID|frontApp", interp), call)
        self.assertGreaterEqual(writer.count("guard allowed()"), 2, "recheck privacy after pixel conversion, before append")
        self.assertNotIn("log(", writer)
        self.assertIn("writer.finishWriting", writer)
        self.assertIn("if !ok, ownsFile", writer, "cleanup must only remove its own failed output")


if __name__ == "__main__":
    unittest.main()

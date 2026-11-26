"""Every text Drafter writes into a field is counted for the draft budget (Focus.wrote, app/DraftCaptureRules.swift).

A write that bypasses the counter makes a draft look longer than the user's keys explain. The only places that may write
text are Focus.setSelectedText (AX), Focus.typeText (key events) and Focus.commandV (⌘V); each calls `wrote(`.
The test typer in DevHooks.swift posts plain key events (no Drafter mark): Keys counts them as the user's letters.

    .venv/bin/python -B tests/test_draft_writes.py
"""
from pathlib import Path
import re, unittest

ROOT = Path(__file__).resolve().parents[1]
APP = sorted((ROOT / "app").glob("*.swift"))

# a write of text into another app, by kind
WRITES = {
    "ax": re.compile(r"AXUIElementSetAttributeValue\([^)]*kAXSelectedTextAttribute"),
    "keys": re.compile(r"keyboardSetUnicodeString"),
    "paste": re.compile(r"virtualKey:\s*9\b"),
}
ALLOWED = {"ax": "setSelectedText", "keys": "typeText", "paste": "commandV"}
# the test typer and the live insert check's ghost and snippet steps: plain key events, counted as the user's letters
EXEMPT = {("DevHooks.swift", "keys"), ("InsertCheck.swift", "keys")}


def func_bodies(src: str) -> dict[str, str]:
    """`static func name(...) { body }` of Focus, by brace count."""
    out = {}
    for m in re.finditer(r"static func (\w+)\(", src):
        i = src.index("{", m.end())
        depth, j = 0, i
        while j < len(src):
            depth += {"{": 1, "}": -1}.get(src[j], 0)
            if depth == 0:
                break
            j += 1
        out.setdefault(m.group(1), src[i:j + 1])
    return out


def enclosing(src: str, pos: int) -> str:
    names = [(m.start(), m.group(1)) for m in re.finditer(r"func (\w+)\(", src) if m.start() < pos]
    return names[-1][1] if names else ""


class Writes(unittest.TestCase):
    def test_every_write_goes_through_focus(self):
        bad = []
        for f in APP:
            src = f.read_text()
            for kind, rx in WRITES.items():
                for m in rx.finditer(src):
                    if (f.name, kind) in EXEMPT:
                        continue
                    if f.name != "Focus.swift" or enclosing(src, m.start()) != ALLOWED[kind]:
                        bad.append(f"{f.name}:{src[:m.start()].count(chr(10)) + 1} {kind} in {enclosing(src, m.start()) or '?'}")
        self.assertEqual(bad, [], "text written outside Focus.setSelectedText/typeText/commandV is not counted")

    def test_the_three_count(self):
        bodies = func_bodies((ROOT / "app/Focus.swift").read_text())
        for name in ALLOWED.values():
            self.assertIn("wrote(", bodies[name], name)
        # paste and insert reach a counted write, never their own
        self.assertIn("commandV()", bodies["paste"])
        self.assertIn("setSelectedText(", bodies["insert"])

    def test_only_wrote_adds(self):
        src = "\n".join(f.read_text() for f in APP)
        self.assertEqual(len(re.findall(r"ownChars\s*\+=", src)), 1, "only Focus.wrote adds to ownChars")
        self.assertIn("private(set) static var ownChars", (ROOT / "app/Focus.swift").read_text())

    def test_the_scan_catches_a_bypass(self):
        fake = 'func sneaky() { AXUIElementSetAttributeValue(el, kAXSelectedTextAttribute as CFString, t as CFString) }'
        self.assertTrue(WRITES["ax"].search(fake))
        self.assertEqual(enclosing(fake, fake.index("AXUI")), "sneaky")


if __name__ == "__main__":
    unittest.main()

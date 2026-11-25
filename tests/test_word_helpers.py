"""Fictional fixtures: Python next-word copies versus actual Swift, and Python token-span copies.

There is no Swift word_ps implementation. Span offsets stay Python character offsets.
No app is built or started. The compiler cache and temporary executable are removed after the test.
Run: .venv/bin/python -B tests/test_word_helpers.py
"""
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path[:0] = [str(ROOT / "engine"), str(ROOT / "bench")]
import fim, gatecore, measure, request_policy, typescore

FIXTURE = ROOT / "tests/fixtures/word_helpers.json"
CASES = json.loads(FIXTURE.read_text())


class PythonCopies(unittest.TestCase):
    def test_next_word(self):
        for case in CASES["words"]:
            for module in (gatecore, fim, measure, typescore):
                with self.subTest(module=module.__name__, text=case["text"]):
                    self.assertEqual(module.next_word(case["text"]), case["word"])

    def test_token_spans(self):
        for case in CASES["spans"]:
            for module in (gatecore, fim):
                with self.subTest(module=module.__name__, case=case["name"]):
                    self.assertEqual(module.word_ps(case["tokens"], case["pos"], case["end"]), case["probabilities"])


class SwiftParity(unittest.TestCase):
    def test_actual_swift_word_and_request_helpers(self):
        # Extract exactly one dependency-free method; fail if its signature disappears.
        source = (ROOT / "app/Keys.swift").read_text()
        start = source.index("    static func nextWord(_ s: String) -> String {")
        opening = source.index("{", start)
        depth = 1
        end = opening + 1
        while depth:
            depth += (source[end] == "{") - (source[end] == "}")
            end += 1
        cache = ROOT / "app/build/module-cache"
        try:
            with tempfile.TemporaryDirectory() as tmp:
                wrapper, binary = Path(tmp) / "Keys.swift", Path(tmp) / "word-helpers"
                wrapper.write_text("import Foundation\nenum ParityKeys {\n" + source[start:end] + "\n}\n")
                cache.mkdir(parents=True, exist_ok=True)
                subprocess.run(["swiftc", "-module-cache-path", str(cache), "-parse-as-library",
                                str(ROOT / "app/GhostRules.swift"), str(wrapper),
                                str(ROOT / "tests/word_helpers.swift"), "-o", str(binary)], check=True)
                got = json.loads(subprocess.check_output([str(binary), str(FIXTURE)], text=True))
            self.assertEqual(got["words"], [c["word"] for c in CASES["words"]])
            current = request_policy.build(request_policy.CURRENT)
            self.assertEqual(got["request"], {k: v for k, v in current.request.items() if k != "keep_on"})
            # the dated bench mode keeps 2026-11-16's 0.3; live went bolder on 17 November (bench/guess_sweep.py)
            self.assertLessEqual(gatecore.guess_bar({}, "live"), current.guess_bar)
        finally:
            if cache.exists(): shutil.rmtree(cache)


if __name__ == "__main__":
    unittest.main()

"""History.tail (app/History.swift) cut out and compiled alone: the last rows without reading the whole file.

    .venv/bin/python -B tests/test_history_tail.py
"""
from pathlib import Path
import re, shutil, subprocess, tempfile, unittest

ROOT = Path(__file__).resolve().parents[1]


class Tail(unittest.TestCase):
    @unittest.skipUnless(shutil.which('swiftc'), 'Swift compiler required')
    def test_tail(self):
        src = (ROOT / 'app/History.swift').read_text()
        m = re.search(r'\n    static func tail\(.*?\n    }\n', src, re.S)
        self.assertIsNotNone(m)
        with tempfile.TemporaryDirectory(prefix='drafter-tail-') as d:
            p = Path(d)
            (p / 'history.swift').write_text('import Foundation\nenum History {' + m.group(0) + '}\n')
            built = subprocess.run(['swiftc', '-module-cache-path', str(p / 'cache'), '-parse-as-library', str(p / 'history.swift'),
                                    str(ROOT / 'tests/history_tail.swift'), '-o', str(p / 'check')], capture_output=True, text=True, timeout=180)
            self.assertEqual(built.returncode, 0, built.stderr[-2000:])
            run = subprocess.run([str(p / 'check')], capture_output=True, text=True, timeout=120)
            self.assertEqual(run.returncode, 0, run.stdout + run.stderr)


if __name__ == '__main__':
    unittest.main()

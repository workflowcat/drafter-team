"""Voice speed round two (2026-11-17): what a touch on the press tells about paged-out weights. No model.

    .venv/bin/python -B tests/test_voice_touch.py
"""
import sys, unittest
from pathlib import Path

ENGINE = Path(__file__).resolve().parent.parent / "engine"
sys.path.insert(0, str(ENGINE))
import guard
from server_src import lift


class Touch(unittest.TestCase):
    def facts(self):
        return lift("touch_facts", path=ENGINE / "voice.py")["touch_facts"]

    def test_usage_reads_this_process(self):
        u = guard.usage()
        self.assertEqual(set(u), {"pageins", "resident", "footprint"})
        self.assertGreater(u["resident"], 0); self.assertGreater(u["footprint"], 0)
        self.assertGreaterEqual(guard.usage()["pageins"], u["pageins"])
        self.assertEqual(guard.usage(pid=999999), {})          # no such process

    def test_facts(self):
        f = self.facts()
        self.assertEqual(f({"pageins": 10, "resident": 200, "footprint": 1300}, {"pageins": 75, "resident": 1300, "footprint": 1300}),
                         {"pageins": 65, "resident": 200, "footprint": 1300})
        self.assertEqual(f({}, {"pageins": 1, "resident": 1, "footprint": 1}), {})
        self.assertEqual(f({"pageins": 5, "resident": 1, "footprint": 1}, {"pageins": 3, "resident": 1, "footprint": 1})["pageins"], 0)


if __name__ == "__main__":
    unittest.main()

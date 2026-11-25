"""The shipped gate and selector (engine/defaults/): numbers only, made for today's features, and used by the engine
when data/ has none of its own (engine/server.py fitted()).

    .venv/bin/python -B tests/test_shipped_defaults.py
"""
import json, sys, unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "engine"))
import gatecore

D = ROOT / "engine/defaults"
NAMES = set(gatecore.NAMES) | set(gatecore.WORD_NAMES) | set(gatecore.SEL_NAMES)


def strings(x):
    if isinstance(x, dict):
        for v in x.values(): yield from strings(v)
    elif isinstance(x, list):
        for v in x: yield from strings(v)
    elif isinstance(x, str): yield x


class Defaults(unittest.TestCase):
    def test_gate_loads(self):
        self.assertIsNotNone(gatecore.load(D / "gate.json"))

    def test_selector_matches_the_features(self):
        s = json.loads((D / "selector.json").read_text())
        self.assertEqual(s["names"], gatecore.SEL_NAMES)
        self.assertEqual(s["wordgate"]["names"], gatecore.WORD_NAMES)

    def test_numbers_only(self):
        for f in ("gate.json", "selector.json"):
            d = json.loads((D / f).read_text())
            d.pop("from", None)
            self.assertEqual([s for s in strings(d) if s not in NAMES], [], f)

    def test_engine_falls_back_to_them(self):
        src = (ROOT / "engine/server.py").read_text()
        self.assertIn('fitted("gate.json")', src)     # in gate_file() since the model catalog (live keeps it)
        self.assertIn("p = fitted(name)", src)


if __name__ == "__main__":
    unittest.main()

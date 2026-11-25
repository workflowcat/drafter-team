import sys, unittest
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "bench"))
from held import Held


class HeldTest(unittest.TestCase):
    def setUp(self):
        self.h = Held(["Привіт, побачимось завтра о десятій біля входу в офіс", "ок"])

    def test_exact_and_spacing(self):
        self.assertTrue(self.h("ок"))
        self.assertTrue(self.h("Привіт,  побачимось завтра о десятій біля входу в офіс"))

    def test_other_takes(self):
        self.assertTrue(self.h("Привіт, побачимось завтра о десятій біля входу в офіс, добре?"))   # a longer take
        self.assertTrue(self.h("Привіт, побачимось завтра о десятій біля входу"))                  # a cut take
        self.assertTrue(self.h("Ще одне. Привіт, побачимось завтра о десятій біля входу в офіс"))   # inside a bigger text

    def test_others_pass(self):
        self.assertFalse(self.h("ок, дякую"))
        self.assertFalse(self.h("Побачимось у понеділок о десятій біля входу в офіс"))


if __name__ == "__main__":
    unittest.main()

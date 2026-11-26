"""Call prep (engine/prep.py) uses temporary, synthetic cache files only."""
from pathlib import Path
import sys
import tempfile
import unittest
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "engine"))
import prep

class PrepTests(unittest.TestCase):
    def test_disabled_vault_gives_an_empty_brief(self):
        with tempfile.TemporaryDirectory() as root:
            self.assertEqual(prep.about("Orchard", data_dir=root), {"people": [], "lines": [], "vault_notes": []})

if __name__ == "__main__": unittest.main()

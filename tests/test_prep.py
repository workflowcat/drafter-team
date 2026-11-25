"""Pre-meeting vault integration uses temporary, synthetic cache files only."""
import json
from pathlib import Path
import sqlite3
import sys
import tempfile
import unittest
from unittest.mock import patch
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "engine"))
import prep

class PrepTests(unittest.TestCase):
    def test_disabled_vault_preserves_existing_brief(self):
        with tempfile.TemporaryDirectory() as root:
            original = {"lines": ["Demo Guest - planning"], "people": ["Demo Guest"]}
            with patch.object(prep, "_people_about", return_value=original):
                result = prep.about("Orchard", data_dir=root)
            self.assertEqual(result["people"], ["Demo Guest"])
            self.assertEqual(result["lines"], ["Demo Guest - planning"])
            self.assertEqual(result["vault_notes"], [])

    def test_unavailable_person_database_is_not_a_brief_failure(self):
        with tempfile.TemporaryDirectory() as root:
            with patch.object(prep, "_people_about", side_effect=sqlite3.OperationalError("unavailable")):
                self.assertEqual(prep.about("Station", data_dir=root), {"people": [], "lines": [], "vault_notes": []})

if __name__ == "__main__": unittest.main()

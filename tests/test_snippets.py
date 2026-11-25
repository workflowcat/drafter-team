import sys, unittest
from pathlib import Path
from unittest.mock import patch
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'engine'))
import snippets
class Snippets(unittest.TestCase):
    def test_offers_without_model(self):
        saved = {';mail': 'au@example.com', ';cal': 'https://example.com/calendar'}
        with patch.object(snippets, 'load', return_value=saved):
            for before, want in [('au', 'au@example.com'), ('AU', 'au@example.com'), ('au@ex', 'au@example.com'), (';ca', saved[';cal']), ('my email is', ' au@example.com'), ('моя пошта: ', 'au@example.com'), ('лінк на календар', ' '+saved[';cal'])]:
                with self.subTest(before=before): self.assertEqual(snippets.offer(before)['run']['new'], want)
            for before in ['author', 'au@example.com', 'other@au', 'AU ', 'my calendar link disappeared']:
                with self.subTest(before=before): self.assertIsNone(snippets.offer(before))
    def test_missing_values(self):
        with patch.object(snippets, 'load', return_value={}): self.assertIsNone(snippets.offer('AU'))
if __name__ == '__main__': unittest.main()

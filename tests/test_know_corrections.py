import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'engine'))
import word_fixes
from words import Words

class Protected(unittest.TestCase):
    def test_legacy_is_one_and_new_count_two_protects(self):
        with tempfile.TemporaryDirectory() as temp:
            root=Path(temp)
            (root/'autocorrect-keep.txt').write_text('tomorow\ntomorow\nretun\n')
            (root/'autocorrect-keep.json').write_text(json.dumps({'retun':2,'other':1}))
            (root/'mywords.txt').write_text('slang\n')
            (root/'known-words.txt').write_text('Hanna\nМаксимом\n')
            with patch.object(word_fixes,'DATA',root):
                kept=word_fixes.keep_words()
                self.assertEqual(kept, {'retun','slang','hanna','максимом'})
                self.assertEqual(word_fixes.edits('say Hanna here','say Hannah here'), [])
                self.assertEqual(word_fixes.edits('say Hanna here','say Han na here')[0]['new'], 'Han na')
                self.assertEqual(word_fixes.edits('say Han na here','say Hanna here')[0]['new'],'Hanna')
                self.assertEqual(word_fixes.edits('go tomorow','go tomorrow')[0]['new'],'tomorrow')
            self.assertEqual((root/'autocorrect-keep.txt').read_text(),'tomorow\ntomorow\nretun\n')

    def test_known_pieces_join_only_to_a_known_word(self):
        for old, new, keep in [('any way', 'anyway', {'any', 'way', 'anyway'}),
                               ('на приклад', 'наприклад', {'на', 'приклад', 'наприклад'}),
                               ('Ган на', 'Ганна', {'на', 'ганна'})]:
            self.assertEqual(word_fixes.edits(old, new, keep)[0]['new'], new)
            self.assertEqual(word_fixes.edits(new, old, keep)[0]['new'], old)
        self.assertEqual(word_fixes.edits('any qzx', 'anyqzx', {'any'}), [])
        self.assertEqual(word_fixes.edits('Hanna', 'Hannah', {'hanna'}), [])

    def test_export_counts_and_words_from_same_snapshot(self):
        with tempfile.TemporaryDirectory() as temp:
            w=Words()
            for _ in range(6): w.add('hello Hanna')
            w.add('rare')
            w.uni['seeded'] = 8  # dictionary/model weight is not an observed use
            root=Path(temp); w.export(root/'mywords.txt')
            self.assertEqual(json.loads((root/'myword-counts.json').read_text()), {'hello':6,'hanna':6})
            self.assertEqual((root/'mywords.txt').read_text().splitlines(), ['hanna','hello','seeded'])

if __name__=='__main__': unittest.main()

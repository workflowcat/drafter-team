"""Knowledge pack fixtures only. No personal files, server, app or models."""
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'engine'))
import know


class PackBuild(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(); self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.dictionary = self.root / 'words.json'
        self.dictionary.write_text(json.dumps({'words': [
            {'text':'Ганна Онищенко','kind':'name'}, {'text':'Максим Ковальський','kind':'name'},
            {'text':'CustomTerm','kind':'term'}, {'text':'Base'}, {'text':'DataKit'},
            {'text':'Old Seed Sentinel','source':'people'},
            {'text':'Scoped Secret','scope':'private'}, {'text':'FreshRepo','kind':'project'}]}))
        self.snips = self.root / 'snippets.json'; self.snips.write_text(json.dumps({';thanks':'Thanks again', ';link':'https://example.test', ';field':'Hi {name}'}))
        self.out = self.root / 'know.json'

    def build(self, **kw):
        return know.build(self.out, dictionary=self.dictionary, snippets=self.snips, now=100000, **kw)

    def test_private_words_and_old_seeds_never_exported(self):
        pack = self.build()
        output = self.out.read_text() + self.out.with_name('known-words.txt').read_text()
        for secret in ('Sentinel', 'Secret', 'https://example.test', '{name}'):
            self.assertNotIn(secret, output)
        h = next(e for e in pack['entries'] if e['name'].startswith('Ганна'))
        self.assertEqual((h['kind'], h['handles']), ('person', {}))
        self.assertEqual({e['kind'] for e in pack['entries']}, {'person','term','phrase'})

    def test_tokens_surnames_forms_and_common_guard(self):
        p = self.build(common={'datakit'})
        h = p['entries'][0]
        self.assertIn('Онищенко', h['tokens']); self.assertIn('Ганною', h['forms'])
        self.assertIn('Ганна', h['tokens']); self.assertIn('Ганні', h['forms'])
        self.assertIn('base', next(e for e in p['entries'] if e['name']=='Base')['common'])
        self.assertIn('datakit', next(e for e in p['entries'] if e['name']=='DataKit')['common'])
        words = self.out.with_name('known-words.txt').read_text().splitlines()
        self.assertIn('Ковальському', words)
        self.assertNotIn('Ганна Онищенко', words)
        self.assertFalse(list(self.root.glob('.know.json*')))

    def test_heat_sent_usage_and_frequent_lowercase(self):
        p = self.build(lines=['ask Ганна about DataKit'] * 6 + ['base base base'] * 5)
        h = p['entries'][0]
        self.assertEqual(h['heat'], 7)      # 1 + 6 lines that name her
        base = next(e for e in p['entries'] if e['name']=='Base')
        self.assertLess(base['heat'], 2)  # ordinary lowercase mentions never heat a term
        pix = next(e for e in p['entries'] if e['name']=='DataKit')
        self.assertGreater(pix['heat'], base['heat'])
        p = self.build(lines=['use customterm'] * 5)
        self.assertIn('customterm', next(e for e in p['entries'] if e['name']=='CustomTerm')['common'])

    def test_reload_and_people_endpoint_data(self):
        self.build(); reader = know.Pack(self.out)
        self.assertEqual(reader.stats()['entries'], 7)
        self.assertEqual(reader.people('онищ'), [])   # a dictionary name has no handle: not a person card
        self.assertEqual(reader.people('Secret'), [])
        know.atomic(self.out, json.dumps({'entries': [{'name': 'Hanna Sample', 'kind': 'person', 'aliases': [], 'tokens': ['Hanna'],
                                                       'forms': [], 'handles': {'email': ['hanna@example.test']}}]}))
        self.assertEqual(reader.people('han')[0]['handles']['email'], ['hanna@example.test'])
        self.assertEqual(reader.people('h'), [])
        self.build(); self.assertEqual(reader.people('han'), [])
        self.out.unlink(); self.assertEqual(reader.stats()['entries'], 0)


class Language(unittest.TestCase):
    def test_case_endings(self):
        for word, forms in {
            'Максим': ['Максима','Максиму','Максимом'], 'Аліна':['Аліни','Аліні','Аліною'],
            'Сергій':['Сергія','Сергію','Сергієм'], 'Юрій':['Юрія','Юрію'],
            'Коваленко':['Коваленка','Коваленку','Коваленком'], 'Мельничук':['Мельничука','Мельничуком'],
            'Романюк':['Романюка','Романюку'], 'Ковальська':['Ковальської','Ковальській','Ковальською'],
            'Ковальський':['Ковальського','Ковальському','Ковальським'], 'Марія':['Марії','Марією'],
            'Ольга':['Ользі'], 'Леся':['Лесі','Лесею']}.items():
            with self.subTest(word=word): self.assertTrue(set(forms) <= know.case_forms(word))
        self.assertEqual(know.case_forms('Коваленко', female=True, surname=True), set())
        self.assertEqual(know.case_forms('Smith'), set())

    def test_conservative_gender_aliases_and_foreign_names(self):
        def forms(name, aliases=()): return know.person_forms({'name':name, 'aliases':list(aliases)})
        self.assertFalse(any(know.CYRILLIC.fullmatch(w) for w in forms('Hannah Sample')))
        self.assertNotIn('Коваленка', forms('Любов Коваленко', ['Коваленко']))
        self.assertIn('Любові', forms('Любов Коваленко'))
        self.assertNotIn('Онищенка', forms('Ганна Онищенко', ['Онищенко']))
        self.assertNotIn('Коваленка', forms('Нінель Коваленко'))
        self.assertIn('Микити', forms('Микита Коваленко'))
        self.assertIn('Коваленка', forms('Микита Коваленко'))
        self.assertIn('Коломійця', forms('Максим Коломієць'))
        self.assertNotIn('Коломіця', forms('Максим Коломієць'))
        self.assertNotIn('Коваленка', forms('Невідоме Коваленко'))
        self.assertIn('Ковальського', forms('Vitalii Kovalskyi', ['Віталій Ковальський']))
        self.assertIn('Віталій', forms('Vitalii Kovalskyi'))
        self.assertFalse(any('Ковалск' in w for w in forms('Vitalii Kovalskyi')))
        self.assertEqual(know.transliterate('Ковальський'), 'Kovalskyi')
        self.assertEqual(know.transliterate('Віталій'), 'Vitalii')
        self.assertTrue(all(w[0].isupper() for w in forms('hanna', ['Ганна'])))

    def test_first_name_instrumental_preserves_existing_gates(self):
        def forms(name, aliases=()): return know.person_forms({'name': name, 'aliases': list(aliases)})
        for name, expected in (('Ганна', 'Ганною'), ('Микита', 'Микитою'), ('Марія', 'Марією')):
            with self.subTest(name=name):
                self.assertIn(expected, forms(name + ' Коваленко'))
        self.assertIn('Марією', forms('Mariia Sample'))
        self.assertNotIn('Іванною', forms('Іванна Коваленко'))  # unknown first name stays gated
        self.assertNotIn('Ганною', forms('Ганна', ['Микита']))  # conflicting genders stay gated
        self.assertNotIn('Коваленком', forms('Марія Коваленко'))
        # Exercise another vowel before -я without expanding the recognized-name table.
        self.assertNotIn('Зоєю', forms('Зоя'))
        with patch.object(know, 'FEMALE', know.FEMALE | {'Зоя'}):
            self.assertIn('Зоєю', forms('Зоя'))
            self.assertNotIn('Зоєю', forms('Ганна Зоя'))  # no new surname rule

    def test_transliteration(self):
        for a, b in [('Юра','Yura'), ('Ганна','Hanna'), ('Сергій','Serhii'), ('Аліна','Alina')]:
            self.assertIn(b, know.first_variants(a)); self.assertIn(a, know.first_variants(b))
        self.assertEqual(know.transliterate('Коваленко'), 'Kovalenko')
        self.assertEqual(know.transliterate('Kovalenko'), '')
        self.assertIn('Сергій', know.first_variants('Serhiy'))

if __name__ == '__main__': unittest.main()

"""The names reference (engine/names.py) on made-up stores only. No personal files, server, app or models.

    .venv/bin/python -B tests/test_names.py
"""
import json
from pathlib import Path
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'engine'))
import names
import know


def entities():
    recs = [
        {'id': 'aleph:p1', 'kind': 'person', 'name': 'Ганна Квітка', 'aliases': ['Slava'],
         'names': {'uk': 'Ганна Квітка', 'en': ''}, 'handles': {'phone': ['+380 00 000 0001'], 'email': ['slava@example.test']},
         'relations': [{'id': 'aleph:pr1', 'why': 'works on', 'w': 0.8, 'src': 'aleph'}], 'related': ['aleph:pr1'],
         'sources': [{'system': 'aleph', 'id': 'p1'}], 'private': False},
        {'id': 'aleph:pr1', 'kind': 'project', 'name': 'Bramblix', 'aliases': [], 'names': {'uk': '', 'en': 'Bramblix'},
         'handles': {}, 'relations': [], 'related': [], 'sources': [{'system': 'aleph', 'id': 'pr1'}], 'private': False},
        {'id': 'aleph:pr1-repo', 'kind': 'tool', 'name': 'Bramblix', 'aliases': [], 'names': {'uk': '', 'en': 'Bramblix'},
         'handles': {}, 'relations': [], 'related': [], 'sources': [{'system': 'aleph', 'id': 'pr1-repo'}],
         'private': False, 'twin_of': 'aleph:pr1'},
        {'id': 'aleph:o1', 'kind': 'org', 'name': 'Larkspur Labs', 'aliases': [], 'names': {'uk': '', 'en': 'Larkspur Labs'},
         'handles': {}, 'relations': [], 'related': [], 'sources': [{'system': 'aleph', 'id': 'o1'}], 'private': False},
        {'id': 'aleph:secret', 'kind': 'person', 'name': 'Hidden Sentinel', 'aliases': [], 'names': {'uk': '', 'en': 'Hidden Sentinel'},
         'handles': {}, 'relations': [], 'related': [], 'sources': [], 'private': True},
        {'id': 'google:people/c9', 'kind': 'person', 'name': 'Quill Contact', 'aliases': [], 'names': {'uk': '', 'en': 'Quill Contact'},
         'handles': {'email': ['quill@example.test']}, 'relations': [], 'related': [], 'sources': [{'system': 'contacts', 'id': 'google:people/c9'}],
         'private': False, 'cards_only': True},
    ]
    return {'records': recs, 'surfaces': {'ганні': [[0, 'form']], 'bramblix': [[1, 'name'], [2, 'name']]}}


def know_pack():
    return {'entries': [
        {'id': 'p1', 'name': 'Ганна Квітка', 'kind': 'person', 'aliases': ['Slava'], 'tokens': ['Ганна', 'Квітка', 'Slava'],
         'forms': ['Ганни', 'Ганну', 'Ганною'], 'common': []},
        {'name': 'Zephyrine', 'kind': 'term', 'aliases': [], 'tokens': ['Zephyrine'], 'forms': [], 'common': []},
        {'name': 'snippet text here', 'kind': 'phrase', 'aliases': [], 'tokens': ['snippet'], 'forms': [], 'common': []},
    ]}


def words():
    return {'terms': ['Bramblix', 'Zephyrine'], 'heard': {'brambel': 'Bramblix'},
            'words': [{'text': 'Bramblix', 'kind': 'project', 'source': 'aleph', 'heard': ['brambel']},
                      {'text': 'Glimmerdocs', 'kind': 'term', 'source': 'voicenotes'}], 'loose_heard': {}}


ROWS = [{'t': 1_760_000_000, 'app': 'Claude', 'text': 'спитай Ганну про Bramblix'},
        {'t': 1_760_100_000, 'app': 'Beeper', 'text': 'Bramblix вже готовий'},
        {'t': 1_760_200_000, 'app': 'Claude', 'text': 'test ⟦drafter-test⟧ Bramblix'}]
CHATS = {'chat-a': ['Ганна, привіт', 'як Bramblix?'], 'chat-b': ['Bramblix знову']}


def build(edits=()):
    return names.build_entries(entities=entities(), know=know_pack(), words=words(), edits=list(edits), rows=ROWS, chats=CHATS)


class Build(unittest.TestCase):
    def test_one_entry_per_thing(self):
        es = build()
        self.assertNotIn('aleph:secret', es)                       # private never enters
        self.assertNotIn('aleph:pr1-repo', es)                     # a twin folds into its main record
        self.assertEqual(es['aleph:pr1']['kind'], 'project')
        self.assertEqual(es['aleph:o1']['kind'], 'company')
        self.assertIn('know:Zephyrine'.replace('Zephyrine', 'zephyrine'), es)   # a dictionary leftover is a term
        self.assertIn('word:glimmerdocs', es)
        self.assertFalse(any(e['uk'] == 'snippet text here' or e['latin'] == 'snippet text here' for e in es.values()))

    def test_fields(self):
        p = build()['aleph:p1']
        self.assertEqual(p['uk'], 'Ганна Квітка')
        self.assertTrue(p['latin'].startswith('Hanna'))       # Latin filled from the Ukrainian
        self.assertIn('Ганні', p['forms'])                    # entity form, capital restored
        self.assertIn('Ганною', p['forms'])                   # know form
        self.assertIn('Slava', p['short'])
        self.assertEqual(p['phones'], ['+380 00 000 0001'])
        self.assertEqual(p['links'], ['aleph:pr1'])
        self.assertEqual(build()['aleph:pr1']['heard'], ['brambel'])

    def test_context(self):
        es = build()
        b, p = es['aleph:pr1']['context'], es['aleph:p1']['context']
        self.assertEqual(b['lines'], 2)                            # the test line is never counted
        self.assertEqual(b['apps'], {'Claude': 1, 'Beeper': 1})
        self.assertEqual(b['chats'], 2)
        self.assertEqual(p['lines'], 1); self.assertEqual(p['chats'], 1)   # a case form counts
        self.assertEqual(b['last_seen'], names.day(1_760_100_000))
        self.assertEqual(es['google:people/c9']['context']['lines'], 0)
        self.assertTrue(es['google:people/c9']['card'])

    def test_shared_word_counts_for_none(self):
        es = names.build_entries(entities={'records': [
            {'id': 'a', 'kind': 'person', 'name': 'Orin Vale', 'names': {}, 'sources': []},
            {'id': 'b', 'kind': 'person', 'name': 'Orin Pike', 'names': {}, 'sources': []}]},
            rows=[{'t': 1, 'app': 'x', 'text': 'Orin said'}, {'t': 2, 'app': 'x', 'text': 'Orin Pike said'}])
        self.assertEqual(es['a']['context']['lines'], 0)
        self.assertEqual(es['b']['context']['lines'], 1)


class Edits(unittest.TestCase):
    def test_cases_file(self):
        """The golden cases app/NameRules.swift runs too."""
        cases = json.loads((Path(__file__).parent / 'names_cases.json').read_text())
        for c in cases:
            es = {e['id']: e for e in json.loads(json.dumps(c['entries']))}
            names.apply_edits(es, c['edits'])
            got = {i: {k: es[i][k] for k in c['fields']} for i in sorted(es)}
            self.assertEqual(got, c['expect'], c['name'])

    def test_spell_hide_merge_in_build(self):
        es = build([{'op': 'spell', 'id': 'aleph:o1', 'latin': 'Larkspur Lab'},
                    {'op': 'hide', 'id': 'word:glimmerdocs', 'on': True},
                    {'op': 'merge', 'id': 'know:zephyrine', 'into': 'aleph:pr1'},
                    {'op': 'merge', 'id': 'gone', 'into': 'aleph:pr1'}])
        self.assertEqual(es['aleph:o1']['latin'], 'Larkspur Lab')
        self.assertIn('Larkspur Labs', es['aleph:o1']['heard'])
        self.assertTrue(es['word:glimmerdocs']['hidden'])
        self.assertNotIn('know:zephyrine', es)
        self.assertIn('Zephyrine', es['aleph:pr1']['short'])

    def test_spelled_person_gets_forms(self):
        es = build([{'op': 'spell', 'id': 'aleph:p1', 'uk': 'Ганна Квіткова'}])
        self.assertIn('Ганна Квітка', es['aleph:p1']['heard'])
        self.assertTrue(any(f.startswith('Квітков') for f in es['aleph:p1']['forms']))

    def test_kind_edit_and_invalid_ignored(self):
        es = build([
            {'op': 'kind', 'id': 'aleph:o1', 'kind': 'project'},
            {'op': 'kind', 'id': 'aleph:p1', 'kind': 'not_a_kind'},
            {'op': 'kind', 'id': 'missing_id', 'kind': 'place'},
        ])
        self.assertEqual(es['aleph:o1']['kind'], 'project')
        self.assertTrue(es['aleph:o1'].get('edited'))
        self.assertEqual(es['aleph:p1']['kind'], 'person')

    def test_kind_edit_apply_count(self):
        entries = {
            'k1': names.blank('k1', 'term', 'Orchard Studio'),
            'k2': names.blank('k2', 'person', 'Olena Koval'),
        }
        n = names.apply_edits(entries, [
            {'op': 'kind', 'id': 'k1', 'kind': 'company'},
            {'op': 'kind', 'id': 'k2', 'kind': 'bogus'},
            {'op': 'kind', 'id': 'gone', 'kind': 'place'},
        ])
        self.assertEqual(n, 1)
        self.assertEqual(entries['k1']['kind'], 'company')
        self.assertTrue(entries['k1'].get('edited'))
        self.assertEqual(entries['k2']['kind'], 'person')


class Derived(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(); self.addCleanup(self.tmp.cleanup)
        self.data = Path(self.tmp.name)
        (self.data / 'entities.json').write_text(json.dumps(entities(), ensure_ascii=False))
        (self.data / 'know.json').write_text(json.dumps(know_pack(), ensure_ascii=False))
        (self.data / 'words.json').write_text(json.dumps(words(), ensure_ascii=False))
        (self.data / 'corpus.jsonl').write_text('\n'.join(json.dumps(r, ensure_ascii=False) for r in ROWS) + '\n')
        (self.data / 'people.json').write_text(json.dumps({'chats': {k: {'mine': v} for k, v in CHATS.items()}}, ensure_ascii=False))

    def test_build_writes_store_and_derived(self):
        (self.data / 'names-edits.json').write_text(json.dumps([{'op': 'hide', 'id': 'know:zephyrine'}, {'op': 'spell', 'id': 'aleph:o1', 'latin': 'Larkspur Lab'}]))
        store = names.build(self.data, now=1)
        self.assertEqual(json.loads((self.data / 'names.json').read_text())['built'], 1)
        kw = (self.data / 'known-words.txt').read_text().split()
        self.assertIn('Ганною', kw); self.assertIn('Bramblix', kw)
        self.assertNotIn('Quill', kw)                               # a contact card is not a known word
        self.assertNotIn('Zephyrine', kw)                           # hidden
        d = json.loads((self.data / 'words.json').read_text())
        self.assertEqual(set(d), {'about', 'updated', 'terms', 'heard', 'keep', 'words', 'loose_heard'})   # Voice Notes' shape
        self.assertNotIn('Zephyrine', d['terms'])
        self.assertIn('Larkspur Lab', d['terms'])                   # his spelling is a term
        self.assertEqual(d['heard'].get('Larkspur Labs'), 'Larkspur Lab')
        self.assertEqual(d['heard'].get('brambel'), 'Bramblix')
        self.assertEqual(d['terms'][0], 'Bramblix')                  # most used first
        self.assertEqual([w['text'] for w in d['words']][:2], ['Glimmerdocs', 'Bramblix'])   # the source of truth is kept
        self.assertEqual(names.stats(store)['entries'], len(store['entries']))

    def test_voice_hint_uses_named_things_only(self):
        store = names.build(self.data, derive_files=False)
        hint = names.voice_hint(store)
        self.assertEqual(hint[0], 'Bramblix')
        self.assertNotIn('Quill Contact', hint)
        self.assertNotIn('Hanna Kvitka', hint)                       # a guessed transliteration is not a spelling
        self.assertIn('Ганна Квітка', hint)
        self.assertEqual(store['voice'], hint)

    def test_derive_after_app_edit(self):
        store = names.build(self.data)
        for e in store['entries']:
            if e['id'] == 'aleph:p1': e['uk'] = 'Ганна Квіткова'; e['edited'] = True
        (self.data / 'names.json').write_text(json.dumps(store, ensure_ascii=False))
        out = names.derive(self.data)
        self.assertGreater(out['known_words'], 0)
        self.assertIn('Квітковою', (self.data / 'known-words.txt').read_text().split())

    def test_know_snapshot_prefers_names(self):
        names.build(self.data)
        pack = know.Pack(self.data / 'know.json')
        self.assertIsInstance(pack.snapshot(), names.Pack)
        import os
        os.environ['DRAFTER_NAMES'] = '0'
        try: self.assertIsInstance(pack.snapshot(), know.Pack)
        finally: del os.environ['DRAFTER_NAMES']


class Finish(unittest.TestCase):
    def pack(self, extra=()):
        recs = [{'id': 'a', 'kind': 'person', 'name': 'Ганна Квітка', 'names': {'uk': 'Ганна Квітка'}, 'sources': []},
                {'id': 'b', 'kind': 'project', 'name': 'Bramblix', 'names': {'en': 'Bramblix'}, 'sources': []},
                {'id': 'c', 'kind': 'person', 'name': 'Brandon Oak', 'names': {'en': 'Brandon Oak'}, 'sources': []}] + list(extra)
        es = names.build_entries(entities={'records': recs}, rows=[{'t': 1, 'app': 'x', 'text': 'Bramblix'}] * 5)
        return names.Pack().load({'entries': names.ordered(es)})

    def test_two_letters_of_a_used_name(self):
        p = self.pack()
        self.assertEqual(p.finish('я про Ган', {'ганна': 2}, {'ган': 2}), 'на')
        self.assertEqual(p.finish('ask Bram', {'bramblix': 4}, {'bram': 4}), 'blix')

    def test_case_form(self):
        p = self.pack()
        self.assertEqual(p.finish('скажи Ганн', {'ганні': 3}, {'ганн': 3}), 'і')

    def test_unclear_or_lowercase_gives_nothing(self):
        p = self.pack()
        self.assertEqual(p.finish('ask Bra', {'bramblix': 1, 'brandon': 1}, {'bra': 2}), '')   # two names fit evenly
        self.assertEqual(p.finish('ask bram', {'bramblix': 4}, {'bram': 4}), '')               # lower case: an ordinary word
        self.assertEqual(p.finish('ask B', {'bramblix': 4}, {'b': 4}), '')                      # one letter
        self.assertEqual(p.finish('ask Bramblix', {'bramblix': 4}, {'bramblix': 4}), '')          # already whole

    def test_other_words_he_writes_win(self):
        p = self.pack()
        self.assertEqual(p.finish('ask Bram', {'bramblix': 1}, {'bram': 200}), '')

    def test_never_used_needs_three_letters(self):
        p = self.pack()
        self.assertEqual(p.finish('ask Br', {}, {}), '')
        self.assertEqual(p.finish('ask Bra', {}, {}), 'mblix')     # the used project leads the unused person

    def test_targets_and_people(self):
        p = self.pack()
        self.assertEqual(p.targets('ask Bra', 'Bramblix is on screen'), [('mblix', 1.0)])
        self.assertEqual(p.people(';ган'), [])                     # no phone or email


if __name__ == '__main__':
    unittest.main()

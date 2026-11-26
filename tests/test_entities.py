"""The entity store and context packs (engine/entities.py) on a made-up cast only: source records handed to build()
(`slices`) in a temporary folder. No personal file, server, app or model.

    .venv/bin/python -B tests/test_entities.py
"""
import json
from pathlib import Path
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'engine'))
import entities
from server_src import lift

CASES = Path(__file__).resolve().parent / 'entity_cases.json'
NOW = 1794000000          # 2026-11-07
TODAY = '2026-11-14'
HANNA = 'notes:people/hanna'


def note(rid, kind, name, aliases=(), date='', role='', org='', summary='', facts=(), links=(), urls=(), handles=None, **kw):
    """One made-up source record, in the shape build() takes."""
    r = {'system': kw.pop('system', 'notes'), 'id': rid, 'kind': kind, 'name': name, 'aliases': list(aliases), 'summary': summary,
         'handles': handles or {}, 'facts': [{'text': t, 'source': 'notes', 'date': date, 'quote': q, 'rank': i, 'private': False}
                                             for i, (t, q) in enumerate(facts)],
         'links': [{'to': to, 'key': key, 'n': 1, 'date': date} for to, key in links], 'private': False, 'date': date, **kw}
    if role: r['role'] = role
    if org: r['org'] = org
    if urls: r['urls'] = list(urls)
    return r


class Cast(unittest.TestCase):
    """Made-up people, a client, two projects, and cards of another made-up source."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(); self.addCleanup(self.tmp.cleanup)
        root = Path(self.tmp.name)
        self.data = root / 'data'; self.data.mkdir()
        (self.data / 'drafter.local.json').write_text(json.dumps({'user': {'name': 'Owner Sample'}}))
        self.codius = root / 'Codius'; (self.codius / 'lantern').mkdir(parents=True)
        self.notes = [
            note('people/hanna', 'person', 'Ганна Ткач', ['Hanna Tkach', 'Ганна', 'HT'], '2026-11-02', role='finance lead', org='Lantern Labs',
                 facts=[('finance lead', False), ('works at Lantern Labs', False)], links=[('notes:orgs/lantern-labs', 'org')]),
            note('people/owner', 'person', 'Owner Sample', summary='his own note'),
            note('people/ivan', 'person', 'Іван Семпл', date='2026-11-01'),
            note('people/ivan-other', 'person', 'Іван Інший', date='2026-11-01'),
            note('orgs/lantern-labs', 'org', 'Lantern Labs', date='2026-11-12', summary='client, ordering tool',
                 facts=[('client, ordering tool', False)], links=[('notes:stories/lantern', 'related')]),
            note('stories/lantern', 'project', 'Lantern', date='2026-11-11', summary='ordering tool for Lantern Labs',
                 facts=[('status: active', False), ('next: invoice export', True), ('ordering tool for Lantern Labs', True)],
                 urls=['https://lantern-gate.example.workers.dev']),
            note('stories/base', 'project', 'Base', date='2026-11-01'),
        ]
        self.cards = [
            note('c1', 'person', 'Hanna T.', system='cards', handles={'email': ['Hanna@Example.test'], 'phone': ['+380 44 555 0100']}),
            note('c2', 'person', 'Petro Card', system='cards', handles={'email': ['petro@example.test']}),
            note('c3', 'person', 'noreply@example.test', system='cards', handles={'email': ['noreply@example.test']}, cards_only=True),
            note('c4', 'person', 'Іван Семпл', system='cards'),
        ]
        # the user's own yes: the card "Hanna T." is Ганна Ткач
        self.same({'same': [[HANNA, 'cards:c1']]})

    def same(self, d):
        (self.data / 'entity-same.json').write_text(json.dumps(d, ensure_ascii=False))

    def build(self, **kw):
        args = dict(slices={'notes': self.notes, 'cards': self.cards}, now=NOW, data=self.data, ordinary={'labs', 'base', 'other'},
                    codius=self.codius)
        args.update(kw)
        return entities.build(**args)

    def rec(self, store, name):
        return next(r for r in store['records'] if r['name'] == name)

    # privacy ------------------------------------------------------------------------------------------------------

    def test_own_name_is_never_a_record(self):
        store = self.build()
        self.assertNotIn('Owner Sample', [r['name'] for r in store['records']])
        self.assertFalse(any(r['private'] for r in store['records']))
        self.assertFalse((self.data / 'entity-sources.json').exists())   # no source cache any more

    def test_a_record_marked_private_says_so(self):
        store = self.build(slices={'notes': self.notes + [dict(note('people/quiet', 'person', 'Quiet Sample'), private=True)]})
        self.assertTrue(self.rec(store, 'Quiet Sample')['private'])

    def test_phone_numbers_never_in_a_pack(self):
        store = self.build()
        for r in store['records']:
            for level in (2, 3):
                text = entities.render(r, level, today=TODAY)
                self.assertNotRegex(text, r'\d{3}[ -]?\d{3}[ -]?\d{2,}', r['name'])
                self.assertNotIn('0100', text)
        self.assertIn('+380 44 555 0100', self.rec(store, 'Ганна Ткач')['handles']['phone'])   # the user's own card keeps it

    def test_no_build_reads_a_source_of_its_own(self):
        store = self.build(slices=None)
        self.assertEqual([r for r in store['records'] if r['sources'][0]['system'] != 'term'], [])

    # merging, ids, kinds ------------------------------------------------------------------------------------------

    def test_one_record_per_thing(self):
        store = self.build()
        h = self.rec(store, 'Ганна Ткач')
        self.assertEqual({s['system'] for s in h['sources']}, {'notes', 'cards'})   # the user's own "same"
        self.assertEqual(h['id'], HANNA)
        self.assertEqual(h['targets']['mail'], 'Hanna@Example.test')
        lantern = self.rec(store, 'Lantern')
        self.assertEqual(lantern['kind'], 'project')
        self.assertEqual({s['system'] for s in lantern['sources']}, {'notes'})
        self.assertIn(self.rec(store, 'Lantern Labs')['id'], h['related'])
        # same full name in the cards, no handle to confirm: kept apart and counted for a "Same?" row
        ivans = [r for r in store['records'] if r['name'] == 'Іван Семпл']
        self.assertEqual(len(ivans), 2)
        self.assertEqual(store['same_pending'], 1)

    def test_his_own_same_and_not_same(self):
        ivan, other = 'notes:people/ivan', 'notes:people/ivan-other'
        self.same({'same': [[ivan, 'cards:c4'], [ivan, other]], 'not': [[ivan, other]]})
        store = self.build()
        self.assertEqual(len([r for r in store['records'] if r['name'] == 'Іван Семпл']), 1)
        self.assertEqual(len([r for r in store['records'] if r['name'] == 'Іван Інший']), 1)   # the user's "not the same" wins

    def test_one_key_kind_fix_wins_on_rebuild(self):
        store = self.build()
        base = self.rec(store, 'Base')
        self.assertEqual(base['kind'], 'project')
        self.assertTrue(entities.correct(base['id'], '4', data=self.data))
        self.assertEqual(self.rec(self.build(), 'Base')['kind'], 'tool')
        self.assertEqual(self.rec(self.build(), 'Base')['kind_by'], 'me')
        entities.correct(base['id'], '0', data=self.data)
        self.assertNotIn('Base', [r['name'] for r in self.build()['records']])
        self.assertFalse(entities.correct(base['id'], '9', data=self.data))

    def test_ids_follow_a_merge(self):
        self.build(slices={'cards': self.cards})
        first = json.loads((self.data / 'entities.json').read_text())
        self.assertIn('cards:c1', [r['id'] for r in first['records']])
        self.build()
        ids = json.loads((self.data / 'entity-ids.json').read_text())
        self.assertEqual(ids['cards:c1'], HANNA)

    # surfaces -----------------------------------------------------------------------------------------------------

    def test_surfaces_case_forms_both_scripts_and_no_ordinary_words(self):
        store = self.build()
        s, recs = store['surfaces'], store['records']
        def who(k): return {recs[i]['name'] for i, _ in s.get(k, [])}
        self.assertIn('Ганна Ткач', who('ганні'))          # dative of the first name
        self.assertIn('Ганна Ткач', who('hanna tkach'))    # the other script, from the note's aliases
        self.assertIn('Ганна Ткач', who('ht'))
        self.assertIn('Lantern Labs', who('lantern labs'))
        self.assertNotIn('labs', s)                         # an ordinary word alone never marks
        # a thing whose own name is an ordinary word is kept, but marked: it counts only when the context decides
        self.assertTrue(store['surface_flags']['base']['ordinary'] and store['surface_flags']['base']['needs_context'])
        self.assertTrue(store['surface_flags']['іван']['shared'])
        self.assertNotIn('lantern labs', store['surface_flags'])   # a two-word name needs nothing
        self.assertNotIn('owner sample', s)                 # the user's own name
        self.assertEqual(len(who('іван')), 2)               # a first name shared by two: ambiguous

    # packs --------------------------------------------------------------------------------------------------------

    def test_levels_budget_and_sources(self):
        store = self.build()
        h, lantern = self.rec(store, 'Ганна Ткач'), self.rec(store, 'Lantern')
        line = entities.render(h, 2, today=TODAY)
        self.assertTrue(line.startswith('- **Ганна Ткач** - finance lead, at Lantern Labs.'), line)
        full = entities.render(lantern, 3, today=TODAY)
        self.assertIn('(project)', full)
        self.assertIn('status: active (notes, 2026-11-11).', full)
        self.assertIn('“next: invoice export” (notes, 2026-11-11).', full)   # someone else's words go in quotes
        self.assertIn('Repo: `', full)
        self.assertEqual(entities.render(h, 1, today=TODAY), '')
        for r in store['records']:
            self.assertLessEqual(len(entities.render(r, 2, today=TODAY)), entities.LINE_MAX)
            self.assertLessEqual(len(entities.render(r, 3, today=TODAY)), entities.FULL_MAX)
        b = entities.block([(h, 2, 2), (lantern, 3, 1)], today=TODAY)
        self.assertTrue(b.startswith(entities.HEADER + '\n- **Ганна Ткач**'))

    def test_stale_pack_is_name_and_pointers(self):
        store = self.build()
        lantern = self.rec(store, 'Lantern')
        text = entities.render(lantern, 3, today='2027-06-01')
        self.assertIn('no recent notes', text)
        self.assertNotIn('invoice export', text)
        self.assertIn('Repo: `', text)

    def test_block_drops_in_order_and_keeps_name_and_first_pointer(self):
        big = []
        for i in range(9):
            big.append({'id': f'x:{i}', 'kind': 'project', 'name': f'Made Up {i}', 'who': 'a made-up thing with a long description ' * 2,
                        'pack': {'facts': [{'text': f'made-up fact {j} ' * 5, 'source': 'notes', 'date': '2026-11-10', 'quote': False} for j in range(4)],
                                 'pointers': [{'label': 'Repo', 'value': f'/tmp/made-up-{i}', 'path': True},
                                              {'label': 'URL', 'value': f'https://made-up-{i}.example', 'path': False}], 'newest': '2026-11-10'}})
        b = entities.block([(r, 3, i) for i, r in enumerate(big)], today=TODAY)
        self.assertLessEqual(len(b), entities.BLOCK_MAX)
        for i in range(9):
            self.assertIn(f'**Made Up {i}**', b)
            self.assertIn(f'/tmp/made-up-{i}', b)

    def test_store_doors(self):
        self.build()
        st = entities.Store(self.data / 'entities.json')
        c = st.context('Ганні', 3, today=TODAY)
        self.assertEqual(c['name'], 'Ганна Ткач')
        self.assertIn(entities.HEADER, c['text'])
        self.assertEqual(st.context('lant', 2)['name'], 'Lantern')   # a prefix finds it
        self.assertEqual(st.context('nothing-like-this')['found'], 0)
        brief = st.brief('Lantern', today=TODAY)['text']
        self.assertLessEqual(len(brief), entities.BRIEF_MAX)
        self.assertIn('**Lantern** (project)', brief)
        self.assertIn('**Lantern Labs**', brief)
        self.assertEqual(st.entity('noreply')['entities'], [])   # contact-only cards are not entities to agents

    def test_engine_routes(self):
        """The real /context, /context/brief and /entity routes of engine/server.py, compiled alone: local only, off with
        the setting."""
        from email.message import Message
        from unittest.mock import Mock
        self.build()
        st = entities.Store(self.data / 'entities.json')
        on = {'contextPacks': True}
        ns = lift('H', LOCAL_HOSTS={'127.0.0.1'}, entity_store=lambda: st, settings_load=lambda: on)
        ns['H'].token = 'test-token'
        h = ns['H'].__new__(ns['H']); h.client_address = ('127.0.0.1', 1234)
        h.headers = Message(); h.headers['Host'] = '127.0.0.1'; h.headers['X-Drafter-Token'] = 'test-token'; h.send = Mock()
        def get(path): h.path = path; h.do_GET(); return h.send.call_args.args
        r = get('/context?q=%D0%93%D0%B0%D0%BD%D0%BD%D1%96&level=3')[0]
        self.assertEqual((r['name'], r['level']), ('Ганна Ткач', 3))
        self.assertIn(entities.HEADER, r['text'])
        self.assertEqual(get('/context?q=lant&level=x')[0]['level'], 2)
        self.assertIn('**Lantern**', get('/context/brief?q=Lantern')[0]['text'])
        self.assertEqual(get('/entity?q=Lantern%20Labs')[0]['entities'][0]['kind'], 'org')
        self.assertEqual(get('/entity?q=Owner%20Sample')[0]['entities'], [])
        on['contextPacks'] = False
        self.assertEqual(get('/context?q=Lantern')[1], 403)
        on['contextPacks'] = True
        h.headers['Origin'] = 'https://example.test'
        self.assertEqual(get('/context?q=Lantern'), ({'error': 'forbidden'}, 403))

    def test_classify_hook_keeps_only_known_kinds(self):
        asked = []
        def ask(n): asked.append(n); return {'Fluxor': 'tool', 'Blorp': 'banana'}.get(n, 'none')
        ask.by = 'local'
        n = entities.classify(['Fluxor', 'Blorp', 'Plain'], ask, data=self.data)
        self.assertEqual(n, 2)
        kinds = json.loads((self.data / 'entity-kinds.json').read_text())
        self.assertEqual(kinds['Fluxor'], {'kind': 'tool', 'by': 'local', 'at': kinds['Fluxor']['at']})
        self.assertNotIn('Blorp', kinds)
        self.assertIn('Fluxor', [r['name'] for r in self.build()['records']])

    def test_classify_is_off_by_default(self):
        import cloud
        self.assertFalse(cloud.allowed('entities', {}))
        self.assertTrue(cloud.allowed('entities', {'entityClassify': True}) or 'provider' in sys.modules)


class Golden(unittest.TestCase):
    """tests/entity_cases.json: the same records and expected text the Swift test (tests/entity_rules.swift) runs."""

    def test_python_renders_the_golden_cases(self):
        g = json.loads(CASES.read_text())
        recs = {r['id']: r for r in g['records']}
        for case in g['blocks']:
            got = entities.block([(recs[i], lv, m) for i, lv, m in case['items']], today=g['today'], limit=case.get('limit', entities.BLOCK_MAX))
            self.assertEqual(got, case['expect'], case['name'])
        for case in g['lines']:
            self.assertEqual(entities.render(recs[case['id']], case['level'], today=g['today']), case['expect'], case['id'])
        for case in g['cut']:
            self.assertEqual(entities.cut(case['s'], case['n']), case['expect'])
        for case in g['fold']:
            self.assertEqual(entities.fold(case['s']), case['expect'])


if __name__ == '__main__':
    unittest.main()

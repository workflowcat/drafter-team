"""The entity store and context packs (engine/entities.py) on a made-up cast only: a fake Aleph SQLite, a fake vault
folder and fake contacts in a temporary folder. No personal file, server, app or model.

    .venv/bin/python -B tests/test_entities.py
"""
import json
from pathlib import Path
import sqlite3
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


def day_ts(d):
    import time
    return time.mktime(time.strptime(d, '%Y-%m-%d')) + 43200


class Cast(unittest.TestCase):
    """Made-up people, a client, a project, a Worker; private sentinels everywhere the filters must hold."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(); self.addCleanup(self.tmp.cleanup)
        root = Path(self.tmp.name)
        self.data = root / 'data'; self.data.mkdir()
        self.codius = root / 'Codius'; (self.codius / 'lantern').mkdir(parents=True); (self.codius / 'lantern-gate').mkdir()
        self.db = root / 'aleph.db'
        con = sqlite3.connect(self.db)
        con.executescript('''
          CREATE TABLE things (id text primary key, kind text not null, name text not null, summary text default '', note text default '',
            scope text default 'work', updated integer, face text default '', short text default '');
          CREATE TABLE names (name text not null, thing text not null, primary key (name, thing));
          CREATE TABLE facts (id integer primary key, subj text not null, rel text not null, obj text default '', value text default '',
            since integer, until integer, source text default '', ref text default '', status text default 'seen',
            scope text default 'work', by text default 'auto', batch text default '', at integer, due integer, done integer);
          CREATE TABLE merged (id text primary key, target text not null, by text default 'auto', at integer);
          CREATE TABLE notsame (a text, b text, primary key (a, b));''')
        things = [
            ('person:me', 'person', 'Owner Sample', '', 'work', ''),
            ('person:hanna-tkach', 'person', 'Ганна Ткач', '', 'work', ''),
            ('person:ivan-sample', 'person', 'Іван Семпл', '', 'work', ''),
            ('person:ivan-other', 'person', 'Іван Інший', '', 'work', ''),
            ('org:lantern-labs', 'org', 'Lantern Labs', 'client; we build their ordering tool', 'work', ''),
            ('project:lantern', 'project', 'Lantern', 'ordering tool for Lantern Labs', 'work', ''),
            ('worker:lantern-gate', 'worker', 'lantern-gate', 'Cloudflare Worker that holds Lantern storage', 'work', ''),
            ('repo:base', 'repo', 'Base', '', 'work', ''),
            ('person:secret-sentinel', 'person', 'Zorya Sentinelska', 'PRIVATE-THING', 'private', ''),
            ('project:hidden-matter', 'project', 'Hidden Matter', 'PRIVATE-PROJECT', 'private', ''),
            ('group:chat-room', 'group', 'Some Chat Group', '', 'work', ''),
        ]
        con.executemany('INSERT INTO things (id, kind, name, summary, scope, short) VALUES (?,?,?,?,?,?)', things)
        con.executemany('INSERT INTO names VALUES (?,?)', [('Hanna Tkach', 'person:hanna-tkach'), ('Ганна', 'person:hanna-tkach'),
                                                            ('SecretAlias', 'person:secret-sentinel')])
        f = lambda *a: con.execute('INSERT INTO facts (subj, rel, obj, value, since, scope, by, status, until) VALUES (?,?,?,?,?,?,?,?,?)', a)
        f('person:hanna-tkach', 'role', '', 'finance lead', day_ts('2026-11-02'), 'work', 'me', 'stated', None)
        f('person:hanna-tkach', 'works_at', 'org:lantern-labs', '', day_ts('2026-11-02'), 'work', 'auto', 'seen', None)
        f('person:hanna-tkach', 'works_on', 'project:lantern', '', day_ts('2026-11-10'), 'work', 'auto', 'seen', None)
        f('person:hanna-tkach', 'handle', '', 'hanna@example.test', None, 'work', 'auto', 'seen', None)
        f('person:hanna-tkach', 'handle', '', '+380 44 555 0100', None, 'work', 'auto', 'seen', None)
        f('person:hanna-tkach', 'note', '', 'PRIVATE-FACT about her health', day_ts('2026-11-03'), 'private', 'auto', 'seen', None)
        f('person:hanna-tkach', 'works_at', 'person:secret-sentinel', '', day_ts('2026-11-03'), 'work', 'auto', 'seen', None)
        f('person:hanna-tkach', 'role', '', 'DISPROVEN-ROLE', day_ts('2026-11-04'), 'work', 'auto', 'disproven', None)
        f('person:hanna-tkach', 'note', '', 'ENDED-FACT', day_ts('2026-01-04'), 'work', 'auto', 'seen', 100)
        f('project:lantern', 'status', '', 'active', day_ts('2026-11-11'), 'work', 'me', 'stated', None)
        f('project:lantern', 'next', '', 'invoice export', day_ts('2026-11-11'), 'work', 'auto', 'seen', None)
        f('project:lantern', 'deployed_as', 'worker:lantern-gate', '', day_ts('2026-11-09'), 'work', 'auto', 'seen', None)
        f('project:lantern', 'note', '', 'call me on +380 67 000 1122 tonight', day_ts('2026-11-09'), 'work', 'me', 'seen', None)
        f('worker:lantern-gate', 'link', '', 'https://lantern-gate.example.workers.dev', None, 'work', 'auto', 'seen', None)
        f('org:lantern-labs', 'relates', 'project:lantern', 'client of', day_ts('2026-11-12'), 'work', 'auto', 'seen', None)
        f('person:secret-sentinel', 'role', '', 'PRIVATE-ROLE', day_ts('2026-11-12'), 'work', 'me', 'seen', None)
        con.execute("INSERT INTO notsame VALUES ('person:ivan-sample', 'person:ivan-other')")
        con.commit(); con.close()
        self.vault = root / 'vault'
        def note(rel, fm, body='Body text.'):
            p = self.vault / rel; p.parent.mkdir(parents=True, exist_ok=True)
            p.write_text('---\n' + fm.strip() + '\n---\n' + body + '\n')
        note('Entities/People/Hanna Tkach.md', 'type: person\nkind: person\nsummary: finance contact\naliases: [HT]\ncreated: 2026-10-01\nupdated: 2026-11-02')
        note('Entities/Organizations/Lantern Labs.md', 'type: org\nkind: organization\nsummary: client, ordering tool\nupdated: 2026-11-12')
        note('Stories/Lantern.md', 'type: story\nstatus: active\nnext: invoice export\nsummary: ordering tool for Lantern Labs\nupdated: 2026-11-11\norigin: kit')
        note('Stories/Notes View.md', 'type: view\nsummary: a view')
        note('Entities/People/Quiet Person.md', 'type: person\nprivate: true\nsummary: PRIVATE-MARKED-NOTE')
        note('Entities/Private/Secret Person.md', 'type: person\nsummary: PRIVATE-FOLDER-NOTE')
        note('Stories/Private/Hidden Matter.md', 'type: story\nsummary: PRIVATE-STORY-NOTE')
        note('Entities/People/.obsidian/Junk.md', 'type: person\nsummary: OBSIDIAN-JUNK')
        note('System/old/Old Person.md', 'type: person\nsummary: SYSTEM-OLD')
        self.contacts = [
            {'id': 'google:people/c1', 'name': 'Hanna T.', 'aliases': [], 'handles': {'email': ['Hanna@Example.test'], 'phone': ['+380 44 555 0100']}, 'cards_only': False},
            {'id': 'google:people/c2', 'name': 'Petro Contact', 'aliases': [], 'handles': {'email': ['petro@example.test']}, 'cards_only': False},
            {'id': 'google:otherContacts/c3', 'name': 'noreply@example.test', 'aliases': [], 'handles': {'email': ['noreply@example.test']}, 'cards_only': True},
            {'id': 'google:people/c4', 'name': 'Іван Семпл', 'aliases': [], 'handles': {}, 'cards_only': False},
        ]

    def build(self, **kw):
        args = dict(db=self.db, vault=self.vault, contacts=self.contacts, now=NOW, data=self.data, ordinary={'labs', 'base', 'other'}, codius=self.codius)
        args.update(kw)
        return entities.build(**args)

    def rec(self, store, name):
        return next(r for r in store['records'] if r['name'] == name)

    # privacy ------------------------------------------------------------------------------------------------------

    def test_private_records_never_reach_the_store_or_a_pack(self):
        store = self.build()
        written = (self.data / 'entities.json').read_text() + (self.data / 'entity-sources.json').read_text()
        packs = '\n'.join(entities.render(r, 3, today=TODAY) for r in store['records'])
        for secret in ('PRIVATE', 'Sentinel', 'SecretAlias', 'Zorya', 'Hidden Matter', 'Quiet Person', 'Secret Person',
                       'OBSIDIAN-JUNK', 'SYSTEM-OLD', 'DISPROVEN', 'ENDED-FACT', 'Owner Sample', 'Some Chat Group'):
            self.assertNotIn(secret, written, secret)
            self.assertNotIn(secret, packs, secret)
        self.assertFalse(any(r['private'] for r in store['records']))

    def test_phone_numbers_never_in_a_pack(self):
        store = self.build()
        for r in store['records']:
            for level in (2, 3):
                text = entities.render(r, level, today=TODAY)
                self.assertNotRegex(text, r'\d{3}[ -]?\d{3}[ -]?\d{2,}', r['name'])
                self.assertNotIn('0100', text)
        self.assertIn('+380 44 555 0100', self.rec(store, 'Ганна Ткач')['handles']['phone'])   # his own card keeps it

    def test_allowed_private_records_only_one_by_one_and_marked(self):
        (self.data / 'context-allow.json').write_text(json.dumps({'aleph': ['person:secret-sentinel'], 'vault': ['Entities/Private/Secret Person.md']}))
        store = self.build()
        z = self.rec(store, 'Zorya Sentinelska')
        self.assertTrue(z['private'])
        self.assertIn('PRIVATE-ROLE', entities.render(z, 3, today=TODAY))
        s = self.rec(store, 'Secret Person')
        self.assertTrue(s['private'])
        written = (self.data / 'entities.json').read_text()
        for still in ('PRIVATE-MARKED-NOTE', 'PRIVATE-STORY-NOTE', 'PRIVATE-PROJECT', 'PRIVATE-FACT'):
            self.assertNotIn(still, written, still)

    def test_vault_off_reads_no_vault(self):
        store = self.build(vault=False)
        self.assertFalse(any(s['system'] == 'vault' for r in store['records'] for s in r['sources']))

    # merging, ids, kinds ------------------------------------------------------------------------------------------

    def test_one_record_per_thing(self):
        store = self.build()
        h = self.rec(store, 'Ганна Ткач')
        self.assertEqual({s['system'] for s in h['sources']}, {'aleph', 'vault', 'contacts'})   # stem + same email
        self.assertEqual(h['id'], 'aleph:person:hanna-tkach')
        self.assertEqual(h['targets']['obsidian'], 'Entities/People/Hanna Tkach')
        self.assertEqual(h['targets']['mail'], 'hanna@example.test')
        lantern = self.rec(store, 'Lantern')
        self.assertEqual(lantern['kind'], 'project')
        self.assertEqual({s['system'] for s in lantern['sources']}, {'aleph', 'vault'})
        self.assertEqual(self.rec(store, 'lantern-gate')['kind'], 'tool')
        self.assertIn(self.rec(store, 'Lantern Labs')['id'], h['related'])
        # same full name in Contacts, no handle to confirm: kept apart and counted for a "Same?" row
        ivans = [r for r in store['records'] if r['name'] == 'Іван Семпл']
        self.assertEqual(len(ivans), 2)
        self.assertEqual(store['same_pending'], 1)
        self.assertNotIn('Notes View', [r['name'] for r in store['records']])

    def test_notsame_and_his_own_answers(self):
        (self.data / 'entity-same.json').write_text(json.dumps({'same': [['aleph:person:ivan-sample', 'contacts:google:people/c4'],
                                                                         ['aleph:person:ivan-sample', 'aleph:person:ivan-other']]}))
        store = self.build()
        self.assertEqual(len([r for r in store['records'] if r['name'] == 'Іван Семпл']), 1)
        self.assertEqual(len([r for r in store['records'] if r['name'] == 'Іван Інший']), 1)   # Aleph's notsame wins

    def test_one_key_kind_fix_wins_on_rebuild(self):
        store = self.build()
        base = self.rec(store, 'Base')
        self.assertEqual(base['kind'], 'tool')
        self.assertTrue(entities.correct(base['id'], '3', data=self.data))
        self.assertEqual(self.rec(self.build(), 'Base')['kind'], 'project')
        self.assertEqual(self.rec(self.build(), 'Base')['kind_by'], 'me')
        entities.correct(base['id'], '0', data=self.data)
        self.assertNotIn('Base', [r['name'] for r in self.build()['records']])
        self.assertFalse(entities.correct(base['id'], '9', data=self.data))

    def test_ids_follow_a_merge(self):
        self.build(db=False)
        first = json.loads((self.data / 'entities.json').read_text())
        self.assertIn('vault:Entities/People/Hanna Tkach.md', [r['id'] for r in first['records']])
        self.build()
        ids = json.loads((self.data / 'entity-ids.json').read_text())
        self.assertEqual(ids['vault:Entities/People/Hanna Tkach.md'], 'aleph:person:hanna-tkach')

    def test_a_failed_source_keeps_its_last_slice(self):
        self.build()
        broken = Path(self.tmp.name) / 'broken.db'; broken.write_text('not a database')
        store = self.build(db=broken)
        self.assertEqual(store['failed'], ['aleph'])
        self.assertIn('lantern-gate', [r['name'] for r in store['records']])

    # surfaces -----------------------------------------------------------------------------------------------------

    def test_surfaces_case_forms_both_scripts_and_no_ordinary_words(self):
        store = self.build()
        s, recs = store['surfaces'], store['records']
        def who(k): return {recs[i]['name'] for i, _ in s.get(k, [])}
        self.assertIn('Ганна Ткач', who('ганні'))          # dative of the first name
        self.assertIn('Ганна Ткач', who('hanna tkach'))    # the other script, from Aleph's names
        self.assertIn('Ганна Ткач', who('ht'))
        self.assertIn('Lantern Labs', who('lantern labs'))
        self.assertNotIn('labs', s)                         # an ordinary word alone never marks
        # a thing whose own name is an ordinary word is kept, but marked: it counts only when the context decides
        self.assertTrue(store['surface_flags']['base']['ordinary'] and store['surface_flags']['base']['needs_context'])
        self.assertTrue(store['surface_flags']['іван']['shared'])
        self.assertNotIn('lantern labs', store['surface_flags'])   # a two-word name needs nothing
        self.assertNotIn('owner sample', s)                 # his own name
        self.assertEqual(len(who('іван')), 2)               # a first name shared by two: ambiguous

    # packs --------------------------------------------------------------------------------------------------------

    def test_levels_budget_and_sources(self):
        store = self.build()
        h, lantern = self.rec(store, 'Ганна Ткач'), self.rec(store, 'Lantern')
        line = entities.render(h, 2, today=TODAY)
        self.assertTrue(line.startswith('- **Ганна Ткач** - finance lead, at Lantern Labs.'), line)
        self.assertIn('Hanna Tkach.md`', line)
        full = entities.render(lantern, 3, today=TODAY)
        self.assertIn('(project)', full)
        self.assertIn('status: active (Aleph, 2026-11-11).', full)
        self.assertIn('“next: invoice export” (Aleph, 2026-11-11).', full)   # someone else's words go in quotes
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
                        'pack': {'facts': [{'text': f'made-up fact {j} ' * 5, 'source': 'vault', 'date': '2026-11-10', 'quote': False} for j in range(4)],
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
        h = ns['H'].__new__(ns['H']); h.client_address = ('127.0.0.1', 1234)
        h.headers = Message(); h.headers['Host'] = '127.0.0.1'; h.send = Mock()
        def get(path): h.path = path; h.do_GET(); return h.send.call_args.args
        r = get('/context?q=%D0%93%D0%B0%D0%BD%D0%BD%D1%96&level=3')[0]
        self.assertEqual((r['name'], r['level']), ('Ганна Ткач', 3))
        self.assertIn(entities.HEADER, r['text'])
        self.assertEqual(get('/context?q=lant&level=x')[0]['level'], 2)
        self.assertIn('**Lantern**', get('/context/brief?q=Lantern')[0]['text'])
        self.assertEqual(get('/entity?q=Lantern%20Labs')[0]['entities'][0]['kind'], 'org')
        self.assertNotIn('PRIVATE', json.dumps(get('/entity?q=Sentinel')[0]))
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

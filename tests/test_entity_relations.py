"""Relations and ambiguous name forms (engine/entities.py, 14 November 2026): typed weighted edges, the floor, the
broad-note damping, co-mentions by NPMI, the context decision for shared / ordinary / short forms, and his fixes.
Made-up entities only, in a temporary folder.

    .venv/bin/python -B tests/test_entity_relations.py
"""
import json
from pathlib import Path
import sys
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'engine'))
import entities as E

CASES = Path(__file__).resolve().parent / 'entity_cases.json'
NOW = time.mktime(time.strptime('2026-11-14', '%Y-%m-%d'))


def c(i, how='first', score=1.0, heat=1, related=False, named=False, kind=False):
    return {'i': i, 'how': how, 'score': score, 'heat': heat, 'related': related, 'named': named, 'kind': kind}


class Weights(unittest.TestCase):
    def test_type_beats_listed_in_a_note(self):
        works = E.piece('v_org', 0.9, '2026-11-01', NOW)
        listed = E.piece('v_entities', 0.9, '2026-11-01', NOW, n=6)
        thread = E.piece('v_thread', 0.9, '2026-11-01', NOW)
        self.assertGreater(works, thread)
        self.assertGreater(works, listed)

    def test_recent_evidence_counts_more(self):
        self.assertGreater(E.piece('v_story', 0.9, '2026-11-10', NOW), E.piece('v_story', 0.9, '2024-01-10', NOW))
        self.assertAlmostEqual(E.recency('', NOW), 0.6)
        self.assertGreaterEqual(E.recency('2001-01-01', NOW), 0.5)

    def test_broad_note_damping(self):
        self.assertEqual(E.damp_star(3), 1.0)
        self.assertLess(E.damp_star(40), E.damp_star(10))
        short = E.piece('v_entities', 0.9, '2026-11-10', NOW, n=2, pair=True)
        broad = E.piece('v_entities', 0.9, '2026-11-10', NOW, n=10, pair=True)
        self.assertGreaterEqual(short, E.FLOOR)          # two things in one short note: a weak edge that stays
        self.assertLess(broad, E.FLOOR)                  # ten things in one note: each pair falls under the floor
        self.assertLess(E.piece('v_entities', 0.9, '2026-11-10', NOW, n=60), E.FLOOR)   # even the note's own link

    def test_noisy_or_and_heat(self):
        self.assertAlmostEqual(E.combine([0.5, 0.5]), 0.75)
        self.assertEqual(E.combine([]), 0.0)
        self.assertLessEqual(E.combine([0.9, 0.9, 0.9]), 1.0)
        self.assertGreater(E.edge_weight([0.5], 30), E.edge_weight([0.5], 1))
        self.assertLess(E.edge_weight([0.5], 30) - E.edge_weight([0.5], 1), 0.11)   # heat nudges, never decides

    def test_npmi_does_not_reward_a_popular_entity(self):
        # 100 lines; A is named in all of them, B and C in 5, B and C together in 4, A with B in 5
        self.assertLessEqual(E.npmi(5, 100, 5, 100), 0.0 + 1e-9)
        self.assertGreater(E.npmi(4, 5, 5, 100), 0.7)
        self.assertEqual(E.npmi(2, 2, 2, 100), 0.0)      # under the minimum count: nothing

    def test_order_by_weight_top_n_and_floor(self):
        edges = [{'id': 'a', 'w': 0.2}, {'id': 'b', 'w': 0.9}, {'id': 'c', 'w': 0.1}, {'id': 'd', 'w': 0.5}]
        kept, dropped = E.rank_edges(edges, 'person')
        self.assertEqual([e['id'] for e in kept], ['b', 'd', 'a'])    # by weight, not by id
        self.assertEqual(dropped, 1)
        many = [{'id': f'x{i:02d}', 'w': 0.5 + i / 100} for i in range(20)]
        self.assertEqual(len(E.rank_edges(many, 'tool')[0]), E.TOP['tool'])
        self.assertLessEqual(len(E.rank_edges(many, 'project', top=20)[0]), E.SHOW_MAX)


class Ambiguity(unittest.TestCase):
    def test_form_flags(self):
        names = ['Vera Stone', 'Vera Lake', 'Anvil', 'Kite', 'deploy-kit']
        self.assertEqual(E.form_flags('vera', [[0, 'first'], [1, 'first']], set(), set(), names), ['shared', 'short'])
        self.assertEqual(E.form_flags('verity', [[0, 'first'], [1, 'first']], set(), set(), names), ['shared'])
        self.assertEqual(E.form_flags('anvil', [[2, 'name']], {'anvil'}, set(), names), ['ordinary'])
        self.assertEqual(E.form_flags('kite', [[3, 'name']], set(), set(), names), ['short'])
        self.assertEqual(E.form_flags('kite', [[3, 'name']], set(), {'kite'}, names), ['ordinary', 'short'])
        # his lower-case habit does not make a lower-case slug ordinary: that is how the slug is written
        self.assertEqual(E.form_flags('deploy-kit', [[4, 'name']], set(), {'deploy-kit'}, names), [])
        self.assertEqual(E.form_flags('vera stone', [[0, 'name']], {'vera'}, set(), names), [])
        # a project and its repo with one name: one thing, not a guess between two
        self.assertEqual(E.form_flags('anvil', [[2, 'name'], [5, 'name']], set(), set(), names + ['anvil']), ['twins'])
        self.assertFalse(E.flag_record(['twins'])['needs_context'])

    def test_labels_in_brackets_are_not_name_parts(self):
        rec = {'kind': 'person', 'name': 'Vera (Office)', 'aliases': ['Vera Stone (old)']}
        forms = E.surfaces_for(rec, set(), set())
        self.assertNotIn('office', forms)
        self.assertNotIn('old', forms)
        self.assertIn('stone', forms)

    def test_own_lower_words_any_script(self):
        lines = ['we need a лава for that', 'that лава is fine', 'more лава please. Лава starts a line', 'Ми з Кобзою', 'з Кобзою']
        words = E.own_lower_words(lines)
        self.assertIn('лава', words)
        self.assertNotIn('кобзою', words)

    def test_no_flags_keeps_the_old_rule(self):
        self.assertEqual(E.decide([c(0, score=3), c(1, score=1)]), (0, True))
        self.assertEqual(E.decide([c(0, score=2), c(1, score=1.5)]), (0, False))

    def test_shared_first_name_heat_alone_never_resolves(self):
        # the old rule resolved this by heat alone (2 >= 2 x 1); now the chooser asks
        got = E.decide([c(0, score=2, heat=20), c(1, score=1)], ['shared'])
        self.assertEqual(got, (0, False))

    def test_shared_form_context_decides(self):
        self.assertEqual(E.decide([c(0, score=2), c(1, score=1, related=True)], ['shared']), (1, True))
        self.assertEqual(E.decide([c(0, score=1, named=True), c(1, score=1)], ['shared']), (0, True))

    def test_shared_form_a_full_name_beats_a_surname(self):
        self.assertEqual(E.decide([c(0, how='name', score=3), c(1, how='part', score=1)], ['shared']), (0, True))

    def test_ordinary_word_needs_two(self):
        self.assertEqual(E.decide([c(0, how='name', score=3.5)], ['ordinary']), (None, False))
        self.assertEqual(E.decide([c(0, how='name', score=3.5, kind=True)], ['ordinary']), (None, False))
        self.assertEqual(E.decide([c(0, how='name', score=3.5, kind=True, heat=20)], ['ordinary']), (0, True))
        self.assertEqual(E.decide([c(0, how='name', score=3.5, related=True)], ['ordinary']), (0, True))

    def test_short_form_needs_one_signal(self):
        self.assertEqual(E.decide([c(0, how='name', score=3)], ['short']), (None, False))
        self.assertEqual(E.decide([c(0, how='name', score=3, kind=True)], ['short']), (0, True))

    def test_a_pick_decides(self):
        self.assertEqual(E.decide([c(0, score=2), c(1, score=1)], ['shared', 'short'], picked=1), (1, True))

    def test_golden_decisions_the_swift_side_runs_too(self):
        g = json.loads(CASES.read_text())
        for case in g['decide']:
            got, ok = E.decide(case['cands'], case['flags'], case.get('picked'))
            self.assertEqual([-1 if got is None else got, ok], case['expect'], case['name'])

    def test_dest_of_app_names(self):
        self.assertEqual(E.dest_of('Claude'), 'ai')
        self.assertEqual(E.dest_of('Beeper'), 'chat')
        self.assertEqual(E.dest_of('com.googlecode.iterm2'), 'agent')
        self.assertEqual(E.dest_of('TextEdit'), 'plain')


class Fixes(unittest.TestCase):
    def test_add_fix_is_pure_and_replaces_its_opposite(self):
        f0 = {'related': [['a', 'b', 'same client']]}
        f1 = E.add_fix(f0, 'not_related', 'b', 'a')
        self.assertEqual(f0, {'related': [['a', 'b', 'same client']]})   # the input is not changed
        self.assertEqual(f1['related'], [])
        self.assertEqual(f1['not_related'], [['a', 'b']])
        self.assertEqual(E.add_fix(f1, 'not_related', 'a', 'b')['not_related'], [['a', 'b']])   # no duplicate
        f2 = E.add_fix(f1, 'not_this', 'Vera', 'x:vera')
        self.assertEqual(f2['not_this'], [['vera', 'x:vera']])
        f3 = E.add_fix(f2, 'same', 'p:1', 'p:2')
        self.assertEqual(E.add_fix(f3, 'not_same', 'p:2', 'p:1')['same'], [])
        with self.assertRaises(ValueError): E.add_fix({}, 'maybe', 'a', 'b')

    def test_save_fix_writes_only_the_fixes_file(self):
        with tempfile.TemporaryDirectory() as d:
            E.save_fix('related', 'a', 'b', 'same team', data=d)
            self.assertEqual(json.loads((Path(d) / 'entity-fixes.json').read_text())['related'], [['a', 'b', 'same team']])
            self.assertEqual(sorted(p.name for p in Path(d).iterdir()), ['entity-fixes.json'])


class Build(unittest.TestCase):
    """A made-up vault: people, an org, a story with a short list, an epic that lists many, and lines he typed."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(); self.addCleanup(self.tmp.cleanup)
        root = Path(self.tmp.name)
        self.data = root / 'data'; self.data.mkdir()
        self.vault = root / 'vault'
        def note(rel, fm):
            p = self.vault / rel; p.parent.mkdir(parents=True, exist_ok=True)
            p.write_text('---\n' + fm.strip() + '\n---\nBody.\n')
        note('Entities/People/Vera Stone.md', 'type: person\norg: "[[Entities/Organizations/Quill Works]]"\nupdated: 2026-11-10')
        note('Entities/People/Vera Lake.md', 'type: person\nupdated: 2026-11-10')
        note('Entities/People/Oskar Brand.md', 'type: person\nupdated: 2026-11-10')
        note('Entities/People/Mira Volk.md', 'type: person\nupdated: 2026-11-10')
        note('Entities/Organizations/Quill Works.md', 'type: org\nsummary: a made-up client\nupdated: 2026-11-10')
        many = ', '.join(f'"[[Entities/People/Filler {i}]]"' for i in range(12))
        for i in range(12): note(f'Entities/People/Filler {i}.md', 'type: person\nupdated: 2026-11-10')
        note('Stories/Anvil.md', 'type: story\nsummary: a made-up project\nupdated: 2026-11-10\n'
             'entities: ["[[Entities/People/Vera Stone]]", "[[Oskar Brand]]"]')
        note('Epics/Everything.md', 'type: epic\nsummary: a broad epic\nupdated: 2026-11-10\nentities: [' + many + ']')
        t = NOW - 86400
        self.lines = ([{'t': t, 'app': 'Claude', 'text': 'Need Mira Volk and Oskar Brand on the call'}] * 4
                      + [{'t': t, 'app': 'Claude', 'text': f'Note {i} about Filler {i % 3} for the epic'} for i in range(30)]
                      + [{'t': t, 'app': 'Beeper', 'text': 'Vera said yes'}, {'t': t, 'app': 'Claude', 'text': 'Ask Vera about Quill Works'}])

    def build(self, **kw):
        args = dict(vault=self.vault, contacts=None, now=NOW, data=self.data, ordinary={'anvil'}, codius=self.data, lines=self.lines)
        args.update(kw)
        return E.build(**args)

    def rec(self, store, name): return next(r for r in store['records'] if r['name'] == name)
    def rel(self, store, a, b): return next((x for x in self.rec(store, a)['relations'] if x['id'] == self.rec(store, b)['id']), None)

    def test_typed_reason_and_weight_and_old_list(self):
        store = self.build()
        vera = self.rec(store, 'Vera Stone')
        works = self.rel(store, 'Vera Stone', 'Quill Works')
        self.assertEqual(works['why'], 'works at')
        self.assertEqual(self.rel(store, 'Quill Works', 'Vera Stone')['why'], 'works here')
        self.assertEqual(vera['related'], [x['id'] for x in vera['relations']])   # old readers keep the ordered id list
        ws = [x['w'] for x in vera['relations']]
        self.assertEqual(ws, sorted(ws, reverse=True))
        self.assertTrue(self.rel(store, 'Anvil', 'Oskar Brand')['why'].startswith('in the same note: story'))   # link by stem

    def test_broad_epic_pairs_fall_under_the_floor(self):
        store = self.build()
        self.assertIsNone(self.rel(store, 'Filler 1', 'Filler 2'))
        self.assertGreater(store['relation_stats']['dropped'], 0)
        self.assertLessEqual(len(self.rec(store, 'Everything')['related']), E.TOP['project'])

    def test_co_mentions_make_an_edge(self):
        store = self.build()
        e = self.rel(store, 'Mira Volk', 'Oskar Brand')
        self.assertIsNotNone(e)
        self.assertEqual(e['why'], 'often together in your lines')
        self.assertEqual(e['src'], ['lines'])

    def test_shared_first_name_is_not_counted_without_context(self):
        store = self.build()
        flags = store['surface_flags']
        self.assertTrue(flags['vera']['shared'])
        # "Vera said yes" decides nothing; "Ask Vera about Quill Works": a related org is named, so it is Vera Stone
        self.assertEqual(self.rec(store, 'Vera Stone')['seen']['typed_30d'], 1)
        self.assertEqual(self.rec(store, 'Vera Lake')['seen']['typed_30d'], 0)
        self.assertTrue(flags['anvil']['ordinary'])

    def test_his_own_name_in_any_case_is_no_entity(self):
        (self.data / 'drafter.local.json').write_text(json.dumps({'user': {'name': 'VERA stone'}}))
        store = self.build()
        self.assertNotIn('Vera Stone', [r['name'] for r in store['records']])
        self.assertEqual(store['dedupe_stats']['own_dropped'], 1)

    def test_fixes_apply_on_build(self):
        f = E.add_fix({}, 'not_related', 'vault:Entities/People/Mira Volk.md', 'vault:Entities/People/Oskar Brand.md')
        f = E.add_fix(f, 'related', 'vault:Entities/People/Vera Lake.md', 'vault:Entities/Organizations/Quill Works.md', 'advisor')
        f = E.add_fix(f, 'not_this', 'Vera', 'vault:Entities/People/Vera Lake.md')
        f = E.add_fix(f, 'same', 'vault:Entities/People/Filler 1.md', 'vault:Entities/People/Filler 2.md')
        (self.data / 'entity-fixes.json').write_text(json.dumps(f))
        store = self.build()
        self.assertIsNone(self.rel(store, 'Mira Volk', 'Oskar Brand'))
        self.assertEqual(self.rel(store, 'Vera Lake', 'Quill Works')['why'], 'advisor')
        self.assertEqual(self.rel(store, 'Vera Lake', 'Quill Works')['src'], ['you'])
        lake = store['records'].index(self.rec(store, 'Vera Lake'))
        self.assertNotIn(lake, [i for i, _ in store['surfaces'].get('vera', [])])
        self.assertFalse(store['surface_flags']['vera']['shared'])   # one record left: nothing shared any more
        self.assertNotIn('Filler 2', [r['name'] for r in store['records']])   # the same-path merge
        self.assertFalse((self.data / 'entities.json').read_text().count('Mira Volk') == 0)


def rec(rid, kind, name, aliases=(), handles=None, evidence=(), sources=1, facts=0, ptrs=()):
    return {'id': rid, 'kind': kind, 'name': name, 'aliases': list(aliases), 'handles': handles or {}, 'evidence': list(evidence),
            'sources': [{'system': 'x', 'id': str(i)} for i in range(sources)], 'kind_by': 'source', 'heat': 1,
            'pack': {'facts': [{}] * facts, 'pointers': list(ptrs)}}


def src(system, rid, name, kind='person', aliases=(), handles=None, vlinks=()):
    return {'system': system, 'id': rid, 'name': name, 'kind': kind, 'aliases': list(aliases), 'handles': handles or {},
            'vlinks': list(vlinks)}


class Review(unittest.TestCase):
    """The lead's review of 14 November: twins, ranking ties, duplicates, his own name, apps as people, ordinary first
    words, chat placeholders."""

    # 1 -------------------------------------------------------------------------------------------------------------
    def test_twins_fold_into_one_thing(self):
        records = [rec('p:anvil', 'project', 'Anvil', sources=2, ptrs=[{'label': 'Story', 'value': '/v/Anvil.md', 'path': True}]),
                   rec('t:anvil-repo', 'tool', 'anvil', ptrs=[{'label': 'URL', 'value': 'https://anvil.example', 'path': False},
                                                             {'label': 'Story', 'value': '/v/Anvil.md', 'path': True}]),
                   rec('t:anvil-worker', 'tool', 'Anvil'), rec('h:vera', 'person', 'Vera Stone'), rec('o:quill', 'org', 'Anvil')]
        main_of = E.fold_twins(records)
        self.assertEqual(main_of, {'t:anvil-repo': 'p:anvil', 't:anvil-worker': 'p:anvil'})   # an org of that name is not a twin
        self.assertEqual([p['label'] for p in records[0]['pack']['pointers']], ['Story', 'URL'])   # the twin's URL; the same note once
        G = E.Edges()
        G.add('p:anvil', 't:anvil-repo', 0.8, 'repo', 'repo of', 'vault')
        G.add('p:anvil', 't:anvil-worker', 0.8, 'runs as', 'runs', 'vault')
        G.add('h:vera', 'p:anvil', 0.6, 'works on', 'people on it', 'vault')
        G.add('h:vera', 't:anvil-repo', 0.7, 'built', 'built by', 'vault')
        E.finish_edges(records, G, main_of=main_of)
        by = {r['id']: r for r in records}
        self.assertEqual(by['p:anvil']['related'], ['h:vera'])                    # no "repo" or "runs as" line to itself
        self.assertEqual(by['h:vera']['related'], ['p:anvil'])                    # the project once, not once per twin
        self.assertEqual(by['h:vera']['relations'][0]['why'], 'built · works on')  # merged, strongest reason first
        self.assertEqual(by['t:anvil-repo']['related'], ['h:vera'])               # a twin shows the thing's relations

    # 2 -------------------------------------------------------------------------------------------------------------
    def test_ties_are_stable(self):
        edges = [{'id': 'a', 'w': 0.9}, {'id': 'b', 'w': 0.3}, {'id': 'c', 'w': 0.5, 'heat': 3},
                 {'id': 'd', 'w': 0.5, 'heat': 3, 'date': '2026-11-01'}, {'id': 'e', 'w': 0.5, 'heat': 9}]
        self.assertEqual([e['id'] for e in E.rank_edges(edges, 'project')[0]], ['a', 'e', 'd', 'c', 'b'])

    # 3, 4 ----------------------------------------------------------------------------------------------------------
    def test_one_person_several_records(self):
        org = src('vault', 'Entities/Organizations/Quill Works.md', 'Quill Works', kind='org')
        groups = [[org],
                  [src('vault', 'People/Олег Бровко.md', 'Олег Бровко', vlinks=[{'path': 'Entities/Organizations/Quill Works', 'key': 'org'}])],
                  [src('vault', 'People/Oleh Brovko.md', 'Oleh Brovko', vlinks=[{'path': 'Quill Works', 'key': 'org'}])],   # other script + same org
                  [src('contacts', 'c1', 'Dana B.', handles={'email': ['dana@example.test']})],
                  [src('board', 'person:dana', 'Dana Brook', handles={'email': ['Dana@Example.test']})],                  # handle + names fit
                  [src('vault', 'People/Kit Fox.md', 'Kit Fox')], [src('contacts', 'c2', 'Kit Fox')],                      # same name, nothing else
                  [src('contacts', 'c3', 'KF')],                                                                           # initials
                  [src('vault', 'People/Mira Volk.md', 'Mira Volk')], [src('board', 'person:mira2', 'Mira Volk')],         # told apart
                  [src('contacts', 'c4', 'VERA stone')], [src('board', 'person:rex', 'Rex Lake', handles={'tg': ['rex_lake']})],
                  [src('contacts', 'c5', 'Rex Lake', handles={'tg': ['other_rex']})]]                                   # usernames differ
        out, queue, n = E.dedupe_people(groups, apart={('vault:People/Mira Volk.md', 'board:person:mira2')}, own=['vera stone'])
        names = sorted(sorted(r['name'] for r in g) for g in out)
        self.assertIn(['Oleh Brovko', 'Олег Бровко'], names)
        self.assertEqual(len(out), len(groups) - 3)   # two merges, one own name
        self.assertIn(['Dana B.', 'Dana Brook'], names)
        self.assertEqual(n['merged'], 2)
        self.assertEqual(n['own_dropped'], 1)                                   # his own name in another case is no entity
        self.assertNotIn(['VERA stone'], names)
        q = {tuple(sorted((x['a'], x['b']))): x for x in queue}
        self.assertEqual(q[('contacts:c2', 'vault:People/Kit Fox.md')]['why'], ['same full name'])
        self.assertIn(('contacts:c3', 'vault:People/Kit Fox.md'), q)                     # initials: asked, not merged
        self.assertNotIn(('board:person:mira2', 'vault:People/Mira Volk.md'), q)          # his "not the same" holds
        self.assertIn('different usernames', q[('board:person:rex', 'contacts:c5')]['why'])
        self.assertEqual(queue[0]['score'], max(x['score'] for x in queue))       # best first

    def test_name_match_rules(self):
        self.assertEqual(E.name_match(['Hanna T.'], ['Hanna Tkach']), (2, 'short surname'))
        self.assertEqual(E.name_match(['Ганна Ткач'], ['Hanna Tkach']), (3, 'same name in the other script'))
        self.assertEqual(E.name_match(['HT'], ['Hanna Tkach']), (2, 'initials'))
        self.assertEqual(E.name_match(['Hanna'], ['Hanna Tkach']), (1, 'first name only'))
        self.assertEqual(E.name_match(['Hanna Lake'], ['Hanna Tkach'])[0], 0)
        self.assertEqual(E.skel('Mykhailo'), E.skel('Михайло'))

    # 5 -------------------------------------------------------------------------------------------------------------
    def test_apps_stored_as_people_become_tools(self):
        records = [rec('t:1', 'tool', 'anvil'), rec('t:2', 'tool', 'kiln'), rec('t:3', 'tool', 'quillbot'),
                   rec('a:1', 'person', 'Claude'),
                   rec('a:2', 'person', 'Robo Smith'),
                   rec('a:3', 'person', 'Vera Stone', handles={'email': ['v@example.test']}),
                   rec('a:4', 'person', 'Quillbot'),
                   rec('a:5', 'person', 'Codex')]
        records[7]['kind_by'] = 'me'                                             # his own kind wins
        self.assertEqual(sorted(E.apps_as_people(records)), ['a:1', 'a:4'])
        self.assertEqual(records[3]['kind'], 'tool')
        self.assertEqual(records[4]['kind'], 'person')                          # a name that is no app stays a person
        self.assertEqual(records[5]['kind'], 'person')                          # a handle: a real person
        self.assertEqual(records[7]['kind'], 'person')

    # 6 -------------------------------------------------------------------------------------------------------------
    def test_ordinary_first_word_never_alone(self):
        words = E.ordinary_words(names={'ivan'})
        self.assertIn('ukrainian', words)                                        # capitalised in the dictionary, folded
        self.assertNotIn('ivan', words)                                          # a first name stays a name
        forms = E.surfaces_for({'kind': 'person', 'name': 'Ukrainian Okafor', 'aliases': []}, {'ukrainian'}, set())
        self.assertNotIn('ukrainian', forms)
        self.assertIn('okafor', forms)
        forms = E.surfaces_for({'kind': 'person', 'name': 'Лава Окафор', 'aliases': []}, set(), set(), {'лава'})
        self.assertNotIn('лава', forms)                                          # his own lower-case word, Ukrainian side

    # 7 -------------------------------------------------------------------------------------------------------------
    def test_chat_placeholder_names_the_person(self):
        records = [{'id': 'p:bear', 'kind': 'person', 'name': 'Bear', 'aliases': [], 'heat': 1},
                   {'id': 't:bear', 'kind': 'tool', 'name': 'bear', 'aliases': [], 'heat': 1}]
        surfaces = {'bear': [[0, 'name'], [1, 'name']]}
        flags = {'bear': ['twins', 'ordinary']}
        got = E.scan('Message Bear on WhatsApp', surfaces, flags, records, dest='plain')
        self.assertEqual(got[0][:2], (0, True))
        got = E.scan('Bear says hi', surfaces, flags, records, dest='plain')
        self.assertEqual(got[0][0], None)                                        # no placeholder: an ordinary word
        for case in json.loads(CASES.read_text())['chat_target']:
            self.assertEqual(E.chat_target(E.fold(case['text'])), case['expect'], case['text'])


if __name__ == '__main__':
    unittest.main()

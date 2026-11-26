import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch
from types import SimpleNamespace
import re
import time

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'engine'))
sys.path.insert(0, str(ROOT / 'bench'))
import know
import words
import typescore
from server_src import lift


def entry(name, heat=1, common=(), forms=(), kind='person'):
    return dict(name=name, kind=kind, tokens=[name], aliases=[], forms=list(forms), heat=heat, common=list(common), handles={})


def pack(*entries):
    p = know.Pack(); p.entries = list(entries); return p


class Typing(unittest.TestCase):
    def test_capitalized_unique_tokens_only(self):
        p = pack(entry('Hanna', 120), entry('Harriet', 1), entry('Base', 3, common=['base']))
        for prefix in ('ha', 'HA', 'Ha', 'h', 'ba', 'Hanna'):
            self.assertEqual(p.finish('to ' + prefix, {'hanna': 1, 'harriet': 1}), '')
        self.assertEqual(p.finish('Ba', {'base': 1}), '')
        self.assertEqual(pack(entry('Hanna'), entry('Hanna', 100)).finish('Han'), 'na')
        self.assertEqual(pack(entry('Hanna'), entry('Hannah', 100)).finish('Hanna'), '')
        self.assertEqual(pack(entry('Юрій', forms=['Юрієм'])).finish('з Юріє'), 'м')
        p = pack(entry('Hanna', forms=['hanna']), entry('codex-kit', kind='repo'), entry('Thanks', forms=['again']))
        for prefix in ('ha', 'code', 'Co', 'Ag'):
            self.assertEqual(p.finish(prefix), '')
        # Ordinary starts in both scripts must not turn into names.
        for name, before in [('Hanna', 'I ha'), ('Максим', 'я ма'), ('Віталій', 'як ві'), ('Kovalskyi', 'to ko'), ('Onyshchenko', 'turn on')]:
            self.assertEqual(pack(entry(name)).finish(before), '')
        self.assertEqual(pack(entry('Максим')).finish('до Макс'), 'им')
        self.assertEqual(pack(entry('Hanna', forms=['Ганні']), entry('Anna', forms=['Ганні'])).finish('Ганн'), 'і')

    def test_common_words_and_phrases_never_finish_or_boost(self):
        for name, kind in [('Thanks', 'phrase'), ('CustomTerm', 'term')]:
            p = pack(entry(name, kind=kind))
            self.assertEqual(p.finish(name[:2], {name.casefold(): 1}), '')
            self.assertEqual(p.targets(name[:2], name), [])
        for name in ('Will', 'Base', 'Thanks', 'Максим'):
            p = pack(entry(name, common=[name.casefold()], forms=[name]))
            self.assertEqual(p.finish(name[:2], {name.casefold(): 1}), '')
            self.assertEqual(p.targets(name[:2], name), [])
        # Every allowed name kind and attested form still works, even beside a common word.
        for kind in know.KINDS:
            p = pack(entry('Hanna', kind=kind, forms=['Ганні']), entry('Harbor', common=['harbor']))
            self.assertEqual(p.finish('Han'), 'na')
            self.assertEqual(p.targets('Ha', 'Hanna Harbor'), [('nna', 1)])
            self.assertEqual(p.finish('Ганн'), 'і')

    def test_bad_pack_read_once_per_change_and_request_snapshot(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp)/'know.json'
            know.atomic(path, json.dumps({'entries':[entry('Hanna')]}))
            p = know.Pack(path)
            self.assertEqual(p.finish('Han'), 'na')
            for invalid in ('broken', '{}', '{"entries":{}}', '{"entries":[null]}'):
                know.atomic(path, invalid)
                with patch.object(Path, 'read_text', autospec=True, side_effect=Path.read_text) as read:
                    for _ in range(3):
                        self.assertEqual(p.finish('Han'), 'na')
                        self.assertEqual(p.targets('Ha', 'Hanna'), [('nna', 1)])
                    self.assertEqual(read.call_count, 1)
            know.atomic(path, json.dumps({'entries':[entry('Harriet')]}))
            with patch.object(Path, 'stat', autospec=True, side_effect=Path.stat) as stat:
                view = p.snapshot()
                self.assertEqual(view.finish('Har'), 'riet')
                self.assertEqual(view.targets('Ha', 'Harriet'), [('rriet', 1)])
                self.assertEqual(stat.call_count, 1)
            know.atomic(path, json.dumps({'entries':[entry('Hanna')]}))
            self.assertEqual(p.finish('Han'), 'na')
            self.assertEqual(view.finish('Har'), 'riet')

    def test_own_writing_wins_then_knowledge(self):
        w = words.Words()
        for _ in range(5): w.add('ask Harold')
        p = pack(entry('Hanna', 100))
        self.assertEqual(words.finish_with_source(w, 'ask Ha', knowledge=p), ('rold','words'))
        self.assertEqual(words.finish_with_source(words.Words(), 'ask Han', knowledge=p), ('na','know'))
        self.assertEqual(words.finish_with_source(words.Words(), 'ask Ha'), ('',''))

    def test_booster_only_matching_capitalized_half_words(self):
        w = words.Words()
        for _ in range(5): w.add('ask Harold tomorrow')
        p = pack(entry('Hanna', forms=['Ганні']), entry('Base', common=['base'], kind='project'))
        for before in ('', 'ask ', 'ask ha', 'ask Zo', 'ask H'):
            own = words.boost_targets(w, before, '')
            self.assertEqual(words.boost_targets(w, before, '', knowledge=p, title='Hanna Base'), own)
        own = words.boost_targets(w, 'ask Ha', ' Ha')
        mixed = dict(words.boost_targets(w, 'ask Ha', ' Ha', knowledge=p, title='Hanna'))
        self.assertAlmostEqual(mixed[' Harold'], dict(own)[' Harold'] * .8)
        self.assertAlmostEqual(mixed[' Hanna'], sum(n for _, n in own) * .2)
        self.assertAlmostEqual(sum(mixed.values()), sum(n for _, n in own))
        self.assertEqual(p.targets('Ha', 'Hannabelle'), [])
        self.assertEqual(p.targets('Ha', 'Ганні'), [])
        self.assertEqual(p.targets('Ган', 'Ганні'), [('ні', 1)])
        self.assertAlmostEqual(sum(n for _,n in words.boost_targets(words.Words(), 'Ha', 'Ha', knowledge=p, title='Hanna')), .2)

    def test_used_name_at_two_letters_and_unused_name_waits(self):
        for name in ('Hanna', 'Максим', 'Straße'):
            with self.subTest(name=name):
                w = words.Words(); p = pack(entry(name))
                before = 'ask ' + name[:2]
                self.assertEqual(words.finish_with_source(w, before, knowledge=p), ('', ''))
                w.add(name.casefold())
                self.assertEqual(w.finish(before), '')  # one observation is below own-finisher threshold
                self.assertEqual(words.finish_with_source(w, before, knowledge=p), (name[2:], 'know'))

    def test_unused_name_needs_three_letters_and_fewer_than_two_competing_uses(self):
        for name, other in (('Hanna', 'hand'), ('Назім', 'назад'), ('Straße', 'STRASSEn')):
            with self.subTest(name=name):
                w = words.Words(); p = pack(entry(name)); before = name[:3]
                # Keep the user's finisher silent to exercise only the knowledge fallback.
                def finish(): return words.finish_with_source(w, before, (99, .6, 1), p)
                self.assertEqual(finish(), (name[3:], 'know'))
                w.add(other)
                self.assertEqual(finish(), (name[3:], 'know'))  # one competing use is allowed
                w.add(other.lower())
                self.assertEqual(finish(), ('', ''))
                w.add(name.casefold())
                self.assertEqual(finish(), (name[3:], 'know'))  # known name wins despite competition

    def test_used_name_share_floor(self):
        p = pack(entry('Hanna'))
        # Totals include the name itself; equality at the 3% floor is allowed.
        for used, competing, expected in ((2, 100, ''), (3, 100, 'nna'), (4, 100, 'nna')):
            with self.subTest(used=used, competing=competing):
                self.assertEqual(p.finish('Ha', {'hanna': used}, {'ha': competing + used}), expected)

    def test_share_floor_skips_fewer_than_two_competing_uses(self):
        p = pack(entry('Hanna'))
        for competing in (0, 1):
            with self.subTest(competing=competing):
                self.assertEqual(p.finish('Ha', {'hanna': 1}, {'ha': competing + 1}), 'nna')
                self.assertEqual(p.finish('Han', {}, {'han': competing}), 'na')

    def test_prefix_total_sums_distinct_words_and_bare_prefix(self):
        w = words.Words(); w.add('HAN hand')
        self.assertEqual(words.finish_with_source(w, 'Han', knowledge=pack(entry('Hanna'))), ('', ''))

    def test_loaded_counts_exclude_dictionary_seeds_and_do_not_scan_on_finish(self):
        def read(path, *args, **kwargs):
            if path.name == 'phrases.jsonl': return json.dumps({'text': 'HAN hand Straße'})
            if path.name == 'words.json': return json.dumps({'words': ['Hanna', 'Harriet']})
            return ''
        with patch.object(Path, 'read_text', read):
            w = words.Words(); w.load()
        self.assertEqual(w.own_folded['strasse'], 1)
        self.assertEqual(w.own_prefix['han'], 2)
        self.assertEqual(w.own_folded['hanna'], 0)
        self.assertEqual(w.own_prefix['har'], 0)
        p = pack(entry('Hanna'), entry('Harriet'))
        with patch.object(w, 'finish', return_value=''), \
             patch.object(Path, 'read_text', side_effect=AssertionError('no files on a key')), \
             patch.object(w.own_folded, 'items', side_effect=AssertionError('no word scan')), \
             patch.object(w.own_prefix, 'items', side_effect=AssertionError('no prefix scan')):
            self.assertEqual(words.finish_with_source(w, 'Han', knowledge=p), ('', ''))
            self.assertEqual(words.finish_with_source(w, 'Har', knowledge=p), ('riet', 'know'))

    def test_replay_fallback_is_same_as_live(self):
        p = pack(entry('Hanna'))
        w = words.Words()
        config = {'w':[], 'th':{'ai':1,'chat':1}}
        pol = typescore.live_policy(w, p, config)
        self.assertEqual(pol({'toks':[]}, 'to Han', 'claude')[0], words.finish_with_source(w,'to Han',knowledge=p)[0])

    def test_replay_stops_where_real_model_gate_stops(self):
        # Execute the actual model method with a synthetic decoder and NumPy logits.
        # No model import, MLX, weights or engine startup.
        import math
        import numpy as np
        from test_model_cancel import model
        ns, m, _ = model()
        texts = ['ready', 'ready ', 'ready later', 'ready later today']
        ps = [.9, .9, .1, .9]
        m.tok.decode = lambda ids: texts[len(ids)-1]
        m.russian_mask = lambda shape: 0
        def generate(*args, **kw):
            for i, p in enumerate(ps):
                logits = np.full(10, math.log(.01)); logits[1] = math.log(p)
                yield 1, logits
        ns['generate_step'] = generate
        ns['SETTLE'] = False      # this test checks the gate stop alone; the round-five early stop has tests/test_settle.py
        got = ns['complete_gated'](m,[0],'',lambda toks:.9,more=.5,max_tokens=8)[0]
        config = {'w':[10], 'th':{'ai':.4,'chat':.4}, 'more':.5}
        row = {'toks':[[t,p,.01,i,''] for i,(t,p) in enumerate(zip(texts,ps))]}
        result, ms = typescore.live_policy(words.Words(),pack(),config)(row,'go ','claude')
        self.assertEqual(result, got)
        self.assertEqual(ms, 2)
        self.assertNotIn('today', result)

    def test_metadata_rejects_changed_pack(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp); path = root/'take.jsonl'; kp=root/'know.json'
            kp.write_text('{"entries":[]}')
            (root/'take.meta.json').write_text(json.dumps({'know_sha': typescore.set_sha(kp)}))
            self.assertEqual(typescore.knowledge_for(path, str(kp)).entries, [])
            kp.write_text('{"entries":[],"version":1}')
            with self.assertRaises(ValueError): typescore.knowledge_for(path, str(kp))

    def test_real_complete_fallback_and_source_without_engine_import(self):
        p = pack(entry('Hanna')); w=words.Words()
        ns = lift('_complete', parts=lambda req,**kw:('ask Han','Claude','','',''), builder_for=lambda f:None, FMT='raw',
                  snippets=SimpleNamespace(offer=lambda b:None), phrases=SimpleNamespace(suggest=lambda b:('',0)),
                  AI_APPS=(), gate=lambda: {'words_first':True}, finisher=w, words_mod=words, knowledge=p,
                  re=re,time=time, short=lambda req,text: False, selector=lambda: None)
        self.assertEqual(ns['_complete']({'before':'ask Han'})['src'],'know')
        self.assertEqual(p.stats()['offered'],1)

    def test_complete_shares_one_reload_with_cache_finisher_and_booster(self):
        from test_ahead import load
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp)/'know.json'
            know.atomic(path, json.dumps({'entries':[entry('Hanna')]}))
            def complete(req, *, pack, **kwargs):
                self.assertEqual(pack.finish('Han'), 'na')
                self.assertEqual(pack.targets('Ha', 'Hanna'), [('nna', 1)])
                return {'text':''}
            ns = load(complete, [0]); ns['knowledge'] = know.Pack(path)
            with patch.object(Path, 'stat', autospec=True, side_effect=Path.stat) as stat:
                ns['complete']({'before':'Ha'})
                self.assertEqual(stat.call_count, 1)

if __name__ == '__main__': unittest.main()

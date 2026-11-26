"""Synthetic CSV and fake subprocess only. Never calls a real GAM."""
import json
import fcntl
import os
from pathlib import Path
import subprocess
import signal
import sys
import tempfile
import time
from types import SimpleNamespace
import unittest
from unittest.mock import Mock, patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'engine'))
import contacts
import know
import test_know

CSV = '''resourceName,names.0.displayName,emailAddresses.0.value,phoneNumbers.0.value
people/c1,Hanna Demo,hanna@example.test,+380 44 555 0100
people/c2,Любов Коваленко,liubov@example.test,+380 44 555 0101
people/c3,Hannah Sample,hannah@example.test,
otherContacts/c4,Ignore This Name,other@example.test,+380 44 555 0102
'''


class Contacts(unittest.TestCase):
    def test_daily_read_only_command_and_failure_cache(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp); csv = root/'contacts.csv'; csv.write_text(CSV)
            workspace = root/'workspace.json'; workspace.write_text(json.dumps({'account':'demo@example.test'}))
            cache = root/'contacts.json'
            run = Mock(return_value=SimpleNamespace(returncode=0, stdout=csv.read_text(), stderr=''))
            def refresh(now):
                return contacts.refresh(cache=cache, workspace=workspace, gam=root/'fake-gam', runner=run, now=now)
            rows = refresh(100)
            self.assertEqual(len(rows), 4)
            run.assert_called_once_with([str(root/'fake-gam'), 'user', 'demo@example.test', 'print', 'contacts', 'fields', 'name,email,phone,addresses,organizations'], capture_output=True, text=True, timeout=25, stdin=subprocess.DEVNULL, start_new_session=True)
            self.assertEqual(refresh(101), rows); self.assertEqual(run.call_count, 1)
            for i, error in enumerate([FileNotFoundError(), subprocess.TimeoutExpired('fake-gam',25), ValueError()]):
                run.side_effect = error
                now = 100 + (i+1)*86400
                self.assertEqual(refresh(now), rows)
                self.assertEqual(refresh(now+1), rows)
                self.assertEqual(run.call_count, i+2)
            self.assertEqual(json.loads(cache.read_text())['updated'], 100)
            # Never reuse one account's contacts after switching accounts.
            workspace.write_text(json.dumps({'account':'other@example.test'}))
            self.assertEqual(refresh(400000), [])

    def test_failure_retries_in_one_hour_then_success_waits_a_day(self):
        for result in (FileNotFoundError(), subprocess.TimeoutExpired('fake', 25),
                       SimpleNamespace(returncode=1, stdout='', stderr='failed')):
            with self.subTest(result=result), tempfile.TemporaryDirectory() as tmp:
                root = Path(tmp); cache = root/'contacts.json'; workspace = root/'workspace.json'
                workspace.write_text(json.dumps({'account':'demo@example.test'}))
                rows = contacts.parse(CSV)
                cache.write_text(json.dumps({'account':'demo@example.test', 'updated':10, 'entries':rows}))
                def fail(*args, **kwargs):
                    self.assertEqual(json.loads(cache.read_text())['attempted'], 100)
                    if isinstance(result, Exception): raise result
                    return result
                run = Mock(side_effect=fail)
                def refresh(now): return contacts.refresh(cache=cache, workspace=workspace, runner=run, now=now)
                self.assertEqual(refresh(100), rows)
                self.assertTrue(json.loads(cache.read_text())['failed'])
                self.assertEqual(json.loads(cache.read_text())['updated'], 10)
                self.assertEqual(refresh(3699), rows); self.assertEqual(run.call_count, 1)
                run.side_effect = None; run.return_value = SimpleNamespace(returncode=0, stdout=CSV, stderr='')
                self.assertEqual(refresh(3700), rows); self.assertEqual(run.call_count, 2)
                self.assertFalse(json.loads(cache.read_text())['failed'])
                refresh(3700+86399); self.assertEqual(run.call_count, 2)
                refresh(3700+86400); self.assertEqual(run.call_count, 3)

    def test_timeout_kills_child_holding_pipes(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp); cache = root/'contacts.json'; workspace = root/'workspace.json'
            workspace.write_text(json.dumps({'account':'demo@example.test'}))
            pidfile = root/'pids'
            # Parent exits immediately; only its child keeps stdout/stderr open.
            script = "import os, subprocess, sys; from pathlib import Path; child = subprocess.Popen([sys.executable, '-c', 'import time; time.sleep(30)']); Path(sys.argv[1]).write_text(f'{os.getpid()} {child.pid}')"
            def fake(args, **kwargs):
                kwargs['timeout'] = .5
                return contacts.run_contacts([sys.executable, '-c', script, str(pidfile)], **kwargs)
            started = time.monotonic()
            try:
                with patch.object(contacts.os, 'killpg', wraps=os.killpg) as kill:
                    self.assertEqual(contacts.refresh(cache=cache, workspace=workspace, runner=fake, now=100), [])
                self.assertLess(time.monotonic()-started, 5)
                self.assertTrue(json.loads(cache.read_text())['failed'])
                parent, child = map(int, pidfile.read_text().split())
                # The real group kill closed the sleeping child's inherited pipes.
                kill.assert_called_once_with(parent, signal.SIGKILL)
            finally:
                if pidfile.exists():
                    parent = int(pidfile.read_text().split()[0])
                    try: os.killpg(parent, signal.SIGKILL)
                    except ProcessLookupError: pass

    def test_unnamed_saved_contacts_are_searchable_cards_only(self):
        rows = contacts.parse('resourceName,name,email,phone\n'
                              'people/mail,Unnamed@example.test,,\n'
                              'people/phone,+380 (44) 555-0199,phone@example.test,\n'
                              'people/blank,,blank@example.test,\n')
        self.assertTrue(all(e['cards_only'] for e in rows))
        self.assertEqual(rows[0]['handles']['email'], ['Unnamed@example.test'])
        # A card-only entry must not regain tokens through aliases, either.
        rows[0]['aliases'] = ['SyntheticAlias']
        fixture = test_know.PackBuild(); fixture.setUp()
        try:
            built = fixture.build(contacts=rows)
            cards = [e for e in built['entries'] if e.get('cards_only')]
            self.assertEqual(len(cards), 3)
            self.assertTrue(all(e['tokens'] == e['forms'] == [] for e in cards))
            p = know.Pack(fixture.out)
            self.assertEqual(p.people('Unnamed@')[0]['handles']['email'], ['Unnamed@example.test'])
            self.assertEqual(p.people('phone@')[0]['handles']['email'], ['phone@example.test'])
            self.assertEqual(p.finish('Un'), '')
            self.assertEqual(p.targets('Un', 'Unnamed'), [])
        finally: fixture.doCleanups()

    def test_overlapping_refresh_does_not_call_gam(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp); cache = root/'contacts.json'; workspace = root/'workspace.json'
            workspace.write_text(json.dumps({'account':'demo@example.test'}))
            cache.write_text(json.dumps({'account':'demo@example.test', 'entries':contacts.parse(CSV)}))
            run = Mock()
            with cache.with_suffix('.lock').open('a') as lock:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                rows = contacts.refresh(cache=cache, workspace=workspace, runner=run)
            self.assertEqual(len(rows), 4)
            run.assert_not_called()

    def test_csv_other_contacts_and_merge_keys(self):
        rows = contacts.parse(CSV)
        other = rows[-1]
        self.assertEqual(other['name'], 'other@example.test')
        self.assertEqual(other['handles'], {'email':['other@example.test']})
        self.assertTrue(other['cards_only'])
        for handle in [{'email':['HANNA@example.test']}, {'phone':['+380445550100']}, {}]:
            known = {'name':'Hanna Demo', 'kind':'person', 'aliases':[], 'handles':handle, 'id':'pack:h'}
            merged = contacts.merge([known], rows)
            self.assertEqual(len(merged),4)
            self.assertEqual(merged[0]['id'],'pack:h')
            self.assertIn('hanna@example.test',merged[0]['handles']['email'])
            self.assertNotIn('source',merged[0])
        # A single shared first name is never enough to merge contacts.
        other_hanna = dict(rows[0], name='Hanna Someone', handles={'email':['separate@example.test']})
        self.assertEqual(len(contacts.merge([other_hanna], rows)),5)
        with self.assertRaises(ValueError): contacts.parse('not a CSV')
        self.assertEqual(contacts.parse('resourceName,name,email,phone\n'), [])

    def test_build_optional_contacts_uses_only_injected_fixtures(self):
        fixture = test_know.PackBuild(); fixture.setUp()
        try:
            pack = fixture.build(contacts=fixture.contacts + contacts.parse(CSV))
            es = pack['entries']
            h = next(e for e in es if e.get('id') == 'h')
            self.assertIn('Hanna Demo', h['aliases'])
            self.assertEqual(len([e for e in es if 'hanna@example.test' in e['handles'].get('email', [])]),1)
            foreign = next(e for e in es if e['name']=='Hannah Sample')
            self.assertEqual(foreign['forms'], [])
            female = next(e for e in es if e['name']=='Любов Коваленко')
            self.assertNotIn('Коваленка',female['forms'])
            self.assertLess(foreign['heat'], next(e for e in es if e['name']=='Base')['heat'])
            other = next(e for e in es if e.get('cards_only'))
            self.assertEqual(other['tokens'] + other['forms'], [])
            p = know.Pack(fixture.out)
            self.assertEqual(p.people('other')[0]['handles'], {'email':['other@example.test']})
            self.assertEqual(p.finish('Ot'), '')
            self.assertTrue(all(w[:1].isupper() for e in es for w in e['forms']))
        finally: fixture.doCleanups()

class MentionFields(unittest.TestCase):
    """Company, title and address for the @ mention list (made-up rows)."""
    CSV2 = '''resourceName,names.0.displayName,emailAddresses.0.value,phoneNumbers.0.value,addresses.0.formattedValue,organizations.0.name,organizations.0.title
people/c1,Ana Demo,ana@example.test,+380 44 555 0100,"Khreshchatyk 1,
Kyiv",Demo Labs,CTO
otherContacts/c2,,other@example.test,,Somewhere 5,Other Co,Boss
'''
    def test_parse_keeps_org_title_address_for_saved_only(self):
        rows = contacts.parse(self.CSV2)
        ana = next(r for r in rows if r['name'] == 'Ana Demo')
        self.assertEqual(ana['org'], 'Demo Labs'); self.assertEqual(ana['role'], 'CTO')
        self.assertEqual(ana['handles']['address'], ['Khreshchatyk 1, Kyiv'])
        other = next(r for r in rows if r['cards_only'])
        self.assertEqual(other['org'], ''); self.assertNotIn('address', other['handles'])

    def test_merge_fills_org_without_overwriting(self):
        known = [{'id': 'a', 'name': 'Ana Demo', 'kind': 'person', 'aliases': [], 'handles': {'email': ['ana@example.test']}}]
        out = contacts.merge(known, contacts.parse(self.CSV2))
        self.assertEqual(out[0]['org'], 'Demo Labs')
        known[0]['org'] = 'Own Org'
        self.assertEqual(contacts.merge(known, contacts.parse(self.CSV2))[0]['org'], 'Own Org')


if __name__ == '__main__': unittest.main()

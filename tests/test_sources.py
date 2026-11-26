"""engine/sources.py with made-up mail, chats and Docs; fake runners only. Never calls GAM or Beeper, never reads data/."""
import json
from pathlib import Path
import re
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'engine'))
import sources
import whom

ME = 'me@example.test'
MAIL = '''User,threadId,id,Date,Subject,From,To,Cc,Attachments,Attachments.0.name,Attachments.1.name,Body
me@example.test,t1,m1,"Mon, 16 Nov 2026 10:00:00 +0000",Contract draft,Olena Demo <olena@example.test>,Me <me@example.test>,,2,draft-v2.pdf,invite.ics,"Here is the draft: https://docs.example.test/d/abc
See the PDF.

On Mon, 16 Nov 2026 at 09:00, Me <me@example.test> wrote:
> please send the draft"
me@example.test,t2,m2,"Mon, 16 Nov 2026 12:00:00 +0000",Re: Contract draft,Me <me@example.test>,Olena Demo <olena@example.test>,Taras Sample <taras@example.test>,0,,,"Thanks, got it. https://example.test/unsubscribe?x=1"
'''
DRIVE = '''Owner,id,name,mimeType,modifiedTime,owners.0.displayName,owners.0.emailAddress,webViewLink
me@example.test,d1,Pricing notes,application/vnd.google-apps.document,2026-11-15T10:00:00Z,Me,me@example.test,https://docs.example.test/d1
me@example.test,d2,Shared deck,application/pdf,2026-11-14T10:00:00Z,Olena Demo,olena@example.test,https://docs.example.test/d2
me@example.test,f1,Folder,application/vnd.google-apps.folder,2026-11-14T10:00:00Z,Me,me@example.test,https://docs.example.test/f1
'''
NOW = 1763380800.0   # 2025-11-17, any fixed time works


def msg(i, ts, text, me=False, chat='!c1', name='Olena Demo'):
    return {'id': str(i), 'chatID': chat, 'senderName': '' if me else name, 'timestamp': ts, 'type': 'TEXT',
            'text': text, 'isSender': me, 'isDeleted': False}


class Base(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(); self.dir = Path(self.tmp.name)
        self.state = sources.State(self.dir / 'sources.json')

    def tearDown(self): self.tmp.cleanup()


class Mail(Base):
    def test_rows_strip_quotes_keep_links_and_files(self):
        rows = list(sources.mail_rows(MAIL, ME))
        self.assertEqual(len(rows), 2)
        a, b = rows
        self.assertFalse(a['mine']); self.assertTrue(b['mine'])
        self.assertNotIn('please send', a['text'])
        self.assertEqual(a['links'], ['https://docs.example.test/d/abc'])
        self.assertEqual(a['files'], ['draft-v2.pdf'])                 # the calendar invite is noise
        self.assertEqual(b['links'], [])                               # unsubscribe links are noise
        self.assertEqual({p['email'] for p in b['who']}, {'olena@example.test', 'taras@example.test'})
        self.assertTrue(a['url'].endswith('/m1'))

    def test_incremental_windows_and_cut_pages(self):
        calls = []
        def run(args):
            q = args[args.index('query') + 1]
            calls.append(q)
            self.assertNotIn('send', ' '.join(args)); self.assertIn('print', args)   # read-only command
            return MAIL if len(calls) == 1 else MAIL.splitlines()[0] + '\n'
        old = sources.MAIL_PAGE
        sources.MAIL_PAGE = 2         # the first page is full: the window narrows and is read again
        try: sources.ingest_mail(self.state, run=run, me=ME, folder=self.dir, now=NOW)
        finally: sources.MAIL_PAGE = old
        a1, b1 = map(int, re.findall(r'after:(\d+) before:(\d+)', calls[0])[0])
        a2, b2 = map(int, re.findall(r'after:(\d+) before:(\d+)', calls[1])[0])
        self.assertEqual(a1, a2); self.assertLess(b2 - a2, b1 - a1)
        st = self.state.read()['mail']
        self.assertAlmostEqual(st['cursor']['after'], NOW, delta=1)
        # a second run starts at the cursor: nothing read twice
        calls.clear()
        sources.ingest_mail(self.state, run=run, me=ME, folder=self.dir, now=NOW + 3600)
        self.assertEqual(len(calls), 1)
        self.assertGreaterEqual(int(re.findall(r'after:(\d+)', calls[0])[0]), int(NOW) - 1)


class Failures(Base):
    def test_mail_keeps_windows_before_a_failure(self):
        n = [0]
        def run(args):
            n[0] += 1
            if n[0] == 3: raise RuntimeError('gam exit 60')
            return MAIL if n[0] == 1 else MAIL.splitlines()[0] + '\n'
        with self.assertRaises(RuntimeError): sources.ingest_mail(self.state, run=run, me=ME, folder=self.dir, now=NOW)
        self.assertEqual(len(sources.read_store(sources.store_path('mail', self.dir))), 2)
        st = self.state.read()['mail']
        self.assertEqual(st['count'], 2)
        self.assertLess(st['cursor']['after'], NOW)                    # the failed window is read again next time
        self.assertGreater(st['cursor']['after'], NOW - sources.MAIL_DAYS * 86400)


class Beeper(Base):
    def test_forward_then_back_in_time(self):
        newer = [msg(3, '2025-11-17T10:00:00Z', 'новий драфт тут https://example.test/x'), msg(2, '2025-11-17T09:00:00Z', 'Claude: підсумок', me=True)]
        older = [msg(1, '2025-10-01T09:00:00Z', 'старе', me=True)]
        def run(args):
            if args[:2] == ['chats', 'list']: return [{'id': '!c1', 'title': 'Demo group'}]
            self.assertEqual(args[:2], ['messages', 'search'])
            before = sources.from_iso(args[args.index('--before') + 1])
            return [m for m in newer + older if sources.from_iso(m['timestamp']) <= before
                    and sources.from_iso(m['timestamp']) >= sources.from_iso(args[args.index('--after') + 1])]
        sources.ingest_beeper(self.state, run=run, folder=self.dir, now=NOW)
        rows = sources.read_store(sources.store_path('beeper', self.dir))
        self.assertEqual(len(rows), 3 if any('старе' in r['text'] for r in rows.values()) else 2)
        r3 = next(r for r in rows.values() if r['text'].startswith('новий'))
        self.assertEqual(r3['title'], 'Demo group'); self.assertFalse(r3['mine'])
        self.assertEqual(r3['links'], ['https://example.test/x'])
        signed = next(r for r in rows.values() if r['text'].startswith('Claude'))
        self.assertFalse(signed['mine'])                                # Claude's lines are not the user's
        cur = self.state.read()['beeper']['cursor']
        self.assertEqual(cur['after'], NOW); self.assertLess(cur['oldest'], NOW - 3 * 86400)
        # keeps going back on the next runs until the horizon
        for _ in range(14): sources.ingest_beeper(self.state, run=run, folder=self.dir, now=NOW)
        self.assertEqual(len(sources.read_store(sources.store_path('beeper', self.dir))), 3)
        self.assertLessEqual(self.state.read()['beeper']['cursor']['oldest'], NOW - sources.BEEPER_DAYS * 86400 + 1)


class Drive(Base):
    def test_titles_and_doc_text(self):
        def run(args):
            if 'filelist' in args: return DRIVE
            self.assertIn('drivefile', args); self.assertIn('get', args)
            d = Path(args[args.index('targetfolder') + 1]); (d / 'doc.txt').write_text('﻿Pricing plan https://example.test/p')
            return ''
        sources.ingest_drive(self.state, run=run, me=ME, folder=self.dir, now=NOW)
        rows = sources.read_store(sources.store_path('drive', self.dir))
        self.assertEqual(set(rows), {'drive:d1', 'drive:d2'})          # folders left out
        self.assertEqual(rows['drive:d1']['text'], 'Pricing plan https://example.test/p')
        self.assertTrue(rows['drive:d1']['mine']); self.assertFalse(rows['drive:d2']['mine'])
        self.assertEqual(rows['drive:d2']['text'], '')                  # only Google Docs get text


class Run(Base):
    def test_switch_errors_and_status(self):
        seen = []
        ingest = {'mail': lambda st: seen.append('mail') or 5, 'beeper': lambda st: 1 / 0, 'drive': lambda st: seen.append('drive') or 1}
        self.state.update('drive', enabled=False)
        out = sources.run(state=self.state, check=lambda n: True, ingest=ingest)
        self.assertEqual(out, {'mail': 5, 'beeper': 'error'})
        self.assertEqual(seen, ['mail'])
        st = {s['name']: s for s in sources.status(self.state)['sources']}
        self.assertTrue(st['mail']['updated']); self.assertIn('ZeroDivisionError', st['beeper']['error'])
        self.assertFalse(st['drive']['enabled'])
        out = sources.run(['mail'], state=self.state, check=lambda n: False, ingest=ingest)
        self.assertEqual(out, {'mail': 'unavailable'})


class Readers(Base):
    def fill(self):
        mail = {r['id']: r for r in sources.mail_rows(MAIL, ME)}
        sources.write_store(sources.store_path('mail', self.dir), mail, 100)
        chat = {r['id']: r for r in sources.beeper_rows([msg(1, '2025-11-17T10:00:00Z', 'привіт')], {'!c1': 'Demo group'})}
        sources.write_store(sources.store_path('beeper', self.dir), chat, 100)
        return sources.Index(self.dir, self.state, sync=True)

    def test_topics_and_find(self):
        ix = self.fill()
        tp = ix.topics(['olena@example.test'], ['Olena Demo'])
        self.assertEqual(tp['mail'], ['Re: Contract draft'])           # one thread, newest subject
        self.assertEqual(tp['chats'], ['Demo group'])
        found = ix.find('draft pdf', who=['olena@example.test'])
        self.assertEqual(found[0]['file'], 'draft-v2.pdf')
        self.assertIn('https://docs.example.test/d/abc', [f['url'] for f in found])
        self.assertEqual(ix.find('zebra quantum'), [])
        self.state.update('mail', enabled=False)                       # off: nothing from it is offered
        self.assertEqual(ix.find('draft pdf'), [])

    def test_items_for_the_index(self):
        self.fill()
        all_ = list(sources.items(folder=self.dir))
        self.assertEqual(len(all_), 3)
        self.assertEqual([r['id'] for r in sources.items(folder=self.dir, include_theirs=False)], ['mail:m2'])

    def test_whom_block_has_topics(self):
        ix = self.fill()
        e = {'id': 'p1', 'kind': 'person', 'uk': 'Олена Демо', 'latin': 'Olena Demo', 'emails': ['olena@example.test']}
        tp = ix.topics(e['emails'], whom.labels(e))
        text = whom.card(e, {}, ['made-up line'], topics=tp)
        self.assertIn('Recent mail with them: Re: Contract draft', text)
        self.assertLessEqual(len(text), whom.BLOCK_MAX)


class NeverStyle(unittest.TestCase):
    def test_no_style_or_training_reader_reads_the_stores(self):
        """Other people's text is context only: corpus, style, phrases and training never open data/sources."""
        files = [ROOT / 'engine/style.py', ROOT / 'engine/words.py', ROOT / 'engine/know.py', ROOT / 'engine/names.py']
        files += sorted((ROOT / 'bench').glob('*.py'))
        for f in files:
            text = f.read_text()
            self.assertNotRegex(text, r"sources\.jsonl|data/sources|import sources|sources\.items", f.name)

    def test_read_only_commands(self):
        text = (ROOT / 'engine/sources.py').read_text()
        for word in ('"send"', '"delete"', '"trash"', '"modify"', '"archive"', '"addlabel"', '"draft"', '"forward"', '"reply"'):
            self.assertNotIn(word, text)


if __name__ == '__main__': unittest.main()

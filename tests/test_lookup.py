import json
import sys
import tempfile
import unittest
from datetime import datetime, timedelta
from pathlib import Path
from unittest.mock import patch
from zoneinfo import ZoneInfo

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'engine'))
import lookup
import integrations
integrations.available = lambda name: True   # the GAM integration is stood in for below; no config on a test Mac

ZONE = ZoneInfo('Europe/Kyiv')


def at(day, hour=0, minute=0):
    return datetime(2026, 10, day, hour, minute, tzinfo=ZONE)


def event(a, b, **extra):
    return {'start': {'dateTime': a.isoformat()}, 'end': {'dateTime': b.isoformat()}, **extra}


class Lookups(unittest.TestCase):
    def test_drive_query_escapes_literals_and_includes_shared_files(self):
        csv = 'Owner,id,name,webViewLink\na@example.com,1,Project notes,https://docs.google.com/document/d/1/edit\n'
        with patch.object(lookup, 'gam', return_value=csv) as call:
            rows = lookup.documents('a@example.com', "O'Brien \\notes")
        args = call.call_args.args
        self.assertIn('anyowner', args)
        self.assertIn("name contains 'O\\'Brien'", args[args.index('query') + 1])
        self.assertIn("name contains '\\\\notes'", args[args.index('query') + 1])
        self.assertEqual(rows[0]['run'], {'kind': 'lookup.insert', 'text': 'https://docs.google.com/document/d/1/edit'})

    def test_saved_links_are_local_and_filter_non_urls(self):
        with tempfile.TemporaryDirectory() as folder, patch.object(lookup, 'DATA', Path(folder)), patch.object(lookup, 'gam') as remote:
            (Path(folder) / 'snippets.json').write_text(json.dumps({';cal': 'https://example.com/cal', ';mail': 'a@example.com', ';bad': 'javascript:alert(1)'}))
            (Path(folder) / 'replacements.json').write_text(json.dumps({';team': 'https://example.com/team'}))
            rows = lookup.search({'kind': 'links', 'query': 'team'})
            self.assertEqual(rows['options'][0]['run']['text'], 'https://example.com/team')
            self.assertEqual(len(lookup.search({'kind': 'links'})['options']), 2)
            remote.assert_not_called()

    def test_reject_credential_urls(self):
        for url in ('https://user:secret@example.com', 'file:///tmp/a', 'javascript:alert(1)', 'https://[invalid'):
            self.assertEqual(lookup.public_url(url), '')

    def test_dates_and_dst(self):
        start, end, remaining = lookup.window('30 next week', at(23, 12), 7)
        self.assertEqual((start.day, end.day, remaining), (26, 31, '30'))
        self.assertEqual(start.utcoffset(), timedelta(hours=2))
        start, end, remaining = lookup.window('Nadia tomorrow', at(23, 12), 14)
        self.assertEqual((start.day, end.day, remaining), (24, 25, 'Nadia'))
        self.assertEqual(lookup.window('30 завтра', at(23), 7)[2], '30')
        with self.assertRaises(ValueError):
            lookup.window('30 2026-02-30', at(23), 7)

    def test_busy_overlap_boundaries_and_lead_time(self):
        rows = [event(at(23, 9), at(23, 10)), event(at(23, 10, 30), at(23, 12))]
        slots = lookup.free_times(rows, at(23), at(24), 30, at(23, 9, 40))
        self.assertEqual(slots[0], (at(23, 10), at(23, 10, 30)))
        self.assertTrue(all(a >= at(23, 9, 55) for a, _ in slots))
        self.assertTrue(all(not (a < at(23, 12) and b > at(23, 10, 30)) for a, b in slots))

    def test_opaque_all_day_blocks_day(self):
        rows = [{'start': {'date': '2026-10-23'}, 'end': {'date': '2026-10-24'}}]
        self.assertEqual(lookup.free_times(rows, at(23), at(24), 30, at(23, 8)), [])

    def test_transparent_and_working_location_do_not_block(self):
        rows = [event(at(23, 9), at(23, 18), transparency='transparent'), event(at(23, 9), at(23, 18), eventType='workingLocation')]
        self.assertEqual(lookup.free_times(rows, at(23), at(24), 30, at(23, 8))[0][0], at(23, 9))

    def test_weekends_and_past_dates_have_no_slots(self):
        self.assertEqual(lookup.free_times([], at(24), at(26), 30, at(23)), [])
        self.assertEqual(lookup.free_times([], at(22), at(23), 30, at(23)), [])

    def test_unusual_duration_stays_on_quarter_hours_and_inside_workday(self):
        slots = lookup.free_times([], at(23), at(24), 20, at(23, 16))
        self.assertTrue(slots)
        for a, b in slots:
            self.assertEqual(a.minute % 15, 0)
            self.assertEqual(b - a, timedelta(minutes=20))
            self.assertLessEqual(b, at(23, 18))

    def test_malformed_event_fails_closed(self):
        with self.assertRaisesRegex(ValueError, 'No free times'):
            lookup.free_times([{'start': {}, 'end': {}}], at(23), at(24), 30, at(23))

    def test_jsonl_calendar_filters_cancelled_and_declined(self):
        rows = [{'id': 'cancel', 'status': 'cancelled'}, {'id': 'decline', 'attendees': [{'self': True, 'responseStatus': 'declined'}]}, {'id': 'keep'}]
        data = '\n'.join(json.dumps({'event': r}) for r in rows)
        with patch.object(lookup, 'gam', return_value=data) as call:
            self.assertEqual(lookup.events('a@example.com', at(23), at(24)), [{'id': 'keep'}])
        self.assertEqual(call.call_args.args[1:4], ('show', 'events', 'primary'))
        with patch.object(lookup, 'gam', return_value='{"event": null}'):
            with self.assertRaisesRegex(ValueError, 'No times'):
                lookup.events('a@example.com', at(23), at(24))

    def test_provider_error_never_suggests_availability(self):
        with patch.object(lookup, 'config', return_value=('a@example.com', ZONE)), patch.object(lookup, 'events', side_effect=ValueError('Connection failed')):
            reply = lookup.search({'kind': 'free', 'query': '30 tomorrow'})
        self.assertEqual(reply['options'], [])
        self.assertEqual(reply['error'], 'Connection failed')

    def test_free_picker_words_and_slots(self):
        """The picker's words (17 November 2026): part of the day, an hour, Ukrainian and Russian days; plain slots out."""
        self.assertEqual(lookup.part_of("30 завтра вранці"), ("morning", "30 завтра"))
        self.assertEqual(lookup.part_of("after lunch")[0], "")
        self.assertEqual(lookup.part_of("60 после обеда")[0], "afternoon")
        mornings = lookup.free_times([], at(23), at(24), 30, at(23, 8), hours=lookup.PARTS["morning"])
        self.assertTrue(mornings and all(a.hour < 13 for a, _ in mornings))
        afternoons = lookup.free_times([], at(23), at(24), 30, at(23, 8), hours=lookup.PARTS["afternoon"])
        self.assertEqual(afternoons[0][0], at(23, 13))
        with patch.object(lookup, 'config', return_value=('a@example.com', ZONE)), patch.object(lookup, 'events', return_value=[]), \
             patch.object(lookup, 'datetime', wraps=lookup.datetime) as dt:
            dt.now.return_value = at(22, 8)   # Thursday: tomorrow is a weekday
            reply = lookup.search({'kind': 'free', 'query': 'година завтра після обіду'})
        self.assertNotIn('error', reply)
        self.assertEqual(reply['minutes'], 60); self.assertEqual(reply['part'], 'afternoon')
        self.assertTrue(reply['slots'] and all('T' in s['start'] for s in reply['slots']))
        self.assertNotIn('2026', reply['options'][-1]['chip'])

    def test_free_rejects_ambiguous_queries_without_reading_calendar(self):
        with patch.object(lookup, 'config', return_value=('a@example.com', ZONE)), patch.object(lookup, 'events') as read:
            for query in ('10 tomorrow', '999 today', 'sometime after lunch', '30 2026-02-30'):
                self.assertIn('error', lookup.search({'kind': 'free', 'query': query}))
            read.assert_not_called()

    def test_meetings_insert_existing_link_not_create_event(self):
        rows = [event(at(26, 10), at(26, 11), summary='Project sync', hangoutLink='https://meet.google.com/aaa-bbbb-ccc', htmlLink='https://calendar.google.com/calendar/event?eid=1')]
        with patch.object(lookup, 'config', return_value=('a@example.com', ZONE)), patch.object(lookup, 'events', return_value=rows):
            reply = lookup.search({'kind': 'meetings', 'query': 'project'})
        self.assertEqual(reply['options'][0]['run'], {'kind': 'lookup.insert', 'text': 'https://meet.google.com/aaa-bbbb-ccc'})
        self.assertIn('Primary calendar only', reply['source'])

    def test_command_shortcuts_bypass_the_model(self):
        import command
        def no_model(*args, **kwargs):
            self.fail('A fixed lookup called the language model')
        with patch.object(lookup, 'search', return_value={'options': []}) as search:
            for kind in ('docs', 'links', 'meetings', 'free', 'accounts'):
                reply = command.plan(';' + kind + ' query', no_model)
                self.assertEqual(reply['by'], 'lookup')
                self.assertEqual(search.call_args.args[0], {'kind': kind, 'query': 'query'})

    def test_local_connection_timeout_is_safe(self):
        with patch.object(lookup, 'GAM') as binary, patch.object(lookup.subprocess, 'run', side_effect=lookup.subprocess.TimeoutExpired('gam', 25)):
            binary.is_file.return_value = True
            with self.assertRaisesRegex(ValueError, 'did not answer'):
                lookup.gam('a@example.com', 'show', 'events')


if __name__ == '__main__':
    unittest.main()

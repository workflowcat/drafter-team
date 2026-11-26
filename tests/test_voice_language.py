"""Round ten: invented text shapes only; no personal takes or model loads."""
import contextlib
import io
import unittest
from unittest.mock import patch

import numpy as np

from test_voice_guard import fake_voice, segment, load
from voice_language import fast_language, pin_value, pinned_plan, prompt_echo, retain_fast


class Language(unittest.TestCase):
    def test_language_majority_and_unknown(self):
        for text, language in [('Новий проєкт готовий до review', 'uk'),
                               ('Please review the проєкт tomorrow', None),
                               ('добре', 'uk'), ('café déjà', 'en'),
                               ('сімʼя', 'uk'), ('так', 'uk'), ('OK', 'en'),
                               ('123!?', None), ('тест test', 'uk'), ('文字文字', None), (None, None)]:
            with self.subTest(text=text):
                self.assertEqual(fast_language(text), language)

    def test_scripts_and_russian_letters_are_contextual(self):
        with fake_voice() as (voice, _):
            for text in ('Текст 漢字', 'Текст 한글', 'Текст عربي', 'text Ελληνικά'):
                self.assertEqual(voice.whisper_rejection(segment(text), 'uk'), 'script')
            for letter in 'ыэъёЫЭЪЁ':
                self.assertEqual(voice.whisper_rejection(segment('текст ' + letter), 'uk'), 'russian')
                self.assertIsNone(voice.whisper_rejection(segment('text ' + letter), 'en'))
                self.assertIsNone(voice.whisper_rejection(segment(letter)))
            self.assertEqual(voice.whisper_rejection(segment('е\u0308'), 'uk'), 'russian')
            for text in ('Проєкт review готовий', 'Їжак, ґанок, сімʼя.', 'cafe\u0301 123 🙂'):
                self.assertIsNone(voice.whisper_rejection(segment(text), 'uk'))

    def test_prompt_order_boundaries_and_real_terms(self):
        prompt = 'Names: Screen Person. Glossary: Amber, Blue Meadow, Cedar, Delta.'
        for text in ('  «GLOSSARY: something', 'Glossary, something',
                     'Names: Screen Person', 'Amber, Blue Meadow, Cedar, Delta'):
            self.assertTrue(prompt_echo(text, prompt), text)
        for text in ('Amber then Blue Meadow then Cedar', 'Amber, Cedar and Delta',
                     'Amber, Blue Meadow Cedar', 'Cedar Blue Meadow Amber',
                     'Amber Blue Meadow', 'Amberwood Blue Meadow Cedar',
                     'Amber. Blue Meadow, Cedar', 'Amber - Blue Meadow - Cedar'):
            self.assertFalse(prompt_echo(text, prompt), text)
        self.assertFalse(prompt_echo('Amber Blue Meadow Cedar', None))
        with fake_voice() as (voice, _):
            self.assertEqual(voice.whisper_rejection(segment('Amber, Blue Meadow, Cedar, Delta'), 'en', prompt), 'prompt_echo')

    def test_fallback_empty_under_half_boundary_and_unknown(self):
        fast = 'One, two three four five six.'
        for careful in ('', '   ', 'one two', 'one !!!'):
            self.assertEqual(retain_fast(careful, fast), fast)
        for careful in ('one two three', 'one two three four', fast):
            self.assertEqual(retain_fast(careful, fast), careful)
        self.assertEqual(retain_fast('new text', None), 'new text')
        self.assertEqual(retain_fast('', None), '')

    def test_pin_only_chooses_the_reader_never_translates(self):
        for raw, want in (('uk', 'uk'), (' EN ', 'en'), ('', None), (None, None), ('ru', None), ('auto', None)):
            self.assertEqual(pin_value(raw), want)
        for pin, fast, plan in [(None, 'Please check the проєкт', 'fast'),
                                ('uk', '', 'fast'), ('en', '   ', 'fast'),
                                ('uk', 'Новий проєкт готовий до review', 'fast'),
                                ('en', 'Please check the report', 'fast'),
                                ('en', 'Новий проєкт готовий', 'careful'),
                                ('uk', 'Please check the report', 'careful'),
                                ('uk', 'Please review the проєкт tomorrow', 'careful'),   # mixed, under 30%
                                ('en', 'Please review the проєкт tomorrow', 'careful'),
                                ('de', 'Новий проєкт', 'fast')]:
            with self.subTest(pin=pin, fast=fast):
                self.assertEqual(pinned_plan(pin, fast), plan)

    def test_pin_reaches_whisper_language_and_guards_stay(self):
        audio = np.full(16000, 0.02, np.float32)
        with fake_voice() as (voice, whisper):
            # a mixed take (under 30% Cyrillic): Whisper reads it as English
            whisper.transcribe.return_value = {'segments': [segment('Please check the report today')]}
            out = voice.careful(audio, fast_text='Please check the звіт report today', pin='en')
            self.assertEqual(whisper.transcribe.call_args.kwargs['language'], 'en')
            self.assertEqual(out, 'Please check the report today')
            whisper.transcribe.return_value = {'segments': [segment('Новий проєкт готовий')]}
            voice.careful(audio, fast_text='Please check the report', pin='uk')
            self.assertEqual(whisper.transcribe.call_args.kwargs['language'], 'uk')
            # a pinned read that comes back in Russian letters is rejected: the fast text stays
            whisper.transcribe.return_value = {'segments': [segment('Новый проект ы')]}
            fast = 'Please check the новий проєкт'
            self.assertEqual(voice.careful(audio, fast_text=fast, pin='uk'), fast)
            # never a translation: English asked over a take heard as Ukrainian, an all-English answer keeps the fast text
            whisper.transcribe.return_value = {'segments': [segment('Please send the meeting notes tomorrow')]}
            fast = 'Надішли нотатки із зустрічі завтра'
            self.assertEqual(voice.careful(audio, fast_text=fast, pin='en'), fast)
            self.assertEqual(voice.whisper_rejection(segment('Please send the meeting notes tomorrow'), 'en', None, fast), 'translation')
            self.assertIsNone(voice.whisper_rejection(segment('Please send the meeting notes tomorrow'), 'en', None, 'Please send the notes'))
            self.assertIsNone(voice.whisper_rejection(segment('Please send the meeting notes tomorrow'), 'en'))
            self.assertEqual(voice.whisper_rejection(segment('Thank you'), 'en', None, 'Дякую тобі'), 'translation')
            self.assertIsNone(voice.whisper_rejection(segment('OK'), 'en', None, 'Дякую тобі'))   # one word: a term
            # a mixed answer (the user's Ukrainian words kept, English terms in English) is taken
            whisper.transcribe.return_value = {'segments': [segment('Надішли notes із meeting завтра')]}
            self.assertEqual(voice.careful(audio, fast_text=fast, pin='en'), 'Надішли notes із meeting завтра')
            # no pin: as before, the fast text's own language
            voice.careful(audio, fast_text='Please check the report')
            self.assertEqual(whisper.transcribe.call_args.kwargs['language'], 'en')

    def test_take_wires_language_prompt_and_fallback(self):
        audio = np.full(16000, 0.02, np.float32)
        fast = 'Цей новий проєкт уже готовий до перевірки'
        with fake_voice() as (voice, whisper):
            voice.HINT = 'Glossary: Amber, Birch, Cedar.'
            for rejected in ('Текст ы', 'Текст 漢字', 'Amber Birch Cedar'):
                whisper.transcribe.return_value = {'segments': [segment(rejected)]}
                self.assertEqual(voice.Readers().careful(audio, fast_text=fast), fast)
                self.assertEqual(whisper.transcribe.call_args.kwargs['language'], 'uk')
            # A compression drop leaves a plausible but shortened nonempty answer.
            whisper.transcribe.return_value = {'segments': [segment('довгий початок', compression_ratio=3),
                                                            segment('готовий проєкт')]}
            self.assertEqual(voice.careful(audio, fast_text=fast), fast)
            whisper.transcribe.return_value = {'segments': [segment('yes')]}
            voice.careful(audio, fast_text='yes')
            self.assertEqual(whisper.transcribe.call_args.kwargs['language'], 'en')
            voice.careful(audio, fast_text='Please check the project')
            self.assertEqual(whisper.transcribe.call_args.kwargs['language'], 'en')

    def test_file_per_piece_language_and_explicit_override(self):
        fast = [dict(start=0, end=1, text='Новий проєкт готовий'),
                dict(start=1, end=2, text='Please check tomorrow')]
        with fake_voice() as (voice, whisper):
            whisper.transcribe.return_value = {'segments': [segment('Новий review')]}
            with patch.object(voice, 'load_pcm16', return_value=np.full(32000, 1000, np.int16)), \
                    patch.object(voice, 'pieces', return_value=[(0, 16000), (16000, 32000)]):
                for lang, expected in ((None, ['uk', 'en']), ('uk', ['uk', 'en']), ('en', ['uk', 'en'])):
                    whisper.transcribe.reset_mock()
                    result = voice.Readers().read_file_whisper('fake', lang=lang, fast_segments=fast)
                    self.assertEqual([c.kwargs['language'] for c in whisper.transcribe.call_args_list], expected)
                    self.assertEqual([s['start'] for s in result], [0, 1])
                whisper.transcribe.reset_mock()
                voice.Readers().read_file_whisper('fake', fast_text='Unrelated whole file text')
                self.assertEqual([c.kwargs['language'] for c in whisper.transcribe.call_args_list], [None, None])
            with patch.object(voice, 'load_pcm16', return_value=np.full(16000, 1000, np.int16)):
                voice.Readers().read_file_whisper('fake', fast_text='Новий проєкт готовий')
                self.assertEqual(whisper.transcribe.call_args.kwargs['language'], 'uk')
                voice.Readers().read_file_whisper('fake')
                self.assertIsNone(whisper.transcribe.call_args.kwargs['language'])

    def test_bench_counts_raw_mismatches_without_hiding_fallback(self):
        bench = load('language_bench', 'bench/voice_models.py')
        base = dict(take='invented.wav', pair='current', status='ok', mode='take')
        quick = dict(base, reader='fast', text='Новий проєкт готовий')
        rows = [quick, dict(base, reader='careful', text=quick['text'], raw_careful_text='Текст ы 漢字',
                            guard_dropped=[{'reason': r} for r in ('script', 'russian', 'prompt_echo')], kept_fast=True),
                dict(base, mode='file', reader='fast', text='Please check tomorrow'),
                dict(base, mode='file', reader='careful', text='Bitte prüfen', decoded_languages=['de'])]
        bench.compare(rows)
        self.assertTrue(rows[1]['script_differs'])
        self.assertTrue(rows[1]['language_differs'])
        self.assertFalse(rows[3]['script_differs'])
        self.assertTrue(rows[3]['language_differs'])
        self.assertEqual(rows[1]['made_up'], ['blocked', 'prompt_echo', 'russian', 'script', 'kept fast'])
        with contextlib.redirect_stdout(io.StringIO()) as output:
            bench.table(rows)
        self.assertIn('1 script, 2 language, 2 either / 2 rows', output.getvalue())


if __name__ == '__main__':
    unittest.main()

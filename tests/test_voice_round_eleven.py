"""Invented transcripts and inert readers only. Never read personal data or load a model."""
import unittest
from unittest.mock import patch
import numpy as np
from test_voice_guard import fake_voice, segment
from voice_language import fast_language, prompt_echo, retain_fast


class RoundEleven(unittest.TestCase):
    def test_real_repeats_and_loop_boundaries(self):
        with fake_voice() as (voice, _):
            for text in ('так, так, так', 'wait, wait, wait', 'бла-бла-бла', 'ні. Ні, ні',
                         'one one one one', 'go now go now', 'a b c d a b c d',
                         'a b c d e a b c d e a b c d e'):
                self.assertIsNone(voice.whisper_rejection(segment(text)), text)
            for text in ('one one one one one', 'go now go now go now',
                         'a b c a b c a b c', 'a b c d a b c d a b c d'):
                self.assertEqual(voice.whisper_rejection(segment(text)), 'word_loop', text)
            self.assertIsNone(voice.whisper_rejection(segment('wait, wait, wait', tokens=[7]*5)))
            self.assertEqual(voice.whisper_rejection(segment('words', tokens=[7]*6)), 'token_loop')
            self.assertIsNone(voice.whisper_rejection(segment('words', tokens=[50257]*8)))

    def test_prompt_lists_not_scattered_names(self):
        prompt = 'Names: Mila, Sava, Northwind. Glossary: Claude, Claude Code, Codex, GitHub.'
        for text in ('Відкрий Claude, перевір Codex і запуш у GitHub',
                     'Claude. Codex. GitHub.', 'Claude and Codex and GitHub',
                     'ClaudeCode Codex GitHub', 'Claude; Codex; GitHub'):
            self.assertFalse(prompt_echo(text, prompt), text)
        for text in ('Claude, Claude Code, Codex, GitHub', 'Names: Mila', 'Glossary: Claude'):
            self.assertTrue(prompt_echo(text, prompt), text)
        for text in ('Claude, Codex, GitHub', 'Claude Code Codex GitHub', 'Mila, Sava Northwind'):
            self.assertFalse(prompt_echo(text, prompt), text)
        self.assertFalse(prompt_echo('Mila Sava Northwind', 'Names: Mila, Sava, Northwind.'))

    def test_language_word_threshold(self):
        for text, expected in [('зроби review у GitHub для DataKit', 'uk'),
                               ('перевір цей pull request', 'uk'), ('так', 'uk'), ('ні', 'uk'),
                               ('а б в one two three four five six seven', 'uk'),
                               ('а б one two three four five six seven eight', None),
                               ('а one two three four five six seven eight nine', None),
                               ('one two three', 'en'), ('123 !?', None)]:
            self.assertEqual(fast_language(text), expected, text)

    def test_russian_fast_context_and_latin_segment(self):
        with fake_voice() as (voice, _):
            for lang in ('uk', 'en', None):
                self.assertEqual(voice.whisper_rejection(segment('новый текст'), lang, fast_text='ні'), 'russian')
            self.assertIsNone(voice.whisper_rejection(segment('new text ё'), 'en', fast_text='new text'))
            for text in ('Thank you for watching', 'please check the project'):
                self.assertEqual(voice.whisper_rejection(segment(text), 'uk'), 'script')
            for text in ('pull request ready', 'перевір please check the project'):
                self.assertIsNone(voice.whisper_rejection(segment(text), 'uk'))

    def test_any_rejection_keeps_entire_fast_take_even_with_long_survivor(self):
        fast = 'перевір цей pull request та надішли мені посилання завтра вранці'
        audio = np.full(16000, 0.02, np.float32)
        bad = [segment('bad', compression_ratio=3), segment('так '*5),
               segment('text', tokens=[7]*6), segment('Names: Mila'),
               segment('новый текст'), segment('Thank you for watching')]
        with fake_voice() as (voice, whisper):
            for rejected in bad:
                whisper.transcribe.return_value = {'segments': [segment(fast + ' сьогодні'), rejected]}
                self.assertEqual(voice.careful(audio, fast_text=fast), fast)
            # A legitimate English phrase rejected on script still survives in fast text.
            whisper.transcribe.return_value = {'segments': [segment('перевір цей'), segment('please check the project')]}
            mixed = 'перевір цей запит please check the project'
            self.assertEqual(voice.careful(audio, fast_text=mixed), mixed)
            whisper.transcribe.return_value = {'segments': [segment(fast + ' сьогодні')]}
            self.assertEqual(voice.careful(audio, fast_text=fast), fast + ' сьогодні')
        self.assertEqual(retain_fast('one two three four five', 'one two three four five six', True), 'one two three four five six')

    def test_file_keeps_only_rejected_piece_fast_and_uses_piece_language(self):
        fast = [dict(start=0, end=1, text='зроби review у GitHub для DataKit'),
                dict(start=1, end=2, text='Please check the project tomorrow')]
        with fake_voice() as (voice, whisper), \
                patch.object(voice, 'load_pcm16', return_value=np.full(32000, 1000, np.int16)), \
                patch.object(voice, 'pieces', return_value=[(0, 16000), (16000, 32000)]):
            whisper.transcribe.side_effect = [
                {'segments': [segment(fast[0]['text'] + ' сьогодні'), segment('новый')]},
                {'segments': [segment('Please check the project today', start=.1, end=.9)]}]
            out = voice.Readers().read_file_whisper('fake', lang='en', fast_segments=fast)
            self.assertEqual(out[0], fast[0])
            self.assertEqual(out[1], dict(start=1.1, end=1.9, text='Please check the project today'))
            self.assertEqual([c.kwargs['language'] for c in whisper.transcribe.call_args_list], ['uk', 'en'])

    def test_file_empty_and_unknown_fast_are_distinct(self):
        with fake_voice() as (voice, whisper), \
                patch.object(voice, 'load_pcm16', return_value=np.full(16000, 1000, np.int16)):
            whisper.transcribe.return_value = {'segments': [segment('valid'), segment('bad', compression_ratio=3)]}
            self.assertEqual(voice.Readers().read_file_whisper('fake', fast_segments=[]), [])
            whisper.transcribe.assert_not_called()
            out = voice.Readers().read_file_whisper('fake')
            self.assertEqual([s['text'] for s in out], ['valid'])
            out = voice.Readers().read_file_whisper('fake', fast_text='one two three four five')
            self.assertEqual(out, [dict(start=0, end=1, text='one two three four five')])

    def test_file_speech_gate_keeps_known_fast_piece(self):
        with fake_voice() as (voice, whisper), \
                patch.object(voice, 'load_pcm16', return_value=np.zeros(16000, np.int16)):
            self.assertEqual(voice.Readers().read_file_whisper('fake', fast_text='known real words'),
                             [dict(start=0, end=1, text='known real words')])
            whisper.transcribe.assert_not_called()


if __name__ == '__main__':
    unittest.main()

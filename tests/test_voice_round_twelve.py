"""Synthetic segments/audio and inert model doubles; no personal files or services."""
import unittest
from unittest.mock import patch

import numpy as np

from test_voice_guard import fake_voice, segment
from voice_language import prompt_echo


class RoundTwelve(unittest.TestCase):
    def test_empty_and_silence_drops_keep_careful_in_take_and_file(self):
        fast, better = 'перевір цей проєкт завтра', 'перевір цей проєкт сьогодні'
        harmless = [segment(' '), {}, segment('...', compression_ratio=3),
                    segment('noise', no_speech_prob=.9, avg_logprob=-2),
                    # Silence wins even when its text would trigger another guard.
                    segment('Names: новый 漢字', no_speech_prob=.9, avg_logprob=-2)]
        with fake_voice() as (voice, whisper), \
                patch.object(voice, 'load_pcm16', return_value=np.full(16000, 1000, np.int16)):
            for tail in harmless:
                with self.subTest(tail=tail):
                    whisper.transcribe.return_value = {'segments': [segment(better, start=.1, end=.8), tail]}
                    self.assertFalse(voice.rejected_words([tail], 'uk'))
                    self.assertEqual(voice.careful(np.full(16000, .02, np.float32), fast_text=fast), better)
                    self.assertEqual(voice.Readers().read_file_whisper('synthetic', fast_text=fast),
                                     [dict(start=.1, end=.8, text=better)])

    def test_rejected_words_keep_fast_in_take_and_file(self):
        fast, better = 'перевір цей проєкт завтра', 'перевір цей проєкт сьогодні докладно'
        with fake_voice() as (voice, whisper), \
                patch.object(voice, 'load_pcm16', return_value=np.full(16000, 1000, np.int16)):
            voice.HINT = 'Glossary: Amber, Birch, Cedar, Delta.'
            bad = [segment('реальні слова', compression_ratio=3), segment('так ' * 5),
                   segment('слова', tokens=[7] * 6), segment('новый'), segment('漢字'),
                   segment('please check this project'), segment('Names: Person'),
                   segment('Amber, Birch, Cedar, Delta')]
            for tail in bad:
                with self.subTest(tail=tail):
                    whisper.transcribe.return_value = {'segments': [segment(better), tail]}
                    self.assertTrue(voice.rejected_words([tail], 'uk', voice.HINT, fast))
                    self.assertEqual(voice.careful(np.full(16000, .02, np.float32), fast_text=fast), fast)
                    self.assertEqual(voice.Readers().read_file_whisper('synthetic', fast_text=fast),
                                     [dict(start=0, end=1, text=fast)])

    def test_echo_labels_or_four_ordered_comma_space_terms(self):
        hint = ('Names: Mila, Sava, Ira, Maya. Glossary: Kyiv, Lviv, Odesa, Kharkiv, '
                'Slack, Telegram, WhatsApp, Claude, Claude Code, Codex, GitHub.')
        for text in ('Kyiv, Lviv, Odesa', 'Slack, Telegram, WhatsApp', 'Claude, Claude, Claude',
                     'Names of the files are here',
                     'Names are here: Mila', 'Kyiv Lviv Odesa Kharkiv',
                     'Kyiv, Lviv, Odesa and Kharkiv', 'Kharkiv, Odesa, Lviv, Kyiv',
                     'Kyiv, Lviv, Lviv, Kharkiv', 'Kyiv,  Lviv, Odesa, Kharkiv',
                     'Kyiv, Lviv, Odesa, Kharkivwood', 'Claude, Claude, Claude, Claude'):
            self.assertFalse(prompt_echo(text, hint), text)
        for text in ('Glossary: anything', 'Glossary words are useful',
                     'Names: anything', 'Kyiv, Lviv, Odesa, Kharkiv',
                     'Перевір Kyiv, Lviv, Odesa, Kharkiv.', 'Mila, Sava, Ira, Maya',
                     'Claude, Claude Code, Codex, GitHub', 'Kyiv, Odesa, Slack, WhatsApp'):
            self.assertTrue(prompt_echo(text, hint), text)
        self.assertFalse(prompt_echo('Names of the files are here', None))
        self.assertTrue(prompt_echo('Names: Person', None))
        self.assertFalse(prompt_echo('Kyiv, Lviv, Odesa, Kharkiv', hint, by_terms=False))

    def test_glossary_echo_without_colon(self):
        for by_terms in (True, False):
            for text in ('Glossary, . Glossary, .', 'Glossary Sina Glossary Sina',
                         'Glossary', 'gLoSsArY words', '«GLOSSARY» words',
                         'Here glossary appears, then GLOSSARY again'):
                with self.subTest(text=text, by_terms=by_terms):
                    self.assertTrue(prompt_echo(text, None, by_terms=by_terms))
            for text in ('Names of the files are here', 'The glossary is useful',
                         'Glossarywood', 'Glossarywood Glossarywood'):
                self.assertFalse(prompt_echo(text, None, by_terms=by_terms), text)

    def test_standalone_bilingual_file_keeps_english_and_term_lists(self):
        hint = 'Glossary: Amber, Birch, Cedar, Delta.'
        good = [segment('Привіт, перевірмо проєкт.', start=.1, end=.3),
                segment("Let's review the pull request today", start=.3, end=.6),
                segment('Amber, Birch, Cedar, Delta', start=.6, end=.9)]
        bad = [segment('noise', no_speech_prob=.9, avg_logprob=-2),
               segment('bad', compression_ratio=3), segment('wait ' * 5),
               segment('text', tokens=[7] * 6), segment('Names: Person')]
        bad += [segment(text) for text in ('漢字', '한글', 'عربي', 'ы', 'э', 'ъ', 'ё')]
        with fake_voice() as (voice, whisper), \
                patch.object(voice, 'load_pcm16', return_value=np.full(16000, 1000, np.int16)):
            voice.HINT = hint
            whisper.transcribe.return_value = {'segments': good + bad}
            for lang in ('uk', 'en', None):
                with self.subTest(lang=lang):
                    out = voice.Readers().read_file_whisper('synthetic', lang=lang)
                    self.assertEqual(out, [dict(start=s['start'], end=s['end'], text=s['text']) for s in good])
            # The same English segment with fast fallback still uses the take guard.
            self.assertEqual(voice.whisper_rejection(good[1], 'uk', fast_text='привіт'), 'script')

    def test_standalone_policy_is_per_piece_not_per_file(self):
        with fake_voice() as (voice, whisper), \
                patch.object(voice, 'load_pcm16', return_value=np.full(32000, 1000, np.int16)), \
                patch.object(voice, 'pieces', return_value=[(0, 16000), (16000, 32000)]):
            english = 'Please check the project today'
            whisper.transcribe.return_value = {'segments': [segment(english)]}
            # Untimed full-file text is not a fallback for either of these pieces.
            out = voice.Readers().read_file_whisper('synthetic', lang='uk', fast_text='привіт усім')
            self.assertEqual([s['text'] for s in out], [english, english])
            self.assertEqual([s['start'] for s in out], [0, 1])


if __name__ == '__main__':
    unittest.main()

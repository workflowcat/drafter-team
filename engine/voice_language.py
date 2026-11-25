"""Pure text checks shared by the voice readers and offline comparison report."""
import re
import unicodedata


def text_words(text):
    return re.findall(r"[^\W_]+(?:['’ʼ][^\W_]+)*", unicodedata.normalize('NFC', text).casefold())


def letter_scripts(text):
    counts = {}
    for char in unicodedata.normalize('NFC', text):
        if not char.isalpha() or char == 'ʼ':
            continue
        name = unicodedata.name(char, '')
        script = next((s for s in ('LATIN', 'CYRILLIC') if s in name), 'OTHER')
        counts[script] = counts.get(script, 0) + 1
    return counts


def fast_language(text):
    """Count words, not term lengths: >=30% Cyrillic is Ukrainian.

    Mixed text below that threshold stays unknown; English requires no Cyrillic.
    Numbers alone do not vote for a language.
    """
    scripts = [letter_scripts(w) for w in text_words(text or '')]
    scripts = [s for s in scripts if s]
    cyr = sum('CYRILLIC' in s for s in scripts)
    if scripts and cyr * 10 >= len(scripts) * 3:
        return 'uk'
    if scripts and not cyr and all('LATIN' in s and 'OTHER' not in s for s in scripts):
        return 'en'
    return None


PINS = ('uk', 'en')


def pin_value(raw):
    """The pin frame's text: "uk" or "en"; anything else (empty included) clears it."""
    raw = (raw or '').strip().lower()
    return raw if raw in PINS else None


def pinned_plan(pin, fast_text):
    """Which reader a take's final text comes from (17 November 2026, research item 4).

    No pin, or nothing said: the fast text (Parakeet). A pin equal to the language the fast text is in: the fast
    text, Parakeet already heard it right. A pin the fast text does not match (another language, or mixed below
    the 30% line): Whisper reads the same audio with language=pin. Never a translation: Whisper only transcribes,
    and its guards (wrong script, Russian letters, prompt echo, loops) still keep the fast text.
    """
    if pin_value(pin) is None or not (fast_text or '').strip():
        return 'fast'
    return 'fast' if fast_language(fast_text) == pin_value(pin) else 'careful'


def russian_letters(text):
    return any(c in unicodedata.normalize('NFC', text).casefold() for c in 'ыэъё')


def prompt_echo(text, prompt, *, by_terms=True):
    text = unicodedata.normalize('NFC', text).casefold()
    if (re.match(r'^\W*(?:glossary\b|names:)', text)
            or len(re.findall(r'\bglossary\b', text)) >= 2):
        return True
    if not by_terms:
        return False
    # Preserve hint order and exact comma-space separators. Three names, repeated
    # names, and ordinary speech mentioning glossary terms are not echoes.
    terms = []
    for match in re.finditer(r'\b(?:Glossary|Names):\s*(.*?)(?=\.\s|$)', prompt or '', re.IGNORECASE):
        for term in match.group(1).split(','):
            term = unicodedata.normalize('NFC', term.strip().rstrip('.')).casefold()
            if term and term not in terms:
                terms.append(term)
    if not terms:
        return False
    term = r"(?<![\w'’ʼ])(?:" + '|'.join(re.escape(t) for t in sorted(terms, key=len, reverse=True)) + r")(?![\w'’ʼ])"
    order = {t: i for i, t in enumerate(terms)}
    previous, run = None, 0
    for match in re.finditer(term, text):
        if (previous and text[previous.end():match.start()] == ', '
                and order[previous.group()] < order[match.group()]):
            run += 1
        else:
            run = 1
        if run >= 4:
            return True
        previous = match
    return False


def retain_fast(careful_text, fast_text, rejected=False):
    """Same audio only: rejected words, empty output or under half keeps fast.

    `rejected` excludes empty segments and segments classified as no_speech.
    """
    if fast_text and (rejected or not careful_text.strip()
                      or len(text_words(careful_text)) * 2 < len(text_words(fast_text))):
        return fast_text
    return careful_text


def piece_text(segments, start, end):
    """Fast sentences overlapping this audio piece, never unrelated parts of the file."""
    return ' '.join(s['text'] for s in segments
                    if s['start'] < end and s['end'] > start)

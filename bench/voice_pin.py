"""The voice language pin on saved takes (17 November 2026, research item 4): numbers only, never text.

Reads the newest saved takes (data/audio/*.wav, 1.5-30 s, at most --takes), Parakeet first (the fast text, kept in
memory only), then Whisper on a sample: mixed takes (fast_language unknown: Cyrillic and Latin words, under 30%
Cyrillic) and Ukrainian and English controls. For each, Whisper today (language from the fast text, None when mixed)
and with the pin (language=uk, language=en), through the engine's own guards (voice.careful). Prints, per group and
read: the output's language (uk / en / mixed / none), how often the guards kept the fast text, the share of the fast
text's Latin and Cyrillic words still in the output (a word the pass changed script on is a translation sign), and
seconds per read. No ground truth: agreement and script, not accuracy.

  .venv/bin/python -B bench/voice_pin.py [--takes 400] [--mixed 30] [--controls 10]
"""
import argparse
import glob
import json
import os
from pathlib import Path
import sys
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'engine'))
CAP_GB = 3.0


def words_by_script(text, letter_scripts, text_words):
    lat, cyr = set(), set()
    for w in text_words(text or ''):
        s = letter_scripts(w)
        if 'CYRILLIC' in s: cyr.add(w)
        elif 'LATIN' in s: lat.add(w)
    return lat, cyr


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--takes', type=int, default=400)
    ap.add_argument('--mixed', type=int, default=30)
    ap.add_argument('--controls', type=int, default=10)
    ap.add_argument('--audio', type=Path, default=ROOT / 'data/audio')
    a = ap.parse_args()

    folder = Path(tempfile.mkdtemp())
    (folder / 'words.json').write_text('{"terms": []}')   # the same empty glossary for every read
    os.environ.update(HF_HUB_OFFLINE='1', DRAFTER_WORDS=str(folder / 'words.json'), DRAFTER_NAMES='0',
                      DRAFTER_VOICE_CAP_GB=str(CAP_GB))
    import voice   # starts the memory guard (CAP_GB)
    from voice_language import fast_language, letter_scripts, text_words, pinned_plan
    import numpy as np
    import wave

    files = sorted(glob.glob(str(a.audio / '*.wav')), key=os.path.getmtime)[-a.takes:]
    def load(f):
        with wave.open(f) as w:
            if w.getframerate() != 16000 or w.getnchannels() != 1: return None
            n = w.getnframes()
            if not 1.5 * 16000 <= n <= 30 * 16000: return None
            return np.frombuffer(w.readframes(n), dtype=np.int16).astype(np.float32) / 32768

    takes = [f for f in files if load(f) is not None]   # paths only: the audio is read again when used

    r = voice.Readers()
    m = r.warm()
    t = time.perf_counter()
    fast = [voice.read(m, load(x)) for x in takes]
    fast_s = (time.perf_counter() - t) / max(1, len(takes))
    del m
    r.drop('bench')   # one voice model at a time: Parakeet is gone before Whisper loads
    import gc, mlx.core as mx
    gc.collect(); mx.clear_cache()
    groups = {'mixed': [], 'uk': [], 'en': []}
    for x, f in zip(takes, fast):
        if not f.strip(): continue
        scripts = [letter_scripts(w) for w in text_words(f)]
        both = any('CYRILLIC' in s for s in scripts) and any('LATIN' in s for s in scripts)
        g = fast_language(f) or ('mixed' if both else None)
        if g in groups: groups[g].append((x, f))
    counts = {g: len(v) for g, v in groups.items()}
    picked = {'mixed': groups['mixed'][-a.mixed:], 'uk': groups['uk'][-a.controls:], 'en': groups['en'][-a.controls:]}

    out = {'takes read': len(takes), 'fast s/take': round(fast_s, 3), 'groups': counts, 'rows': {}}
    for g, items in picked.items():
        for name, pin in (('today', None), ('pin uk', 'uk'), ('pin en', 'en')):
            row = dict(n=0, uk=0, en=0, mixed=0, none=0, kept_fast=0, plan_fast=0, lat_kept=0.0, cyr_kept=0.0, s=0.0)
            for x, f in items:
                row['n'] += 1
                if pin and pinned_plan(pin, f) == 'fast':
                    row['plan_fast'] += 1   # the app would keep Parakeet's text: no Whisper pass at all
                t = time.perf_counter()
                o = voice.careful(load(x), '', fast_text=f, pin=pin)
                row['s'] += time.perf_counter() - t
                if o == f: row['kept_fast'] += 1
                lang = fast_language(o)
                row[lang or ('none' if not o.strip() else 'mixed')] += 1
                lat, cyr = words_by_script(f, letter_scripts, text_words)
                ol, oc = words_by_script(o, letter_scripts, text_words)
                if lat: row['lat_kept'] += len(lat & ol) / len(lat)
                if cyr: row['cyr_kept'] += len(cyr & oc) / len(cyr)
            if row['n']:
                for k in ('lat_kept', 'cyr_kept', 's'): row[k] = round(row[k] / row['n'], 2)
            out['rows'][f'{g} / {name}'] = row
    print(json.dumps(out, indent=1))


if __name__ == '__main__':
    main()

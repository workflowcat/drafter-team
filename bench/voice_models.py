"""Compare current and smaller voice model pairs offline, in isolated processes.

Explicit audio paths only, --synthetic (macOS say), or --noise (numpy + say). Never scans recordings or
reads personal settings/dictionary. Default pairs: current, BF16 + Whisper q4.
Each pair/take gets its own process, one reader at a time, 3 decimal GB footprint
and MLX limits, a 0.1 s watchdog and 180 s deadline (same as smoke_voice.py).
Word difference is disagreement with today's reader, NOT accuracy against truth.
"""
import argparse
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import time
import unicodedata

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'engine'))
from voice_settings import FAST, CAREFUL, FAST_BF16, CAREFUL_Q4
from voice_language import fast_language, letter_scripts, russian_letters

CAP_BYTES = 3_000_000_000
TIMEOUT = 180
TEXTS = {
    'en': 'The quick brown fox jumps over the lazy dog. Please send the meeting notes tomorrow morning.',
    'uk': 'Будь ласка, надішли нотатки із зустрічі завтра вранці. Ми обговоримо новий проєкт у пʼятницю.',
}


def words(text):
    text = unicodedata.normalize('NFC', text).casefold()
    text = text.translate(str.maketrans({'’': "'", 'ʼ': "'", '‘': "'", '`': "'"}))
    return re.findall(r"[^\W_]+(?:'[^\W_]+)*", text, re.UNICODE)


def difference(reference, hypothesis):
    """Levenshtein word edits, O(hypothesis words) memory. Empty ref => undefined rate."""
    ref, hyp = words(reference), words(hypothesis)
    previous = list(range(len(hyp) + 1))
    for i, left in enumerate(ref, 1):
        current = [i]
        for j, right in enumerate(hyp, 1):
            current.append(min(previous[j] + 1, current[-1] + 1,
                               previous[j - 1] + (left != right)))
        previous = current
    edits = previous[-1]
    return dict(edits=edits, reference_words=len(ref),
                rate=edits / len(ref) if ref else (0.0 if not hyp else None))


def say_voices(output):
    result = {}
    for line in output.splitlines():
        match = re.match(r'^(.+?)\s+([a-z]{2,3})[_-][A-Z0-9]+\s+#', line)
        if match:
            name, language = match.groups()
            result.setdefault(language, name.strip())
            if name.strip() == 'Samantha':
                result[language] = 'Samantha'
    return result


def synthetic(folder):
    listed = subprocess.run(['say', '-v', '?'], capture_output=True, text=True, check=True, timeout=30)
    voices = say_voices(listed.stdout)
    if 'en' not in voices:
        raise RuntimeError('No English say voice available')
    clips = []
    for lang, text in TEXTS.items():
        if lang not in voices:
            print(f'SKIP synthetic {lang}: no say voice installed', flush=True)
            continue
        aiff, wav = folder / f'{lang}.aiff', folder / f'{lang}.wav'
        subprocess.run(['say', '-v', voices[lang], '-r', '165', '-o', str(aiff), text], check=True, timeout=30)
        subprocess.run(['afconvert', '-f', 'WAVE', '-d', 'LEI16@16000', '-c', '1', str(aiff), str(wav)],
                       check=True, timeout=30)
        print(f'Synthetic {lang} ({voices[lang]}), expected: {text}', flush=True)
        clips.append(wav)
    return clips


def noise(folder):
    """Deterministic non-speech probes, 16 kHz PCM16, written only in the temp set.

    These are approximations, not recordings or a validated speech detector set.
    Clicks and cough exceed the energy gate to exercise the readers as well.
    """
    import numpy as np
    import wave
    rate = 16000
    rng = np.random.default_rng(9)
    silence = np.zeros(2 * rate)
    room = rng.normal(0, 0.0007, 10 * rate)
    clicks = rng.normal(0, 0.0007, 6 * rate)
    pulse = np.arange(int(0.025 * rate)) / rate
    for start in np.arange(0.3, 5.8, 0.4):
        at = int(start * rate)
        clicks[at:at + len(pulse)] += rng.normal(0, 0.25, len(pulse)) * np.exp(-pulse / 0.008)
    cough = rng.normal(0, 0.0007, 4 * rate)
    burst = rng.normal(0, 1, int(0.45 * rate))
    burst = np.convolve(burst, np.ones(5) / 5, mode='same')
    cough[rate:rate + len(burst)] += 0.4 * burst * np.hanning(len(burst))
    clips = []
    for name, samples in (('silence', silence), ('room', room), ('clicks', clicks), ('cough', cough)):
        path = folder / f'noise-{name}.wav'
        with wave.open(str(path), 'wb') as output:
            output.setnchannels(1)
            output.setsampwidth(2)
            output.setframerate(rate)
            output.writeframes((np.clip(samples, -1, 1) * 32767).astype('<i2').tobytes())
        clips.append(path)
    return clips


def worker(fast, careful, wav, mode, folder):
    """Called only in the manual child process; imports/loads MLX here, never in parent/tests."""
    settings = folder / 'settings.json'
    settings.write_text(json.dumps({'voiceFast': fast, 'voiceCareful': careful}))
    glossary = folder / 'words.json'
    glossary.write_text('{"terms": []}')
    os.environ.update(HF_HUB_OFFLINE='1', TRANSFORMERS_OFFLINE='1',
                      HF_HUB_DISABLE_TELEMETRY='1', HF_HUB_DISABLE_IMPLICIT_TOKEN='1',
                      DRAFTER_VOICE_SETTINGS=str(settings), DRAFTER_WORDS=str(glossary),
                      DRAFTER_VOICE_CAP_GB=str(CAP_BYTES / 2**30),
                      DRAFTER_FILE_CAP_GB=str(CAP_BYTES / 2**30))
    import guard
    guard.start(CAP_BYTES / 2**30, every=0.1, hold=1, spike=0)
    import threading
    import resource
    import mlx.core as mx
    mx.set_memory_limit(CAP_BYTES)
    import voice
    mx.set_memory_limit(CAP_BYTES)
    mx.set_cache_limit(64 * 2**20)
    decoded_languages = []

    def offline_read(load):
        result = load()  # missing cache is a failure; never a download
        if isinstance(result, dict) and result.get('language'):
            decoded_languages.append(result['language'])
        return result

    voice.online = offline_read
    readers = voice.Readers()
    rejected = []
    careful_reads = [0]
    raw_text, kept_text = [], []
    keep_segments = voice.whisper_segments

    def audited_segments(segments, language=None, prompt=None, fast_text=None, **policy):
        careful_reads[0] += 1
        raw_text.extend(s.get('text', '').strip() for s in segments)
        for segment in segments:
            reason = voice.whisper_rejection(segment, language, prompt, fast_text, **policy)
            if reason and segment.get('text', '').strip():
                rejected.append(dict(segment=segment, reason=reason))
        kept = keep_segments(segments, language, prompt, fast_text, **policy)
        kept_text.extend(s['text'].strip() for s in kept)
        return kept

    voice.whisper_segments = audited_segments
    fast_text = None  # unknown on error; empty on a successful no-speech read
    fast_segments = None
    failed = False
    for reader, model in (('fast', fast), ('careful', careful)):
        rejected.clear()
        careful_reads[0] = 0
        raw_text.clear()
        kept_text.clear()
        decoded_languages.clear()
        mx.reset_peak_memory()
        peak = [guard.footprint_gb() * 2**30]
        stop = threading.Event()

        def sample():
            while not stop.is_set():
                peak[0] = max(peak[0], guard.footprint_gb() * 2**30)
                stop.wait(0.05)

        sampler = threading.Thread(target=sample, daemon=True)
        sampler.start()
        started = time.perf_counter()
        result = dict(event='result', reader=reader, model=model, mode=mode)
        try:
            if mode == 'file':
                # Explicit readers, not read_file's fallback: attribute text to the
                # right model. Both paths retain the same hard 3 GB cap.
                segments = (readers.read_file_fast(str(wav)) if reader == 'fast'
                            else readers.read_file_whisper(str(wav), fast_text=fast_text, fast_segments=fast_segments))
                if reader == 'fast':
                    fast_segments = segments
                text = ' '.join(s['text'] for s in segments)
                result['segments'] = segments
            else:
                audio = voice.load_pcm16(str(wav)).astype('float32') / 32768
                try:
                    if reader == 'fast':
                        take = voice.Take(readers.warm())
                        try:
                            take.add(audio)
                            text = take.text()  # production chunking / speech gate / soft speech boost
                        finally:
                            del take  # don't retain Parakeet during the careful pass
                    else:
                        text = readers.careful(audio, fast_text=fast_text)
                finally:
                    del audio
            mx.synchronize()
            result.update(status='ok', text=text)
            if reader == 'fast':
                fast_text = text
        except Exception as error:
            failed = True
            result.update(status='error', error=f'{type(error).__name__}: {error}')
        finally:
            result['guard_dropped'] = list(rejected)
            if reader == 'careful':
                result['raw_careful_text'] = ' '.join(raw_text)
                result['guarded_careful_text'] = ' '.join(kept_text)
                result['decoded_languages'] = list(decoded_languages)
                result['kept_fast'] = (mode == 'take' and bool(fast_text)
                                       and result.get('text') == fast_text
                                       and result.get('text') != result['guarded_careful_text'])
                result['whisper_reads'] = careful_reads[0]
                result['guard_skipped'] = result.get('status') == 'ok' and careful_reads[0] == 0
            stop.set()
            sampler.join(timeout=1)
            result.update(seconds=round(time.perf_counter() - started, 3),
                          peak_footprint_GB=round(max(peak[0], guard.footprint_gb() * 2**30) / 1e9, 3),
                          peak_mlx_GB=round(mx.get_peak_memory() / 1e9, 3),
                          process_peak_rss_GB=round(resource.getrusage(resource.RUSAGE_SELF).ru_maxrss / 1e9, 3))
            print(json.dumps(result, ensure_ascii=False), flush=True)
            readers.drop('benchmark reader done')
    return 1 if failed else 0


def run_pair(name, fast, careful, wav, mode, folder):
    command = [sys.executable, '-B', str(Path(__file__).resolve()), '--worker',
               '--pair', name, fast, careful, '--mode', mode, '--folder', str(folder), str(wav)]
    # Stream through temp files so a killed/timed-out pair keeps its completed reader.
    with tempfile.TemporaryFile(mode='w+') as stdout, tempfile.TemporaryFile(mode='w+') as stderr:
        try:
            completed = subprocess.run(command, stdout=stdout, stderr=stderr, timeout=TIMEOUT)
            reason = f'worker exit {completed.returncode}' if completed.returncode else ''
        except subprocess.TimeoutExpired:
            reason = f'watchdog timeout after {TIMEOUT} s'
        stdout.seek(0)
        rows = {}
        for line in stdout:
            try:
                result = json.loads(line)
            except ValueError:
                continue  # progress output from a library
            if isinstance(result, dict) and result.get('event') == 'result':
                rows[result['reader']] = result
        stderr.seek(0)
        detail = stderr.read()[-2000:]
    if reason:
        print(f'{name} / {wav.name}: {reason}\n{detail}', file=sys.stderr, flush=True)
    for reader, model in (('fast', fast), ('careful', careful)):
        if reader not in rows:
            rows[reader] = dict(reader=reader, model=model, status='error', error=reason or 'missing result')
        rows[reader].update(pair=name, take=str(wav), mode=mode)
        # An exit failure after results is not silently treated as a successful pair.
        if reason:
            rows[reader]['process_error'] = reason
    return list(rows.values())


def compare(rows):
    baseline = {(r['take'], r.get('mode'), r['reader']): r for r in rows if r['pair'] == 'current'}
    fast = {(r['take'], r.get('mode'), r['pair']): r for r in rows if r['reader'] == 'fast'}
    for row in rows:
        ref = baseline.get((row['take'], row.get('mode'), row['reader']))
        if row['status'] == 'ok' and ref and ref['status'] == 'ok':
            row['difference'] = difference(ref['text'], row['text'])
        flags = []
        if row.get('guard_dropped'):
            flags.append('blocked')
            flags.extend(sorted({s['reason'] for s in row['guard_dropped']}))
        if row.get('kept_fast'):
            flags.append('kept fast')
        quick = fast.get((row['take'], row.get('mode'), row['pair']))
        if row['reader'] == 'careful' and row['status'] == 'ok' and quick and quick['status'] == 'ok':
            # Raw is before both guard and fast retention, so rejected translations
            # remain visible. No inference: Latin-language changes need listening.
            raw = row.get('raw_careful_text', row['text'])
            row['script_differs'] = bool(raw.strip() and quick['text'].strip()) and (
                set(letter_scripts(raw)) != set(letter_scripts(quick['text'])))
            expected = fast_language(quick['text'])
            observed = set(row.get('decoded_languages', []))
            inferred = fast_language(raw)
            if inferred:
                observed.add(inferred)
            if russian_letters(raw):
                observed.add('ru')
            row['language_differs'] = bool(raw.strip() and expected and observed - {expected})
        if row['status'] == 'ok' and row['text'].strip():
            if row.get('expected_speech') is False:
                flags.append('noise text')
            if ref and ref['status'] == 'ok' and not ref['text'].strip():
                flags.append('current empty')
        row['made_up'] = flags
    return rows


def table(rows):
    print('\nWord difference vs current reader; case/punctuation ignored; not ground-truth WER.')
    print('Seconds include loading + reading. Footprint/MLX peaks are per reader; RSS is process lifetime.')
    print('Skipped means no Whisper decoding; its memory/time is not a model measurement.')
    print('Made up: blocked + reasons = rejected segments; kept fast = take fallback; noise text = non-speech output; current empty = review flag.')
    compared = [r for r in rows if 'script_differs' in r]
    print(f"Careful vs fast, before guard/fallback: {sum(r['script_differs'] for r in compared)} script, "
          f"{sum(r['language_differs'] for r in compared)} language, "
          f"{sum(r['script_differs'] or r['language_differs'] for r in compared)} either / {len(compared)} rows.")
    print('Language flags use decoder language, script majority and Russian letters; same-script translations need listening.')
    print('| Take | Pair | Reader | Word diff | Edits / ref words | Seconds | Peak footprint GB | Peak MLX GB | Made up | Status |')
    print('|---|---|---|---:|---:|---:|---:|---:|---|---|')
    for row in rows:
        delta = row.get('difference')
        rate = f"{delta['rate']:.1%}" if delta and delta['rate'] is not None else 'n/a'
        edits = f"{delta['edits']} / {delta['reference_words']}" if delta else 'n/a'
        values = [Path(row['take']).name, row['pair'], row['reader'], rate, edits,
                  row.get('seconds', '-'), row.get('peak_footprint_GB', '-'), row.get('peak_mlx_GB', '-'),
                  ', '.join(row.get('made_up', [])) or ('no' if row['status'] == 'ok' else 'n/a'),
                  row.get('error') or row.get('process_error') or ('skipped' if row.get('guard_skipped') else row['status'])]
        print('| ' + ' | '.join(str(v).replace('|', '\\|').replace('\n', ' ') for v in values) + ' |')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('takes', nargs='*', type=Path, help='Only these files are read; no directory scanning')
    parser.add_argument('--synthetic', action='store_true')
    parser.add_argument('--noise', action='store_true', help='Temp numpy non-speech set plus synthetic speech')
    parser.add_argument('--pair', nargs=3, action='append', metavar=('NAME', 'FAST', 'CAREFUL'),
                        help='Repeat for candidate pairs; current baseline is always included')
    parser.add_argument('--mode', choices=('take', 'file'), default='take',
                        help='take: dictation final text; file: chunked call/file readers')
    parser.add_argument('--json', type=Path, help='Optional local report, including full text (may be private)')
    parser.add_argument('--worker', action='store_true', help=argparse.SUPPRESS)
    parser.add_argument('--folder', type=Path, help=argparse.SUPPRESS)
    args = parser.parse_args()
    if args.worker:
        if len(args.takes) != 1 or not args.pair or len(args.pair) != 1 or args.folder is None:
            parser.error('worker requires one pair, one take and a temporary folder')
        _, fast, careful = args.pair[0]
        return worker(fast, careful, args.takes[0], args.mode, args.folder)
    if not args.takes and not args.synthetic and not args.noise:
        parser.error('give explicit audio paths, --synthetic or --noise')
    if sys.platform != 'darwin':
        parser.error('macOS with Apple-silicon Metal is required')
    pairs = [('current', FAST, CAREFUL)] + (args.pair or [('smaller', FAST_BF16, CAREFUL_Q4)])
    if len({p[0] for p in pairs}) != len(pairs):
        parser.error('pair names must be unique; current is reserved')
    takes = [p.expanduser().resolve() for p in args.takes]
    if any(not p.is_file() for p in takes):
        parser.error('every take must be an existing file')
    if args.json and args.json.exists():
        parser.error('--json output already exists; choose a new path')
    rows = []
    print(f'Python: {sys.executable}\n3 GB cap, {TIMEOUT} s per pair/take; cached models only; mode={args.mode}.', flush=True)
    with tempfile.TemporaryDirectory(prefix='drafter-voice-models-') as temp:
        folder = Path(temp)
        generated = []
        if args.synthetic or args.noise:
            generated = synthetic(folder)
            takes += generated
        noise_clips = noise(folder) if args.noise else []
        takes += noise_clips
        for wav in takes:
            for name, fast, careful in pairs:
                print(f'Reading {wav} / {name}', flush=True)
                with tempfile.TemporaryDirectory(dir=folder) as child:
                    results = run_pair(name, os.path.expanduser(fast), os.path.expanduser(careful),
                                       wav, args.mode, Path(child))
                rows.extend(results)
                for result in results:
                    result['expected_speech'] = True if wav in generated else False if wav in noise_clips else None
                    if wav in generated and result['status'] == 'ok' and not result['text'].strip():
                        result.update(status='error', error='No text for synthetic speech')
                    print(json.dumps(result, ensure_ascii=False), flush=True)
    compare(rows)
    if args.json:
        with args.json.open('x') as output:
            json.dump(dict(cap_bytes=CAP_BYTES, timeout_s=TIMEOUT, rows=rows), output, ensure_ascii=False, indent=2)
    table(rows)
    return int(any(r['status'] != 'ok' or r.get('process_error') for r in rows))


if __name__ == '__main__':
    sys.exit(main())

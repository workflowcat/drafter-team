"""Manual, offline voice parity smoke. Run only on a Mac with working Metal.

Synthesizes one public English sentence in a temporary directory, then gives each
reader its own process. No server, settings, dictionary or personal recordings.
"""
import argparse
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]
TEXT = 'The quick brown fox jumps over the lazy dog. Please send the meeting notes tomorrow morning.'
CAP_BYTES = 3_000_000_000


def worker(reader, wav):
    os.environ.update(HF_HUB_OFFLINE='1', TRANSFORMERS_OFFLINE='1',
                      HF_HUB_DISABLE_TELEMETRY='1', HF_HUB_DISABLE_IMPLICIT_TOKEN='1',
                      DRAFTER_VOICE_CAP_GB=str(CAP_BYTES / 2**30),
                      DRAFTER_FILE_CAP_GB=str(CAP_BYTES / 2**30),
                      DRAFTER_VOICE_SETTINGS=str(wav.parent / 'settings.json'),
                      DRAFTER_WORDS=str(wav.parent / 'words.json'))
    sys.path.insert(0, str(ROOT / 'engine'))
    import guard
    guard.start(CAP_BYTES / 2**30, every=0.1, hold=1, spike=0)
    import threading
    import resource
    peak = [0.0]
    stop = threading.Event()

    def sample():
        while not stop.is_set():
            peak[0] = max(peak[0], guard.footprint_gb() * 2**30)
            stop.wait(0.05)

    thread = threading.Thread(target=sample, daemon=True)
    thread.start()
    started = time.perf_counter()
    import mlx.core as mx
    mx.set_memory_limit(CAP_BYTES)
    import voice
    # voice sets its normal cache size on import; the smoke uses the smaller cap.
    mx.set_memory_limit(CAP_BYTES)
    mx.set_cache_limit(64 * 2**20)
    # Keep voice's loading/transcription functions, but prohibit its online retry.
    voice.online = lambda load: load()
    audio = voice.load_pcm16(str(wav)).astype('float32') / 32768
    readers = voice.Readers()
    loaded = time.perf_counter()
    try:
        if reader == 'parakeet':
            text = voice.read(readers.warm(), audio)
        else:
            text = readers.careful(audio)
        mx.synchronize()
        elapsed = time.perf_counter() - loaded
        result = dict(reader=reader, text=text, load_and_transcribe_s=round(elapsed, 3),
                      total_s=round(time.perf_counter() - started, 3),
                      peak_mlx_GB=round(mx.get_peak_memory() / 1e9, 3),
                      peak_footprint_GB=round(max(peak[0], guard.footprint_gb() * 2**30) / 1e9, 3),
                      peak_rss_GB=round(resource.getrusage(resource.RUSAGE_SELF).ru_maxrss / 1e9, 3))
        print(json.dumps(result, ensure_ascii=False), flush=True)
        if not text.strip():
            raise RuntimeError(f'{reader} returned no text for the speech clip')
    finally:
        readers.drop('smoke done')
        stop.set()
        thread.join(timeout=1)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--worker', choices=('parakeet', 'whisper'), help=argparse.SUPPRESS)
    parser.add_argument('--wav', type=Path, help=argparse.SUPPRESS)
    args = parser.parse_args()
    if args.worker:
        if args.wav is None:
            parser.error('--worker requires --wav')
        worker(args.worker, args.wav)
        return
    if sys.platform != 'darwin':
        parser.error('macOS say, afconvert and Apple-silicon Metal are required')
    with tempfile.TemporaryDirectory(prefix='drafter-voice-smoke-') as folder:
        folder = Path(folder)
        aiff, wav = folder / 'speech.aiff', folder / 'speech.wav'
        (folder / 'words.json').write_text('{"terms": []}')
        subprocess.run(['say', '-v', 'Samantha', '-r', '165', '-o', str(aiff), TEXT], check=True, timeout=30)
        subprocess.run(['afconvert', '-f', 'WAVE', '-d', 'LEI16@16000', '-c', '1', str(aiff), str(wav)],
                       check=True, timeout=30)
        import wave
        with wave.open(str(wav)) as audio:
            assert (audio.getframerate(), audio.getnchannels(), audio.getsampwidth()) == (16000, 1, 2)
        print(f'Python: {sys.executable}\nExpected: {TEXT}\nCap: 3 GB; cached models only; 180 s per reader.', flush=True)
        failed = []
        for reader in ('parakeet', 'whisper'):
            try:
                subprocess.run([sys.executable, '-B', str(Path(__file__).resolve()), '--worker', reader,
                                '--wav', str(wav)], check=True, timeout=180)
            except (subprocess.CalledProcessError, subprocess.TimeoutExpired) as error:
                print(f'FAIL {reader}: {error}', file=sys.stderr, flush=True)
                failed.append(reader)
        if failed:
            sys.exit(1)


if __name__ == '__main__':
    main()

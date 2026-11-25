"""Compile the production process controller with inert app stubs. No model, mic, clipboard or user data."""
from pathlib import Path
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[1]
source = (root / 'app/Voice.swift').read_text()
controller = source[source.index('final class VoiceEngine {'):source.index('/// Where the time goes')]
with tempfile.TemporaryDirectory(prefix='drafter-lifecycle-') as tmp:
    scratch = Path(tmp)
    (scratch / 'engine').mkdir()
    (scratch / 'data').mkdir()
    (scratch / 'VoiceEngine.swift').write_text('import Foundation\nimport CoreGraphics\n' + controller)
    (scratch / 'engine/voice.py').write_text('''import sys, struct, os, json, time
while True:
    header = sys.stdin.buffer.read(5)
    if len(header) != 5: break
    kind, n = struct.unpack('<BI', header)
    sys.stdin.buffer.read(n * 4)
    if kind == 250: print(json.dumps({'draft': 'ready'}), flush=True)
    elif kind == 0: sys.stdout.write('{"draft":'); sys.stdout.flush()
    elif kind == 254: os._exit(137)
    elif kind == 255:
        time.sleep(0.2)
        print(json.dumps({'text': 'synthetic final', 'loud': False}), flush=True)
''')
    binary = scratch / 'checks'
    subprocess.run(['swiftc', '-swift-version', '5', str(scratch / 'VoiceEngine.swift'),
                    str(root / 'tests/voice_engine_lifecycle.swift'),
                    str(root / 'app/VoiceFlowRules.swift'),   # WakeBuffer: the audio kept while the engine starts
                    str(root / 'app/VoiceWarmRules.swift'),   # the background touch's timing (voice warm round)
                    '-o', str(binary)], check=True)
    subprocess.run([str(binary), str(scratch), sys.executable], check=True, timeout=90)

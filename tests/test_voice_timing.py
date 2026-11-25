"""engine/voice_timing.py: speech start and words-after-speech on made-up sound (no model, no data/)."""
import sys
from pathlib import Path
import numpy as np
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "engine"))
from voice_timing import SpeechClock, RATE

quiet = np.zeros(RATE // 2, np.float32)                       # 0.5 s room
loud = (0.1 * np.sin(np.arange(RATE) / 5)).astype(np.float32)  # 1 s speech-level tone

c = SpeechClock()
for chunk in np.array_split(np.concatenate([quiet, loud]), 23):   # odd chunk sizes: frames cross chunk edges
    c.add(chunk)
assert abs(c.at - RATE // 2) <= 480, c.at
assert c.first_words(200, "") is None, "no words, no number"
ms = c.first_words(200, "hello")
assert 1150 <= ms <= 1250, ms        # 1 s of speech heard + 200 ms read
assert c.first_words(200, "hello again") is None, "once per take"

c = SpeechClock(); c.add(quiet); c.add(quiet)
assert c.at is None and c.first_words(100, "words") is None, "no speech start, no number"

c = SpeechClock(); c.add(loud[:100]); c.add(loud[100:])
assert c.at == 0, c.at
print("voice timing: ok")

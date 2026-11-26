"""Voice model selection, kept free of MLX and import-time file reads."""
import json
import os
from pathlib import Path

FAST = "mlx-community/parakeet-tdt-0.6b-v3"
CAREFUL = "mlx-community/whisper-large-v3-turbo"
CAREFUL_Q4 = "mlx-community/whisper-large-v3-turbo-q4"
FAST_BF16 = "~/.cache/drafter-models/parakeet-tdt-0.6b-v3-bf16"


def model_names(settings):
    if not isinstance(settings, dict):
        settings = {}

    def name(key, default):
        value = settings.get(key)
        return os.path.expanduser(value.strip()) if isinstance(value, str) and value.strip() else default

    return name("voiceFast", FAST), name("voiceCareful", CAREFUL)


def load_models(path=None):
    # Same JSON / empty-on-failure convention as server.settings_load. The override
    # isolates manual benchmarks from personal settings; selection is per process.
    if path is None:
        path = os.environ.get("DRAFTER_VOICE_SETTINGS")
    if path is None:
        # resolved at call time (DRAFTER_DATA, engine/data_dir.py), so importing this module reads nothing
        import sys
        sys.path.insert(0, str(Path(__file__).resolve().parent))
        from data_dir import data_dir
        path = data_dir() / "settings.json"
    path = Path(path)
    try:
        settings = json.loads(path.read_text())
    except (OSError, ValueError):
        settings = {}
    return model_names(settings)

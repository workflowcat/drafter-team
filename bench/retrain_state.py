"""Replay cutoff and independent weekly attempt time."""
from pathlib import Path


def last_retrain(root):
    try:
        return float((Path(root) / "data/review/last-retrain").read_text().strip())
    except FileNotFoundError:
        # First rolling replay: the current layer must never have seen its lines.
        try: return (Path(root) / "data/adapters/adapters.safetensors").stat().st_mtime
        except FileNotFoundError: return 0.0


def last_attempt(root):
    try:
        return float((Path(root) / "data/review/last-retrain-attempt").read_text().strip())
    except FileNotFoundError:
        return last_retrain(root)

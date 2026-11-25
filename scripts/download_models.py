"""Download weights only. Never imports MLX or loads a model.

    .venv/bin/python scripts/download_models.py            # the text model (typing)
    .venv/bin/python scripts/download_models.py --voice    # also the two voice readers (dictation, calls)
"""
import os, sys
os.environ["HF_HUB_DISABLE_TELEMETRY"] = "1"
os.environ["HF_HUB_DISABLE_IMPLICIT_TOKEN"] = "1"
from huggingface_hub import snapshot_download

# Observed cached snapshot sizes on 1 November 2026; upstream main may change.
TEXT = [
    ("mlx-community/Qwen3-1.7B-4bit", 984015687),
]
VOICE = [
    ("mlx-community/parakeet-tdt-0.6b-v3", 2508532829),
    ("mlx-community/whisper-large-v3-turbo", 1613979758),
]
MODELS = TEXT + VOICE

if __name__ == "__main__":
    pick = MODELS if "--voice" in sys.argv else TEXT
    print("Approximate download sizes (no models loaded):", flush=True)
    for repo, size in pick:
        print(f"  {repo}: {size / 1e9:.2f} GB", flush=True)
    print(f"Total: {sum(s for _, s in pick) / 1e9:.2f} GB; existing cache files are reused.", flush=True)
    if pick is TEXT: print("Voice readers skipped (dictation and calls): add --voice for them.", flush=True)
    for repo, _ in pick:
        snapshot_download(repo_id=repo)

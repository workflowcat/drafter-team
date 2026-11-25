"""Optional manual check: one cached Qwen model, no server or personal adapter."""
import os
from pathlib import Path
import sys

os.environ["HF_HUB_OFFLINE"] = "1"
os.environ["TRANSFORMERS_OFFLINE"] = "1"
os.environ["DRAFTER_CAP_GB"] = "3"
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "engine"))
import guard
# Physical footprint watchdog in addition to the MLX allocation limit.
guard.start(3, spike=0)
from model import Model
import mlx.core as mx
mx.set_memory_limit(3 * 10**9)
mx.set_cache_limit(64 * 2**20)
model = Model("mlx-community/Qwen3-1.7B-4bit")
print(model.oneshot(model.encode("The capital of France is"), max_tokens=4))
print(f"Peak MLX: {mx.get_peak_memory() / 1e9:.2f} GB")

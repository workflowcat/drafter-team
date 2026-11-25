"""Parity round (2026-11-15): what a "Personal style" change costs in the engine, and that 100 % after a change is
exactly today's model. Run it under the guard, one model, mains power:

    .venv/bin/python -B bench/weights/guarded.py 4.0 bench/parity_strength.py

Loads the live model with his layer (merged, as the engine does), reads the head, then sets the strength to 50 %, 0 %
and back to 100 %, timing each, and compares the next-token logits on a made-up line with those before. Numbers only."""
import json, os, sys, time
from pathlib import Path

os.environ.setdefault("DRAFTER_CAP_GB", "3.0"); os.environ["DRAFTER_HEAD_CACHE"] = ""; os.environ.setdefault("HF_HUB_OFFLINE", "1")
ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "engine"))
import mlx.core as mx
from model import Model
from prompt import Builder

m = Model("mlx-community/Qwen3-1.7B-4bit", ROOT / "data/adapters")
b = Builder(m, "raw")
m.warm(b.head_ids)
ids, _ = b.ids("Привіт, я завтра буду в офісі після обіду, тож можемо", "Beeper", "Zebra")


def logits():
    with m.lock:
        tail = m._feed(ids)                          # the cache holds the head (and what is shared), the rest is read here
        out = m.model(mx.array([tail]), cache=m.cache)[0, -1]
        mx.eval(out); m.ids = list(ids); return out


before = logits()
out = {"merged_layers": len(m.fused), "mlx_gb": round(mx.get_active_memory() / 2**30, 2)}
for s in (0.5, 0.0, 1.0):
    out[f"set_{int(s * 100)}_s"] = round(m.set_strength(s), 2)
    out[f"mlx_gb_{int(s * 100)}"] = round(mx.get_active_memory() / 2**30, 2)
    l = logits()
    out[f"top_{int(s * 100)}_same"] = int(mx.argmax(l).item() == mx.argmax(before).item())
    out[f"max_diff_{int(s * 100)}"] = round(float(mx.max(mx.abs(l - before)).item()), 4)
out["peak_gb"] = round(mx.get_peak_memory() / 2**30, 2)
print(json.dumps(out))

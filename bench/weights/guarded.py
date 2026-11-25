"""Run one model step under the memory watchdog (engine/guard.py), in this process only.

    .venv/bin/python -B bench/weights/guarded.py <cap GB> <script.py | -m module> [args ...]
The guard exits the process when its footprint stays over the cap for 2 s or ever passes cap + 0.5 GB (the Mac froze
on 2026-10-06 during a local model run)."""
import atexit, os, runpy, sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent.parent
sys.path.insert(0, str(ROOT / "engine"))
import guard

cap, target, rest = float(sys.argv[1]), sys.argv[2], sys.argv[3:]
guard.start(cap)
if os.environ.get("DRAFTER_MLX_CACHE_GB"):   # smaller MLX buffer cache: keeps the footprint under the cap (Qwen3.5 training)
    import mlx.core as _mx
    _mx.set_cache_limit(int(float(os.environ["DRAFTER_MLX_CACHE_GB"]) * 2**30))


@atexit.register
def _peak():
    """mlx-lm 0.32 training no longer prints its peak memory: every guarded step prints MLX's own at exit."""
    mx = sys.modules.get("mlx.core")
    if mx is not None: print(f"Peak mem {mx.get_peak_memory() / 2**30:.3f} GB (guarded step)", flush=True)

if target == "-m":
    module, rest = rest[0], rest[1:]
    sys.argv = [module, *rest]
    runpy.run_module(module, run_name="__main__", alter_sys=True)
else:
    sys.path.insert(0, str(Path(target).resolve().parent))
    sys.argv = [target, *rest]
    runpy.run_path(target, run_name="__main__")

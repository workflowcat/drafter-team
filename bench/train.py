"""LoRA on Andrii's writing, with the memory guard (the Mac froze on 2026-10-06 during a local model run).

    .venv/bin/python bench/train.py <iters> [extra mlx_lm.lora args]
Adapter goes to data/adapters/ (local only). Drafter's typing help must be paused while it runs."""
import os, runpy, sys
from pathlib import Path
ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "engine"))
import guard
sys.path.insert(0, str(ROOT / "bench"))
from lora_recipe import RECIPE      # the same numbers as the remote trainer (bench/remote/train_lora.py)
R = RECIPE
guard.start(float(os.environ.get("DRAFTER_TRAIN_CAP_GB", "6.0")))
iters = sys.argv[1] if len(sys.argv) > 1 else "20"
sys.argv = ["mlx_lm.lora", "--model", "mlx-community/Qwen3-1.7B-4bit", "--train", "--data", str(ROOT / "data/train"),
            "--adapter-path", str(ROOT / "data/adapters"), "--iters", iters, "--batch-size", str(R["batch"]),
            "--num-layers", str(R["layers"]), "--learning-rate", str(R["lr"]), "--max-seq-length", str(R["max_seq"]),
            "--steps-per-report", "10", "--steps-per-eval", str(R["steps_per_eval"]), "--val-batches", str(R["val_batches"]),
            "--save-every", "200", "--seed", str(R["seed"]), *sys.argv[2:]]
runpy.run_module("mlx_lm.lora", run_name="__main__")

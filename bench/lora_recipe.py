"""His layer's recipe, one place for both trainers: bench/train.py (MLX on the Mac, mlx_lm.lora) and
bench/remote/train_lora.py (PyTorch + PEFT on your server, through bench/remote_train.py). Same numbers, so the two
layers compare. rank and scale are mlx_lm's defaults (lora_parameters rank 8, scale 20); PEFT gets lora_alpha =
scale * rank. layers = the last N transformer blocks, every linear in each (q k v o gate up down for Qwen3)."""
RECIPE = {"iters": 1500, "batch": 4, "lr": 1e-4, "rank": 8, "scale": 20.0, "dropout": 0.0, "layers": 16,
          "max_seq": 256, "seed": 7, "steps_per_eval": 200, "val_batches": 20}

# the MLX repo the engine types with -> its Hugging Face base (the full-precision weights the 4-bit copy came from)
HF_BASE = {"mlx-community/Qwen3-1.7B-4bit": "Qwen/Qwen3-1.7B",
           "mlx-community/Qwen3-4B-Instruct-2507-4bit": "Qwen/Qwen3-4B-Instruct-2507"}
SHORT = {"1.7b": "mlx-community/Qwen3-1.7B-4bit", "4b": "mlx-community/Qwen3-4B-Instruct-2507-4bit"}

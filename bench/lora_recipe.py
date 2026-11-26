"""The user's layer's recipe, one place: bench/train.py (MLX on the Mac, mlx_lm.lora) reads it. rank and scale are mlx_lm's
defaults (lora_parameters rank 8, scale 20). layers = the last N transformer blocks, every linear in each
(q k v o gate up down for Qwen3)."""
RECIPE = {"iters": 1500, "batch": 4, "lr": 1e-4, "rank": 8, "scale": 20.0, "dropout": 0.0, "layers": 16,
          "max_seq": 256, "seed": 7, "steps_per_eval": 200, "val_batches": 20}

"""His layer (LoRA) on the Hugging Face base, CPU only, inside the drafter-train container (bench/remote/Dockerfile) on
your server (integrations.server). Started by bench/remote_train.py on the Mac; never run on the Mac.

    python /app/train_lora.py --base Qwen/Qwen3-4B-Instruct-2507 --data /work/data --out /work/out \
        --iters 1500 --batch 4 --lr 1e-4 --rank 8 --scale 20 --layers 16 --max-seq 256 --seed 7 --threads 10

Mirrors mlx_lm.lora as bench/train.py runs it, so the layers compare:
- rows {"text"}: tokenizer.encode(text), EOS appended when missing, cut at --max-seq tokens;
- batches: rows sorted by length, cut into batches of --batch (the remainder dropped), batch order shuffled each pass
  with numpy seeded once by --seed;
- loss: next-token cross entropy over each row's real tokens, averaged over the batch's tokens (mlx_lm also scores one
  padding token after the end of each row; that quirk is left out here);
- LoRA on every linear (q k v o gate up down) of the last --layers blocks, rank r, PEFT lora_alpha = scale * r so the
  output scale is MLX's `scale`; A uniform +-1/sqrt(in) (PEFT's kaiming default, the same range as MLX), B zero;
- Adam as mlx.optimizers.Adam: betas 0.9/0.999, eps 1e-8, NO bias correction, constant lr.
The base runs in bfloat16, the LoRA weights in float32. Out: PEFT adapter (adapter_model.safetensors,
adapter_config.json, float32), meta.json (time, peak memory, losses), train.log."""
import argparse, json, os, resource, time
from pathlib import Path

import numpy as np
import torch

KEYS = ["q_proj", "k_proj", "v_proj", "o_proj", "gate_proj", "up_proj", "down_proj"]


class MlxAdam(torch.optim.Optimizer):
    """mlx.optimizers.Adam with its default bias_correction=False: p -= lr * m / (sqrt(v) + eps)."""
    def __init__(self, params, lr, betas=(0.9, 0.999), eps=1e-8):
        super().__init__(params, dict(lr=lr, betas=betas, eps=eps))

    @torch.no_grad()
    def step(self):
        for g in self.param_groups:
            b1, b2 = g["betas"]
            for p in g["params"]:
                if p.grad is None: continue
                st = self.state[p]
                if not st: st["m"], st["v"] = torch.zeros_like(p), torch.zeros_like(p)
                st["m"].mul_(b1).add_(p.grad, alpha=1 - b1)
                st["v"].mul_(b2).addcmul_(p.grad, p.grad, value=1 - b2)
                p.addcdiv_(st["m"], st["v"].sqrt().add_(g["eps"]), value=-g["lr"])


def read_rows(path):
    return [json.loads(l)["text"] for l in Path(path).read_text(encoding="utf-8").splitlines() if l.strip()]


def encode(tok, texts, max_seq):
    out = []
    for t in texts:
        ids = tok.encode(t)
        if not ids or ids[-1] != tok.eos_token_id: ids.append(tok.eos_token_id)
        out.append(ids[:max_seq])
    return out


def batches(rows, size):
    idx = sorted(range(len(rows)), key=lambda i: len(rows[i]))
    if len(rows) < size: raise SystemExit(f"{len(rows)} rows, fewer than one batch of {size}")
    return [idx[i:i + size] for i in range(0, len(idx) - size + 1, size)]


def tensors(rows, ids, pad):
    n = max(len(rows[i]) for i in ids)
    x = torch.full((len(ids), n), pad, dtype=torch.long)
    mask = torch.zeros((len(ids), n), dtype=torch.bool)
    for j, i in enumerate(ids):
        x[j, :len(rows[i])] = torch.tensor(rows[i]); mask[j, :len(rows[i])] = True
    return x, mask


def loss_of(model, x, mask):
    logits = model(input_ids=x[:, :-1], attention_mask=mask[:, :-1].long()).logits.float()
    tgt, m = x[:, 1:], mask[:, 1:]
    ce = torch.nn.functional.cross_entropy(logits.reshape(-1, logits.shape[-1]), tgt.reshape(-1), reduction="none")
    n = m.sum()
    return (ce * m.reshape(-1)).sum() / n, int(n)


def peak_gb():
    """(container cgroup peak, this process's max RSS) in GB; the cgroup file is missing on older kernels."""
    cg = None
    for f in ("/sys/fs/cgroup/memory.peak", "/sys/fs/cgroup/memory/memory.max_usage_in_bytes"):
        try: cg = round(int(Path(f).read_text()) / 1e9, 2); break
        except (OSError, ValueError): pass
    return cg, round(resource.getrusage(resource.RUSAGE_SELF).ru_maxrss * 1024 / 1e9, 2)


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--base", required=True); p.add_argument("--revision")
    p.add_argument("--data", default="/work/data"); p.add_argument("--out", default="/work/out")
    for k, t, d in (("iters", int, 1500), ("batch", int, 4), ("lr", float, 1e-4), ("rank", int, 8), ("scale", float, 20.0),
                    ("layers", int, 16), ("max-seq", int, 256), ("seed", int, 7), ("threads", int, 10),
                    ("steps-per-eval", int, 200), ("val-batches", int, 20), ("report", int, 10)):
        p.add_argument("--" + k, type=t, default=d)
    p.add_argument("--grad-checkpoint", action="store_true", help="less memory, about a third more time")
    a = p.parse_args()
    out = Path(a.out); out.mkdir(parents=True, exist_ok=True)
    log_f = open(out / "train.log", "a", buffering=1)

    def log(s):
        line = f"{time.strftime('%H:%M:%S')} {s}"
        print(line, flush=True); log_f.write(line + "\n")

    torch.set_num_threads(a.threads); torch.manual_seed(a.seed); np.random.seed(a.seed)
    from transformers import AutoModelForCausalLM, AutoTokenizer
    from peft import LoraConfig, get_peft_model
    t0 = time.time()
    tok = AutoTokenizer.from_pretrained(a.base, revision=a.revision)
    model = AutoModelForCausalLM.from_pretrained(a.base, revision=a.revision, torch_dtype=torch.bfloat16, low_cpu_mem_usage=True)
    total = model.config.num_hidden_layers
    if a.layers > total: raise SystemExit(f"--layers {a.layers} > {total} blocks")
    model = get_peft_model(model, LoraConfig(r=a.rank, lora_alpha=a.scale * a.rank, lora_dropout=0.0, bias="none",
                                             target_modules=KEYS, layers_to_transform=list(range(total - a.layers, total)),
                                             task_type="CAUSAL_LM"))
    for n, w in model.named_parameters():
        if w.requires_grad: w.data = w.data.float()
    if a.grad_checkpoint: model.gradient_checkpointing_enable(gradient_checkpointing_kwargs={"use_reentrant": False})
    trainable = sum(w.numel() for w in model.parameters() if w.requires_grad)
    log(f"loaded {a.base} in {time.time() - t0:.0f} s: {total} blocks, LoRA on the last {a.layers}, {trainable:,} trainable, {a.threads} threads")

    pad = tok.pad_token_id if tok.pad_token_id is not None else tok.eos_token_id
    train = encode(tok, read_rows(Path(a.data) / "train.jsonl"), a.max_seq)
    valid = encode(tok, read_rows(Path(a.data) / "valid.jsonl"), a.max_seq)
    tb = batches(train, a.batch)
    vb = batches(valid, min(a.batch, len(valid)))[:a.val_batches] if valid else []
    log(f"rows: {len(train)} train ({sum(map(len, train)):,} tokens), {len(valid)} valid; {len(tb)} batches a pass")

    def val_loss():
        if not vb: return None
        model.eval(); tot = n = 0
        with torch.no_grad():
            for ids in vb:
                l, k = loss_of(model, *tensors(valid, ids, pad)); tot += float(l) * k; n += k
        model.train(); return round(tot / n, 4)

    opt = MlxAdam([w for w in model.parameters() if w.requires_grad], lr=a.lr)
    model.train()
    order, losses, toks, t_train = [], [], 0, time.time()
    first_val = val_loss(); log(f"step 0 val loss {first_val}")
    t_train = time.time()
    for step in range(1, a.iters + 1):
        if not order: order = list(np.random.permutation(len(tb)))
        x, mask = tensors(train, tb[order.pop(0)], pad)
        loss, n = loss_of(model, x, mask)
        opt.zero_grad(set_to_none=True); loss.backward(); opt.step()
        losses.append(float(loss)); toks += n
        if step % a.report == 0 or step == a.iters:
            el = time.time() - t_train
            log(f"step {step}/{a.iters} loss {np.mean(losses[-a.report:]):.4f} {el / step:.2f} s/step {toks / el:.0f} tok/s "
                f"eta {(a.iters - step) * el / step / 3600:.2f} h peak {peak_gb()}")
        if step % a.steps_per_eval == 0 and step != a.iters: log(f"step {step} val loss {val_loss()}")
    seconds = time.time() - t_train
    last_val = val_loss(); log(f"step {a.iters} val loss {last_val}")
    model.save_pretrained(str(out), safe_serialization=True)
    cg, rss = peak_gb()
    meta = {"base": a.base, "revision": a.revision, "num_hidden_layers": total, "iters": a.iters, "seconds": round(seconds),
            "sec_per_step": round(seconds / a.iters, 3), "load_seconds": round(t_train - t0), "tokens": toks,
            "peak_gb_cgroup": cg, "peak_gb_rss": rss, "train_rows": len(train), "valid_rows": len(valid),
            "loss_first": round(losses[0], 4), "loss_last10": round(float(np.mean(losses[-10:])), 4),
            "val_first": first_val, "val_last": last_val, "threads": a.threads, "torch": torch.__version__,
            "recipe": {k: getattr(a, k) for k in ("batch", "lr", "rank", "scale", "layers", "max_seq", "seed")}}
    (out / "meta.json").write_text(json.dumps(meta, indent=1))
    log(f"done: {a.iters} steps in {seconds / 3600:.2f} h, peak {cg} GB (cgroup), {rss} GB (rss)")


if __name__ == "__main__":
    os.environ.setdefault("TOKENIZERS_PARALLELISM", "false")
    main()

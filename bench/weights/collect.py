"""One forward pass over lines with the model as Drafter runs it (base + his layer merged, the engine's prompt head
warm), storing what the bias fit or the steering vectors need. A model step: run it only through guarded.py (the
orchestrators bias.py and steer.py do). One model, this process only.

    guarded.py 4 bench/weights/collect.py logits --lines L.jsonl --out X.npz [--model M] [--adapter A] [--min-count 5]
    guarded.py 4 bench/weights/collect.py hidden --lines L.jsonl --out X.npz --layer 14 [--generic 300]

Lines: JSON rows {"text", "app", "group"}. Each line is fed as the engine would see it with no screen text: the head,
then "[App] (style)\\n" + the line; only the line's own tokens count.
logits: for every position, the log-probability (after the engine's Russian-letter mask) of each candidate token (the
  tokens written >= min-count times in the lines), the token written and its log-probability.
hidden: per line, the mean output of block `layer` over the line's tokens; plus the mean norm of one token's state.
  --generic N first writes N lines with his layer off and no head (the model's own voice, same app tags, sampled at
  temperature 0.8), group "generic"; their text is never stored."""
import argparse, json, os, sys, time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent.parent
sys.path[:0] = [str(ROOT / "engine"), str(ROOT / "bench/weights")]
os.environ.setdefault("HF_HUB_OFFLINE", "1")
os.environ.pop("DRAFTER_TWEAKS", None)          # measure the model itself

ap = argparse.ArgumentParser()
ap.add_argument("mode", choices=["logits", "hidden"])
ap.add_argument("--lines", required=True)
ap.add_argument("--out", required=True)
ap.add_argument("--model", default="mlx-community/Qwen3-1.7B-4bit")
ap.add_argument("--adapter", default="data/adapters")
ap.add_argument("--min-count", type=int, default=5)
ap.add_argument("--most", type=int, default=2000)
ap.add_argument("--max-positions", type=int, default=32000)
ap.add_argument("--layer", type=int, default=14)
ap.add_argument("--generic", type=int, default=0)
ap.add_argument("--cap", type=float, default=3.0)
a = ap.parse_args()
os.environ["DRAFTER_CAP_GB"] = str(a.cap)

import numpy as np
import mlx.core as mx
from mlx_lm.models.cache import trim_prompt_cache, make_prompt_cache
from mlx_lm.sample_utils import make_sampler
from model import Model
from prompt import Builder, tail
import biasfit

t0 = time.time()
rows = [json.loads(l) for l in Path(a.lines).read_text().splitlines() if l.strip()]
adapter = (ROOT / a.adapter) if a.adapter and a.adapter != "none" else None
m = Model(a.model, adapter)
b = Builder(m, "raw")
m.warm(b.head_ids)
head = len(m.ids)
print(f"loaded in {time.time() - t0:.1f}s, head {head} tokens, {len(rows)} lines", flush=True)


def split_ids(text, app):
    pre = m.encode(tail("", app))
    full = m.encode(tail("", app) + text)
    return (pre, full) if full[: len(pre)] == pre and len(full) > len(pre) else (None, None)


def forward(full):
    """Logits for `full` fed after the warm head; the cache goes back to the head after."""
    out = m.model(mx.array(full)[None], cache=m.cache)
    mx.eval(out)
    trim_prompt_cache(m.cache, len(full))
    return out[0]


if a.mode == "logits":
    toks = []
    for r in rows:
        pre, full = split_ids(r["text"], r.get("app") or "Claude")
        toks.append((pre, full))
    cand = biasfit.candidates([f[len(p):] for p, f in toks if p is not None], a.min_count, a.most)
    cidx = mx.array(cand)
    cand_lp, ys, y_lp, kinds, skipped, vocab = [], [], [], [], 0, 0
    import tweaks
    for r, (pre, full) in zip(rows, toks):
        if pre is None: skipped += 1; continue
        logits = forward(full)[len(pre) - 1: len(full) - 1].astype(mx.float32)
        logits = logits + m.russian_mask(logits.shape)
        lp = logits - mx.logsumexp(logits, axis=-1, keepdims=True)
        vocab = int(lp.shape[-1])
        y = mx.array(full[len(pre):])
        cl, yl = lp[:, cidx], mx.take_along_axis(lp, y[:, None], axis=-1)[:, 0]
        mx.eval(cl, yl)
        cand_lp.append(np.array(cl).astype(np.float16)); y_lp.append(np.array(yl)); ys.append(np.array(y))
        kinds += [tweaks.kind_of(r.get("app"))] * len(full[len(pre):])
        mx.clear_cache()
        if sum(len(x) for x in ys) >= a.max_positions: break
    np.savez(a.out, cand=cand, cand_lp=np.concatenate(cand_lp), y=np.concatenate(ys), y_lp=np.concatenate(y_lp),
             kind=np.array(kinds), vocab=np.array(vocab), meta=json.dumps({"skipped": skipped, "head": head}))
    print(f"logits: {sum(len(x) for x in ys)} positions, {len(cand)} candidate tokens, {skipped} lines skipped, "
          f"{time.time() - t0:.0f}s, peak {mx.get_peak_memory() / 2**30:.2f} GB", flush=True)
else:
    block = m.model.layers[a.layer]
    base_cls, seen = type(block), {}

    def capture(self, x, mask=None, cache=None):
        out = base_cls.__call__(self, x, mask, cache)
        seen["h"] = out
        return out
    block.__class__ = type("Capture", (base_cls,), {"__call__": capture})

    if a.generic:
        apps = [r.get("app") or "Claude" for r in rows] or ["Claude"]
        sampler, made = make_sampler(temp=0.8), []
        eos = set(getattr(m.tok, "eos_token_ids", None) or [m.tok.eos_token_id])
        m.lora(False)
        for i in range(a.generic):
            app = apps[i % len(apps)]
            ids, cache, out = m.encode(tail("", app)), make_prompt_cache(m.model), []
            y = mx.array(ids)
            for _ in range(40):
                logits = m.model(y[None], cache=cache)[:, -1, :]
                t = int(sampler(logits - mx.logsumexp(logits, axis=-1, keepdims=True)).item())
                if t in eos or "\n" in m.tok.decode([t]): break
                out.append(t); y = mx.array([t])
            text = m.tok.decode(out).strip()
            if len(text.split()) >= 3: made.append({"text": text, "app": app, "group": "generic"})
            del cache; mx.clear_cache()
        m.lora(True)
        rows = rows + made
        print(f"generic lines: {len(made)} of {a.generic}", flush=True)

    H, groups, langs, norms, skipped = [], [], [], [], 0
    for r in rows:
        pre, full = split_ids(r["text"], r.get("app") or "Claude")
        if pre is None: skipped += 1; continue
        forward(full)
        h = seen["h"][0, len(pre):].astype(mx.float32)
        mean, norm = h.mean(0), mx.linalg.norm(h, axis=-1).mean()
        mx.eval(mean, norm)
        H.append(np.array(mean)); norms.append(float(norm.item())); groups.append(r.get("group") or ""); langs.append(r.get("lang") or "")
        mx.clear_cache()
    np.savez(a.out, H=np.stack(H), group=np.array(groups), lang=np.array(langs), token_norm=np.array(float(np.mean(norms))),
             layer=np.array(a.layer), meta=json.dumps({"skipped": skipped, "head": head}))
    print(f"hidden: {len(H)} lines at block {a.layer}, token norm {np.mean(norms):.1f}, {skipped} skipped, "
          f"{time.time() - t0:.0f}s, peak {mx.get_peak_memory() / 2**30:.2f} GB", flush=True)

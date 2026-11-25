"""Mid-line round (2026-11-15): record what the live model writes at every key inside a gap of the mid-line set
(bench/fim.py sets), with each token's p and the p of the rest of the line's first token at the same step (engine/fim.py
reads it to end the ghost). One process, one model; run it under the guard (bench/fim.py rec does).

    DRAFTER_MID_FORM=none|after .venv/bin/python -B bench/weights/guarded.py 4.0 bench/fim_record.py --label L [--n 3]

-> data/bench/fim/<label>.jsonl: {"i", "pos", "heal", "rest_tok", "toks": [[text, p, p2, ms, piece, p_rest], ...]}"""
import argparse, json, os, sys, time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
ap = argparse.ArgumentParser()
ap.add_argument("--set", default="data/bench/fim/mid.json")
ap.add_argument("--label", required=True)
ap.add_argument("--n", type=int, default=100000)
ap.add_argument("--tokens", type=int, default=16)
ap.add_argument("--cap", type=float, default=3.0)
ap.add_argument("--adapter", default="data/adapters")
a = ap.parse_args()
os.environ["DRAFTER_CAP_GB"] = str(a.cap)
os.environ.setdefault("HF_HUB_OFFLINE", "1")
os.environ["DRAFTER_HEAD_CACHE"] = ""            # never touch the live engine's head file
sys.path.insert(0, str(ROOT / "engine")); sys.path.insert(0, str(ROOT / "bench"))

import mlx.core as mx
from mlx_lm.generate import generate_step
from model import Model
import prompt
from prompt import Builder
import know, words as words_mod, ngram
from retrain_state import last_retrain

items = json.loads((ROOT / a.set).read_text())[: a.n]
out_p = ROOT / "data/bench/fim" / f"{a.label}.jsonl"
out_p.parent.mkdir(parents=True, exist_ok=True)
boost = float(json.loads((ROOT / "data/gate.json").read_text()).get("boost", 0) or 0)
knowledge = know.Pack(ROOT / "data/know.json"); knowledge.reload(); knowledge.path = None
W = None
if boost:   # his words from before the held lines only, as typebench builds them
    W = words_mod.Words()
    for line in ngram.corpus(last_retrain(ROOT)):
        if not words_mod.RUSSIAN.search(line): W.add(line, rebuild=False)
    W.vocab = sorted(W.uni)

t = time.time()
m = Model("mlx-community/Qwen3-1.7B-4bit", ROOT / a.adapter)
b = Builder(m, "raw")
m.warm(b.head_ids)
print(f"{a.label}: form {prompt.MID_FORM}, loaded in {time.time() - t:.1f}s, boost {boost}", flush=True)
eos = set(getattr(m.tok, "eos_token_ids", None) or [m.tok.eos_token_id])
ru = lambda toks, logits: logits + m.russian_mask(logits.shape)


def record(before, app, context, after):
    ids, heal, stable = b.ids_stable(before, app, "", context, "", "", "", after)
    rest_tok = m.encode(after)[0] if after.strip() else None
    t0 = time.perf_counter()
    tail = m._feed(ids, stable); m.ids = list(ids)
    procs = ([m.healer(heal, len(tail))] if heal else []) + [ru]
    bp = m.booster(words_mod.boost_targets(W, before, heal, knowledge=knowledge, context=context, title=""), len(tail), boost) if W else None
    if bp: procs.append(bp)
    toks, out = [], []
    for tok, lp in generate_step(mx.array(tail), m.model, max_tokens=a.tokens + (6 if heal else 0), sampler=m.sampler,
                                 prompt_cache=m.cache, prefill_step_size=512, logits_processors=procs):
        tok = int(tok); m.ids.append(tok)
        top = mx.topk(lp, 2); mx.eval(top)
        vals = sorted([float(x) for x in top.tolist()], reverse=True)
        p = float(mx.exp(lp[tok])); p2 = float(mx.exp(mx.array(vals[1]))) if len(vals) > 1 else 0.0
        pr = float(mx.exp(lp[rest_tok])) if rest_tok is not None else 0.0
        ms = (time.perf_counter() - t0) * 1000
        if tok in eos: break
        out.append(tok)
        full = m.tok.decode(out)
        text = full[len(heal):] if heal and len(full) >= len(heal) and full.startswith(heal) else ("" if heal else full)
        toks.append([text, round(p, 4), round(p2, 4), round(ms, 1), m.tok.decode([tok]), round(pr, 4)])
        if "\n" in text or sum(1 for x in toks if x[0]) >= a.tokens: break
    return heal, rest_tok, toks


with out_p.open("w") as f:
    for i, it in enumerate(items):
        s, e = it["gap"]
        text, after = it["text"], it["text"][it["gap"][1]:]
        for pos in range(s, e + 1):
            heal, rt, toks = record(text[:pos], it["app"], it.get("context", ""), after)
            f.write(json.dumps({"i": i, "pos": pos, "heal": heal, "rest_tok": rt, "toks": toks}, ensure_ascii=False) + "\n")
        mx.clear_cache()
        if mx.get_peak_memory() / 2**30 > a.cap:
            print(f"stopped at item {i}: peak over the cap", flush=True); break
        if i % 20 == 19: print(f"  {i + 1} items, {time.time() - t:.0f}s, peak {mx.get_peak_memory() / 2**30:.2f} GB", flush=True)
print(f"{a.label}: {len(items)} items in {time.time() - t:.0f}s, peak {mx.get_peak_memory() / 2**30:.2f} GB", flush=True)

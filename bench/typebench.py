"""Record what a model would offer at EVERY letter of the fresh replay set, with each token's probability and time,
so any show/hide rule (bars, word count, a decision gate) can be scored offline without running the model again
(bench/typescore.py). Runs in its own process with its own memory cap; the running Drafter engine is not touched.

    .venv/bin/python bench/typebench.py <repo> [--adapter data/adapters] [--fmt raw|bare] [--n 100] [--tokens 8]
                                        [--set data/replay-fresh.json] [--label name] [--cap 3.0]

Output: data/bench/<label>.jsonl, one row per position:
  {"i": item, "pos": letters typed, "heal": half word re-spelled, "toks": [[text so far, p, p2, ms], ...], "prefill_ms": ...}
"""
import argparse, json, os, re, subprocess, sys, time
from pathlib import Path
from retrain_state import last_retrain

ROOT = Path(__file__).resolve().parent.parent
ap = argparse.ArgumentParser()
ap.add_argument("repo")
ap.add_argument("--adapter", default=None)
ap.add_argument("--fmt", default="raw")
ap.add_argument("--n", type=int, default=100)
ap.add_argument("--tokens", type=int, default=8)
ap.add_argument("--set", default="data/replay-fresh.json")
ap.add_argument("--label", default=None)
ap.add_argument("--cap", type=float, default=3.0, help="MLX memory limit for this process, GB")
ap.add_argument("--min-free", type=int, default=25, help="stop when system free memory falls under this %%")
ap.add_argument("--boost", type=float, default=None, help="mix his own next words in (Model.booster), this share")
ap.add_argument("--know", default="data/know.json", help="local knowledge pack path, or none")
ap.add_argument("--people", action="store_true", help="Beeper replies get his older messages in that chat (data/bench/people-fresh.json)")
ap.add_argument("--ctx-chars", type=int, default=None, help="keep only the last N characters of the screen context (the engine: 1000; 0 = none)")
ap.add_argument("--app", default=None, help="only the items from this app (Beeper, Claude)")
ap.add_argument("--notes", default="", help="parity round: a writing instruction for every line (engine/prompt.py notes)")
ap.add_argument("--every", type=int, default=1, help="parity round: only every Nth key of a line (short A/B runs)")
ap.add_argument("--strength", type=float, default=1.0, help="parity round: his layer's merge scale, 0..1")
ap.add_argument("--no-clip", action="store_true", help="parity round: leave the set's clip field out")
ap.add_argument("--no-stable", action="store_true", help="the old copy path: read the screen text again at every key")
a = ap.parse_args()
if a.boost is None:
    try: a.boost = float(json.loads((ROOT / "data/gate.json").read_text()).get("boost", 0))
    except (OSError, ValueError): a.boost = 0.0
os.environ["DRAFTER_CAP_GB"] = str(a.cap)      # model.py sets the MLX limits from this at import
os.environ.setdefault("HF_HUB_OFFLINE", "1")
sys.path.insert(0, str(ROOT / "engine"))

import mlx.core as mx
from mlx_lm.generate import generate_step
from model import Model
from prompt import Builder
import people
import know, words as words_mod
knowledge = know.Pack(None if a.know == "none" else ROOT / a.know)
knowledge.reload()
knowledge.path = None  # freeze this explicit snapshot for a reproducible recording

label = a.label or re.sub(r"[^\w.-]+", "_", a.repo.split("/")[-1] + ("+lora" if a.adapter else "") + ("" if a.fmt == "raw" else "-" + a.fmt))
out_p = ROOT / "data/bench" / f"{label}.jsonl"
out_p.parent.mkdir(exist_ok=True)
items = json.loads((ROOT / a.set).read_text())[: a.n]
sys.path.insert(0, str(ROOT / "bench"))
import typescore
sha = typescore.set_sha(ROOT / a.set)
typescore.SETS.mkdir(parents=True, exist_ok=True)
if not (typescore.SETS / f"{sha}.json").exists(): (typescore.SETS / f"{sha}.json").write_bytes((ROOT / a.set).read_bytes())
(ROOT / "data/bench" / f"{label}.meta.json").write_text(json.dumps({"set": a.set, "set_sha": sha, "repo": a.repo, "adapter": a.adapter,
    "tokens": a.tokens, "know": a.know, "know_sha": typescore.set_sha(ROOT / a.know) if a.know != "none" and (ROOT / a.know).exists() else None, "boost": a.boost, "people": a.people, "app": a.app, "ctx_chars": a.ctx_chars, "fused": os.environ.get("DRAFTER_LORA_FUSE", "1") == "1", "stable": not a.no_stable, "notes": a.notes, "every": a.every, "strength": a.strength, "clip": not a.no_clip, "made": time.strftime("%Y-%m-%d %H:%M")}, indent=1))


def free_pct():
    try:
        s = subprocess.run(["memory_pressure"], capture_output=True, text=True, timeout=10).stdout
        return int(re.search(r"free percentage: (\d+)%", s).group(1))
    except Exception: return 100


t = time.time()
m = Model(a.repo, ROOT / a.adapter if a.adapter else None, **({"strength": a.strength} if a.strength != 1.0 else {}))
b = Builder(m, a.fmt)
m.warm(b.head_ids)
print(f"{label}: loaded in {time.time() - t:.1f}s, head {len(b.head_ids)} tokens, mlx {mx.get_active_memory() / 2**30:.2f} GB", flush=True)
eos = set(getattr(m.tok, "eos_token_ids", None) or [m.tok.eos_token_id])
W = None
if a.boost:   # his words from before the fresh lines only (bench/ngram.py corpus), so nothing leaks
    sys.path.insert(0, str(ROOT / "bench"))
    import ngram, words as words_mod
    W = words_mod.Words()
    for line in ngram.corpus(last_retrain(ROOT)):
        if not words_mod.RUSSIAN.search(line): W.add(line, rebuild=False)
    W.vocab = sorted(W.uni)
    print(f"booster {a.boost}: {len(W.vocab)} words", flush=True)
def people_rows():
    d = json.loads((ROOT / "data/bench/people-fresh.json").read_text())
    if isinstance(d, dict):          # since 2026-11-01 tied to its set
        if d.get("set_sha") != sha: raise SystemExit("data/bench/people-fresh.json is for another fresh set: run bench/people_fresh.py")
        d = d["rows"]
    return {r["i"]: r["mine"] for r in d}
PEOPLE = people_rows() if a.people else {}
ru = lambda toks, logits: logits + m.russian_mask(logits.shape)


def record(before, app, context, mine="", title="", clip=""):
    ids, heal, stable = b.ids_stable(before, app, title, context, mine, clip, a.notes)
    t0 = time.perf_counter()   # before _feed (big-model round): restoring a copy is part of the key's time
    # big-model round: a cache that cannot be cut back keeps a copy after the screen text (Model._feed), as the
    # engine now does; for the live Qwen3 cache `stable` changes nothing
    tail = m._feed(ids, None if a.no_stable else stable); m.ids = list(ids)
    procs = ([m.healer(heal, len(tail))] if heal else []) + [ru]
    bp = m.booster(words_mod.boost_targets(W, before, heal, knowledge=knowledge, context=context, title=title), len(tail), a.boost) if W else None
    if bp: procs.append(bp)
    toks, out, prefill = [], [], None
    for tok, lp in generate_step(mx.array(tail), m.model, max_tokens=a.tokens + (6 if heal else 0), sampler=m.sampler,
                                 prompt_cache=m.cache, prefill_step_size=512, logits_processors=procs):
        tok = int(tok); m.ids.append(tok)
        top = mx.topk(lp, 2); mx.eval(top)
        vals = sorted([float(x) for x in top.tolist()], reverse=True)
        p = float(mx.exp(lp[tok])); p2 = float(mx.exp(mx.array(vals[1]))) if len(vals) > 1 else 0.0
        ms = (time.perf_counter() - t0) * 1000
        if prefill is None: prefill = ms
        if tok in eos: break
        out.append(tok)
        full = m.tok.decode(out)
        text = full[len(heal):] if heal and len(full) >= len(heal) and full.startswith(heal) else ("" if heal else full)
        toks.append([text, round(p, 4), round(p2, 4), round(ms, 1), m.tok.decode([tok])])
        if "\n" in text or sum(1 for x in toks if x[0]) >= a.tokens: break
    return heal, toks, prefill or 0.0


done = 0
with out_p.open("w") as f:
    for i, it in enumerate(items):
        if done and free_pct() < a.min_free:
            print(f"stopped at item {i}: system free memory under {a.min_free}%", flush=True); break
        if a.app and it["app"] != a.app: continue
        if a.ctx_chars is not None: it = {**it, "context": it.get("context", "")[-a.ctx_chars:] if a.ctx_chars else ""}
        mine = people.earlier(PEOPLE[i], it.get("context", "")) if i in PEOPLE else ""
        text = it["text"]
        for pos in range(1, len(text)):
            before = text[:pos]
            if len(before.strip()) < 2 or pos % a.every: continue
            heal, toks, pre = record(before, it["app"], it.get("context", ""), mine, it.get("title", ""), "" if a.no_clip else it.get("clip", ""))
            f.write(json.dumps({"i": i, "pos": pos, "heal": heal, "toks": toks, "max_tokens": a.tokens, "prefill_ms": round(pre, 1)}, ensure_ascii=False) + "\n")
        mx.clear_cache(); done += 1
        if mx.get_peak_memory() / 2**30 > a.cap:
            print(f"stopped at item {i}: peak {mx.get_peak_memory() / 2**30:.2f} GB over the cap", flush=True); break
        if i % 10 == 9: print(f"  {i + 1} items, {time.time() - t:.0f}s, peak {mx.get_peak_memory() / 2**30:.2f} GB, free {free_pct()}%", flush=True)
print(f"{label}: {done} items -> {out_p.relative_to(ROOT)} in {time.time() - t:.0f}s, peak {mx.get_peak_memory() / 2**30:.2f} GB, cache rebuilds {m.rebuilds}")

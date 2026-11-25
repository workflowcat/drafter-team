"""Where the engine's time per suggestion goes (2026-11-13 typing round), in its own process with its own memory cap
(the running engine is not touched). Replays the first letters of held-out lines key by key, the way the live engine
sees them (one prompt cache, a letter or two new per request), and times each step of a gated suggestion:
prompt prefill, first token, each further token, with the LoRA layer unmerged (today) or merged in memory, with and
without the word booster.

    .venv/bin/python bench/speed.py [--n 6] [--keys 40] [--cap 3.0]
"""
import argparse, json, os, statistics, sys, time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
ap = argparse.ArgumentParser()
ap.add_argument("--n", type=int, default=6)
ap.add_argument("--keys", type=int, default=40)
ap.add_argument("--cap", type=float, default=3.0)
ap.add_argument("--set", default="data/replay-fresh.json")
ap.add_argument("--round2", action="store_true", help="only the merged layer: the round-one rule and the AI-app tail")
a = ap.parse_args()
os.environ["DRAFTER_CAP_GB"] = str(a.cap); os.environ["DRAFTER_LORA_FUSE"] = "0"  # merged below, by hand
os.environ.setdefault("HF_HUB_OFFLINE", "1")
sys.path.insert(0, str(ROOT / "engine")); sys.path.insert(0, str(ROOT / "bench"))
import mlx.core as mx
from model import Model
from prompt import Builder
import gatecore, words as words_mod, know, ngram
from retrain_state import last_retrain

items = json.loads((ROOT / a.set).read_text())[: a.n]
m = Model("mlx-community/Qwen3-1.7B-4bit", ROOT / "data/adapters")
b = Builder(m, "raw"); m.warm(b.head_ids)
g = gatecore.load(ROOT / "data/gate.json")
W = ngram.Words(ngram.corpus(last_retrain(ROOT)))
pack = know.Pack(ROOT / "data/know.json"); pack.reload()


def run(label, boost=True, grow={}, only_merged_tail=False):
    """Times per key. All keys: first token and total. Keys that end in a ghost of 5+ letters: the first paint (round
    two: the first whole words, model.complete_gated on_part) and the whole ghost, both from before the prompt is built
    (what the engine does for a request, without HTTP)."""
    first, total, per, paint, whole, prep = [], [], [], [], [], []
    for it in items:
        m.cache, m.ids = None, []; m.warm(b.head_ids)
        text = it["text"]
        for pos in range(2, min(len(text), a.keys)):
            before = text[:pos]
            tp = time.perf_counter()
            ids, heal = b.ids(before, it["app"], "", it.get("context", ""), "")
            finish = W.finish(before, 2, 0.5, 1)
            def decide(toks):
                f, _ = gatecore.features(toks, before, it["src"] == "claude", finish)
                p = gatecore.score(g["w"], f) if f else 0.0
                return p if p >= g["th"]["ai"] else None
            bt = words_mod.boost_targets(W, before, heal, knowledge=pack, context=it.get("context", "")) if boost else None
            parts = []
            def on_part(txt, sure):
                if not parts and gatecore.letters(txt) >= 5: parts.append(time.perf_counter())
            t0 = time.perf_counter()
            prep.append((t0 - tp) * 1000)
            text_out, gp, f_ms, t_ms = m.complete_gated(ids, heal, decide, more=0.5, max_words=3, max_tokens=grow.get("max_tokens", 10),
                                                        boost=bt, lam=0.3 if boost else 0, on_part=on_part,
                                                        **{k: v for k, v in grow.items() if k != "max_tokens"})
            first.append(f_ms); total.append(t_ms)
            n = len(m.tok.encode(heal + text_out)) if text_out else 0
            if n > 1: per.append((t_ms - f_ms) / max(1, n - 1))
            if gatecore.letters(text_out) >= 5:
                whole.append((t0 - tp) * 1000 + t_ms)
                paint.append(((parts[0] if parts else t0 + t_ms / 1000) - tp) * 1000)
    q = lambda xs, p: sorted(xs)[int(len(xs) * p)] if xs else 0
    md = lambda xs: statistics.median(xs) if xs else 0
    print(f"{label:44s} every key: first token p50 {md(first):5.1f} · total p50 {md(total):5.1f} p90 {q(total, .9):5.1f} · per token {md(per):4.1f} · "
          f"prompt+words {md(prep):4.1f} ms | ghosts {len(whole)}: first paint p50 {md(paint):5.1f} p90 {q(paint, .9):5.1f} · whole p50 {md(whole):5.1f} "
          f"p90 {q(whole, .9):5.1f} ms · peak {mx.get_peak_memory() / 2**30:.2f} GB", flush=True)


if a.round2:
    m.fuse_lora()
    pick = {"min_letters": 5, "grow": 0.05, "grow_words": 6}
    run("merged, min 5 grow 0.05 (round one)", grow=dict(pick))
    run("merged, + tail 0.2 / 8 words (AI apps)", grow=dict(pick, tail=0.2, tail_words=8, max_tokens=18))
    sys.exit(0)
run("LoRA unmerged + booster (live)")
run("LoRA unmerged, no booster", boost=False)
m.fuse_lora() if hasattr(m, "fuse_lora") else None
if hasattr(m, "fuse_lora"):
    run("LoRA merged + booster")
    run("LoRA merged, no booster", boost=False)
    run("LoRA merged + booster, min 5 grow 0.05", grow={"min_letters": 5, "grow": 0.05, "grow_words": 6})
    run("LoRA merged + booster, min 5 grow 0.05, tail 0.2", grow={"min_letters": 5, "grow": 0.05, "grow_words": 6, "tail": 0.2, "tail_words": 8, "max_tokens": 18})
m.lora(False)
run("base (layer off) + booster")

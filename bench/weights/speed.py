"""Item C: two load-time speed items, measured against the engine as it runs today.

1. A fused model folder: base + his live layer merged once on disk (mlx_lm fuse), so the engine loads one model and
   skips `Model.fuse_lora` (112 merges at every load and wake). Measured: load seconds, memory, ms per token, prompt
   head prefill, and whether the first tokens of a few made-up prompts are the same.
2. A prompt-cache file for the fixed prompt head (about 690 tokens: rules, his words, his example messages): saved
   once per head (mlx_lm save_prompt_cache), read at load instead of prefilling the head. Measured: prefill ms against
   file read ms, file size, and the next-token logits from both caches (they must match).

    .venv/bin/python -B bench/weights/speed.py --smoke        # fewer tokens; still builds the fused folder once
    .venv/bin/python -B bench/weights/speed.py
Each measurement loads one model in its own guarded process. Output: data/bench/weights/speed.json.
The fused folder (bench/out/weights/fused-live, ~1 GB) has no plain layers, so chips and rewrites, which run with the
layer off (`Model.lora(False)`), would run on his layer: see docs/rounds/2026-11-14-weights.md before using it live.
Internals: --worker fuse|measure|pcache run under guarded.py."""
import argparse, json, os, sys, time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import common as C

FUSED = C.OUT / "fused-live"
PROMPTS = [("Claude", "Can you check why the build fails on the second"), ("Beeper", "Привіт, я сьогодні трохи"),
           ("Claude", "Let's add a test for the parser and then")]     # made up


def worker_fuse(a):
    import runpy
    sys.argv = ["mlx_lm.fuse", "--model", C.BASE, "--adapter-path", str(C.ROOT / C.LIVE), "--save-path", str(FUSED)]
    runpy.run_module("mlx_lm.fuse", run_name="__main__")


def per_token_ms(total_ms, first_ms, made):
    """Decode time per token after the first, over the tokens really made (not the asked maximum)."""
    return (total_ms - first_ms) / max(made - 1, 1)


def _setup():
    os.environ.setdefault("DRAFTER_CAP_GB", "3.6")
    sys.path.insert(0, str(C.ROOT / "engine"))


def worker_measure(a):
    """One way of loading (engine = base + live layer merged at load; fused = the fused folder), then the numbers."""
    _setup()
    import mlx.core as mx
    import guard
    from model import Model
    from prompt import Builder, tail
    t = time.perf_counter()
    m = Model(C.BASE, C.ROOT / C.LIVE) if a.how == "engine" else Model(str(FUSED))
    load_s = time.perf_counter() - t
    loaded_gb = mx.get_active_memory() / 2**30
    b = Builder(m, "raw")
    t = time.perf_counter(); m.warm(b.head_ids); head_ms = (time.perf_counter() - t) * 1000
    n_tok = 8 if a.smoke else 32
    per_token, first, tokens = [], [], []
    for app, text in PROMPTS:
        ids, heal = b.ids(text, app)
        out, f, total = m.complete("", max_tokens=n_tok, stop=None, raw_ids=ids, heal=heal)
        first.append(out[:40])
        made = len(m.last_p)                   # tokens really made: an end-of-text token stops the loop early
        per_token.append(per_token_ms(total, f, made))
        tokens.append(made)
    res = {"how": a.how, "load_s": round(load_s, 2), "loaded_gb": round(loaded_gb, 3), "head_tokens": len(b.head_ids),
           "head_prefill_ms": round(head_ms, 1), "ms_per_token": round(sorted(per_token)[len(per_token) // 2], 2), "tokens_made": tokens,
           "footprint_gb": round(guard.footprint_gb(), 3), "peak_gb": round(mx.get_peak_memory() / 2**30, 3),
           "lora_merged": len(m.fused), "first_words_digest": __import__("hashlib").sha1("|".join(first).encode()).hexdigest()[:10]}
    Path(a.out).write_text(json.dumps(res))
    print(json.dumps(res), flush=True)


def worker_pcache(a):
    """The head as a file: prefill and save, read back, compare the next-token logits from both caches."""
    _setup()
    import hashlib
    import mlx.core as mx
    from mlx_lm.models.cache import save_prompt_cache, load_prompt_cache, make_prompt_cache
    from model import Model
    from prompt import Builder
    m = Model(C.BASE, C.ROOT / C.LIVE)
    b = Builder(m, "raw")
    head = b.head_ids
    t = time.perf_counter(); m.warm(head); prefill_ms = (time.perf_counter() - t) * 1000
    key = hashlib.sha1((C.BASE + str((C.ROOT / C.LIVE / "adapters.safetensors").stat().st_mtime) + ",".join(map(str, head))).encode()).hexdigest()[:16]
    path = C.WORK / f"head-cache-{key}.safetensors"   # the head holds his example messages: kept under data/
    C.WORK.mkdir(parents=True, exist_ok=True)
    t = time.perf_counter(); save_prompt_cache(str(path), m.cache, {"key": key, "tokens": str(len(head))}); save_ms = (time.perf_counter() - t) * 1000
    probe = mx.array(m.encode("\n[Claude]\nLet's")[:4])
    a1 = m.model(probe[None], cache=m.cache)[0, -1]; mx.eval(a1)
    t = time.perf_counter(); cache, meta = load_prompt_cache(str(path), return_metadata=True); mx.eval([c.state for c in cache]); read_ms = (time.perf_counter() - t) * 1000
    a2 = m.model(probe[None], cache=cache)[0, -1]; mx.eval(a2)
    res = {"head_tokens": len(head), "prefill_ms": round(prefill_ms, 1), "save_ms": round(save_ms, 1), "read_ms": round(read_ms, 1),
           "file_mb": round(path.stat().st_size / 2**20, 1), "max_logit_diff": float(mx.abs(a1.astype(mx.float32) - a2.astype(mx.float32)).max().item()),
           "same_top_token": int(mx.argmax(a1).item()) == int(mx.argmax(a2).item()), "meta_ok": meta.get("key") == key}
    Path(a.out).write_text(json.dumps(res))
    print(json.dumps(res), flush=True)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--smoke", action="store_true")
    ap.add_argument("--worker", choices=["fuse", "measure", "pcache"])
    ap.add_argument("--how"); ap.add_argument("--out")
    ap.add_argument("--sleep-engine", action="store_true")
    a = ap.parse_args()
    if a.worker:
        return {"fuse": worker_fuse, "measure": worker_measure, "pcache": worker_pcache}[a.worker](a)
    C.need_data()
    me, tag = Path(__file__), "-smoke" if a.smoke else ""
    smoke = ["--smoke"] if a.smoke else []
    res = {"smoke": a.smoke}
    from contextlib import nullcontext
    from retrain import sleeping_engine
    with (sleeping_engine() if a.sleep_engine else nullcontext()):
        if not (FUSED / "config.json").exists():
            t = time.time()
            code, lines = C.guarded(me, ["--worker", "fuse"], 4.0, log=C.RESULTS / "logs" / "speed-fuse.log")
            if code: raise SystemExit(f"fuse failed ({code}): {lines[-1:]}")
            res["fuse_s"] = round(time.time() - t)
        res["fused_gb_on_disk"] = round(sum(f.stat().st_size for f in FUSED.glob("*.safetensors")) / 1e9, 3)
        for how in ("engine", "fused", "engine", "fused"):     # twice each, alternating: the second load reads a warm file cache
            out = C.WORK / f"speed-{how}.json"
            code, lines = C.guarded(me, ["--worker", "measure", "--how", how, "--out", out, *smoke], 4.0,
                                    log=C.RESULTS / "logs" / f"speed-{how}{tag}.log")
            if code: raise SystemExit(f"measure {how} failed ({code}): {lines[-1:]}")
            res.setdefault(how, []).append(json.loads(out.read_text()))
        out = C.WORK / "speed-pcache.json"
        code, lines = C.guarded(me, ["--worker", "pcache", "--out", out], 4.0, log=C.RESULTS / "logs" / f"speed-pcache{tag}.log")
        if code: raise SystemExit(f"prompt cache failed ({code}): {lines[-1:]}")
        res["prompt_cache"] = json.loads(out.read_text())
        res["same_first_words"] = len({r["first_words_digest"] for r in res["engine"] + res["fused"]}) == 1
    p = C.write(f"speed{tag}", res)
    print(json.dumps(res, indent=1)); print(f"-> {p}")


if __name__ == "__main__":
    main()

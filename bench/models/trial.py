"""One candidate base model, judged like the live layer: untrained score, then the user's layer trained with the live recipe
(and with the best recipe of the weights round when data/bench/weights/train-*.json holds one), scored again.

    .venv/bin/python -B bench/models/trial.py qwen35-2b --smoke                 # 3 lines, 20 steps: the plumbing
    .venv/bin/python -B bench/models/trial.py qwen35-2b --sleep-engine         # the full trial
    .venv/bin/python -B bench/models/trial.py --list                            # the candidates
Options: --set <held set> (default data/bench/weights/held-137.json), --skip-base, --only-recipe ref|best,
--sleep-engine (unload the running Drafter model while this runs, like the retrain).

Reported per stage (base, ref, best), per app kind (claude = AI apps, beeper = chats): letters saved and right first
words (the retrain's own score, gate refit on held-out folds), right %, wrong per 1,000 letters, saved % and ms
through the one replay, ms to the first token and per token, peak memory of the recording and of the training, and
the retrain's decision against the live layer. Output: data/bench/models/trial-<candidate>.json; the layer in
bench/out/models/<candidate>-<recipe>/ (promote by hand only). One model per process, one process at a time."""
import argparse, json, sys, time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import shared as S
sys.path.insert(0, str(S.ROOT / "bench/weights"))
import recency
import train_sweep as TS        # the live recipe, the variants, the training data builder of the weights round


def model_path(c):
    """The repo name, or the pinned cached snapshot folder when the candidate names a revision."""
    if not c.get("rev"): return c["repo"]
    from huggingface_hub import snapshot_download
    return snapshot_download(c["repo"], revision=c["rev"], local_files_only=True)


def train_args(c, r, out, data_dir, smoke):
    """bench/train.py arguments for recipe `r` on candidate `c` (its batch and gradient checkpointing for memory)."""
    iters = 20 if smoke else r["iters"]
    args = [iters, "--model", model_path(c), "--adapter-path", out, "--data", data_dir, "-c", out / "recipe.yaml",
            "--fine-tune-type", r["fine_tune_type"], "--num-layers", r["num_layers"], "--learning-rate", r["lr"],
            "--batch-size", min(r["batch"], c["batch"]), "--save-every", max(iters, 1),
            "--steps-per-eval", 10 if smoke else 250]
    if c.get("ckpt"): args.append("--grad-checkpoint")
    return args


def train(name, c, r, data_dir, smoke):
    out = S.OUT / name
    out.mkdir(parents=True, exist_ok=True)
    TS.config_yaml(r, out / "recipe.yaml")
    cap = c["train_cap"] + (1.0 if r["fine_tune_type"] == "dora" or r["num_layers"] == -1 else 0.0)
    t = time.time()
    code, lines = S.W.guarded(S.ROOT / "bench/train.py", train_args(c, r, out, data_dir, smoke), cap, timeout=6 * 3600,
                              env={"DRAFTER_TRAIN_CAP_GB": str(cap)}, log=S.RESULTS / "logs" / f"train-{name}.log")
    if code or not (out / "adapters.safetensors").exists():
        raise RuntimeError(f"{name}: training failed ({code}): {lines[-1:]}")
    return {"seconds": round(time.time() - t), "cap_gb": cap, **S.W.peak_and_loss(lines),
            "adapter": str(out.relative_to(S.ROOT))}


def stage(label, cand, adapter, smoke, live):
    rec, lines = S.record(label, cand, adapter=adapter, smoke=smoke)
    s, detail = S.score(rec, smoke)
    return {"recording": rec.name, "peak_gb": S.peak_gb(lines), "score": s, "detail": detail,
            "vs_live": S.W.versus(s, live) if "smoke_error" not in s else {"switch": None}}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("candidate", nargs="?")
    ap.add_argument("--smoke", action="store_true")
    ap.add_argument("--list", action="store_true")
    ap.add_argument("--set", default=S.SET)
    ap.add_argument("--skip-base", action="store_true")
    ap.add_argument("--only-recipe", choices=("ref", "best"), default=None)
    ap.add_argument("--sleep-engine", action="store_true")
    a = ap.parse_args()
    if a.list or not a.candidate:
        for n, c in S.CANDIDATES.items():
            print(f"{n:12s} {c['repo']:48s} cached {'yes' if S.cached(c['repo'], c['rev']) else 'NO '}  {c['note']}")
        return
    c = S.candidate(a.candidate)
    if not S.cached(c["repo"], c["rev"]):
        rev = f", revision='{c['rev']}'" if c["rev"] else ""
        raise SystemExit(f"{c['repo']} is not in the cache. Check `df -h ~` (keep 40 GB free), then:\n"
                         f"  .venv/bin/python -c \"from huggingface_hub import snapshot_download as s; "
                         f"s('{c['repo']}'{rev})\"")
    S.W.need_data()
    S.SET = a.set
    set_path = S.W.held_set(a.set)
    is_held, cut = S.W.held_lines(set_path), S.W.cut_time()
    best_name, best = S.best_recipe()
    recipes = [("ref", TS.recipe("ref"))]
    if best: recipes.append((f"best-{best_name}", {**TS.LIVE, **best}))
    if a.only_recipe == "ref": recipes = recipes[:1]
    if a.only_recipe == "best": recipes = recipes[1:]
    sfx = "-smoke" if a.smoke else ""
    res = {"candidate": a.candidate, **{k: c[k] for k in ("repo", "rev", "note")}, "set": str(a.set), "smoke": a.smoke,
           "best_recipe": best_name, "stages": {}}
    from contextlib import nullcontext
    from retrain import sleeping_engine
    with (sleeping_engine() if a.sleep_engine else nullcontext()):
        live = S.W.baseline(a.set, a.smoke)
        res["live"] = live
        print(f"live layer: {live}", flush=True)
        if not a.skip_base:
            res["stages"]["base"] = stage(f"models-{a.candidate}-base{sfx}", a.candidate, None, a.smoke, live)
            print(f"{a.candidate} untrained: {res['stages']['base']['score']}", flush=True)
            S.write(f"trial-{a.candidate}{sfx}", res)
        for rname, r in recipes:
            data_dir = S.W.WORK / f"train-{TS.data_key(set_path, TS.MIX)}-{r.get('half_life') or 'flat'}"
            if not (data_dir / "train.jsonl").exists() or a.smoke:
                info = recency.build(data_dir, TS.MIX, cut, is_held, r.get("half_life"))
                (data_dir / "info.json").write_text(json.dumps(info))
            name = f"{a.candidate}-{rname}{sfx}"
            tr = train(name, c, r, data_dir, a.smoke)
            st = stage(f"models-{name}", a.candidate, S.OUT.relative_to(S.ROOT) / name, a.smoke, live)
            res["stages"][rname] = {"recipe": r, "train": tr, **st}
            print(f"{name}: {st['score']} vs live {st['vs_live']}", flush=True)
            S.write(f"trial-{a.candidate}{sfx}", res)
    p = S.write(f"trial-{a.candidate}{sfx}", res)
    print(f"-> {p.relative_to(S.ROOT)}")


if __name__ == "__main__":
    main()

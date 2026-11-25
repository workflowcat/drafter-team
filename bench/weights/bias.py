"""Item B2: a per-token logit bias learned from his held-in lines, applied as a bias on the model's output head
(engine/tweaks.py, DRAFTER_TWEAKS). One forward pass stores the model's distributions (collect.py), the fit needs no
model (biasfit.py), then the held-out set is recorded with the bias and scored like the weekly retrain.

    .venv/bin/python -B bench/weights/bias.py --smoke          # 15 lines, 3 held lines: checks the plumbing
    .venv/bin/python -B bench/weights/bias.py                  # all variants below
    .venv/bin/python -B bench/weights/bias.py --only all-1.0 --ai 3000 --chat 1500
Variants: all-1.0 one bias for every app; kind-1.0 one for AI apps and one for chats; all-0.5 half the fitted bias.
The bias sits on top of the live layer (fitted with it on), so it only moves what the layer still gets wrong.
Output: data/bench/weights/bias-<variant>.json; the bias file bench/out/weights/bias-<variant>.npz."""
import argparse, json, sys, time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import common as C

VARIANTS = {"all-1.0": ("all", 1.0), "kind-1.0": ("kind", 1.0), "all-0.5": ("all", 0.5)}


def fit(npz, kinds, min_positions=500):
    import numpy as np
    import biasfit
    z = np.load(npz)
    out, report = {}, {}
    for kind in kinds:
        m = np.ones(len(z["y"]), bool) if kind == "all" else z["kind"] == kind
        if m.sum() < min_positions: continue
        d = biasfit.pack(z["cand"], z["cand_lp"][m], z["y"][m], z["y_lp"][m])
        r = biasfit.choose(d)
        b = r["b"]
        out[kind] = biasfit.dense(b, z["cand"], int(z["vocab"]))
        before, after = r["valid"][r["lam"]]
        report[kind] = {"positions": int(m.sum()), "candidates": int(len(b)), "lam": r["lam"],
                        "valid_nll_before": before, "valid_nll_after": after,
                        "valid_ppl_change_pct": round((np.exp(after - before) - 1) * 100, 2),
                        "tokens_over_0.5": int((abs(b) > 0.5).sum()), "max_abs": round(float(abs(b).max()), 3),
                        "by_lam": {str(k): v for k, v in r["valid"].items()}}
    return out, report


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--smoke", action="store_true")
    ap.add_argument("--only", default=None)
    ap.add_argument("--set", default=None)
    ap.add_argument("--ai", type=int, default=1500)
    ap.add_argument("--chat", type=int, default=1000)
    ap.add_argument("--sleep-engine", action="store_true")
    a = ap.parse_args()
    C.need_data()
    names = a.only.split(",") if a.only else (["all-1.0"] if a.smoke else list(VARIANTS))
    set_path = C.held_set(a.set)
    tag = "-smoke" if a.smoke else ""
    from contextlib import nullcontext
    from retrain import sleeping_engine
    with (sleeping_engine() if a.sleep_engine else nullcontext()):
        live = C.baseline(a.set, a.smoke)
        rows = C.his_lines(a.set, (("ai", 10), ("chat", 5)) if a.smoke else (("ai", a.ai), ("chat", a.chat)))
        import random
        random.Random(7).shuffle(rows)        # kinds mixed, so the position cap does not cut one kind off
        lines = C.write_lines(rows, f"bias-lines{tag}.jsonl")
        npz = C.WORK / f"bias-logits{tag}.npz"
        t = time.time()
        code, out = C.guarded(C.ROOT / "bench/weights/collect.py",
                              ["logits", "--lines", lines, "--out", npz, "--min-count", 2 if a.smoke else 5], 4.0,
                              log=C.RESULTS / "logs" / f"bias-collect{tag}.log")
        if code: raise SystemExit(f"collect failed ({code}): {out[-1:]}")
        collect_s = round(time.time() - t)
        biases, report = fit(npz, ("all", "ai", "chat"), 20 if a.smoke else 500)   # a smoke run has ~300 positions
        if "all" not in biases: raise SystemExit(f"too few positions to fit a bias: {report}")
        print(f"fit: {json.dumps(report)}", flush=True)
        import numpy as np
        for name in names:
            how, scale = VARIANTS[name]
            keys = ["all"] if how == "all" else [k for k in ("ai", "chat") if k in biases]
            path = C.OUT / f"bias-{name}{tag}.npz"
            C.OUT.mkdir(parents=True, exist_ok=True)
            np.savez(path, **{f"bias_{k}": biases[k] * scale for k in keys}, meta=json.dumps({"scale": scale}))
            label = f"weights-bias-{name}{tag}"
            env = {"DRAFTER_TWEAKS": str(path)}
            if how == "all":
                rec = C.record(label, adapter=C.LIVE, set_path=set_path, smoke=a.smoke, env=env)
            else:
                rec = C.record_by_kind(label, {k: {**env, "DRAFTER_TWEAKS_KIND": k} for k in keys},
                                       set_path=set_path, adapter=C.LIVE, smoke=a.smoke)
            s = C.score(rec, set_path, a.smoke)
            res = {"variant": name, "scale": scale, "kinds": keys, "fit": report, "collect_seconds": collect_s,
                   "lines": {k: sum(1 for r in rows if r["group"] == k) for k in ("ai", "chat")},
                   "score": s, "live": live, "vs_live": C.versus(s, live), "smoke": a.smoke}
            p = C.write(f"bias-{name}{tag}", res)
            print(f"{name}: {s} vs live {res['vs_live']} -> {p.relative_to(C.ROOT)}", flush=True)


if __name__ == "__main__":
    main()

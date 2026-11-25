"""Item B3: steering vectors. The mean hidden state at a middle block (default 14 of 28) over his held-in lines minus
the same over a contrast set, added at inference with a strength knob (engine/tweaks.py, DRAFTER_TWEAKS; off unless
the file is named). Per app kind it switches with no reload (Model.tweak_kind).

    .venv/bin/python -B bench/weights/steer.py --smoke                # a few lines, 3 held lines: checks the plumbing
    .venv/bin/python -B bench/weights/steer.py                        # all variants below
    .venv/bin/python -B bench/weights/steer.py --only his-1.0 --layer 10
Vectors (strength 1.0 = add the whole gap between the two means):
  his   his lines minus the model's own lines in the same apps (written with his layer off and no head)
  kind  AI-app lines and chat lines, each minus the centre of the two (one vector per kind, picked by the app)
  lang  Ukrainian minus English lines: measured (how well it separates, how close to `kind`), not applied
Output: data/bench/weights/steer-<variant>.json; vectors in bench/out/weights/steer-<variant>.npz."""
import argparse, json, sys, time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import common as C

VARIANTS = {"his-1.0": ("his", 1.0), "kind-1.0": ("kind", 1.0), "his-0.5": ("his", 0.5), "his-2.0": ("his", 2.0)}


def vectors(npz):
    import numpy as np
    import steervec as S
    z = np.load(npz)
    H, g, norm = z["H"], z["group"], float(z["token_norm"])
    his, gen = H[(g == "ai") | (g == "chat")], H[g == "generic"]
    out = {"his": {"all": S.vector(his, gen)} if len(gen) else {},
           "kind": S.kind_vectors({"ai": H[g == "ai"], "chat": H[g == "chat"]})}
    report = {"token_norm": round(norm, 2), "lines": {k: int((g == k).sum()) for k in ("ai", "chat", "generic")},
              "his_norm_rel": round(float(np.linalg.norm(out["his"]["all"])) / norm, 4) if out["his"] else None,
              "kind_norm_rel": round(float(np.linalg.norm(out["kind"]["ai"])) / norm, 4),
              "his_holdout_acc": S.holdout_accuracy(his, gen) if len(gen) else None,
              "kind_holdout_acc": S.holdout_accuracy(H[g == "ai"], H[g == "chat"])}
    if "lang" in z.files:
        lang = z["lang"]
        uk, en = H[lang == "uk"], H[lang == "en"]
        if len(uk) and len(en):
            v = S.vector(uk, en)
            report.update({"lang_holdout_acc": S.holdout_accuracy(uk, en),
                           "lang_vs_kind_cosine": round(S.cosine(v, out["kind"]["chat"]), 3)})
    return out, report


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--smoke", action="store_true")
    ap.add_argument("--only", default=None)
    ap.add_argument("--set", default=None)
    ap.add_argument("--layer", type=int, default=14)
    ap.add_argument("--per-kind", type=int, default=600)
    ap.add_argument("--generic", type=int, default=300)
    ap.add_argument("--sleep-engine", action="store_true")
    a = ap.parse_args()
    C.need_data()
    names = a.only.split(",") if a.only else (["his-1.0"] if a.smoke else list(VARIANTS))
    set_path = C.held_set(a.set)
    tag = "-smoke" if a.smoke else ""
    n = 6 if a.smoke else a.per_kind
    from contextlib import nullcontext
    from retrain import sleeping_engine
    import numpy as np
    with (sleeping_engine() if a.sleep_engine else nullcontext()):
        live = C.baseline(a.set, a.smoke)
        rows = C.his_lines(a.set, (("ai", n), ("chat", n)))
        lines = C.write_lines(rows, f"steer-lines{tag}.jsonl")
        npz = C.WORK / f"steer-hidden-L{a.layer}{tag}.npz"
        t = time.time()
        code, out = C.guarded(C.ROOT / "bench/weights/collect.py",
                              ["hidden", "--lines", lines, "--out", npz, "--layer", a.layer,
                               "--generic", 4 if a.smoke else a.generic], 4.0,
                              log=C.RESULTS / "logs" / f"steer-collect{tag}.log")
        if code: raise SystemExit(f"collect failed ({code}): {out[-1:]}")
        collect_s = round(time.time() - t)
        vecs, report = vectors(npz)
        print(f"vectors: {json.dumps(report)}", flush=True)
        for name in names:
            how, strength = VARIANTS[name]
            if not vecs.get(how): print(f"{name}: no vector (no lines for it)"); continue
            path = C.OUT / f"steer-{name}{tag}.npz"
            C.OUT.mkdir(parents=True, exist_ok=True)
            np.savez(path, **{f"steer_{k}": v.astype(np.float32) for k, v in vecs[how].items()},
                     meta=json.dumps({"layer": a.layer, "strength": strength}))
            label = f"weights-steer-{name}-L{a.layer}{tag}"
            env = {"DRAFTER_TWEAKS": str(path)}
            if how == "his":
                rec = C.record(label, adapter=C.LIVE, set_path=set_path, smoke=a.smoke, env=env)
            else:
                rec = C.record_by_kind(label, {k: {**env, "DRAFTER_TWEAKS_KIND": k} for k in vecs[how]},
                                       set_path=set_path, adapter=C.LIVE, smoke=a.smoke)
            s = C.score(rec, set_path, a.smoke)
            res = {"variant": name, "layer": a.layer, "strength": strength, "vectors": report,
                   "collect_seconds": collect_s, "score": s, "live": live, "vs_live": C.versus(s, live), "smoke": a.smoke}
            p = C.write(f"steer-{name}-L{a.layer}{tag}", res)
            print(f"{name}: {s} vs live {res['vs_live']} -> {p.relative_to(C.ROOT)}", flush=True)


if __name__ == "__main__":
    main()

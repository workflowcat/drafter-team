"""Shared parts of the weights round (docs/rounds/2026-11-14-weights.md): paths, the guarded model step, the held-out
recording and score, the result files.

Every script here is an orchestrator that loads no model itself. Each model step runs in its own process under
engine/guard.py (bench/weights/guarded.py), one at a time, after a free-memory check. Scores are the weekly retrain's
own test (bench/retrain.py `_compare`): bench/typebench.py records the held-out set the way Drafter types (word booster
share from data/gate.json, the per-chat lines when they belong to the set), bench/gate.py `summary` scores it with a
gate refit on held-out folds, and `retrain.decide` says whether it would beat the live layer.

Run from the main checkout (it has data/): `cd <repo> && .venv/bin/python -B bench/weights/<script>.py --smoke` first.
Results: data/bench/weights/<name>.json (numbers only). His text in working files: data/bench/weights/work/ (data/ never
goes to git). Candidate weights: bench/out/weights/ (git ignores it). Nothing here writes data/adapters*, gate.json or
selector.json."""
import json, os, re, subprocess, sys, time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent.parent
DATA = Path(os.environ.get("DRAFTER_DATA") or ROOT / "data")   # model steps (typebench) always use ROOT/data
RESULTS = DATA / "bench/weights"
WORK = RESULTS / "work"
OUT = ROOT / "bench/out/weights"
PY = str(ROOT / ".venv/bin/python")
BASE = "mlx-community/Qwen3-1.7B-4bit"
LIVE = "data/adapters"
for p in (ROOT / "bench", ROOT / "engine"):
    if str(p) not in sys.path: sys.path.insert(0, str(p))


def need_data():
    if not (DATA / "corpus.jsonl").exists():
        raise SystemExit(f"no data/corpus.jsonl under {ROOT}: run this from the main checkout (it holds data/)")


def free_pct():
    try:
        s = subprocess.run(["memory_pressure"], capture_output=True, text=True, timeout=10).stdout
        return int(re.search(r"free percentage: (\d+)%", s).group(1))
    except Exception:
        return 100


def guarded(script, args, cap_gb, timeout=7200, env=None, min_free=25, log=None):
    """Run `script` (a path under ROOT, or `-m module`) in its own process under the memory guard at `cap_gb`.
    -> (exit code, stdout lines). Refuses to start when the system has under `min_free` % memory free."""
    if free_pct() < min_free:
        raise SystemExit(f"system free memory under {min_free}%: not starting {script} (another model running?)")
    WORK.mkdir(parents=True, exist_ok=True)        # workers write their numbers there (speed.py, bias.py, steer.py)
    cmd = [PY, "-B", str(ROOT / "bench/weights/guarded.py"), str(cap_gb), str(script), *map(str, args)]
    e = {**os.environ, "HF_HUB_OFFLINE": os.environ.get("HF_HUB_OFFLINE", "1"), **(env or {})}
    t = time.time()
    r = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout, stdin=subprocess.DEVNULL, env=e, cwd=ROOT)
    lines = [l for l in (r.stdout + "\n" + r.stderr).splitlines() if l.strip() and "Warning" not in l]
    if log:
        Path(log).parent.mkdir(parents=True, exist_ok=True)
        Path(log).write_text(f"$ {' '.join(cmd[3:])}\n# {time.time() - t:.0f}s, exit {r.returncode}\n" + "\n".join(lines) + "\n")
    return r.returncode, lines


def gate_boost():
    try: return float(json.loads((DATA / "gate.json").read_text()).get("boost", 0) or 0)
    except (OSError, ValueError): return 0.0


def held_set(path=None):
    """The held-out set every score here uses: the retrain's (data/replay-fresh.json) unless --set names another."""
    p = Path(path) if path else DATA / "replay-fresh.json"
    p = p if p.is_absolute() else ROOT / p
    if not path:        # the default set can be the 8 November draw with no chat lines: refuse it, name another
        from retrain import missing_kinds
        missing = missing_kinds(json.loads(p.read_text()))
        if missing: raise SystemExit(f"{p.name} has no {', '.join(missing)} lines: pass --set (e.g. data/bench/weights/held-137.json)")
    return p


def held_lines(set_path):
    """Lines training and fitting must leave out: the default held files (bench/held.py) and the chosen set."""
    import held
    extra = [x["text"] for x in json.loads(Path(set_path).read_text())]
    return held.Held(list(held.texts()) + extra)


def cut_time():
    """Lines dated at or after this were not trained on by the live layer and are the held-out side."""
    from retrain_state import last_retrain
    return last_retrain(ROOT) or None


def record(label, repo=BASE, adapter=None, set_path=None, smoke=False, env=None, app=None, cap=3.0, guard_gb=4.0):
    """The held-out set recorded as Drafter types it (bench/retrain.py `record`, same arguments). -> recording path."""
    import typescore
    set_path = held_set(set_path)
    args = [repo, "--set", str(set_path), "--boost", str(gate_boost()), "--label", label, "--cap", str(cap),
            "--n", "3" if smoke else "100000"]
    if adapter: args += ["--adapter", str(adapter)]
    if app: args += ["--app", app]
    try:
        d = json.loads((DATA / "bench/people-fresh.json").read_text())
        if d.get("rows") and d.get("set_sha") == typescore.set_sha(set_path): args.append("--people")
    except Exception:
        pass
    code, lines = guarded(ROOT / "bench/typebench.py", args, guard_gb, timeout=3 * 3600, env=env,
                          log=RESULTS / "logs" / f"{label}.log")
    if code: raise RuntimeError(f"{label}: typebench failed ({code}): {lines[-1:] or ''}")
    return DATA / "bench" / f"{label}.jsonl"


def record_by_kind(label, kinds_env, set_path=None, **kw):
    """One recording per app of the set, each with its own environment (per-kind steering or bias), joined into one
    file the scorer reads like any other. kinds_env: {kind: env dict}; kind of an app from engine/tweaks.kind_of."""
    import tweaks, typescore
    set_path = held_set(set_path)
    apps = sorted({x["app"] for x in json.loads(set_path.read_text())})
    parts = []
    for app in apps:
        env = kinds_env.get(tweaks.kind_of(app)) or kinds_env.get("all") or {}
        name = re.sub(r"[^\w-]+", "_", app)
        parts.append(record(f"{label}-{name}", set_path=set_path, env=env, app=app, **kw))
    out = DATA / "bench" / f"{label}.jsonl"
    rows = [l for p in parts for l in p.read_text().splitlines() if l.strip()]
    rows.sort(key=lambda l: (json.loads(l)["i"], json.loads(l)["pos"]))
    out.write_text("\n".join(rows) + "\n")
    meta = typescore.meta(parts[0]) if parts else {}
    meta.update({"app": None, "parts": [p.name for p in parts]})
    Path(str(out)[: -len(".jsonl")] + ".meta.json").write_text(json.dumps(meta, indent=1))
    return out


def score(rec, set_path=None, smoke=False):
    """{app: {"saved", "right", "shown"}} on held-out gate folds (bench/gate.py summary), after the same coverage
    check `_compare` makes. A smoke recording covers 3 lines and is scored as it is."""
    import gate, typescore
    if not smoke:
        items = json.loads(held_set(set_path).read_text())
        expected = {(i, pos) for i, item in enumerate(items) for pos in range(1, len(item["text"]))
                    if len(item["text"][:pos].strip()) >= 2}
        covered, rows = typescore.load(rec)
        if covered != items or set(rows) != expected:
            raise RuntimeError(f"{rec.name}: recording cut short or made on another set")
        return gate.summary(rec)
    try:
        return gate.summary(rec)
    except Exception as e:      # 3 lines may be too few for the gate's folds: the smoke run checks the plumbing only
        return {"smoke_error": f"{type(e).__name__}: {e}"[:200]}


def baseline(set_path=None, smoke=False):
    """The live layer's score on this set, recorded once per set, live layer and booster share, and kept."""
    import hashlib, typescore
    layer = (ROOT / LIVE / "adapters.safetensors").stat().st_mtime
    sha = hashlib.sha1(f"{typescore.set_sha(held_set(set_path))}{layer}{gate_boost()}".encode()).hexdigest()[:12]
    p = RESULTS / f"live-{sha}{'-smoke' if smoke else ''}.json"
    if p.exists(): return json.loads(p.read_text())["score"]
    rec = record(f"weights-live-{sha}{'-smoke' if smoke else ''}", adapter=LIVE, set_path=set_path, smoke=smoke)
    s = score(rec, set_path, smoke)
    write(p.stem, {"what": "live layer", "set_sha": sha, "score": s})
    return s


def versus(score_new, score_live):
    """The retrain's own decision against the live layer: (switch?, letters-saved gain in points, apps worse)."""
    from retrain import decide
    if "smoke_error" in score_new or "smoke_error" in score_live: return {"switch": None}
    switch, gain, worse = decide(score_live, score_new)
    return {"switch": switch, "gain_points": gain, "worse_apps": worse}


def write(name, result):
    RESULTS.mkdir(parents=True, exist_ok=True)
    p = RESULTS / f"{name}.json"
    p.write_text(json.dumps({**result, "made": time.strftime("%Y-%m-%d %H:%M")}, indent=1, ensure_ascii=False))
    return p


def peak_and_loss(lines):
    """Numbers from mlx_lm training output: last validation loss, peak memory (GB), iterations/second."""
    lines = [re.sub(r"\x1b\[[0-9;]*m", "", l) for l in lines]      # mlx-lm 0.32 colours its table
    val = [float(m.group(1) or m.group(2)) for l in lines
           for m in [re.search(r"Val loss ([\d.]+)|^\s*\d+\s+val ([\d.]+)", l)] if m]
    peak = [float(m.group(1)) for l in lines for m in [re.search(r"Peak mem ([\d.]+) GB", l)] if m]
    its = [float(m.group(1)) for l in lines for m in [re.search(r"It/sec ([\d.]+)", l)] if m]
    return {"val_loss": val[-1] if val else None, "val_loss_first": val[0] if val else None,
            "peak_gb": max(peak) if peak else None, "it_per_s": round(sum(its) / len(its), 3) if its else None}


CYRILLIC = re.compile(r"[а-яіїєґА-ЯІЇЄҐ]")
LATIN = re.compile(r"[a-zA-Z]")


def lang_of(text):
    """"uk" or "en" by the larger share of letters, "" when neither has 70 %."""
    c, l = len(CYRILLIC.findall(text)), len(LATIN.findall(text))
    if c + l == 0: return ""
    return "uk" if c / (c + l) >= 0.7 else ("en" if l / (c + l) >= 0.7 else "")


def his_lines(set_path=None, per_kind=(("ai", 2000), ("chat", 1000)), seed=5, max_chars=400):
    """His held-in lines (dated before the cut, no held line), as {"text", "app", "group", "lang"}, `n` per kind:
    ai = typed lines in AI apps, Claude Code and Codex prompts; chat = Beeper messages. Takes are left out."""
    import random
    import corpus as Corp
    import tweaks
    from held import norm
    from make_train import APP_TAG
    is_held = held_lines(held_set(set_path))
    pools = {}
    for r in Corp.load(DATA / "corpus.jsonl", before=cut_time()):
        if r["src"] not in ("typed", "cc", "codex", "beeper"): continue
        t = norm(r["text"])
        if len(t) < 12 or len(t) > max_chars or is_held(t): continue
        app = APP_TAG.get(r["src"]) or r.get("app") or "Claude"
        kind = tweaks.kind_of(app)
        pools.setdefault(kind, []).append({"text": t, "app": app, "group": kind, "lang": lang_of(t)})
    out = []
    for kind, n in per_kind:
        pool = pools.get(kind, [])
        random.Random(seed).shuffle(pool)
        out += pool[:n]
    return out


def write_lines(rows, name):
    WORK.mkdir(parents=True, exist_ok=True)
    p = WORK / name
    p.write_text("".join(json.dumps(r, ensure_ascii=False) + "\n" for r in rows))
    return p

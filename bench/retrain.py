"""Weekly retrain on the user's newest writing, switched on only if it types better on lines neither layer has seen.

    .venv/bin/python bench/retrain.py [--force]
    .venv/bin/python bench/retrain.py --compare data/adapters data/adapters-prev    # the test alone: nothing moves

Runs only when the last retrain is 7+ days old, the Mac is on power and the user has been away from the keyboard 10+ minutes
(--force skips those checks).

The rolling test set (2026-11-01; before, 30 fixed messages from 19 October replayed through the running engine
decided). Each run first draws a new fresh set from what the user wrote since the last retrain (bench/make_fresh.py: 40
Beeper replies with the chat above them, 60 lines to Claude; data/replay-fresh.json) and their older lines in each of
those chats (bench/people_fresh.py). Training leaves those lines out (bench/make_train.py), so both layers are tested
on lines they never saw; next week they train and a new set is drawn. Each layer is recorded on the set the way
Drafter types (bench/typebench.py with the word booster and the per-person lines), scored through the decision gate
on held-out folds (bench/gate.py summary), and the new layer is kept only when it saves more letters over both apps
(by more than MARGIN points) and neither app's share of right first words drops by more than RIGHT_DROP. On a switch
the gate is refit on the new layer's recording and Drafter restarts. Report: data/review/retrain-YYYY-MM-DD.md."""
import errno, json, os, re, shutil, subprocess, sys, tempfile, threading, time
from contextlib import contextmanager
from urllib.request import Request, urlopen
from urllib.error import URLError
from pathlib import Path
ROOT = Path(__file__).resolve().parent.parent
PY = str(ROOT / ".venv/bin/python")
SETTINGS = ROOT / "data/settings.json"
STAMP = ROOT / "data/review/last-retrain"
MARGIN, RIGHT_DROP, MIN_ITEMS = 0.5, 2.0, 50
force = "--force" in sys.argv
sys.path.insert(0, str(ROOT / "bench"))
sys.path.insert(1, str(ROOT / "engine"))
from retrain_state import last_retrain, last_attempt
from lora_recipe import RECIPE


def base_model(settings):
    """The engine repo the layer is recorded with (record below)."""
    return (settings or {}).get("model") or "mlx-community/Qwen3-1.7B-4bit"


def idle_s():
    out = subprocess.run(["ioreg", "-c", "IOHIDSystem"], capture_output=True, text=True).stdout
    m = re.search(r'"HIDIdleTime" = (\d+)', out)
    return int(m.group(1)) / 1e9 if m else 0


def on_power():
    return "AC Power" in subprocess.run(["pmset", "-g", "batt"], capture_output=True, text=True).stdout


def engine_headers():
    """JSON headers plus the engine's token from data/engine.token (DRAFTER_DATA when set), when there is one."""
    h = {"Content-Type": "application/json"}
    try: t = (Path(os.environ.get("DRAFTER_DATA") or ROOT / "data") / "engine.token").read_text().strip()
    except OSError: t = ""
    if t: h["X-Drafter-Token"] = t
    return h


def engine_post(route, **body):
    request = Request("http://127.0.0.1:8798/" + route, data=json.dumps(body).encode(), headers=engine_headers())
    with urlopen(request, timeout=45) as response:
        result = json.load(response)
    if result.get("error") or result.get("stale"):
        raise RuntimeError(f"engine /{route}: {result}")
    return result


@contextmanager
def sleeping_engine(report=None):
    """Hold the engine's bounded sleep lease through both recordings and scoring, even over an hour."""
    stopped, failures = threading.Event(), []
    def renew():
        while not stopped.wait(1800):
            try: engine_post("sleep", secs=3600, retrain=True)
            except Exception as e:
                failures.append(e)
                return
    worker = None
    try:
        try:
            engine_post("sleep", secs=3600, retrain=True)
        except URLError as e:
            if not isinstance(e.reason, OSError) or e.reason.errno != errno.ECONNREFUSED: raise
            # Nothing is listening, so there is no resident model to unload.
            yield
            return
        worker = threading.Thread(target=renew, daemon=True, name="retrain-sleep")
        worker.start()
        yield
        if failures: raise RuntimeError(f"engine sleep renewal failed: {failures[0]}")
    finally:
        stopped.set()
        if worker: worker.join()
        if worker:
            try: engine_post("wake")
            except Exception as e:
                message = f"- engine wake failed ({e}); comparison decision retained; wake/restart engine manually"
                if report is not None: report.append(message)
                else: print(message)


def step(script, *args, timeout=900):
    r = subprocess.run([PY, str(ROOT / script), *args], capture_output=True, text=True, timeout=timeout, stdin=subprocess.DEVNULL)
    lines = [l for l in r.stdout.strip().splitlines() if "Warning" not in l]
    return r.returncode, (lines[-1] if lines else r.stderr.strip()[-300:])


def record(adapter, label):
    """The set as Drafter would type it with this layer -> (recording, last line of the bench)."""
    st = json.loads(SETTINGS.read_text())
    g = json.loads((ROOT / "data/gate.json").read_text()) if (ROOT / "data/gate.json").exists() else {}
    args = [base_model(st), "--adapter", str(Path(adapter).relative_to(ROOT) if Path(adapter).is_absolute() else adapter),
            "--boost", str(g.get("boost", 0) or 0), "--label", label]
    try:      # the user's older lines per chat, when they were read for this very set (Beeper may have been off)
        import typescore
        d = json.loads((ROOT / "data/bench/people-fresh.json").read_text())
        if d.get("rows") and d.get("set_sha") == typescore.set_sha(ROOT / "data/replay-fresh.json"): args.append("--people")
    except Exception: pass
    code, last = step("bench/typebench.py", *args, timeout=2400)
    if code: raise RuntimeError(f"{label} failed ({code}): {last}")
    return ROOT / "data/bench" / f"{label}.jsonl", last


def decide(cur, new):
    """(switch?, letters-saved gain in points over the apps, apps whose right share fell too far)"""
    apps = sorted(set(cur) & set(new))
    gain = round(sum(new[a]["saved"] - cur[a]["saved"] for a in apps), 2)
    worse = [a for a in apps if new[a]["right"] < cur[a]["right"] - RIGHT_DROP]
    return bool(apps) and gain > MARGIN and not worse, gain, worse


def compare(cur_dir, new_dir, report):
    try:
        with sleeping_engine(report):
            return _compare(cur_dir, new_dir, report)
    except Exception as e:
        report.append(f"- comparison failed ({e}): kept the current layer")
        return False, None


def _compare(cur_dir, new_dir, report):
    import gate, typescore
    try:
        items = json.loads((ROOT / "data/replay-fresh.json").read_text())
        missing = missing_kinds(items)
        if missing:     # the 8 November set (60 AI-app lines, 0 chat lines) stayed the default until the next draw
            report.append(f"- the test set has no {', '.join(missing)} lines: not a fair test, kept the current layer")
            return False, None
        expected = {(i, pos) for i, item in enumerate(items) for pos in range(1, len(item["text"]))
                    if len(item["text"][:pos].strip()) >= 2}
        rec_c, line_c = record(cur_dir, "retrain-cur")
        rec_n, line_n = record(new_dir, "retrain-new")
        report += [f"- recorded {cur_dir}: {line_c}", f"- recorded {new_dir}: {line_n}"]
        for rec in (rec_c, rec_n):
            covered, rows = typescore.load(rec)
            if not expected or covered != items or set(rows) != expected:
                report.append("- test cut short or different test set: kept the current layer"); return False, None
        cur, new = gate.summary(rec_c), gate.summary(rec_n)
    except (Exception, SystemExit) as e:
        report.append(f"- scoring failed ({e}): kept the current layer"); return False, None
    show = lambda s: " · ".join(f"{a} {v['saved']}% saved, {v['right']}% right" for a, v in sorted(s.items()))
    switch, gain, worse = decide(cur, new)
    report += [f"- {cur_dir}: {show(cur)}", f"- {new_dir}: {show(new)}",
               f"- letters saved {gain:+.1f} points over the apps" + (f"; right first words fell in {', '.join(worse)}" if worse else "")]
    return switch, rec_n


def missing_kinds(items):
    """The kinds of line a fair layer test needs (chats and AI apps) that `items` lacks: [] when both are there.
    A line's kind: its `src` ("beeper" / "claude"), else its app (Beeper = chat, any other = AI app)."""
    have = {i.get("src") or ("beeper" if i.get("app") == "Beeper" else "claude") for i in items}
    return [k for k in ("beeper", "claude") if k not in have]


def fresh_set(report):
    """Publish only a usable fresh set; a failed/small draw leaves the last set intact."""
    target = ROOT / "data/replay-fresh.json"
    with tempfile.TemporaryDirectory(prefix="replay-", dir=target.parent) as folder:
        candidate = Path(folder) / "fresh.json"
        code, line = step("bench/make_fresh.py", "--output", str(candidate), "--min-items", "0", timeout=600)
        report.append(f"- fresh set: {line}")
        if code: return 0
        items = json.loads(candidate.read_text())
        # 8 November: `beeper` was not on launchd's PATH, the set held 0 chat lines and the layers were judged on
        # AI-app lines alone. Both kinds or no comparison.
        missing = missing_kinds(items)
        if missing:
            report.append(f"- no {', '.join(missing)} lines in the fresh set: not a fair test of the layers")
            return 0
        if len(items) >= MIN_ITEMS: candidate.replace(target)
        return len(items)


def main():
    if "--compare" in sys.argv:
        a, b = sys.argv[sys.argv.index("--compare") + 1: sys.argv.index("--compare") + 3]
        report = [f"# Layer test {time.strftime('%Y-%m-%d %H:%M')} (nothing moved)"]
        switch, _ = compare(a, b, report)
        report.append(f"- the retrain would {'switch to' if switch else 'keep'} {'the second' if switch else 'the first'} ({b if switch else a})")
        print("\n".join(report)); sys.exit(0)

    if not force:
        last = last_attempt(ROOT)
        # not running is a normal outcome, so exit 0 (launchd showed the nightly job as failed every night)
        if time.time() - last < 7 * 86400: print("not due"); sys.exit(0)
        if not on_power() or idle_s() < 600: print("not now: needs power and 10 min away from the keyboard"); sys.exit(0)

    report = [f"# Retrain {time.strftime('%Y-%m-%d %H:%M')}"]
    # 1. the rolling test set: lines since the last retrain, left out of training below
    n_items = fresh_set(report)
    if n_items < MIN_ITEMS:
        report.append(f"- {n_items} fresh lines, too few to tell two layers apart: no retrain this time (tried again tomorrow)")
        write_report(report)
        return
    # Pin a first-run adapter mtime before a winning layer replaces that file.
    # Gate refitting must use exactly the cutoff used by the comparison.
    if not STAMP.exists():
        cut = last_retrain(ROOT)
        if cut:
            STAMP.parent.mkdir(parents=True, exist_ok=True)
            STAMP.write_text(str(cut))
    code, line = step("bench/people_fresh.py", timeout=900)
    report.append(f"- the user's older lines per chat: {line}")
    if code:
        report.append("- no per-chat lines: the Beeper test would not match how Drafter types; no retrain this time")
        write_report(report)
        return
    # 2. Train on this week's staged phrases, leaving the timestamp-free live corpus
    # at the old cutoff for every bench, gate refit and retry until comparison completes.
    staged = ROOT / "data/phrases-next.jsonl"
    try:
        # training lines come from the dated corpus with per-source weights (bench/corpus.py, corpus.WEIGHTS; Argon
        # review 25), rebuilt now so this week's lines are in; the fresh test lines are held out by make_train
        for script, args in (("engine/memory.py", ("build", "--output", str(staged))),
                             ("bench/corpus.py", ()),
                             ("bench/make_train.py", ("--corpus", str(ROOT / "data/corpus.jsonl")))):
            code, line = step(script, *args)
            report.append(f"- {script}: {line}")
            if code: raise RuntimeError(f"{script} failed ({code})")
    except Exception as e:
        report.append(f"- training data failed: {e}")
        write_report(report)
        return
    ok, switch, rec_new = False, False, None
    try:
        # paused=True terminates the server through Main.swift. Keep it alive but
        # unload its model instead, through training AND the full comparison.
        with sleeping_engine(report):
            shutil.rmtree(ROOT / "data/adapters-new", ignore_errors=True)
            r = subprocess.run([PY, str(ROOT / "bench/train.py"), str(RECIPE["iters"]), "--adapter-path", str(ROOT / "data/adapters-new")],
                               capture_output=True, text=True, timeout=3600, stdin=subprocess.DEVNULL)
            ok = r.returncode == 0 and (ROOT / "data/adapters-new/adapters.safetensors").exists()
            report.append(f"- training: {'done' if ok else 'failed: ' + r.stderr[-300:]}")
            if ok:
                switch, rec_new = _compare("data/adapters", "data/adapters-new", report)
    except Exception as e:
        switch, rec_new = False, None
        report.append(f"- retrain failed: {e}")
    if ok:
        if switch:
            shutil.rmtree(ROOT / "data/adapters-prev", ignore_errors=True)
            shutil.move(ROOT / "data/adapters", ROOT / "data/adapters-prev")
            shutil.move(ROOT / "data/adapters-new", ROOT / "data/adapters")
            # the gate learns what this model's probabilities mean: refit it on the new layer's recording
            report.append(f"- switched to the new layer; the old one is in data/adapters-prev; gate: {step('bench/gate.py', str(rec_new), '--save')[1][:80]}")
            subprocess.run(["launchctl", "kickstart", "-k", f"gui/{os.getuid()}/" + __import__("local").launchd_label()], capture_output=True)
        else:
            report.append("- kept the current layer" +
                          ("; test cut short or failed, compare again before switching" if rec_new is None else ""))
    # A failed comparison throttles training, but must not advance the replay cutoff.
    if ok:
        STAMP.parent.mkdir(parents=True, exist_ok=True)
        STAMP.with_name("last-retrain-attempt").write_text(str(time.time()))
        if rec_new is not None:
            # Publish only after comparison AND gate refitting; retries rebuild staging.
            staged.replace(ROOT / "data/phrases.jsonl")
            STAMP.write_text(str(time.time()))
    write_report(report)


def write_report(report):
    folder = ROOT / "data/review"
    folder.mkdir(parents=True, exist_ok=True)
    (folder / f"retrain-{time.strftime('%Y-%m-%d')}.md").write_text("\n".join(report) + "\n")
    print("\n".join(report))


if __name__ == "__main__":
    main()

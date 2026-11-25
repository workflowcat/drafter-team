"""Background jobs on a server you control (the `server` integration: data/drafter.local.json integrations.server, off
by default; the host is an ssh alias with Docker): a small queue on the Mac and one driver. Off, nothing is queued or sent.

    .venv/bin/python -B bench/jobs.py add careful <recording folder>   # queue a careful re-transcribe of a call or long note
    .venv/bin/python -B bench/jobs.py add index                        # queue the journal index (one at a time)
    .venv/bin/python -B bench/jobs.py run [--max N]                    # run what is due; the nightly and "on demand" call this
    .venv/bin/python -B bench/jobs.py status
    .venv/bin/python -B bench/jobs.py smoke [careful|index|check] [--dry-run]   # made-up audio and lines only: no data/ read

The queue is data/jobs/queue/<id>.json: {id, kind, inputs, created, tries, next_at, error}. A run takes each due job in
order: it stages the inputs in a temp folder on the Mac, sends them to ~/drafter-jobs/job-<id>/in, runs the kind in the
drafter-jobs container (`nice -n 19`, --cpus 10, --memory 16g; models in the volume drafter-hf-cache, fetched by the
first run), pulls back only the kind's result files, and removes the job folder and
the container in a finally, on success and on failure. When the server cannot be reached (Mac offline, server down),
the job waits: tries + 1 and the next try 15 min, 30 min, ... up to 6 h later; after 8 failed runs it moves to
data/jobs/failed/. Nothing on the Mac waits for a job: the recording page shows the careful text once it is there, and
search falls back to its own index when there is no journal index.

A kind is (stage inputs -> files + container command, result files, finish on the Mac). The team call archive
(docs/roadmap.md item 9) adds a kind here and reuses the queue, the transport, the caps and the clean-up."""
import argparse, fcntl, json, os, shlex, shutil, subprocess, sys, tempfile, time, uuid, wave
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "engine"))
import local as _local
HOST = str(_local.setting("server", "host") or "").strip()   # the ssh alias; empty or off: no job runs (team round, 25 November 2026)


def server_on():
    return _local.enabled("server") and bool(HOST)
IMAGE = "drafter-jobs"
CACHE = "drafter-hf-cache"
REMOTE = "drafter-jobs"
CPUS, MEMORY = 10, "16g"
CAREFUL_MODEL = "large-v3-turbo"    # 0.52 min per audio min on 10 threads; large-v3 1.76 (docs/rounds/2026-11-17-jobs.md)
CAREFUL_BEAM = 5
MAX_TRIES = 8
TEST_MARK = "⟦drafter-test⟧"


def data_dir():
    return Path(os.environ.get("DRAFTER_DATA") or ROOT / "data")


def qdir(sub="queue"):
    d = data_dir() / "jobs" / sub
    d.mkdir(parents=True, exist_ok=True)
    return d


def backoff(tries):
    return min(6 * 3600, 900 * 2 ** max(0, tries - 1))


# MARK: kinds

def wav_secs(p):
    try:
        with wave.open(str(p)) as w: return w.getnframes() / w.getframerate()
    except Exception: return 0.0


def careful_stage(job, dest):
    """A recording folder -> its sides' wav and job.json. None when the audio is gone (pruned after 14 days)."""
    d = Path(job["inputs"]["dir"])
    meta = {}
    try: meta = json.loads((d / "meta.json").read_text())
    except Exception: pass
    sides = []
    for name in ("me", "them"):
        f = d / f"{name}.wav"
        if f.exists() and wav_secs(f) >= 1:
            shutil.copy(f, dest / f"{name}.wav"); sides.append({"name": name, "file": f"{name}.wav"})
    if not sides: return None
    people = ((meta.get("event") or {}).get("people") or [])[:12]
    (dest / "job.json").write_text(json.dumps({"sides": sides, "model": job["inputs"].get("model", CAREFUL_MODEL),
                                               "beam": job["inputs"].get("beam", CAREFUL_BEAM),
                                               "language": job["inputs"].get("language"), "hint": ", ".join(people)}, ensure_ascii=False))
    return ["careful"], [f"{s['name']}.json" for s in sides] + ["meta.json"]


def careful_finish(job, back):
    """careful.json beside the recording: {model, at, me:[...], them:[...]}; the recording page merges the sides."""
    d = Path(job["inputs"]["dir"])
    meta = json.loads((back / "meta.json").read_text())
    out = {"model": meta["model"], "at": time.time(), "min_per_audio_min": meta["min_per_audio_min"]}
    for name in ("me", "them"):
        f = back / f"{name}.json"
        if f.exists(): out[name] = json.loads(f.read_text())
    if d.exists():
        tmp = d / ".careful.json.tmp"
        tmp.write_text(json.dumps(out, ensure_ascii=False)); tmp.replace(d / "careful.json")
    return meta


def journal_items(data):
    """What the journal holds as text, in rows {id, at, kind, text}: voice takes, lines he sent, his own journal items,
    and recordings' transcripts. Copies (the clipboard) stay out: mostly others' text, sometimes secrets.
    Rows holding the test mark never go."""
    out = []

    def jsonl(name):
        p = data / name
        if not p.exists(): return []
        rows = []
        for l in p.read_text(encoding="utf-8", errors="ignore").splitlines():
            try: rows.append(json.loads(l))
            except Exception: pass
        return rows
    for i, r in enumerate(jsonl("takes.jsonl")):
        out.append({"id": f"v:{r.get('id', i)}", "at": r.get("t", 0), "kind": "said", "text": r.get("text", "")})
    for i, r in enumerate(jsonl("typed.jsonl")):
        out.append({"id": f"t:{r.get('id', int(r.get('t', i) * 1000))}", "at": r.get("t", 0), "kind": "typed", "text": r.get("text", "")})
    try:
        for it in json.loads((data / "journal.json").read_text()).get("items", []):
            out.append({"id": f"j:{it['id']}", "at": it.get("at", 0), "kind": "own", "text": it.get("text", "")})
    except Exception: pass
    calls = data / "calls"
    if calls.exists():
        for d in sorted(p for p in calls.iterdir() if p.is_dir()):
            t = d / "transcript.txt"
            if not t.exists(): continue
            try: started = json.loads((d / "meta.json").read_text()).get("started", 0)
            except Exception: started = t.stat().st_mtime
            out.append({"id": f"d:{d}", "at": started, "kind": "call", "text": t.read_text(encoding="utf-8", errors="ignore")})
    return [r for r in out if isinstance(r["text"], str) and len(r["text"].strip()) >= 12 and TEST_MARK not in r["text"]]


def index_stage(job, dest):
    rows = job["inputs"].get("rows") or journal_items(data_dir())
    (dest / "items.jsonl").write_text("".join(json.dumps({"id": r["id"], "text": r["text"]}, ensure_ascii=False) + "\n" for r in rows), encoding="utf-8")
    (dest / "rows.json").write_text(json.dumps([{k: r[k] for k in ("id", "at", "kind")} for r in rows]))   # stays on the Mac
    return ["index"], ["vectors.npy", "items.json", "tags.json", "meta.json"]


def index_finish(job, back, stage):
    """data/jobs/journal-index/: vectors.npy (float16), items.json ({id, at, kind, tags}), tags.json, meta.json."""
    dest = Path(job["inputs"].get("out") or data_dir() / "jobs" / "journal-index")
    tmp = dest.with_name(dest.name + ".new")
    shutil.rmtree(tmp, ignore_errors=True); tmp.mkdir(parents=True)
    rows = {r["id"]: r for r in json.loads((stage / "rows.json").read_text())}
    items = [{**rows.get(it["id"], {"id": it["id"]}), "tags": it["tags"]} for it in json.loads((back / "items.json").read_text())]
    shutil.copy(back / "vectors.npy", tmp / "vectors.npy")
    (tmp / "items.json").write_text(json.dumps(items, ensure_ascii=False))
    shutil.copy(back / "tags.json", tmp / "tags.json")
    meta = json.loads((back / "meta.json").read_text()); meta["at"] = time.time()
    meta["bytes"] = sum(f.stat().st_size for f in tmp.iterdir())
    (tmp / "meta.json").write_text(json.dumps(meta, indent=1))
    old = dest.with_name(dest.name + ".old")
    shutil.rmtree(old, ignore_errors=True)
    if dest.exists(): dest.rename(old)
    tmp.rename(dest); shutil.rmtree(old, ignore_errors=True)
    return meta


KINDS = {
    "careful": {"stage": careful_stage, "finish": lambda job, back, stage: careful_finish(job, back), "hours": 6},
    "index": {"stage": index_stage, "finish": index_finish, "hours": 3},
    "check": {"stage": lambda job, dest: (["check"], ["meta.json"]), "finish": lambda job, back, stage: json.loads((back / "meta.json").read_text()), "hours": 1},
}


# MARK: the queue

def add(kind, inputs=None, data=None):
    """Queue a job. The same careful folder or a second index while one waits is not queued twice. -> the job."""
    if kind not in KINDS: raise SystemExit(f"unknown kind {kind!r}: {sorted(KINDS)}")
    inputs = inputs or {}
    for f in qdir().glob("*.json"):
        j = json.loads(f.read_text())
        if j["kind"] == kind and j["inputs"] == inputs: return j
    job = {"id": time.strftime("%Y%m%d-%H%M%S-") + uuid.uuid4().hex[:6], "kind": kind, "inputs": inputs,
           "created": time.time(), "tries": 0, "next_at": 0, "error": ""}
    save(job)
    return job


def save(job, sub="queue"):
    p = qdir(sub) / f"{job['id']}.json"
    tmp = p.with_suffix(".tmp"); tmp.write_text(json.dumps(job, ensure_ascii=False, indent=1)); tmp.replace(p)


def due(now=None):
    now = now or time.time()
    jobs = [json.loads(f.read_text()) for f in sorted(qdir().glob("*.json"))]
    return [j for j in jobs if j.get("next_at", 0) <= now]


def reachable(runner):
    try: runner(["ssh", "-o", "ConnectTimeout=8", "-o", "BatchMode=yes", HOST, "true"], 30); return True
    except Exception: return False


# MARK: one run on the server

def plan(job, files, cmd):
    """The remote commands of one job, in order: (label, argv). Paths relative to the server home; docker -v needs
    absolute ones, so those use $HOME inside the remote shell."""
    run, name = f"{REMOTE}/job-{job['id']}", f"drafter-job-{job['id']}"
    docker = ["docker", "run", "--rm", "--name", name, "--cpus", str(CPUS), "--memory", MEMORY, "--memory-swap", MEMORY,
              "-e", f"OMP_NUM_THREADS={CPUS}", "-v", f"{CACHE}:/cache", "-v", f"$HOME/{run}/in:/work/in:ro",
              "-v", f"$HOME/{run}/out:/work/out", IMAGE, "nice", "-n", "19", "python", "/app/job.py", *cmd, "--threads", str(CPUS)]
    q = lambda argv: " ".join(a if a.startswith("$HOME/") else shlex.quote(a) for a in argv)
    image = [str(ROOT / "bench/remote/jobs/Dockerfile"), str(ROOT / "bench/remote/jobs/job.py"), str(ROOT / "engine/embed_np.py")]
    return run, name, [
        ("mkdir", ["ssh", HOST, f"mkdir -p {REMOTE}/image {run}/in {run}/out"]),
        ("image files", ["rsync", "-a", *image, f"{HOST}:{REMOTE}/image/"]),
        ("build", ["ssh", HOST, f"docker build -q -t {IMAGE} {REMOTE}/image"]),
        ("inputs up", ["rsync", "-a", "{stage}/", f"{HOST}:{run}/in/"]),
        ("run", ["ssh", HOST, q(docker)]),
        ("back", ["rsync", "-a", *[f"--include={f}" for f in files], "--exclude=*", f"{HOST}:{run}/out/", "{back}/"]),
    ]


def cleanup_cmd(run, name):
    return ["ssh", HOST, f"docker rm -f {name} >/dev/null 2>&1; rm -rf {run}; test ! -e {run}"]


def run_job(job, runner, dry_run=False, say=print, stage_extra=None):
    """One job, start to end. -> the finish result. Raises on a failed step; the server folder goes anyway."""
    kind = KINDS[job["kind"]]
    t0 = time.time()
    with tempfile.TemporaryDirectory(prefix="drafter-job-") as tmp:
        stage, back = Path(tmp) / "in", Path(tmp) / "back"
        stage.mkdir(); back.mkdir()
        if stage_extra: stage_extra(stage)
        made = kind["stage"](job, stage)
        if made is None: return {"skipped": "inputs gone"}
        cmd, files = made
        run, name, steps = plan(job, files, cmd)
        size = sum(f.stat().st_size for f in stage.iterdir() if f.name != "rows.json")
        say(f"job {job['id']} ({job['kind']}): {size / 1e6:.1f} MB up")
        try:
            for label, argv in steps:
                argv = [a.replace("{stage}", str(stage)).replace("{back}", str(back)) for a in argv]
                if label == "inputs up": argv = argv[:2] + ["--exclude=rows.json"] + argv[2:]
                say(f"[{label}] {shlex.join(argv)}")
                if not dry_run: runner(argv, kind["hours"] * 3600 if label == "run" else 1800)
        finally:
            argv = cleanup_cmd(run, name)
            say(f"[clean] {shlex.join(argv)}")
            if not dry_run:
                try: runner(argv, 300)
                except Exception as e:
                    say(f"WARNING: the job folder may still be on {HOST}: {run} ({e}); delete it: ssh {HOST} 'rm -rf {run}'")
                    raise
        if dry_run: say("dry run: nothing ran"); return {}
        missing = [f for f in files if not (back / f).exists()]
        if missing: raise RuntimeError(f"not back from {HOST}: {missing}")
        res = kind["finish"](job, back, stage)
        res["wall_sec"] = round(time.time() - t0, 1)
        return res


def default_runner(argv, timeout):
    subprocess.run(argv, check=True, timeout=timeout, stdin=subprocess.DEVNULL)


def run_due(runner=None, max_jobs=10, say=print, now=None):
    """Every due job, one at a time, under a lock (the nightly and an on-demand run never overlap). -> results."""
    runner = runner or default_runner
    lock = open(qdir("..") / "run.lock", "w")
    try: fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError: say("another run holds the lock"); return []
    out = []
    try:
        jobs = due(now)[:max_jobs]
        if not jobs: return out
        if not reachable(runner):
            for j in jobs: retry(j, f"{HOST} not reachable", say)
            return out
        for j in jobs:
            try:
                res = run_job(j, runner, say=say)
                j.update(done_at=time.time(), result=res, error="")
                save(j, "done"); (qdir() / f"{j['id']}.json").unlink(missing_ok=True)
                say(f"done {j['id']}: {json.dumps(res)}"); out.append(res)
            except Exception as e:
                retry(j, str(e)[:300], say)
    finally:
        lock.close()
    return out


def retry(job, why, say):
    job["tries"] += 1; job["error"] = why
    if job["tries"] >= MAX_TRIES:
        save(job, "failed"); (qdir() / f"{job['id']}.json").unlink(missing_ok=True)
        say(f"failed {job['id']} after {job['tries']} tries: {why}"); return
    job["next_at"] = time.time() + backoff(job["tries"])
    save(job); say(f"waits {job['id']} ({why}); next try in {backoff(job['tries']) / 60:.0f} min")


# MARK: what the nightly queues

def nightly_queue(min_minutes=3):
    """Finished calls and long notes of at least min_minutes with audio and no careful.json yet, and one index."""
    calls = data_dir() / "calls"
    n = 0
    if calls.exists():
        for d in sorted(p for p in calls.iterdir() if p.is_dir()):
            if (d / "careful.json").exists() or not (d / "me.wav").exists() or (d / "me.pcm").exists(): continue
            if not ((d / "transcript.txt").exists() or (d / "lines.json").exists()): continue
            if max(wav_secs(d / "me.wav"), wav_secs(d / "them.wav")) < min_minutes * 60: continue
            add("careful", {"dir": str(d)}); n += 1
    add("index")
    return n


# MARK: smoke: made-up inputs only

SMOKE_UK = ["Добрий день, це вигадана розмова для перевірки.", "Ми домовились надіслати макет буклета до п'ятниці.",
            "Бюджет на друк треба погодити з бухгалтерією завтра зранку."]
SMOKE_EN = ["Hello, this is a made up call to test the careful pass.", "Let's move the deck review to Thursday afternoon.",
            "Please send the invoice draft before the end of the week."]


def say_wav(lines, voice, dest):
    """macOS `say` reads made-up lines into a 16 kHz mono 16-bit wav."""
    aiff = dest.with_suffix(".aiff")
    subprocess.run(["say", "-v", voice, "-o", str(aiff), " ".join(lines)], check=True)
    subprocess.run(["afconvert", "-f", "WAVE", "-d", "LEI16@16000", "-c", "1", str(aiff), str(dest)], check=True)
    aiff.unlink()


def smoke_call(folder, repeat=1):
    """A made-up recording folder: me.wav (Ukrainian, Lesya) and them.wav (English, Samantha), meta.json."""
    folder.mkdir(parents=True, exist_ok=True)
    say_wav(SMOKE_UK * repeat, "Lesya", folder / "me.wav")
    say_wav(SMOKE_EN * repeat, "Samantha", folder / "them.wav")
    (folder / "meta.json").write_text(json.dumps({"call": True, "started": time.time(), "event": {"title": "made-up", "people": ["Test Person"]}}))
    return folder


def smoke_rows(n=60, long=False):
    topics = [("друк буклет макет", "the print run of the booklet"), ("бюджет рахунок оплата", "the invoice and the budget"),
              ("дзвінок клієнт зустріч", "a client call next week"), ("код реліз тести", "the release and its tests")]
    rows = []
    for i in range(n):
        uk, en = topics[i % 4]
        rows.append({"id": f"smoke:{i}", "at": 1.7e9 + i * 3600, "kind": "said",
                     "text": (f"Вигаданий рядок {i}: {uk}, номер {i % 7}. " if i % 2 else f"Made-up line {i} about {en}, item {i % 7}. ") * (8 if long else 1)})
    return rows


def smoke(kind, dry_run=False, repeat=1, model=None, say=print, beam=None, rows=None):
    with tempfile.TemporaryDirectory(prefix="drafter-jobs-smoke-") as tmp:
        tmp = Path(tmp)
        if kind == "careful":
            folder = smoke_call(tmp / "call", repeat)
            job = {"id": "smoke-" + uuid.uuid4().hex[:6], "kind": "careful", "inputs": {"dir": str(folder), **({"model": model} if model else {}), **({"beam": beam} if beam else {})}}
        elif kind == "index":
            job = {"id": "smoke-" + uuid.uuid4().hex[:6], "kind": "index", "inputs": {"rows": smoke_rows(rows or 60, long=bool(rows)), "out": str(tmp / "index")}}
        else:
            job = {"id": "smoke-" + uuid.uuid4().hex[:6], "kind": "check", "inputs": {}}
        res = run_job(job, default_runner, dry_run=dry_run, say=say)
        if kind == "careful" and not dry_run:
            c = json.loads((folder / "careful.json").read_text())
            say("careful: " + " | ".join(f"{k}: {' '.join(r['text'] for r in c.get(k, []))}" for k in ("me", "them")))
        if kind == "index" and not dry_run:
            say("tags: " + ", ".join(t["tag"] for t in json.loads((tmp / "index/tags.json").read_text())))
        return res


def main(argv=None):
    p = argparse.ArgumentParser(description="Drafter's background jobs on your server (integrations.server)")
    sub = p.add_subparsers(dest="cmd", required=True)
    a = sub.add_parser("add"); a.add_argument("kind", choices=["careful", "index"]); a.add_argument("dir", nargs="?")
    r = sub.add_parser("run"); r.add_argument("--max", type=int, default=10)
    sub.add_parser("status")
    sub.add_parser("nightly")
    s = sub.add_parser("smoke"); s.add_argument("kind", nargs="?", default="careful", choices=["careful", "index", "check"])
    s.add_argument("--dry-run", action="store_true"); s.add_argument("--repeat", type=int, default=1); s.add_argument("--model"); s.add_argument("--beam", type=int); s.add_argument("--rows", type=int)
    a = p.parse_args(argv)
    if a.cmd in ("add", "run", "nightly") and not server_on():
        print("server jobs are off: turn on integrations.server (enabled, host) in data/drafter.local.json"); return 0
    if a.cmd == "add":
        if a.kind == "careful" and not a.dir: raise SystemExit("careful needs a recording folder")
        print(json.dumps(add(a.kind, {"dir": str(Path(a.dir).resolve())} if a.kind == "careful" else {})))
    elif a.cmd == "run": run_due(max_jobs=a.max)
    elif a.cmd == "nightly": print(f"queued {nightly_queue()} careful"); run_due()
    elif a.cmd == "status":
        for sub_ in ("queue", "done", "failed"):
            js = [json.loads(f.read_text()) for f in sorted(qdir(sub_).glob("*.json"))]
            print(f"{sub_}: {len(js)}")
            for j in js[-5:]: print(f"  {j['id']} {j['kind']} tries {j['tries']} {j.get('error', '')[:80]}")
    elif a.cmd == "smoke": print(json.dumps(smoke(a.kind, a.dry_run, a.repeat, a.model, beam=a.beam, rows=a.rows)))


if __name__ == "__main__":
    main()

"""Loads the action files in actions/ and picks the one whose trigger matches the line being typed."""
import importlib.util, sys
from pathlib import Path

DIR = Path(__file__).resolve().parent.parent / "actions"
sys.path.insert(0, str(DIR))
sys.path.insert(0, str(Path(__file__).resolve().parent))
import integrations


def _load():
    out = []
    for p in sorted(DIR.glob("*.py")):
        if p.name.startswith("_"): continue
        spec = importlib.util.spec_from_file_location("action_" + p.stem, p)
        m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
        out.append(m)
    return out


ALL = _load()
BY_ID = {a.ID: a for a in ALL}


class Found:
    def __init__(self, mod, line): self.mod, self.line = mod, line

    def extract(self, before, ask):
        r = self.mod.extract(self.line, ask)
        if not r: return None
        if r.get("run", {}).get("kind") == "none": return None
        return {"id": self.mod.ID, **r}


_seen = {}


def cached(found, before, ask):
    """The same line is not read twice: pauses while typing would otherwise re-run the model on it."""
    k = (found.mod.ID, found.line.strip())
    if k not in _seen:
        if len(_seen) > 200: _seen.clear()
        try:
            _seen[k] = found.extract(before, ask)
        except Exception as e:
            if type(e).__name__ == "Cancelled": return None     # he typed on; read it again next time
            raise
    return _seen[k]


SETTINGS = Path(__file__).resolve().parent.parent / "data" / "settings.json"


def off():
    """Action ids switched off (data/settings.json `actions_off`, set from Aleph or by hand)."""
    try: return set(__import__("json").loads(SETTINGS.read_text()).get("actions_off", []))
    except Exception: return set()


def usable(a):
    """Every private integration the action needs (its NEEDS) is on in the local config and answers."""
    return integrations.all_available(getattr(a, "NEEDS", ()))


def detect(before):
    """Only the last line counts, and only once it has a few words."""
    line = before.splitlines()[-1] if before.strip() else ""
    if len(line.split()) < 3: return None
    skip = off()
    for a in ALL:
        if a.ID in skip or not usable(a): continue
        if a.TRIGGER.search(line): return Found(a, line)
    return None


import queue as _queue, threading as _threading, uuid as _uuid

PENDING = []          # app-side runs waiting for the Drafter app (EventKit lives there, with its permission)
_RESULTS = {}
_LOCK = _threading.Lock()
_NEW = _threading.Condition(_LOCK)   # a job came in: wakes a /pending?wait= that is waiting for one


def run_python(id_, fields, wait=20):
    """Runs an action by id. Python actions run here; app-side ones (calendar, reminder) are handed to the
    Drafter app, which polls /pending, runs them and reports to /done."""
    a = BY_ID.get(id_)
    if not a: return {"error": f"no action {id_}"}
    if not usable(a): return {"error": f"{id_} is off on this Mac"}
    if id_ in off(): return {"error": f"{id_} is switched off"}   # the same list the chips honour
    try:
        if hasattr(a, "run"): return {"done": a.run(fields)}
        if not hasattr(a, "to_run"): return {"error": f"{id_} has no runner"}
        job = {"job": _uuid.uuid4().hex[:12], "id": id_, "run": a.to_run(fields)}
    except Exception as e:
        return {"error": str(e)[:200]}
    ev = _threading.Event()
    with _NEW: PENDING.append(job); _RESULTS[job["job"]] = ev; _NEW.notify_all()
    if not ev.wait(wait):
        with _LOCK:
            if job in PENDING: PENDING.remove(job)
        return {"error": "Drafter app did not pick it up (is it running and not paused?)"}
    return getattr(ev, "result", {"error": "no result"})


def queue_app(run, wait=20):
    """An app-side step with no action file (eventkit.free: free slots from his calendars, for Aleph's bar)."""
    job = {"job": _uuid.uuid4().hex[:12], "id": run.get("kind", ""), "run": run}
    ev = _threading.Event()
    with _NEW: PENDING.append(job); _RESULTS[job["job"]] = ev; _NEW.notify_all()
    if not ev.wait(wait):
        with _LOCK:
            if job in PENDING: PENDING.remove(job)
        return {"error": "Drafter app did not pick it up (is it running and not paused?)"}
    return getattr(ev, "result", {"error": "no result"})


def take_pending(wait=0.0):
    """The app-side jobs waiting now. wait > 0: when there are none, hold up to `wait` s for one (the app asks again
    as soon as this answers, so a job reaches it at once and an idle app asks ~2 times a minute, not 60)."""
    with _NEW:
        if not PENDING and wait > 0: _NEW.wait_for(lambda: PENDING, timeout=wait)
        out = list(PENDING); PENDING.clear()
    return out


def finish(job_id, result):
    with _LOCK: ev = _RESULTS.pop(job_id, None)
    if ev: ev.result = result; ev.set()

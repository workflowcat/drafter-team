"""The model catalog (Cotypist parity round 2, 15 November 2026): which typing models Drafter offers, what each was
measured at on this Mac, which one suits a Mac, whether its weights are here, the download the user starts, and the switch.

engine/catalog.json holds the numbers (the big and Qwen3.5 rounds' trial table). Rules here are plain functions so the
tests run them on made-up tables; the server holds the one model and calls switch() on the worker thread.

Never two models in memory: switch() unloads the current model before it loads the next, and loads the live model
back when the next one fails. No network here except the download the user starts (engine/fetch_model.py, its own process).
"""
import ctypes, json, os, subprocess, sys, threading, time
from pathlib import Path

HERE = Path(__file__).resolve().parent
FILE = HERE / "catalog.json"
LIVE = "live"

# memory budget for the text model (app/Voice.swift: a long call read again lets the voice engine take 3.4 GB,
# engine/voice.py DRAFTER_FILE_CAP_GB; macOS and the user's apps keep the rest)
VOICE_GB = 3.4
SYSTEM_GB = 6.0
SHARE = 0.25          # never more than a quarter of the Mac's memory for typing
P95_MS = 150          # a ghost later than this at the 95th key feels slow (the live model: 126 ms)
MARGIN_GB = 1.0       # free memory kept after a switch


def load(path=FILE):
    """-> list of catalog entries (dicts), in the file's order."""
    return json.loads(Path(path).read_text())["models"]


def entry(models, mid):
    return next((m for m in models if m["id"] == mid), None)


def by_repo(models, repo):
    return next((m for m in models if m["repo"] == repo), None)


# ---- this Mac -------------------------------------------------------------------------------------------------------

_libc = None


def _sysctl_int(name, size):
    global _libc
    try:
        _libc = _libc or ctypes.CDLL("/usr/lib/libSystem.B.dylib")
        v = (ctypes.c_int64 if size == 8 else ctypes.c_int32)(0)
        n = ctypes.c_size_t(size)
        if _libc.sysctlbyname(name.encode(), ctypes.byref(v), ctypes.byref(n), None, 0) == 0: return int(v.value)
    except Exception:
        pass
    return None


def machine():
    """{total_gb, free_gb}: hw.memsize and kern.memorystatus_level (the share macOS counts as available, as the
    app's Budget.free reads it). free_gb is None when it cannot be read."""
    total = (_sysctl_int("hw.memsize", 8) or 0) / 2**30
    level = _sysctl_int("kern.memorystatus_level", 4)
    return {"total_gb": round(total, 1), "free_gb": round(total * level / 100, 1) if level is not None and total else None}


def budget_gb(total_gb, free_gb=None, current_gb=0.0):
    """Memory the typing model may use: what is left after macOS, the user's apps and the voice engine's worst case, at most
    a quarter of the Mac, and no more than is free now (plus what the current model gives back) less a margin."""
    b = min(total_gb - SYSTEM_GB - VOICE_GB, total_gb * SHARE)
    if free_gb is not None: b = min(b, free_gb + current_gb - MARGIN_GB)
    return round(b, 2)


def quality(m):
    """Order of quality: words in a row at every key (one gate each, the fairest column), then first words."""
    return (m["words_all"], m["first_word_pct"], m["kept_per_1k"])


def recommend(models, total_gb, free_gb=None, current_gb=0.0, speed_scale=1.0, p95_limit=P95_MS):
    """-> (id, one-line reason). The best quality whose p95 (measured here, times `speed_scale` for a slower Mac)
    stays under the limit and whose memory fits the budget; else the fastest that fits; else the smallest."""
    budget = budget_gb(total_gb, free_gb, current_gb)
    fits = [m for m in models if m["memory_gb"] <= budget]
    quick = [m for m in fits if m["p95_ms"] * speed_scale < p95_limit]
    if quick:
        best = max(quick, key=quality)
        why = (f"best words in a row ({best['words_all']:.2f}) of the models that answer in time "
               f"(p95 {round(best['p95_ms'] * speed_scale)} ms, under {p95_limit}) and fit {budget:.1f} GB")
        if best.get("layer"):
            others = [m for m in models if m.get("layer") and m is not best]
            why += "; with your own layer" if others else "; the only one with your own layer"
        return best["id"], why
    if fits:
        best = min(fits, key=lambda m: m["p95_ms"])
        return best["id"], f"none answers under {p95_limit} ms here; the fastest that fits {budget:.1f} GB"
    best = min(models, key=lambda m: m["memory_gb"])
    return best["id"], f"none fits {budget:.1f} GB; the smallest ({best['memory_gb']:.1f} GB)"


def speed_mark(m):
    """1-3: three = p95 under 130 ms, two = under the limit, one = slower."""
    return 3 if m["p95_ms"] < 130 else 2 if m["p95_ms"] < P95_MS else 1


def quality_mark(models, m):
    """1-3 against the best in the catalog: three = within 5 %, two = within 12 %, one = further."""
    top = max(x["words_all"] for x in models) or 1
    r = m["words_all"] / top
    return 3 if r >= 0.95 else 2 if r >= 0.88 else 1


# ---- weights on this Mac --------------------------------------------------------------------------------------------

def hub_cache():
    try:
        from huggingface_hub import constants
        return Path(constants.HF_HUB_CACHE)
    except Exception:
        return Path(os.environ.get("HF_HOME", Path.home() / ".cache/huggingface")) / "hub"


def repo_dir(repo, cache=None):
    return Path(cache or hub_cache()) / ("models--" + repo.replace("/", "--"))


def local_path(m, cache=None):
    """The snapshot folder holding every weight file of this entry, or None (never a network call)."""
    d = repo_dir(m["repo"], cache)
    rev = m.get("rev")
    if not rev:
        try: rev = (d / "refs" / "main").read_text().strip()
        except OSError: return None
    snap = d / "snapshots" / rev
    if not (snap / "config.json").exists(): return None
    weights = list(snap.glob("*.safetensors"))
    if not weights: return None
    idx = snap / "model.safetensors.index.json"
    if idx.exists():
        try:
            need = set(json.loads(idx.read_text()).get("weight_map", {}).values())
            if any(not (snap / f).exists() for f in need): return None
        except Exception:
            return None
    if any(not w.exists() or w.stat().st_size == 0 for w in weights): return None   # a link to a missing blob
    return snap


def downloaded(m, cache=None):
    return local_path(m, cache) is not None


def bytes_here(repo, cache=None):
    """Bytes of this repo in the cache now, partial files included (the download's progress)."""
    n = 0
    for root, _, files in os.walk(repo_dir(repo, cache) / "blobs"):
        for f in files:
            try: n += os.stat(os.path.join(root, f)).st_size
            except OSError: pass
    return n


class Downloads:
    """Downloads the user started, one process each (engine/fetch_model.py), cancellable by that exact process."""
    def __init__(self, spawn=None, cache=None):
        self.jobs, self.lock, self.cache = {}, threading.Lock(), cache
        self.spawn = spawn or (lambda m: subprocess.Popen(
            [sys.executable, "-B", str(HERE / "fetch_model.py"), m["repo"], m.get("rev") or ""],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL))

    def start(self, m):
        with self.lock:
            j = self.jobs.get(m["id"])
            if j and j["proc"].poll() is None: return self.state(m)
            if downloaded(m, self.cache): return {"state": "done", "pct": 100}
            self.jobs[m["id"]] = {"proc": self.spawn(m), "t": time.time(), "state": "downloading", "m": m}
            print(f"model download: {m['id']} started", flush=True)
        return self.state(m)

    def cancel(self, mid):
        with self.lock:
            j = self.jobs.get(mid)
            if not j or j["proc"].poll() is not None: return False
            j["proc"].terminate()
            try: j["proc"].wait(5)
            except Exception: j["proc"].kill()
            j["state"] = "cancelled"
            print(f"model download: {mid} cancelled", flush=True)
            return True

    def state(self, m):
        """{state: none|downloading|done|failed|cancelled, pct}."""
        if downloaded(m, self.cache) and not (self.jobs.get(m["id"]) and self.jobs[m["id"]]["proc"].poll() is None):
            return {"state": "done", "pct": 100}
        j = self.jobs.get(m["id"])
        if not j: return {"state": "none", "pct": 0}
        code = j["proc"].poll()
        if j["state"] == "downloading" and code is not None:
            j["state"] = "done" if code == 0 and downloaded(m, self.cache) else "failed"
            print(f"model download: {m['id']} {j['state']} in {time.time() - j['t']:.0f} s", flush=True)
        total = m["disk_gb"] * 1e9
        pct = 100 if j["state"] == "done" else min(99, int(bytes_here(m["repo"], self.cache) * 100 / total)) if total else 0
        return {"state": j["state"], "pct": pct}


# ---- the switch -----------------------------------------------------------------------------------------------------

def marker_path(data):
    return Path(data) / "cache" / "model-loading.json"


def start_pick(models, settings, data, env_repo=None, cache=None):
    """The model the engine starts with: DRAFTER_MODEL (a bench run) wins; else the user's pick in Settings when its weights
    are here; else live. A pick whose load killed the engine (the guard; the marker file is still there) is skipped
    once, and the marker goes. -> (entry or None for an unknown repo, note)"""
    live = entry(models, LIVE)
    # the app passes the old settings "model" (the live repo) as DRAFTER_MODEL on every start: that must not hide
    # the user's pick in the picker; a bench run names another repo and still wins
    if env_repo and not ((settings or {}).get("typingModel") and live and env_repo == live["repo"]):
        return by_repo(models, env_repo), "env"
    mk = marker_path(data)
    if mk.exists():
        mk.unlink(missing_ok=True)
        return entry(models, LIVE), "last load did not finish: live"
    pick = entry(models, (settings or {}).get("typingModel") or LIVE)
    if pick is None or pick["id"] == LIVE: return entry(models, LIVE), "live"
    if not downloaded(pick, cache): return entry(models, LIVE), "picked model not downloaded: live"
    return pick, "picked"


LAYERS = "layers"     # data/layers/<name>: a layer trained for a catalog model other than live (never data/adapters*)


def layer_dir(m, data):
    """The folder of an entry's own layer (`"layer": "layers/<name>"`, under data/layers/ only), or None for live's
    `true`, no layer, or a path that leaves data/layers/."""
    lay = m.get("layer")
    if not isinstance(lay, str) or not lay or data is None: return None
    root = (Path(data) / LAYERS).resolve()
    d = (Path(data) / lay).resolve()
    return d if d != root and root in d.parents else None


def adapter_for(m, live_adapter, data=None, log=True):
    """The user's layer only for the model it was trained on: `true` = the live layer (data/adapters, DRAFTER_ADAPTER);
    a string = that folder under data/layers/ when it holds a layer, else None (the model runs as its base, one log
    line, its base gate: gate_name)."""
    lay = m.get("layer")
    if lay is True: return live_adapter
    d = layer_dir(m, data)
    if d is not None and (d / "adapters.safetensors").exists() and (d / "adapter_config.json").exists(): return str(d)
    if lay and log: print(f"model layer: {m['id']} has no layer here, its base model without it", flush=True)
    return None


def has_layer(m, live_adapter, data=None):
    """For /models: whether this entry runs with the user's layer on this Mac (the Personal style slider is on for it)."""
    if m.get("layer") is True: return True
    return adapter_for(m, live_adapter, data, log=False) is not None


def here(models, live_adapter, data=None):
    """The catalog as this Mac has it: an entry whose layer is not here is shown and ranked as what it is. Live without
    a layer is the plain base model (name without " + my style", its numbers were measured with a layer, so it is not
    recommended); an entry for another model's layer that is missing here is left out (its base entry stays). A new
    person's Mac gets the plain list (team round, 25 November 2026)."""
    out = []
    for m in models:
        if not m.get("layer"): out.append(m); continue
        if m.get("layer") is True:
            if live_adapter and (Path(live_adapter) / "adapters.safetensors").exists(): out.append(m)
            else: out.append({**m, "name": m["name"].replace(" + my style", ""), "layer": False, "unranked": True})
        elif has_layer(m, live_adapter, data): out.append(m)
    return out


def ranked(models):
    """The entries recommend() may pick: none whose numbers do not hold on this Mac."""
    return [m for m in models if not m.get("unranked")]


def gate_name(models, m, layered):
    """The gate file an entry uses: its own; an entry whose layer is missing here takes the gate of the catalog entry
    with the same weights and no layer (fitted on that base), else None (the shipped default gate)."""
    if layered or not isinstance(m.get("layer"), str): return m.get("gate")
    base = next((x for x in models if x["repo"] == m["repo"] and not x.get("layer")), None)
    return base["gate"] if base else None


def best_quality(models):
    """The entry with the best words in a row (then first words, kept letters): the picker marks it."""
    return max(models, key=quality)["id"] if models else None


def switch(model, target, live, live_adapter, *, rebuild, set_cap, data, cache=None, src_for=None, free_gb=None):
    """Put `target` in place of the loaded model. Order: check it can load (weights here, memory free), then unload
    the current model, raise the guard to the target's cap, load, read the head again (rebuild). A failed load
    unloads what is left, sets live's cap and loads live. -> (entry now loaded, error word or None, seconds)."""
    t = time.time()
    src_for = src_for or (lambda m: None if m["id"] == LIVE else local_path(m, cache))
    src = src_for(target)
    if target["id"] != LIVE and src is None: return None, "not downloaded", 0.0
    cur_gb = getattr(model, "loaded_gb", lambda: 0.0)()
    if free_gb is not None and target["memory_gb"] > free_gb + cur_gb - MARGIN_GB:
        return None, "not enough free memory", 0.0
    mk = marker_path(data)
    try:
        if target["id"] != LIVE:
            mk.parent.mkdir(parents=True, exist_ok=True); mk.write_text(json.dumps({"id": target["id"], "t": time.time()}))
        model.unload()
        set_cap(target["cap_gb"])
        model.load_as(target["repo"], adapter_for(target, live_adapter, data), src)
        rebuild()
        mk.unlink(missing_ok=True)
        return target, None, time.time() - t
    except Exception as e:
        err = type(e).__name__
        print(f"model switch: {target['id']} failed ({err}), back to live", flush=True)
        model.unload()
        set_cap(live["cap_gb"])
        model.load_as(live["repo"], adapter_for(live, live_adapter, data), None)
        rebuild()
        mk.unlink(missing_ok=True)
        return live, err, time.time() - t

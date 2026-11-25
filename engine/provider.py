"""Connect a model (2026-11-14): with nothing connected Drafter is fully local. Connecting is the user's own act, in
Settings, one of three ways:

  cli        the user's signed-in `claude` CLI (kept-running processes, engine/claude_type.py Worker)
  anthropic  an Anthropic API key (Messages API over HTTPS)
  openai     any OpenAI-compatible endpoint: base URL, key, model name (another provider or a local server)

The choice lives in data/settings.json `connect` ({provider, fastModel, carefulModel, baseURL, apiModel}); keys never do.
A key lives in the macOS Keychain (app/Connect.swift); the app hands it to the engine over the local HTTP port
(POST /model-key) after each engine start, and the engine keeps it in memory only: never in a file, a log or a
process argument. Every feature still has its own switch (engine/cloud.py), off until the user turns it on; cloud.allowed
asks connected() first. One place makes the call: ask() for one-off prompts, ApiWorker for the features that keep a
worker (claude_type.Worker returns one when an API is connected).
"""
import json, os, socket, threading, time, urllib.error, urllib.request
from pathlib import Path
from urllib.parse import urlparse

ROOT = Path(__file__).resolve().parent.parent
SETTINGS = ROOT / "data" / "settings.json"
KINDS = ("cli", "anthropic", "openai")
DEFAULTS = {"provider": "", "fastModel": "claude-haiku-5-5", "carefulModel": "claude-sonnet-5-5", "baseURL": "", "apiModel": ""}
ANTHROPIC = "https://api.anthropic.com"

_keys = {}                    # provider -> key, in memory only
_lock = threading.Lock()
state = {"generation": 0, "last_error": ""}


def _settings():
    try: return json.loads(SETTINGS.read_text())
    except Exception: return {}


def connection(st=None):
    st = _settings() if st is None else st
    c = st.get("connect") if isinstance(st, dict) else None
    out = dict(DEFAULTS)
    if isinstance(c, dict): out.update({k: v for k, v in c.items() if isinstance(v, str)})
    return out


def kind(st=None):
    k = connection(st)["provider"]
    return k if k in KINDS else ""


def connected(st=None):
    """A way is picked, and for an API its key is in memory (handed over by the app from the Keychain)."""
    k = kind(st)
    if k == "cli": return True
    if k == "anthropic": return bool(_keys.get("anthropic"))
    if k == "openai": return bool(_keys.get("openai")) and bool(connection(st)["baseURL"])
    return False


def set_key(provider, key):
    """POST /model-key: the key for `provider` (empty = forget it). A change starts fresh workers."""
    with _lock:
        if provider not in ("anthropic", "openai"): return False
        if key: _keys[provider] = key
        else: _keys.pop(provider, None)
        state["generation"] += 1
    return True


def forget_all():
    with _lock:
        _keys.clear(); state["generation"] += 1


def model_for(alias, st=None):
    """A feature asks for "haiku" (fast helpers) or "sonnet"/"opus" (proofread, rework); the connected way says which
    model that is. The CLI path keeps the alias as it is."""
    c, k = connection(st), kind(st)
    if k == "cli": return alias
    fast = "haiku" in (alias or "")
    if k == "openai" and c["apiModel"]: return c["apiModel"]
    return c["fastModel"] if fast else c["carefulModel"]


def reachable(st=None, timeout=1.5):
    k = kind(st)
    if not k: return False
    host, port = "api.anthropic.com", 443
    base = connection(st)["baseURL"]
    if k == "openai" or (k == "anthropic" and base):
        u = urlparse(base); host = u.hostname or ""; port = u.port or (443 if u.scheme == "https" else 80)
    if not host: return False
    try:
        socket.create_connection((host, port), timeout=timeout).close(); return True
    except OSError:
        return False


class Refused(Exception):
    """The provider said no: a wrong or revoked key, no access to the model."""


def _post(url, headers, body, timeout):
    req = urllib.request.Request(url, data=json.dumps(body).encode(), headers={"Content-Type": "application/json", **headers})
    try:
        return json.loads(urllib.request.urlopen(req, timeout=timeout).read())
    except urllib.error.HTTPError as e:
        if e.code in (401, 403): raise Refused(f"the provider refused the key ({e.code})") from None
        raise


def complete(system, user, model, max_tokens=1024, timeout=30, st=None):
    """One request to the connected API -> the answer text. Raises Refused, or OSError/TimeoutError when it fails."""
    k, c = kind(st), connection(st)
    if k == "anthropic":
        base = (c["baseURL"] or ANTHROPIC).rstrip("/")
        body = {"model": model, "max_tokens": max_tokens, "messages": [{"role": "user", "content": user}]}
        if system: body["system"] = system
        d = _post(base + "/v1/messages", {"x-api-key": _keys.get("anthropic", ""), "anthropic-version": "2023-06-01"}, body, timeout)
        return "".join(b.get("text", "") for b in d.get("content", []) if b.get("type") == "text")
    if k == "openai":
        msgs = ([{"role": "system", "content": system}] if system else []) + [{"role": "user", "content": user}]
        d = _post(c["baseURL"].rstrip("/") + "/chat/completions", {"Authorization": "Bearer " + _keys.get("openai", "")},
                  {"model": model, "max_tokens": max_tokens, "messages": msgs}, timeout)
        return ((d.get("choices") or [{}])[0].get("message") or {}).get("content") or ""
    raise OSError("no API connected")


def ask(text, timeout=60, tier="haiku", st=None):
    """claude_worker.ask for an API connection: -> the answer, or None when it failed (the caller goes local)."""
    try:
        out = complete("", text, model_for(tier, st), timeout=timeout, st=st)
        state["last_error"] = ""
        return out.strip() or None
    except Exception as e:
        state["last_error"] = type(e).__name__ + (": " + str(e) if isinstance(e, Refused) else "")
        print("model:", state["last_error"], flush=True)    # never the text, never the key
        return None


class ApiWorker:
    """Stands in for claude_type.Worker on an API connection: the same ask/alive/stop and counters, one HTTPS request
    per ask. The system text goes in each request (the API caches nothing here; it is the same text every time)."""
    MAX_TURNS = 40

    def __init__(self, model, system, max_tokens=None):
        self.model, self.system, self.max_tokens = model, system, max_tokens or 300
        self.turns, self.started, self.used, self.dead = 0, time.time(), time.time(), False
        self.generation, self.usage = state["generation"], {}
        self.idle = threading.Event(); self.idle.set()

    def alive(self): return not self.dead and self.generation == state["generation"]

    def ask(self, user, cancelled=lambda: False, wait=1.5, deadline=6.0, whole=False):
        if not self.idle.wait(wait) or not self.alive(): return None
        self.idle.clear(); self.turns += 1; self.used = time.time()
        t0 = time.time()
        try:
            out = complete(self.system, user, model_for(self.model), max_tokens=self.max_tokens, timeout=deadline)
            state["last_error"] = ""
        except Exception as e:
            state["last_error"] = type(e).__name__ + (": " + str(e) if isinstance(e, Refused) else "")
            print("model:", state["last_error"], flush=True)
            return None
        finally:
            self.idle.set()
        if cancelled(): return None
        ms = round((time.time() - t0) * 1000)
        return out, ms, ms

    def stop(self): self.dead = True

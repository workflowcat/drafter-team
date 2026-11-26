"""Kept-running `claude` processes for the Claude helpers that are still on (2026-11-17: Claude left the live typing
path; the pause, the early lane, proofread, fact chips, translate and the next message went).
Rework (⌥Tab, engine/rework.py) builds its worker from here: one `claude` process per system prompt (no tools, no
settings, no MCP), capped at MAX_LIVE, stopped by one reaper after 10 idle minutes or at once when memory is low. An
API connection (engine/provider.py) gets provider.ApiWorker with the same face.

What leaves the Mac goes through the caller's switch (engine/cloud.py); nothing here sends on its own.
"""
import json, os, re, subprocess, sys, threading, time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import provider

RUSSIAN = re.compile(r"[ыэъёЫЭЪЁ]")
MAX_WORDS = 9     # an answer that is not asked `whole` ends at a sentence end or past this many words


def _enough(raw):
    return "\n" in raw or bool(re.search(r"[.!?…](\s|$)", raw)) or len(raw.split()) > MAX_WORDS or "∅" in raw


class Worker:
    """One `claude` process with a system prompt as its whole setup (no tools, no settings, no MCP), kept running: the
    system prompt stays in Claude's cache, so a turn costs ~0.7 s (Haiku) to ~1.3 s (Sonnet) warm (2026-10-31, CLI 2.1)."""
    MAX_TURNS = 40
    # every live process, for the cap and the reaper (2026-11-01: up to seven `claude` processes, ~120 MB each, ran at
    # once: pause, early, proofread, facts, translate, rework + the haiku worker)
    live, _reg = [], threading.Lock()

    def __new__(cls, model, system, max_tokens=None):
        # an API connection (engine/provider.py) gets a worker with the same face that makes HTTPS requests instead
        if provider.kind() in ("anthropic", "openai"): return provider.ApiWorker(model, system, max_tokens)
        return super().__new__(cls)

    def __init__(self, model, system, max_tokens=None):
        self.model, self.system, self.turns, self.started = model, system, 0, time.time()
        self.used, self.dead, self.generation = time.time(), False, provider.state["generation"]
        Worker.make_room()
        env = {k: v for k, v in os.environ.items() if not k.startswith(("CLAUDE", "ANTHROPIC"))}
        env.update(PATH=f"{Path.home()}/.local/bin:/usr/bin:/bin", CLAUDE_CODE_MAX_OUTPUT_TOKENS=str(max_tokens or 32 + 6 * MAX_WORDS))
        # his text never goes on the command line (any process reads argv through `ps`; 2026-11-14): the system prompt
        # goes in a 0600 file the CLI reads at start, deleted once the process answers anything (it reads the file once)
        self.system_file = prompt_file(system)
        self.p = subprocess.Popen(Worker.argv(model, self.system_file), stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                  stderr=subprocess.DEVNULL, text=True, env=env)
        self.deltas, self.idle, self.usage = None, threading.Event(), {}
        self.idle.set()
        with Worker._reg: Worker.live.append(self)
        threading.Thread(target=self._pump, daemon=True).start()

    @staticmethod
    def argv(model, system_file):
        """The command line: flags and paths only. Never the system prompt or a message (tests/test_claude_argv.py)."""
        return [CLI, "-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose",
                "--include-partial-messages", "--model", model, "--system-prompt-file", system_file, "--tools", "", "--effort", "low",
                "--strict-mcp-config", "--mcp-config", '{"mcpServers":{}}', "--setting-sources", "",
                "--disable-slash-commands", "--no-session-persistence"]

    def alive(self): return not self.dead and self.p.poll() is None and self.generation == provider.state["generation"]

    def _drop_file(self):
        f, self.system_file = self.system_file, None
        if f:
            try: os.unlink(f)
            except OSError: pass

    def _pump(self):
        for line in self.p.stdout:
            self._drop_file()   # it answered: the system prompt has been read
            try: d = json.loads(line)
            except Exception: continue
            q = self.deltas
            if d.get("type") == "stream_event":
                ev = d.get("event") or {}
                if ev.get("type") == "content_block_delta" and (ev.get("delta") or {}).get("type") == "text_delta" and q:
                    q.put(ev["delta"]["text"])
            elif d.get("type") == "result":
                self.usage = d.get("usage") or {}
                if q: q.put(None)
                self.idle.set()
        if self.deltas: self.deltas.put(None)
        self.idle.set()
        self._drop_file()   # ended before it answered

    def ask(self, user, cancelled=lambda: False, wait=1.5, deadline=6.0, whole=False):
        """-> (raw text, first_ms, ms), or None. Returns as soon as the sentence is whole (or, with `whole`, the answer is
        over); the turn finishes on its own."""
        import queue
        self.used = time.time()
        if not self.idle.wait(wait): return None
        with Worker._reg:     # taken under the same lock eviction uses, so a worker is never stopped mid-request
            if not self.alive() or not self.idle.is_set(): return None
            self.idle.clear(); self.turns += 1
        q = self.deltas = queue.Queue()
        t0 = time.time(); first = None; out = ""
        try:
            self.p.stdin.write(json.dumps({"type": "user", "message": {"role": "user", "content": user}}) + "\n"); self.p.stdin.flush()
        except Exception:
            self.idle.set(); return None
        end = t0 + deadline
        while time.time() < end:
            if cancelled(): return None
            try: piece = q.get(timeout=0.05)
            except Exception: continue
            if piece is None: break
            if first is None: first = time.time()
            out += piece
            if not whole and _enough(out): break
        else:
            self.p.kill(); return None
        return out, round(((first or time.time()) - t0) * 1000), round((time.time() - t0) * 1000)

    def stop(self):
        self.dead = True
        try: self.p.kill()
        except Exception: pass
        self._drop_file()

    @classmethod
    def make_room(cls):
        """At most MAX_LIVE processes: a new one stops the idle one used longest ago (it starts again when needed)."""
        with cls._reg:
            cls.live = [w for w in cls.live if w.alive()]
            idle = sorted((w for w in cls.live if w.idle.is_set()), key=lambda w: w.used)
            while len(cls.live) >= MAX_LIVE and idle:
                w = idle.pop(0); w.stop(); cls.live.remove(w)

    @classmethod
    def reap(cls, idle_s):
        """Stop every process with no turn running and none asked for `idle_s` seconds. -> how many."""
        n = 0
        with cls._reg:
            for w in list(cls.live):
                if not w.alive(): cls.live.remove(w)
                elif w.idle.is_set() and time.time() - w.used > idle_s:
                    w.stop(); cls.live.remove(w); n += 1
        return n


MAX_LIVE = int(os.environ.get("DRAFTER_CLAUDE_MAX", "4"))


def mem_free():
    """macOS memory level in % (kern.memorystatus_level, what the system counts as free); -1 when unknown."""
    try:
        import ctypes
        libc = ctypes.CDLL("libc.dylib")
        v, n = ctypes.c_int(0), ctypes.c_size_t(4)
        if libc.sysctlbyname(b"kern.memorystatus_level", ctypes.byref(v), ctypes.byref(n), None, ctypes.c_size_t(0)) == 0:
            return v.value
    except Exception:
        pass
    return -1


def reap(idle_s=600):
    """Kept processes idle for idle_s go; the haiku worker (claude_worker) too, when it was loaded."""
    n = Worker.reap(idle_s)
    cw = sys.modules.get("claude_worker")
    if cw and hasattr(cw, "reap"): n += cw.reap(idle_s)
    return n


def _reaper():
    """Every minute: processes idle 10 minutes go, and all idle ones while the Mac is short of memory (< 20% free)."""
    while True:
        time.sleep(60)
        try:
            low = 0 <= mem_free() < 20
            n = reap(0 if low else 600)
            if n and low: print(f"claude: memory low, stopped {n} idle", flush=True)
        except Exception as e:
            print("claude reaper:", e, flush=True)


threading.Thread(target=_reaper, daemon=True).start()


import integrations
CLI = (integrations.claude_bin() if integrations.available("claude") else "") or "/nonexistent/claude"   # the `claude` CLI only when the local config turns it on and it is there (engine/integrations.py); else a path that never exists

# Prompt files for `claude` processes (system prompts): a folder only this user can open; each file 0600 and gone as
# soon as its process has read it (Worker._drop_file); leftovers of a crash go at the next engine start.
PROMPT_DIR = Path(os.environ.get("TMPDIR", "/tmp")) / "drafter-prompts"


def prompt_file(text):
    """-> path of a new 0600 file holding `text`, for --system-prompt-file."""
    import tempfile
    PROMPT_DIR.mkdir(mode=0o700, exist_ok=True)
    os.chmod(PROMPT_DIR, 0o700)
    fd, path = tempfile.mkstemp(prefix="sp-", suffix=".txt", dir=PROMPT_DIR)   # mkstemp: 0600, O_EXCL
    with os.fdopen(fd, "w", encoding="utf-8") as f: f.write(text)
    return path


def _clear_prompt_files(older_s=3600):
    """Files a crashed engine left (an hour old: a bench importing this must not take a live worker's file)."""
    try:
        for f in PROMPT_DIR.glob("sp-*.txt"):
            if time.time() - f.stat().st_mtime > older_s: f.unlink()
    except OSError: pass


_clear_prompt_files()

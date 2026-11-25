"""One `claude` process kept running (Haiku, no plugins, no MCP, no settings), so a request takes ~2-3 s instead of the
~8-14 s of starting the CLI each time. Every request carries its own full instructions; the process is restarted every
8 requests so earlier chats do not pile up in its context. Used for replies, call summaries and questions to the notes.
Only called on Andrii's own action (Tab on an empty box, the end of a call he recorded, a question he asked)."""
import json, os, queue, subprocess, threading, time
from pathlib import Path

import sys
sys.path.insert(0, str(Path(__file__).resolve().parent))
import integrations
# the `claude` CLI only when the local config turns it on and it is there (engine/integrations.py); else a path that never exists
CMD = [(integrations.claude_bin() if integrations.available("claude") else "") or "/nonexistent/claude", "-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose",
       "--model", "haiku", "--strict-mcp-config", "--mcp-config", '{"mcpServers":{}}', "--setting-sources", "",
       "--disable-slash-commands", "--no-session-persistence"]
ENV = {**os.environ, "PATH": f"{Path.home()}/.local/bin:/usr/bin:/bin"}
_lock = threading.Lock()
_proc, _used, _lines, _last = None, 0, None, 0.0


def _start():
    global _proc, _used
    global _lines
    _proc = subprocess.Popen(CMD, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True, env=ENV)
    _used = 0
    # a reader thread per process: ask() waits on the queue with a deadline instead of a blocking readline()
    _lines = q = queue.Queue()
    def pump(out=_proc.stdout):
        for line in out: q.put(line)
        q.put(None)
    threading.Thread(target=pump, daemon=True).start()


def ask(text, timeout=60):
    """-> Claude's answer text, or None when it failed. An API connection answers through engine/provider.py."""
    import provider
    if provider.kind() in ("anthropic", "openai"): return provider.ask(text, timeout)
    global _proc, _used
    # one hard deadline for the whole call: waiting for the lock counts too (Codex review 2026-10-21: a blocked
    # readline() could hold every caller, so the local fallback was never reached)
    end = time.time() + timeout
    if not _lock.acquire(timeout=max(0.1, timeout)): return None
    global _last
    _last = time.time()
    try:
        if _proc is None or _proc.poll() is not None or _used >= 8:
            if _proc and _proc.poll() is None: _proc.kill()
            _start()
        _used += 1
        msg = "Answer only this message; earlier messages in this conversation are unrelated.\n\n" + text
        try:
            _proc.stdin.write(json.dumps({"type": "user", "message": {"role": "user", "content": msg}}) + "\n"); _proc.stdin.flush()
            while time.time() < end:
                try: line = _lines.get(timeout=max(0.05, end - time.time()))
                except queue.Empty: break
                if not line: break
                d = json.loads(line)
                if d.get("type") == "result":
                    return None if d.get("is_error") else (d.get("result") or "").strip()
        except Exception as e:
            print("claude worker:", e, flush=True)
        _proc.kill(); _proc = None   # timed out or failed: a fresh process next time, never a half-read answer
        return None
    finally:
        _lock.release()


def reap(idle_s):
    """Stop the process when nothing asked for idle_s seconds and no request runs (claude_type's reaper). -> 0 or 1."""
    global _proc
    if _proc is None or time.time() - _last < idle_s or not _lock.acquire(blocking=False): return 0
    try:
        if _proc is None or _proc.poll() is not None: _proc = None; return 0
        _proc.kill(); _proc = None
        return 1
    finally:
        _lock.release()


def warm():
    """Start the process ahead of time (in the background), so the first real request is quick too."""
    threading.Thread(target=lambda: ask("Reply with: ok", 30), daemon=True).start()

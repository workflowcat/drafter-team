"""Read-only local MCP adapter. Run with Python 3.11+; no installed packages needed.

Only saved recordings, notes, promises, entities and the existing search cache are
read. No engine HTTP calls, source sync, repair, model, screen or network access.
"""
import argparse
import json
import math
import os
from pathlib import Path
import re
import sqlite3
import sys

# Also prevent bytecode writes when clients forget the documented -B flag.
sys.dont_write_bytecode = True
if __package__:
    from . import entities, promises, local_search
else:
    import entities
    import promises
    import local_search

ROOT = Path(__file__).resolve().parents[1]
PROTOCOL_VERSION = "2024-11-05"
MAX_MESSAGE = 1024 * 1024
MAX_FILE = 32 * 1024 * 1024
EOF = object()


class ToolError(Exception):
    """A fixed, public error message, never an underlying exception or user text."""


class InvalidParams(Exception):
    pass


def string(description, **extra):
    return {"type": "string", "description": description, **extra}


def integer(default, maximum, minimum=1):
    return {"type": "integer", "default": default, "minimum": minimum, "maximum": maximum}


def tool(name, description, properties, required=()):
    return {"name": "drafter_" + name, "description": description,
            "inputSchema": {"type": "object", "properties": properties,
                            "required": list(required), "additionalProperties": False}}


TOOLS = [
    tool("search_sources", "Search the existing local Mail, Beeper, Drive and Obsidian FTS5 cache. Returns ranked snippets; never syncs sources.", {
        "query": string("Search words (literal prefixes).", minLength=1, maxLength=4096),
        "kinds": {"type": "array", "items": {"type": "string", "enum": ["mail", "beeper", "drive", "obsidian"]}, "maxItems": 4},
        "who": {"type": "array", "items": string("Exact person name or email to boost, not filter."), "maxItems": 25},
        "limit": integer(10, 25)}, ("query",)),
    tool("list_recordings", "List calls and long notes, newest first. Query matches saved metadata, notes and transcript words.", {
        "query": string("Optional words to match.", maxLength=4096), "limit": integer(10, 25)}),
    tool("read_recording", "Read one recording: saved metadata, own notes, linked summary/to-dos and a transcript character page.", {
        "id": string("Folder name returned by list_recordings, never a path.", minLength=1, maxLength=255),
        "max_chars": integer(12000, 100000), "offset": integer(0, 100000000, 0)}, ("id",)),
    tool("list_promises", "List open saved promises with what, person, app, due (epoch seconds) and overdue.", {}),
    tool("entity_context", "Find entity information and its saved context pack. Disabled when settings contextPacks is false.", {
        "query": string("Entity name or alias.", minLength=1, maxLength=4096), "level": integer(2, 3)}, ("query",)),
    tool("recent_notes", "Search or list saved Markdown notes, newest filename first. Returns summary, to-dos and bounded Markdown.", {
        "query": string("Optional words to match in the note.", maxLength=4096), "limit": integer(10, 20)}),
]
TOOL_MAP = {t["name"]: t for t in TOOLS}


def validate(value, schema):
    kind = schema.get("type")
    valid = {"object": isinstance(value, dict), "array": isinstance(value, list),
             "string": isinstance(value, str), "integer": type(value) is int}.get(kind, True)
    if not valid:
        raise InvalidParams()
    if kind == "object":
        props = schema["properties"]
        if set(value) - set(props) or any(k not in value for k in schema.get("required", [])):
            raise InvalidParams()
        for key, item in value.items():
            validate(item, props[key])
    elif kind == "array":
        if len(value) > schema.get("maxItems", 100):
            raise InvalidParams()
        for item in value:
            validate(item, schema["items"])
    elif kind == "integer":
        if not schema.get("minimum", 0) <= value <= schema.get("maximum", 100000000):
            raise InvalidParams()
    elif kind == "string":
        if not schema.get("minLength", 0) <= len(value) <= schema.get("maxLength", 4096):
            raise InvalidParams()
    if "enum" in schema and value not in schema["enum"]:
        raise InvalidParams()


def number(value):
    return value if type(value) in (int, float) and math.isfinite(value) else 0


def text(value):
    return value if isinstance(value, str) else ""


def matches(query, value):
    return all(word in value.casefold() for word in query.casefold().split())


class ReadOnlySearch(local_search.LocalSearchIndex):
    """Reuse ranking/FTS SQL without LocalSearchIndex's repair-on-read path.

    readonly_shm prevents SQLite from creating/modifying WAL shared memory. A
    closed, checkpointed cache is read into RAM and cached by file identity so
    repeated queries do not re-copy up to 256 MiB (no sidecars created).
    Never mark the live database immutable: that would silently ignore its WAL.
    """
    def __init__(self, files):
        super().__init__(data_dir=files.data)
        self.files = files
        self._mem_db = None
        self._mem_key = None

    def _drop_mem(self):
        if self._mem_db is not None:
            try:
                self._mem_db.close()
            except sqlite3.Error:
                pass
            self._mem_db = None
            self._mem_key = None

    def close(self):
        self._drop_mem()
        super().close()

    def _prepare(self, db):
        db.row_factory = sqlite3.Row
        db.create_function("fold", 1, local_search.fold, deterministic=True)
        db.execute("PRAGMA query_only=ON")
        db.execute("PRAGMA temp_store=MEMORY")
        version = db.execute("SELECT val FROM meta WHERE key='schema_version'").fetchone()
        if version is None or version[0] != local_search.SCHEMA_VERSION:
            raise ToolError("Search cache schema is unavailable. Drafter must refresh its index.")

    def _read(self, action, default):
        path = self.files.path("cache", "search.sqlite")
        if not path.is_file():
            self._drop_mem()
            return default
        wal = self.files.path("cache", "search.sqlite-wal")
        db = None
        close_after = False
        try:
            if wal.exists():
                self._drop_mem()
                db = sqlite3.connect(path.as_uri() + "?mode=ro&readonly_shm=1", uri=True, timeout=0.2)
                close_after = True
                self._prepare(db)
            else:
                before = path.stat()
                key = (before.st_dev, before.st_ino, before.st_mtime_ns, before.st_size)
                if self._mem_db is not None and self._mem_key == key:
                    db = self._mem_db
                else:
                    self._drop_mem()
                    # A stable, bounded checkpoint image; concurrent changes retry on the next call.
                    if before.st_size > 256 * 1024 * 1024:
                        raise ToolError("Closed search cache is too large. Open Drafter to read its WAL cache.")
                    raw = bytearray(path.read_bytes())
                    after = path.stat()
                    if (before.st_dev, before.st_ino, before.st_mtime_ns, before.st_size) != (after.st_dev, after.st_ino, after.st_mtime_ns, after.st_size) or wal.exists():
                        raise ToolError("Search cache changed while reading. Retry the search.")
                    if raw[:16] != b"SQLite format 3\0":
                        raise ToolError("Search cache is unavailable. Drafter must build a healthy index.")
                    # deserialize cannot read a WAL-mode image; this only changes the RAM copy.
                    raw[18:20] = b"\x01\x01"
                    loaded = sqlite3.connect(":memory:")
                    try:
                        loaded.deserialize(bytes(raw))
                        self._prepare(loaded)
                    except Exception:
                        loaded.close()
                        raise
                    self._mem_db = loaded
                    self._mem_key = key
                    db = loaded
            return action(db)
        except ToolError:
            raise
        except (sqlite3.Error, OSError, ValueError):
            if db is self._mem_db:
                self._drop_mem()
            raise ToolError("Search cache is unavailable. Drafter must build a healthy index.") from None
        finally:
            if close_after and db is not None:
                db.close()


class Drafter:
    def __init__(self, data):
        self.data = Path(data).expanduser().resolve()
        self._search = None

    def close(self):
        if self._search is not None:
            self._search.close()
            self._search = None

    def path(self, *parts):
        """Fixed file allowlist at call sites; reject symlinks at every level."""
        path = self.data
        for part in parts:
            path = path / part
            if path.is_symlink():
                raise ToolError("Symlinked data is not exposed by MCP.")
        try:
            path.resolve().relative_to(self.data)
        except (ValueError, RuntimeError):
            raise ToolError("Path must stay inside the selected data directory.") from None
        return path

    def read(self, *parts):
        path = self.path(*parts)
        if not path.is_file():
            return ""
        with path.open("rb") as stream:
            raw = stream.read(MAX_FILE + 1)
        if len(raw) > MAX_FILE:
            raise ToolError("Saved file exceeds the MCP read limit.")
        return raw.decode("utf-8", errors="replace")

    def json(self, *parts, default=None):
        try:
            return json.loads(self.read(*parts))
        except ValueError:
            return default

    def children(self, folder):
        path = self.path(folder)
        return sorted(path.iterdir(), key=lambda p: p.name, reverse=True) if path.is_dir() else []

    def notes(self):
        rows = []
        for path in self.children("notes"):
            if path.suffix != ".md" or path.is_symlink() or not path.is_file():
                continue
            body = self.read("notes", path.name)
            row = {"id": path.name, "title": path.stem, "people": [], "summary": [], "todos": [],
                   "recording_id": None, "markdown": body[:12000], "truncated": len(body) > 12000}
            section, audio = "", ""
            for line in body.splitlines():
                line = line.strip()
                if line.startswith("# "):
                    row["title"] = re.sub(r"^(?:Call: |Дзвінок: )", "", line[2:])
                elif line.startswith("## "):
                    section = line[3:].casefold()
                elif line.startswith(("Про: ", "About: ")):
                    row["people"] = [p.strip() for p in line.split(":", 1)[1].split(",") if p.strip()]
                elif line.startswith(("Запис: ", "Recording: ")):
                    audio = line.split(":", 1)[1].strip()
                elif line.startswith("- "):
                    if section in ("головне", "summary"):
                        row["summary"].append(line[2:])
                    elif section in ("фоловапи", "follow-ups", "todos"):
                        row["todos"].append(line[2:])
            # A link is metadata, never a path to follow. Accept only our calls folder.
            if audio:
                link = Path(os.path.normpath(audio))
                if link.parent in (self.data / "calls", Path("data/calls"), Path("calls")):
                    row["recording_id"] = link.name
            rows.append((row, body))
        return rows

    def transcript(self, rid):
        rows = self.json("calls", rid, "lines.json")
        if isinstance(rows, list):
            lines = []
            for row in rows:
                if not isinstance(row, dict) or not text(row.get("text")):
                    continue
                who = text(row.get("who"))
                start = row.get("start")
                stamp = f"[{number(start):g}s] " if type(start) in (int, float) else ""
                lines.append(stamp + (who + ": " if who else "") + row["text"])
            if lines:
                return "\n".join(lines) + "\n"
        return self.read("calls", rid, "transcript.txt")

    def recording(self, rid, notes):
        meta = self.json("calls", rid, "meta.json", default={})
        meta = meta if isinstance(meta, dict) else {}
        event = meta.get("event") if isinstance(meta.get("event"), dict) else {}
        note = next((n for n, _ in notes if n["recording_id"] == rid), {})
        title = text(meta.get("title")) or text(event.get("title")) or note.get("title")
        people = note.get("people") or event.get("people") or meta.get("people") or []
        people = [p for p in people if isinstance(p, str)] if isinstance(people, list) else []
        duration = max(0, number(meta.get("duration_secs")))
        for name in ("me.wav", "them.wav", "me.pcm", "them.pcm"):
            path = self.path("calls", rid, name)
            if path.is_file():
                duration = max(duration, (path.stat().st_size - (44 if name.endswith(".wav") else 0)) / 32000)
        shots = self.json("calls", rid, "shots.json", default=[])
        return {"id": rid, "title": title or ("Call" if meta.get("call") else "Note"),
                "started": number(meta.get("started")), "call": bool(meta.get("call")),
                "app": text(meta.get("app")), "people": people, "duration_secs": duration,
                "has_transcript": any(self.path("calls", rid, n).is_file() for n in ("lines.json", "transcript.txt")),
                "has_video": self.path("calls", rid, "screen.mp4").is_file(),
                "shot_count": len(shots) if isinstance(shots, list) else 0}, meta, note

    def search_sources(self, query, kinds=None, who=None, limit=10):
        # Validate path/symlink guard before initializing LocalSearchIndex.
        self.path("cache", "search.sqlite")
        if self._search is None:
            try:
                self._search = ReadOnlySearch(self)
            except (ValueError, OSError):
                raise ToolError("Search cache is unavailable. Drafter must build a healthy index.") from None
        return self._search.search(query, kinds=kinds, who=who or (), limit=limit)

    def list_recordings(self, query="", limit=10):
        notes, rows = self.notes(), []
        for folder in self.children("calls"):
            if folder.is_symlink() or not folder.is_dir():
                continue
            try:
                row, meta, note = self.recording(folder.name, notes)
                hay = json.dumps([row, meta, note], ensure_ascii=False)
                if query:
                    hay += "\n" + self.transcript(folder.name) + "\n" + self.read("calls", folder.name, "my-notes.md")
                if matches(query, hay):
                    rows.append(row)
            except (ToolError, OSError):
                continue
        return sorted(rows, key=lambda r: (r["started"], r["id"]), reverse=True)[:limit]

    def read_recording(self, id, max_chars=12000, offset=0):
        if id in (".", "..") or any(c in id for c in ("/", "\\", "\0")):
            raise ToolError("Recording id must be a single folder name inside calls.")
        folder = self.path("calls", id)
        if not folder.is_dir():
            raise ToolError("Recording not found. Use drafter_list_recordings for available ids.")
        row, meta, note = self.recording(id, self.notes())
        # Expose known recording metadata only, not arbitrary future fields or secrets.
        metadata = {k: meta[k] for k in ("call", "started", "app", "file", "inPerson", "place", "project",
                                       "details", "speakers", "merged", "mergedInto") if k in meta}
        transcript = self.transcript(id)
        start = min(offset, len(transcript))
        end = min(start + max_chars, len(transcript))
        if end < len(transcript):
            boundary = transcript.rfind("\n", start, end)
            if boundary >= start:
                end = boundary + 1
        return {**row, "metadata": metadata, "my_notes": self.read("calls", id, "my-notes.md"),
                "note": {k: note[k] for k in ("id", "title", "summary", "todos") if k in note},
                "transcript": transcript[start:end], "offset": start, "total_chars": len(transcript),
                "next_offset": end if end < len(transcript) else None, "truncated": end < len(transcript)}

    def list_promises(self):
        path = self.path("promises.json")
        if not path.is_file():
            return []
        return [{k: row.get(k) for k in ("what", "person", "app", "due", "overdue")}
                for row in promises.Book(path).open()]

    def _load_settings(self):
        settings_path = self.path("settings.json")
        if not settings_path.exists():
            return None
        raw = self.read("settings.json")
        try:
            parsed = json.loads(raw)
        except ValueError:
            raise ToolError("Cannot read settings.json. MCP access is disabled until settings are valid.") from None
        if not isinstance(parsed, dict):
            raise ToolError("Cannot read settings.json. MCP access is disabled until settings are valid.")
        return parsed

    def _require_mcp_enabled(self):
        settings = self._load_settings()
        if not settings or settings.get("mcp") is not True:
            raise ToolError("MCP access is off. Enable MCP in Drafter Settings (Cloud) to allow local clients to read saved data.")
        return settings

    def entity_context(self, query, level=2):
        settings = self._require_mcp_enabled()
        if settings.get("contextPacks", True) is not True:
            raise ToolError("Entity context is disabled by the contextPacks setting.")
        path = self.path("entities.json")
        if path.exists() and not path.is_file():
            raise ToolError("Entity store is not a regular file.")
        store = entities.Store(path)
        return {"entity": store.entity(query), "context": store.context(query, level=level)}

    def recent_notes(self, query="", limit=10):
        return [row for row, body in self.notes() if matches(query, body)][:limit]

    def call(self, name, arguments):
        if not isinstance(name, str) or name not in TOOL_MAP:
            raise InvalidParams()
        validate(arguments, TOOL_MAP[name]["inputSchema"])
        self._require_mcp_enabled()
        return getattr(self, name.removeprefix("drafter_"))(**arguments)


def error(ident, code, message):
    return {"jsonrpc": "2.0", "id": ident, "error": {"code": code, "message": message}}


def dispatch(service, request):
    if not isinstance(request, dict):
        return error(None, -32600, "Invalid JSON-RPC request")
    ident = request.get("id")
    if request.get("jsonrpc") != "2.0" or not isinstance(request.get("method"), str) or (ident is not None and type(ident) not in (str, int)):
        return error(None, -32600, "Invalid JSON-RPC request")
    if "id" not in request:
        return None  # initialized, cancellation and other notifications never get replies
    params = request.get("params", {})
    if not isinstance(params, dict):
        return error(ident, -32602, "Params must be an object")
    method = request["method"]
    if method == "initialize":
        result = {"protocolVersion": PROTOCOL_VERSION, "serverInfo": {"name": "drafter", "version": "1.0.0"},
                  "capabilities": {"tools": {}}}
    elif method == "ping":
        result = {}
    elif method == "tools/list":
        result = {"tools": TOOLS}
    elif method == "tools/call":
        try:
            value = service.call(params.get("name"), params.get("arguments", {}))
            result = {"content": [{"type": "text", "text": json.dumps(value, ensure_ascii=False, allow_nan=False)}], "isError": False}
        except InvalidParams:
            return error(ident, -32602, "Unknown tool or invalid arguments; check tools/list")
        except Exception as exc:
            # Do not interpolate unexpected exceptions: paths, queries and saved text may be in them.
            message = str(exc) if isinstance(exc, ToolError) else "Saved data is unavailable or malformed. Retry after Drafter finishes saving."
            result = {"content": [{"type": "text", "text": message}], "isError": True}
    else:
        return error(ident, -32601, "Method not found")
    return {"jsonrpc": "2.0", "id": ident, "result": result}


class TransportError(Exception):
    pass


class Transport:
    def __init__(self, reader, writer):
        self.reader, self.writer, self.framed = reader, writer, False

    def read(self):
        while True:
            line = self.reader.readline(MAX_MESSAGE + 1)
            if not line:
                return EOF
            if line.strip():
                break
        self.framed = line.lower().startswith((b"content-length:", b"content-type:"))
        if self.framed:
            length, invalid, size = None, False, 0
            while line.strip():
                size += len(line)
                if size > MAX_MESSAGE:
                    raise TransportError()
                key, sep, value = line.partition(b":")
                if not sep:
                    invalid = True
                if key.lower() == b"content-length":
                    if length is not None or not value.strip().isdigit() or len(value.strip()) > 9:
                        invalid = True
                    else:
                        length = int(value.strip())
                line = self.reader.readline(MAX_MESSAGE + 1)
                if not line:
                    raise TransportError()
            if length is None or length > MAX_MESSAGE or invalid:
                raise TransportError()
            line = self.reader.read(length)
            if len(line) != length:
                raise TransportError()
        elif len(line) > MAX_MESSAGE:
            while line and not line.endswith(b"\n"):
                line = self.reader.readline(MAX_MESSAGE + 1)
            raise TransportError()
        try:
            return json.loads(line, parse_constant=lambda _: (_ for _ in ()).throw(ValueError()))
        except (ValueError, UnicodeError, RecursionError):
            raise TransportError() from None

    def write(self, response):
        # Escape lone surrogate code points too: malformed text must not kill the loop.
        payload = json.dumps(response, ensure_ascii=True, allow_nan=False, separators=(",", ":")).encode("utf-8")
        self.writer.write((f"Content-Length: {len(payload)}\r\n\r\n".encode() + payload) if self.framed else payload + b"\n")
        self.writer.flush()


def serve(service, reader, writer):
    transport = Transport(reader, writer)
    try:
        while True:
            try:
                request = transport.read()
            except TransportError:
                transport.write(error(None, -32700, "Invalid JSON or framing"))
                continue
            if request is EOF:
                return
            response = dispatch(service, request)
            if response is not None:
                transport.write(response)
    finally:
        if hasattr(service, "close"):
            service.close()


def main():
    parser = argparse.ArgumentParser(description="Drafter read-only local MCP server (stdio)")
    parser.add_argument("--data", type=Path, default=ROOT / "data", help="Saved data directory (default: repo data)")
    args = parser.parse_args()
    try:
        serve(Drafter(args.data), sys.stdin.buffer, sys.stdout.buffer)
    except (BrokenPipeError, KeyboardInterrupt):
        pass


if __name__ == "__main__":
    main()

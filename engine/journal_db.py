"""The journal in SQLite, phase 1 (23 November 2026): data/typed.jsonl, takes.jsonl and clipboard.jsonl copied row by
row into data/journal.sqlite. The JSONL files stay authoritative and are never written here: the app and the engine
append to them as before, and this module follows them (dual write through one writer, the engine).

- One `rows` table with a `store` column. Each row keeps its JSONL line verbatim (`line`, the exact bytes), the raw JSON
  token of its timestamp (`t_raw`, never re-formatted; `t` is its float for sorting), and the fields readers query.
- A row's identity is (store, sha256 of its line, occurrence of that same line), so a rewrite of the file (clipboard
  trim, a row removed in the Quick panel) is matched line by line: rows gone from the file are marked `removed_at`,
  never deleted.
- Following by byte offset: the inode, the bytes consumed and the last 64 of them are kept in `sync`. A file that grew
  is read from the offset; another inode, a shorter file or changed bytes before the offset means a full resync. A
  line still being written (no newline) waits for the next pass.
- Hidden rows: data/drafts-hidden.json (DraftHide, scripts/hide_bad_drafts.py) and the journal's soft archive
  (data/journal.json `hidden`, JournalStore) are mirrored into `hidden`; `rows.hidden` is a bit set (1 DraftHide,
  2 journal archive). Searches here leave hidden and removed rows out.
- `meta.schema_version`; WAL; a corrupt file (or another schema) is moved aside, never deleted, and rebuilt from JSONL.

    python -B engine/journal_db.py sync [--data DIR] [--db PATH]     # backfill / catch up, prints numbers only
"""
import argparse
import collections
import hashlib
import json
import os
import sqlite3
import sys
import threading
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(Path(__file__).resolve().parent))
from data_dir import data_dir as _data_dir  # noqa: E402
from local_search import _is_corruption, safe_fts_query  # noqa: E402

SCHEMA_VERSION = "1"
STORES = ("typed", "takes", "clipboard")
FILES = {s: s + ".jsonl" for s in STORES}
HIDDEN_FILES = {"drafts": "drafts-hidden.json", "journal": "journal.json"}
TAIL = 64
HIDE_DRAFT, HIDE_JOURNAL = 1, 2

SCHEMA = """
CREATE TABLE IF NOT EXISTS rows(
    rid INTEGER PRIMARY KEY,
    store TEXT NOT NULL, sha TEXT NOT NULL, dup INTEGER NOT NULL,
    line BLOB NOT NULL,              -- the JSONL line, byte for byte (no newline)
    ok INTEGER NOT NULL,             -- 1: the line parsed as a JSON object
    t REAL, t_raw TEXT,              -- t as a float, and its JSON token exactly as written
    id TEXT, app TEXT, kind TEXT, text TEXT, raw TEXT, jkey TEXT,
    seq INTEGER NOT NULL,            -- its line number in the file now (0-based); order of the JSONL
    added_at REAL NOT NULL, removed_at REAL, removed_why TEXT,
    hidden INTEGER NOT NULL DEFAULT 0,
    UNIQUE(store, sha, dup));
CREATE INDEX IF NOT EXISTS rows_live ON rows(store, removed_at, seq);
CREATE INDEX IF NOT EXISTS rows_t ON rows(store, t);
CREATE INDEX IF NOT EXISTS rows_jkey ON rows(jkey);
CREATE VIRTUAL TABLE IF NOT EXISTS rows_fts USING fts5(body, content='', tokenize='unicode61 remove_diacritics 2');
CREATE TABLE IF NOT EXISTS sync(
    name TEXT PRIMARY KEY, path TEXT, inode INTEGER, size INTEGER, offset INTEGER, tail BLOB,
    lines INTEGER, mtime_ns INTEGER, synced_at REAL);
CREATE TABLE IF NOT EXISTS hidden(
    source TEXT NOT NULL, key TEXT NOT NULL, store TEXT, t REAL, ms INTEGER,
    added_at REAL NOT NULL, removed_at REAL, PRIMARY KEY(source, key));
CREATE TABLE IF NOT EXISTS events(at REAL NOT NULL, store TEXT, what TEXT NOT NULL, n INTEGER NOT NULL);
"""


class _SchemaMismatch(sqlite3.DatabaseError):
    pass


class _Raw(str):
    """A JSON number token kept as written."""


def cut(chunk: bytes):
    """Whole lines in `chunk` (empty ones dropped) and the bytes they used; as FileMark.cut in app/QuickRead.swift."""
    last = chunk.rfind(b"\n")
    if last < 0:
        return [], 0
    return [l for l in chunk[:last].split(b"\n") if l], last + 1


def sha(line: bytes) -> str:
    return hashlib.sha256(line).hexdigest()


def swift_double(x: float) -> str:
    """Swift's "\\(Double)" for the journal ids: the shortest round-trip form, like Python's repr."""
    return repr(float(x))


def parse(line: bytes):
    """-> (object or None, t_raw or None). Number tokens are read as written, so a timestamp is never re-formatted."""
    try:
        s = line.decode("utf-8")
        raw = json.loads(s, parse_float=_Raw, parse_int=_Raw)
        obj = json.loads(s)
    except (UnicodeDecodeError, ValueError):
        return None, None
    if not isinstance(obj, dict):
        return None, None
    t = raw.get("t")
    return obj, (str(t) if isinstance(t, _Raw) else None)


def _str(v):
    return v if isinstance(v, str) else None


def fields(store: str, line: bytes) -> dict:
    """The columns of one line (everything else stays in `line`)."""
    obj, t_raw = parse(line)
    if obj is None:
        return {"ok": 0, "t": None, "t_raw": None, "id": None, "app": None, "kind": None, "text": None, "raw": None,
                "jkey": None, "body": ""}
    t = float(t_raw) if t_raw is not None else None
    text, raw = _str(obj.get("text")), _str(obj.get("raw"))
    rid = _str(obj.get("id"))
    if store == "takes":
        jkey = "v:" + (rid if rid is not None else f"take-{swift_double(t or 0)}-{_str(obj.get('audio')) or ''}")
    elif store == "typed":
        jkey = "t:sent" + swift_double(t or 0)
    else:
        jkey = f"c:{int((t or 0) * 1000)}"
    files = obj.get("files")
    body = " ".join(x for x in [text, raw, _str(obj.get("title")), _str(obj.get("app")),
                                " ".join(f for f in files if isinstance(f, str)) if isinstance(files, list) else None] if x)
    return {"ok": 1, "t": t, "t_raw": t_raw, "id": rid, "app": _str(obj.get("app")),
            "kind": _str(obj.get("kind")) or {"typed": "sent", "takes": "take", "clipboard": "text"}[store],
            "text": text, "raw": raw, "jkey": jkey, "body": body}


def _stat(path: Path):
    try:
        st = path.stat()
        return st.st_ino, st.st_size, st.st_mtime_ns
    except FileNotFoundError:
        return None


def enabled(data_dir=None) -> bool:
    """The app's `journalDB` setting (data/settings.json, default on): the journal reads come from the database."""
    try:
        st = json.loads((Path(data_dir or _data_dir()) / "settings.json").read_text())
        return st.get("journalDB", True) is not False
    except (OSError, ValueError, AttributeError):
        return True


class JournalDB:
    def __init__(self, data_dir=None, db_path=None):
        self.data_dir = Path(data_dir or _data_dir()).absolute()
        self.db_path = Path(db_path or self.data_dir / "journal.sqlite").absolute()
        if self.db_path.suffix.lower() in (".jsonl", ".json"):
            raise ValueError("The journal database must not be a JSONL or JSON file")
        self._lock = threading.RLock()
        self._db = None
        self.error = ""
        self.last = {}

    # MARK: connection

    def _open(self):
        if self._db is not None:
            return self._db
        self.db_path.parent.mkdir(parents=True, exist_ok=True)
        db = sqlite3.connect(self.db_path, timeout=5, check_same_thread=False)
        try:
            db.execute("PRAGMA busy_timeout=5000")
            db.execute("PRAGMA journal_mode=WAL")
            db.execute("PRAGMA synchronous=NORMAL")
            db.execute("CREATE TABLE IF NOT EXISTS meta(key TEXT PRIMARY KEY, val TEXT)")
            v = db.execute("SELECT val FROM meta WHERE key='schema_version'").fetchone()
            if v is not None and v[0] != SCHEMA_VERSION:
                raise _SchemaMismatch("journal schema " + str(v[0]))
            db.executescript(SCHEMA)
            if v is None:
                with db:
                    db.execute("INSERT OR REPLACE INTO meta VALUES('schema_version', ?)", (SCHEMA_VERSION,))
                    db.execute("INSERT OR REPLACE INTO meta VALUES('created_at', ?)", (repr(time.time()),))
        except BaseException:
            db.close()
            raise
        self._db = db
        return db

    def close(self):
        with self._lock:
            if self._db is not None:
                try:
                    self._db.close()
                except sqlite3.DatabaseError:
                    pass
            self._db = None

    def _set_aside(self):
        """Corrupt or another schema: the file goes aside (kept), a new one is built from the JSONL files."""
        self.close()
        stamp = time.strftime("%Y%m%d-%H%M%S")
        for suffix in ("", "-wal", "-shm"):
            p = Path(str(self.db_path) + suffix)
            if p.exists():
                p.rename(Path(str(self.db_path) + f".aside-{stamp}{suffix}"))

    # MARK: sync

    def sync(self, full=False) -> dict:
        """Brings every store and both hidden lists up to date. -> numbers per store (added, removed, full).
        `full`: every file read whole and matched again (the follower does it every 10 minutes): catches a rewrite in
        place that kept the size and the last bytes."""
        with self._lock:
            for attempt in range(2):
                try:
                    db = self._open()
                    out = {s: self._sync_store(db, s, full) for s in STORES}
                    changed_hidden = self._sync_hidden(db)
                    if changed_hidden or any(v["added"] or v["removed"] for v in out.values()):
                        self._apply_hidden(db)
                    out["hidden_changed"] = changed_hidden
                    self.error, self.last = "", out
                    return out
                except sqlite3.DatabaseError as exc:
                    self.error = type(exc).__name__
                    if attempt or not (_is_corruption(exc) or isinstance(exc, _SchemaMismatch)):
                        raise
                    self._set_aside()
        return {}

    def _event(self, db, store, what, n):
        if n:
            db.execute("INSERT INTO events VALUES(?,?,?,?)", (time.time(), store, what, n))

    def _insert(self, db, store, line, seq, now):
        h = sha(line)
        dup = db.execute("SELECT COALESCE(MAX(dup)+1, 0) FROM rows WHERE store=? AND sha=?", (store, h)).fetchone()[0]
        f = fields(store, line)
        cur = db.execute(
            "INSERT INTO rows(store,sha,dup,line,ok,t,t_raw,id,app,kind,text,raw,jkey,seq,added_at) "
            "VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
            (store, h, dup, line, f["ok"], f["t"], f["t_raw"], f["id"], f["app"], f["kind"], f["text"], f["raw"],
             f["jkey"], seq, now))
        if f["body"]:
            db.execute("INSERT INTO rows_fts(rowid, body) VALUES(?,?)", (cur.lastrowid, f["body"]))

    def _sync_store(self, db, store, full=False) -> dict:
        path = self.data_dir / FILES[store]
        st = _stat(path)
        mark = db.execute("SELECT inode,size,offset,tail,lines,mtime_ns FROM sync WHERE name=?", (store,)).fetchone()
        now = time.time()
        res = {"added": 0, "removed": 0, "full": False}
        if st is None:
            # the file is gone: its rows stay, marked removed (a later file starts over)
            with db:
                n = db.execute("UPDATE rows SET removed_at=?, removed_why='file missing' WHERE store=? AND removed_at IS NULL",
                               (now, store)).rowcount
                self._event(db, store, "removed", n)
                db.execute("INSERT OR REPLACE INTO sync VALUES(?,?,?,?,?,?,?,?,?)",
                           (store, str(path), 0, 0, 0, b"", 0, 0, now))
            res["removed"] = n
            return res
        inode, size, mtime_ns = st
        with open(path, "rb") as fh:
            plan = "full"
            if mark is not None and not full:
                m_inode, m_size, m_off, m_tail, m_lines, m_mtime = mark
                if m_off and inode == m_inode and size >= m_off:
                    fh.seek(m_off - len(m_tail or b""))
                    if fh.read(len(m_tail or b"")) == (m_tail or b""):
                        # the same size but written since: a rewrite in place (an append changes the size)
                        plan = ("same" if mtime_ns == m_mtime else "full") if size == m_off else "append"
                elif not m_off and inode == m_inode and size == 0:
                    plan = "same"
            if plan == "same":
                return res
            with db:
                if plan == "append":
                    fh.seek(m_off)
                    chunk = fh.read()
                    lines, used = cut(chunk)
                    if not used:
                        return res
                    for i, line in enumerate(lines):
                        self._insert(db, store, line, m_lines + i, now)
                    offset, total = m_off + used, m_lines + len(lines)
                    tail = ((m_tail or b"") + chunk[:used])[-TAIL:]
                    res["added"] = len(lines)
                else:
                    fh.seek(0)
                    chunk = fh.read()
                    lines, used = cut(chunk)
                    res.update(self._resync(db, store, lines, now))
                    offset, total, tail = used, len(lines), chunk[:used][-TAIL:]
                self._event(db, store, "added", res["added"])
                self._event(db, store, "removed", res["removed"])
                if res["full"] and mark is not None and (res["added"] or res["removed"]):
                    self._event(db, store, "resync", 1)
                db.execute("INSERT OR REPLACE INTO sync VALUES(?,?,?,?,?,?,?,?,?)",
                           (store, str(path), inode, size, offset, tail, total, mtime_ns, now))
        return res

    def _resync(self, db, store, lines, now) -> dict:
        """The whole file against the live rows: each line keeps its row (by hash, in order), new lines are added, rows
        no longer in the file are marked removed."""
        pool = collections.defaultdict(collections.deque)
        for rid, h, seq in db.execute("SELECT rid, sha, seq FROM rows WHERE store=? AND removed_at IS NULL ORDER BY sha, dup",
                                      (store,)):
            pool[h].append((rid, seq))
        added = 0
        for i, line in enumerate(lines):
            q = pool.get(sha(line))
            if q:
                rid, seq = q.popleft()
                if seq != i:
                    db.execute("UPDATE rows SET seq=? WHERE rid=?", (i, rid))
            else:
                self._insert(db, store, line, i, now)
                added += 1
        gone = [rid for q in pool.values() for rid, _ in q]
        for rid in gone:
            db.execute("UPDATE rows SET removed_at=?, removed_why='gone from file' WHERE rid=?", (now, rid))
        return {"added": added, "removed": len(gone), "full": True}

    # MARK: hidden

    def _hidden_keys(self, source, path):
        """The hide list as rows of the `hidden` table: key -> (store, t, ms)."""
        try:
            j = json.loads(path.read_text())
        except (OSError, ValueError):
            return {}
        out = {}
        if source == "drafts":
            for e in j.get("hidden", []) if isinstance(j, dict) else []:
                if not isinstance(e, dict) or not isinstance(e.get("t"), (int, float)) or isinstance(e.get("t"), bool):
                    continue
                kind = e.get("kind")
                store = "typed" if kind == "sent" else "drafts" if kind == "draft" else None
                out[f"{kind}:{swift_double(e['t'])}"] = (store, float(e["t"]), None)
        else:
            for k in j.get("hidden", []) if isinstance(j, dict) else []:
                if not isinstance(k, str) or not k:
                    continue
                store, t, ms = None, None, None
                if k.startswith("v:"):
                    store = "takes"
                elif k.startswith("t:sent"):
                    store = "typed"
                    try:
                        t = float(k[6:])
                    except ValueError:
                        store = None
                elif k.startswith("t:draft"):
                    store = "drafts"
                elif k.startswith("c:"):
                    store = "clipboard"
                    try:
                        ms = int(k.split(":")[1])
                    except (IndexError, ValueError):
                        store = None
                out[k] = (store, t, ms)
        return out

    def _sync_hidden(self, db) -> bool:
        changed = False
        now = time.time()
        for source, name in HIDDEN_FILES.items():
            path = self.data_dir / name
            st = _stat(path)
            stamp = (st[0], st[1], st[2]) if st else (0, 0, 0)
            mark = db.execute("SELECT inode,size,mtime_ns FROM sync WHERE name=?", ("hidden:" + source,)).fetchone()
            if mark is not None and tuple(mark) == stamp:
                continue
            keys = self._hidden_keys(source, path) if st else {}
            with db:
                have = {k for (k,) in db.execute("SELECT key FROM hidden WHERE source=? AND removed_at IS NULL", (source,))}
                new = [k for k in keys if k not in have]
                for k in new:
                    store, t, ms = keys[k]
                    db.execute("INSERT OR REPLACE INTO hidden VALUES(?,?,?,?,?,?,NULL)", (source, k, store, t, ms, now))
                gone = have - set(keys)
                for k in gone:
                    db.execute("UPDATE hidden SET removed_at=? WHERE source=? AND key=?", (now, source, k))
                self._event(db, "hidden:" + source, "hidden", len(new))
                self._event(db, "hidden:" + source, "unhidden", len(gone))
                db.execute("INSERT OR REPLACE INTO sync VALUES(?,?,?,?,?,?,?,?,?)",
                           ("hidden:" + source, str(path), stamp[0], stamp[1], 0, b"", 0, stamp[2], now))
            changed = changed or bool(new or gone)
        return changed

    def _apply_hidden(self, db):
        with db:
            db.execute("UPDATE rows SET hidden=0 WHERE hidden!=0")
            live = "removed_at IS NULL"
            db.execute(f"UPDATE rows SET hidden=hidden|{HIDE_DRAFT} WHERE store='typed' AND t IN "
                       f"(SELECT t FROM hidden WHERE source='drafts' AND store='typed' AND {live})")
            db.execute(f"UPDATE rows SET hidden=hidden|{HIDE_JOURNAL} WHERE store='takes' AND jkey IN "
                       f"(SELECT key FROM hidden WHERE source='journal' AND store='takes' AND {live})")
            db.execute(f"UPDATE rows SET hidden=hidden|{HIDE_JOURNAL} WHERE store='typed' AND t IN "
                       f"(SELECT t FROM hidden WHERE source='journal' AND store='typed' AND {live})")
            db.execute(f"UPDATE rows SET hidden=hidden|{HIDE_JOURNAL} WHERE store='clipboard' AND "
                       f"CAST(t*1000 AS INTEGER) IN (SELECT ms FROM hidden WHERE source='journal' AND store='clipboard' AND {live})")

    # MARK: reads

    def _reader(self):
        """A read-only connection (readers never create or change the database); None: no database (yet)."""
        if not self.db_path.exists():
            return None
        db = sqlite3.connect(f"file:{self.db_path.as_posix()}?mode=ro", uri=True, timeout=1, check_same_thread=False)
        db.execute("PRAGMA busy_timeout=1000")
        v = db.execute("SELECT val FROM meta WHERE key='schema_version'").fetchone()
        if v is None or v[0] != SCHEMA_VERSION:
            db.close()
            return None
        return db

    def _read(self, action, default):
        try:
            db = self._reader()
        except sqlite3.DatabaseError:
            return default
        if db is None:
            return default
        try:
            return action(db)
        except sqlite3.DatabaseError:
            return default
        finally:
            db.close()

    def current(self, store, db=None) -> bool:
        """The database holds every whole line the file has now (same inode, consumed up to its size)."""
        if db is None:
            return self._read(lambda d: self.current(store, d), False)
        st = _stat(self.data_dir / FILES[store])
        row = db.execute("SELECT inode, offset FROM sync WHERE name=?", (store,)).fetchone()
        if st is None or row is None:
            return False
        return row[0] == st[0] and row[1] == st[1]

    def newest(self, store, n, visible=True):
        """The newest `n` live rows, oldest first, as dicts; None when the database is behind the file (read JSONL)."""
        q = "SELECT line FROM rows WHERE store=? AND removed_at IS NULL AND ok=1"
        if visible:
            q += " AND hidden=0"

        def go(db):
            if not self.current(store, db):
                return None
            lines = [r[0] for r in db.execute(q + " ORDER BY seq DESC LIMIT ?", (store, n))]
            return [json.loads(bytes(l)) for l in reversed(lines)]
        return self._read(go, None)

    def search(self, query, stores=STORES, limit=20):
        """FTS5 over the live, visible rows: [(store, row dict)], best first."""
        fts = safe_fts_query(query)
        if not fts:
            return []
        marks = ",".join("?" * len(stores))
        rows = self._read(lambda db: db.execute(
            f"SELECT r.store, r.line FROM rows_fts f JOIN rows r ON r.rid=f.rowid WHERE rows_fts MATCH ? "
            f"AND r.removed_at IS NULL AND r.hidden=0 AND r.store IN ({marks}) ORDER BY bm25(rows_fts) LIMIT ?",
            (fts, *stores, limit)).fetchall(), [])
        return [(s, json.loads(bytes(l))) for s, l in rows]

    def counts(self) -> dict:
        with self._lock:
            db = self._open()
            out = {}
            for s in STORES:
                live, removed, hidden = db.execute(
                    "SELECT SUM(removed_at IS NULL), SUM(removed_at IS NOT NULL), SUM(removed_at IS NULL AND hidden!=0) "
                    "FROM rows WHERE store=?", (s,)).fetchone()
                out[s] = {"live": live or 0, "removed": removed or 0, "hidden": hidden or 0}
            return out


def takes_rows(data_dir, last):
    """Voice takes for engine search (engine/ask.py): the newest `last`, oldest first, hidden and removed rows left out.
    From the database with `journalDB` on and the database current; else from takes.jsonl as before."""
    data_dir = Path(data_dir)
    if enabled(data_dir):
        rows = JournalDB(data_dir).newest("takes", last)
        if rows is not None:
            return rows
    out = []
    for line in (data_dir / "takes.jsonl").read_bytes().split(b"\n")[-last - 1:]:
        if line.strip():
            try:
                out.append(json.loads(line))
            except ValueError:
                pass
    return out[-last:]


class Follower:
    """The engine's follower thread: syncs every `every` seconds, or at once after a poke (a line just written)."""

    def __init__(self, data_dir, every=2.0, db_path=None):
        self.jdb = JournalDB(data_dir, db_path)
        self.every = every
        self._wake = threading.Event()
        self._stop = threading.Event()
        self._thread = None
        self._logged = 0.0
        self.full_every = 600.0

    def start(self):
        if self._thread is None:
            self._thread = threading.Thread(target=self._run, name="journal-db", daemon=True)
            self._thread.start()
        return self

    def poke(self):
        self._wake.set()

    def stop(self):
        self._stop.set()
        self._wake.set()
        if self._thread is not None:
            self._thread.join(timeout=5)
        self.jdb.close()

    def _run(self):
        first, last_full = True, time.monotonic()
        while not self._stop.is_set():
            try:
                t0 = time.perf_counter()
                full = time.monotonic() - last_full >= self.full_every
                out = self.jdb.sync(full=full)
                if full:
                    last_full = time.monotonic()
                if first or any(isinstance(v, dict) and (v["full"] or v["removed"]) for v in out.values()):
                    ms = round((time.perf_counter() - t0) * 1000)
                    print("journal db: " + " ".join(f"{s} +{out[s]['added']} -{out[s]['removed']}" for s in STORES)
                          + f" in {ms} ms", flush=True)
                first = False
            except Exception as e:  # never stops the engine; logged at most once a minute
                if time.time() - self._logged > 60:
                    self._logged = time.time()
                    print("journal db: sync failed:", type(e).__name__, flush=True)
            self._wake.wait(self.every)
            self._wake.clear()


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("cmd", choices=["sync", "status"])
    ap.add_argument("--data", default=str(_data_dir()))
    ap.add_argument("--db", default=None)
    a = ap.parse_args(argv)
    jdb = JournalDB(a.data, a.db)
    t0 = time.perf_counter()
    if a.cmd == "sync":
        out = jdb.sync()
        for s in STORES:
            print(f"{s}: added {out[s]['added']} removed {out[s]['removed']} full {int(out[s]['full'])}")
    for s, c in jdb.counts().items():
        print(f"{s}: live {c['live']} removed {c['removed']} hidden {c['hidden']}")
    jdb.close()
    size = sum(Path(str(jdb.db_path) + x).stat().st_size for x in ("", "-wal") if Path(str(jdb.db_path) + x).exists())
    print(f"ms {round((time.perf_counter() - t0) * 1000)} bytes {size}")


if __name__ == "__main__":
    main()

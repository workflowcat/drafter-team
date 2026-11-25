"""Rebuildable, local-only SQLite + FTS5 cache for data/sources/*.jsonl (mail, beeper, drive).

JSONL stores remain authoritative. Sync is per-file (keyed by each store's mtime and size) and runs on a single writer
connection; readers use per-thread read-only WAL connections without taking the writer lock, so requests never block
during a background refresh. No network, model, style or training reader is involved.
"""
import json
import os
import re
import sqlite3
import threading
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SCHEMA_VERSION = "2"
SOURCE_NAMES = ("mail", "beeper", "drive", "obsidian")
_WRITE_LOCKS, _WRITE_LOCKS_LOCK = {}, threading.Lock()
_TOKEN = re.compile(r"[^\W_]+", re.UNICODE)
_CORRUPT_CODES = {
    sqlite3.SQLITE_CORRUPT,
    sqlite3.SQLITE_NOTADB,
    getattr(sqlite3, "SQLITE_FORMAT", 24),
}


class _SchemaMismatch(sqlite3.DatabaseError):
    pass


def fold(value):
    return " ".join(str(value or "").casefold().split())


def safe_fts_query(raw: str) -> str:
    """Literal Unicode prefixes joined by OR; operators and punctuation are treated as plain tokens."""
    words = dict.fromkeys(_TOKEN.findall(str(raw or "")[:4096]))
    return " OR ".join('"' + word + '"*' for word in list(words)[:64])


def _stamp(path):
    try:
        st = path.stat()
        return [st.st_mtime_ns, st.st_size]
    except FileNotFoundError:
        return None


def _number(value):
    try:
        n = float(value or 0)
        return n if -1e20 < n < 1e20 else 0.0
    except (TypeError, ValueError):
        return 0.0


def _strings(value):
    return [s for s in value if isinstance(s, str)] if isinstance(value, list) else []


def _people(value):
    return [{"name": str(p.get("name") or ""), "email": str(p.get("email") or "")}
            for p in value if isinstance(p, dict)] if isinstance(value, list) else []


def _json(value):
    return json.dumps(value, ensure_ascii=False)


def _is_corruption(exc):
    if isinstance(exc, _SchemaMismatch):
        return True
    code = getattr(exc, "sqlite_errorcode", 0) & 255
    if code in _CORRUPT_CODES:
        return True
    msg = str(exc).lower()
    return "malformed" in msg or "not a database" in msg


class LocalSearchIndex:
    def __init__(self, data_dir=None, db_path=None):
        if data_dir is None and db_path is not None:
            parent = Path(db_path).absolute().parent
            data_dir = parent.parent if parent.name == "cache" else parent
        self.data_dir = Path(data_dir or ROOT / "data").absolute()
        self.db_path = Path(db_path or self.data_dir / "cache/search.sqlite").absolute()
        if self.db_path.suffix.lower() in (".jsonl", ".md") or self.db_path.is_symlink():
            raise ValueError("The cache path must be a database file, not a source file or symlink")
        self.sources_dir = self.data_dir / "sources"
        self.enabled = None
        with _WRITE_LOCKS_LOCK:
            self._write_lock = _WRITE_LOCKS.setdefault(str(self.db_path.resolve()), threading.RLock())
        self._writer, self._writer_id = None, None
        self._readers = threading.local()
        self.last_sync_ms, self.error = 0.0, ""

    def close(self):
        self._close_reader()
        with self._write_lock:
            self._close_writer()

    def _close_writer(self):
        if self._writer is not None:
            try:
                self._writer.close()
            except sqlite3.DatabaseError:
                pass
        self._writer, self._writer_id = None, None

    def _close_reader(self):
        conn = getattr(self._readers, "conn", None)
        if conn is not None:
            try:
                conn.close()
            except sqlite3.DatabaseError:
                pass
        self._readers.conn, self._readers.identity = None, None

    def _file_id(self):
        try:
            st = self.db_path.stat()
            return st.st_dev, st.st_ino
        except FileNotFoundError:
            return None

    def _open_writer(self):
        if self._writer is not None and self._file_id() == self._writer_id:
            return False
        self._close_writer()
        self.db_path.parent.mkdir(parents=True, exist_ok=True)
        db = sqlite3.connect(self.db_path, timeout=5, check_same_thread=False)
        self._writer = db
        db.row_factory = sqlite3.Row
        db.create_function("fold", 1, fold, deterministic=True)
        db.execute("PRAGMA busy_timeout=5000")
        db.execute("PRAGMA journal_mode=WAL")
        db.execute("PRAGMA synchronous=NORMAL")
        db.execute("PRAGMA temp_store=MEMORY")
        db.execute("CREATE TABLE IF NOT EXISTS meta(key TEXT PRIMARY KEY, val TEXT)")
        version = db.execute("SELECT val FROM meta WHERE key='schema_version'").fetchone()
        if version is not None and version[0] != SCHEMA_VERSION:
            raise _SchemaMismatch("search cache schema changed")
        fresh = version is None
        if fresh:
            db.executescript("""
                CREATE TABLE docs(
                    doc_id TEXT PRIMARY KEY, kind TEXT, src TEXT, t REAL, title TEXT,
                    body TEXT, who_json TEXT, who_text TEXT, links_json TEXT,
                    files_json TEXT, url TEXT, chat TEXT, mine INTEGER,
                    links_text TEXT, files_text TEXT, find_text TEXT);
                CREATE INDEX docs_src_time ON docs(src, t DESC);
                CREATE VIRTUAL TABLE docs_fts USING fts5(
                    title, body, who_text, links_text, files_text,
                    content='docs', content_rowid='rowid',
                    tokenize='unicode61 remove_diacritics 2');
                CREATE VIRTUAL TABLE docs_find USING fts5(
                    find_text, content='docs', content_rowid='rowid', tokenize='trigram');
                CREATE TRIGGER docs_ai AFTER INSERT ON docs BEGIN
                    INSERT INTO docs_fts(rowid,title,body,who_text,links_text,files_text)
                    VALUES(new.rowid,new.title,new.body,new.who_text,new.links_text,new.files_text);
                    INSERT INTO docs_find(rowid,find_text) VALUES(new.rowid,new.find_text);
                END;
                CREATE TRIGGER docs_ad AFTER DELETE ON docs BEGIN
                    INSERT INTO docs_fts(docs_fts,rowid,title,body,who_text,links_text,files_text)
                    VALUES('delete',old.rowid,old.title,old.body,old.who_text,old.links_text,old.files_text);
                    INSERT INTO docs_find(docs_find,rowid,find_text) VALUES('delete',old.rowid,old.find_text);
                END;
                CREATE TRIGGER docs_au AFTER UPDATE ON docs BEGIN
                    INSERT INTO docs_fts(docs_fts,rowid,title,body,who_text,links_text,files_text)
                    VALUES('delete',old.rowid,old.title,old.body,old.who_text,old.links_text,old.files_text);
                    INSERT INTO docs_find(docs_find,rowid,find_text) VALUES('delete',old.rowid,old.find_text);
                    INSERT INTO docs_fts(rowid,title,body,who_text,links_text,files_text)
                    VALUES(new.rowid,new.title,new.body,new.who_text,new.links_text,new.files_text);
                    INSERT INTO docs_find(rowid,find_text) VALUES(new.rowid,new.find_text);
                END;
            """)
            with db:
                db.execute("INSERT INTO meta VALUES('schema_version', ?)", (SCHEMA_VERSION,))
        self._writer_id = self._file_id()
        return fresh

    def _open_reader(self):
        """Non-blocking per-thread read-only WAL connection. Never acquires _write_lock."""
        fid = self._file_id()
        if fid is None:
            self._close_reader()
            return None
        conn = getattr(self._readers, "conn", None)
        if conn is not None and getattr(self._readers, "identity", None) == fid:
            return conn
        self._close_reader()
        uri = f"file:{self.db_path.as_posix()}?mode=ro"
        db = sqlite3.connect(uri, uri=True, timeout=0.2, check_same_thread=False)
        db.row_factory = sqlite3.Row
        db.create_function("fold", 1, fold, deterministic=True)
        db.execute("PRAGMA busy_timeout=200")
        db.execute("PRAGMA query_only=ON")
        db.execute("PRAGMA temp_store=MEMORY")
        version = db.execute("SELECT val FROM meta WHERE key='schema_version'").fetchone()
        if version is None or version[0] != SCHEMA_VERSION:
            db.close()
            raise _SchemaMismatch("search cache schema not ready")
        self._readers.conn, self._readers.identity = db, fid
        return db

    def _reset(self):
        self._close_reader()
        self._close_writer()
        for path in (self.db_path, Path(str(self.db_path) + "-wal"), Path(str(self.db_path) + "-shm")):
            path.unlink(missing_ok=True)

    def _read(self, action, default):
        """Run a read-only query without acquiring _write_lock. Only resets on genuine corruption."""
        for attempt in range(2):
            try:
                db = self._open_reader()
                if db is None:
                    return default
                result = action(db)
                self.error = ""
                return result
            except sqlite3.DatabaseError as exc:
                self.error = type(exc).__name__
                if not _is_corruption(exc) or attempt:
                    break
                # Corrupt DB on read: serialize recovery through _write_lock and retry once.
                with self._write_lock:
                    try:
                        self._reset()
                        self._open_writer()
                        self._sync_locked()
                    except (sqlite3.DatabaseError, OSError):
                        break
            except OSError as exc:
                self.error = type(exc).__name__
                break
        return default

    def sync(self, sources_dir=None, data_dir=None, enabled=None):
        """Per-file stamp sync: parses changed JSONL stores before opening the write transaction."""
        with self._write_lock:
            if data_dir is not None:
                self.data_dir = Path(data_dir).absolute()
            if sources_dir is not None or data_dir is not None:
                self.sources_dir = Path(sources_dir or self.data_dir / "sources").absolute()
            self.enabled = enabled
            for attempt in range(2):
                try:
                    self._open_writer()
                    result = self._sync_locked()
                    self.error = ""
                    return result
                except sqlite3.DatabaseError as exc:
                    self.error = type(exc).__name__
                    if not _is_corruption(exc) or attempt:
                        break
                    try:
                        self._reset()
                    except OSError:
                        break
                except OSError as exc:
                    self.error = type(exc).__name__
                    break
            return {"changed": [], "error": self.error or "cache unavailable"}

    def _switches(self):
        enabled = self.enabled
        if enabled is None:
            try:
                enabled = json.loads((self.data_dir / "sources.json").read_text())
            except (OSError, ValueError):
                enabled = {}
        if isinstance(enabled, dict):
            return {name: bool(value.get("enabled", True) if isinstance(value, dict) else value)
                    for name, value in enabled.items()}
        return {name: name in enabled for name in SOURCE_NAMES}

    def _read_jsonl(self, path):
        rows = {}
        with path.open(encoding="utf-8", errors="replace") as stream:
            for line in stream:
                try:
                    row = json.loads(line)
                except ValueError:
                    continue
                if isinstance(row, dict) and row.get("id"):
                    rows[str(row["id"])] = row
        return sorted(rows.values(), key=lambda r: -_number(r.get("t")))

    def _values(self, row, kind):
        title, body = str(row.get("title") or ""), str(row.get("text") or "")
        people, links, files = _people(row.get("who")), _strings(row.get("links")), _strings(row.get("files"))
        url = str(row.get("url") or "")
        head = body[:120 if kind == "beeper" else 300]
        return (str(row["id"]), kind, kind, _number(row.get("t")), title, body, _json(people),
                " ".join(p["name"] + " " + p["email"] for p in people), _json(links), _json(files),
                url, str(row.get("chat") or ""), int(bool(row.get("mine"))),
                " ".join([*links, url]), " ".join(files), fold(" ".join([title, head, *files, *links])))

    def _sync_locked(self):
        start = time.perf_counter()
        from sources import INDEX_MAX
        switches = self._switches()
        import obsidian
        vault = str(obsidian.vault_path(self.data_dir) or "")
        switches["obsidian"] = switches.get("obsidian", True) and obsidian.enabled(self.data_dir)
        db = self._writer
        old = {r[0][6:]: r[1] for r in db.execute("SELECT key,val FROM meta WHERE key LIKE 'stamp:%'")}
        # Parse and materialize tuples outside any write transaction so WAL readers stay unblocked.
        changes = []
        for name in SOURCE_NAMES:
            path, cap = self.sources_dir / (name + ".jsonl"), INDEX_MAX[name]
            stamp = _stamp(path) if switches.get(name, True) else "off"
            value = _json([str(path), stamp, cap] + ([vault] if name == "obsidian" else []))
            if old.get(name) == value:
                continue
            prepared = []
            if stamp not in (None, "off"):
                rows = self._read_jsonl(path)[:cap]
                if _stamp(path) != stamp:
                    continue
                if name == "obsidian": rows = [r for r in rows if r.get("_vault") == vault]
                prepared = [self._values(row, name) for row in rows]
            changes.append((name, value, prepared))
        if changes:
            with db:
                for name, value, prepared in changes:
                    db.execute("DELETE FROM docs WHERE kind=?", (name,))
                    if prepared:
                        db.executemany("INSERT INTO docs VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)", prepared)
                    db.execute("INSERT OR REPLACE INTO meta VALUES(?,?)", ("stamp:" + name, value))
                    if name == "obsidian":
                        db.execute("INSERT OR REPLACE INTO meta VALUES(?,?)", ("obsidian_vault", vault if switches["obsidian"] else ""))
        self.last_sync_ms = (time.perf_counter() - start) * 1000
        return {"changed": [name for name, _, _ in changes], "ms": self.last_sync_ms}

    @staticmethod
    def _who_sql(who):
        words = sorted({fold(word) for word in who if fold(word)})
        if not words:
            return "0", []
        slots = ",".join("?" for _ in words)
        return ("EXISTS(SELECT 1 FROM json_each(d.who_json) p WHERE "
                f"fold(json_extract(p.value,'$.name')) IN ({slots}) OR "
                f"fold(json_extract(p.value,'$.email')) IN ({slots}))", words + words)

    def _vault_filter(self):
        import obsidian
        vault = str(obsidian.vault_path(self.data_dir) or "") if obsidian.enabled(self.data_dir) else ""
        return (" AND (d.kind != 'obsidian' OR (? != '' AND "
                "? = (SELECT val FROM meta WHERE key='obsidian_vault')))", [vault, vault])

    def search(self, query, *, kinds=None, who=(), since=0, limit=20):
        match = safe_fts_query(query)
        if not match or limit <= 0 or kinds == [] or kinds == ():
            return []
        boost, params = self._who_sql(who)
        filters = ""
        selected = [kinds] if isinstance(kinds, str) else list(kinds) if kinds is not None else None
        if selected is not None:
            if not selected:
                return []
            filters = " AND d.kind IN (" + ",".join("?" for _ in selected) + ")"
        vault_filter, vault_params = self._vault_filter()
        sql = ("SELECT d.*, snippet(docs_fts,1,'','',' ... ',32) AS snippet, "
               f"-bm25(docs_fts,4,1,2,1,2) + 0.5 * ({boost}) AS score "
               "FROM docs_fts CROSS JOIN docs d ON d.rowid=docs_fts.rowid "
               "WHERE docs_fts MATCH ? AND d.t>=?" + filters + vault_filter + " ORDER BY score DESC,d.t DESC LIMIT ?")
        params += [match, since, *(selected or []), *vault_params, limit]
        return self._read(lambda db: [
            {"id": r["doc_id"], "kind": r["kind"], "src": r["src"], "t": r["t"],
             "title": r["title"], "snippet": r["snippet"], "who": json.loads(r["who_json"]),
             "links": json.loads(r["links_json"]), "files": json.loads(r["files_json"]),
             "url": r["url"], "score": r["score"]}
            for r in db.execute(sql, params)
        ], [])

    def find_links_files(self, query, who=(), n=8, since=0):
        """Fast trigram-indexed link & file search matching sources.Index.find() semantics."""
        words = re.findall(r"[^\W_]{3,}", fold(query)[:4096])[:64]
        if not words or n <= 0:
            return []
        ws = {fold(x) for x in who if x}
        boost, boost_params = self._who_sql(who)
        hits = " + ".join("(instr(d.find_text,?)>0)" for _ in words)
        match = " OR ".join('"' + w + '"' for w in dict.fromkeys(words))
        vault_filter, vault_params = self._vault_filter()
        sql = (f"SELECT d.*, (({hits}) * 1.0 / ? + 0.5 * ({boost})) AS score "
               "FROM docs_find CROSS JOIN docs d ON d.rowid=docs_find.rowid "
               "WHERE docs_find MATCH ? AND d.t>=? " + vault_filter +
               "ORDER BY score DESC,d.t DESC,CASE d.src WHEN 'mail' THEN 0 WHEN 'drive' THEN 1 ELSE 2 END,d.rowid")
        params = [*words, len(words), *boost_params, match, since, *vault_params]

        def run(db):
            cursor = db.execute(sql, params)
            try:
                return self._links(cursor, words, ws, n)
            finally:
                cursor.close()
        return self._read(run, [])

    @staticmethod
    def _links(rows, words, ws, n):
        result, seen = [], set()
        for row in rows:
            if not any(word in row["find_text"] for word in words):
                continue
            people = json.loads(row["who_json"])
            with_them = bool(ws & {fold(p[k]) for p in people for k in ("name", "email")})
            sender = next((p["name"] or p["email"] for p in people), "")
            files, links = json.loads(row["files_json"]), json.loads(row["links_json"])
            targets = [(f, row["url"]) for f in files[:3]]
            if row["src"] != "obsidian":
                targets += [("", u) for u in links[:3] if with_them or any(w in fold(u) for w in words)]
            if row["src"] in ("drive", "obsidian") and not files:
                targets.append(("", row["url"]))
            for file, url in targets:
                if (file, url) in seen:
                    continue
                seen.add((file, url))
                result.append({"title": row["title"], "file": file, "url": url, "src": row["src"], "t": row["t"], "from": sender})
                if len(result) >= n:
                    return result
        return result

    def topics(self, emails=(), names=(), n=3):
        es = sorted({e.lower() for e in emails if e})
        ns = sorted({fold(x) for x in names if len(fold(x)) >= 3})

        def recent(db):
            result = {"mail": [], "chats": []}
            for kind, values, field, dest in (("mail", es, "email", "mail"), ("beeper", ns, "name", "chats")):
                if not values or n <= 0:
                    continue
                sql = ("SELECT title,chat FROM docs d WHERE src=? AND EXISTS(SELECT 1 FROM json_each(d.who_json) p "
                       f"WHERE {'fold(' if kind == 'beeper' else '('}json_extract(p.value,'$.{field}')) IN (" +
                       ",".join("?" for _ in values) + ")) ORDER BY t DESC")
                seen = set()
                for row in db.execute(sql, [kind, *values]):
                    title = row["title"]
                    if kind == "mail":
                        if not title or fold(title) in seen:
                            continue
                        seen.add(fold(re.sub(r"^((re|fwd?|відп)\s*:\s*)+", "", title, flags=re.I)))
                    else:
                        if row["chat"] in seen:
                            continue
                        seen.add(row["chat"])
                        if not title or fold(title) in ns:
                            continue
                    result[dest].append(title)
                    if len(result[dest]) >= n:
                        break
            return result
        return self._read(recent, {"mail": [], "chats": []})

    def source_rows(self, name):
        """Compatibility snapshot for sources.Index.rows, loaded only on access."""
        return self._read(lambda db: [
            {"id": r["doc_id"], "src": r["src"], "t": r["t"], "title": r["title"],
             "who": json.loads(r["who_json"]), "mine": bool(r["mine"]),
             "links": json.loads(r["links_json"]), "files": json.loads(r["files_json"]),
             "url": r["url"], "chat": r["chat"], "head": r["body"][:120 if name == "beeper" else 300]}
            for r in db.execute("SELECT * FROM docs WHERE src=? ORDER BY t DESC", (name,))
        ], [])

    def stats(self):
        def counts(db):
            by_src = {r[0]: r[1] for r in db.execute("SELECT src,count(*) FROM docs GROUP BY src")}
            size = sum(path.stat().st_size for path in (self.db_path, Path(str(self.db_path) + "-wal")) if path.exists())
            return {"src": by_src, "db_bytes": size, "last_sync_ms": self.last_sync_ms}
        result = self._read(counts, {"src": {}, "db_bytes": 0, "last_sync_ms": self.last_sync_ms})
        if self.error:
            result["error"] = self.error
        return result

// The journal window's rows from data/journal.sqlite (journal in SQLite, phase 1, 23 November 2026). The engine
// (engine/journal_db.py) copies typed.jsonl, takes.jsonl and clipboard.jsonl into it row by row, each line verbatim;
// the files stay as they are. With `journalDB` on (default) the window reads the newest rows from the database, opened
// query-only; whenever the database cannot answer for a file as it is now (no database, another schema, the engine
// behind the file: another inode or bytes not yet copied) that file is read from JSONL as before. Off: JSONL only.
// Rows come back exactly as JSONLFollow.parse gives them, so everything after the read is unchanged (DraftHide, the
// journal's own archive in JournalStore). Foundation + SQLite3; tests/journal_db.swift.
import Foundation
import SQLite3

enum JournalDBRules {
    static let schemaVersion = "1"
    /// The database holds every whole line of the file as it is now. With the file's write time kept (`syncMtime`, ns;
    /// 0 for rows written before it was read here) that must match too: a file rewritten in place to the same size
    /// keeps its inode and size (review 25 November 2026, Astra).
    static func current(syncInode: UInt64, syncOffset: UInt64, fileInode: UInt64, fileSize: UInt64, syncMtime: Int64 = 0, fileMtime: Int64 = 0) -> Bool {
        syncInode != 0 && syncInode == fileInode && syncOffset == fileSize && (syncMtime == 0 || syncMtime == fileMtime)
    }
    /// The setting decides; the database answers only when it can (nil), else the JSONL read runs.
    static func pick(on: Bool, db: () -> [[String: Any]]?, jsonl: () -> [[String: Any]]) -> (rows: [[String: Any]], fromDB: Bool) {
        if on, let rows = db() { return (rows, true) }
        return (jsonl(), false)
    }
}

final class JournalDBRead {
    let url: URL
    init(_ url: URL) { self.url = url }

    /// The newest `n` live rows of `store` (typed, takes, clipboard), newest first (JSONLFollow.newest's order);
    /// nil: read `file` instead.
    func newest(_ store: String, file: URL, n: Int) -> [[String: Any]]? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        var db: OpaquePointer?
        // read-write without create, then query_only: a read-only handle cannot open a WAL database whose -shm file
        // is gone (the engine closed it); this one never creates the database and never writes to it
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK, let db else {
            if let db { sqlite3_close(db) }
            return nil
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 500)
        guard sqlite3_exec(db, "PRAGMA query_only=ON", nil, nil, nil) == SQLITE_OK else { return nil }
        guard text(db, "SELECT val FROM meta WHERE key='schema_version'", []).first == JournalDBRules.schemaVersion else { return nil }
        var fs = stat()
        guard stat(file.path, &fs) == 0 else { return nil }
        let inode = UInt64(fs.st_ino), size = UInt64(fs.st_size)
        let mtime = Int64(fs.st_mtimespec.tv_sec) * 1_000_000_000 + Int64(fs.st_mtimespec.tv_nsec)
        var st: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT inode, offset, mtime_ns FROM sync WHERE name=?", -1, &st, nil) == SQLITE_OK else { return nil }
        bind(st, 1, store)
        var ok = false
        if sqlite3_step(st) == SQLITE_ROW {
            ok = JournalDBRules.current(syncInode: UInt64(sqlite3_column_int64(st, 0)), syncOffset: UInt64(sqlite3_column_int64(st, 1)),
                                        fileInode: inode, fileSize: size, syncMtime: sqlite3_column_int64(st, 2), fileMtime: mtime)
        }
        sqlite3_finalize(st)
        guard ok else { return nil }
        guard sqlite3_prepare_v2(db, "SELECT line FROM rows WHERE store=? AND removed_at IS NULL ORDER BY seq DESC LIMIT ?", -1, &st, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(st) }
        bind(st, 1, store); sqlite3_bind_int64(st, 2, Int64(n))
        var rows: [[String: Any]] = []
        while true {
            let r = sqlite3_step(st)
            if r == SQLITE_DONE { break }
            guard r == SQLITE_ROW else { return nil }
            let len = Int(sqlite3_column_bytes(st, 0))
            guard let p = sqlite3_column_blob(st, 0) else { continue }
            if let row = JSONLFollow.parse(Data(bytes: p, count: len)) { rows.append(row) }
        }
        return rows
    }

    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    private func bind(_ st: OpaquePointer?, _ i: Int32, _ s: String) { sqlite3_bind_text(st, i, s, -1, Self.transient) }
    private func text(_ db: OpaquePointer, _ sql: String, _ args: [String]) -> [String] {
        var st: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &st, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(st) }
        for (i, a) in args.enumerated() { bind(st, Int32(i + 1), a) }
        var out: [String] = []
        while sqlite3_step(st) == SQLITE_ROW { if let c = sqlite3_column_text(st, 0) { out.append(String(cString: c)) } }
        return out
    }
}

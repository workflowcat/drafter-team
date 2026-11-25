// swiftc -parse-as-library app/JournalDB.swift app/QuickRead.swift app/DraftCaptureRules.swift app/Entry.swift app/PictureLookRules.swift app/ClipRules.swift app/QuickRules.swift tests/journal_db.swift -o app/build/journal-db-test && app/build/journal-db-test
// The journal window's database read (journal in SQLite, phase 1): the setting off never asks the database; a
// database that is current answers newest first, removed rows left out; behind the file, another inode, another
// schema or no database: nil (the JSONL read runs). Made-up rows in a temporary folder; the database is made here
// with the same tables engine/journal_db.py writes (tests/test_journal_db.py checks the two together).
import Foundation
import SQLite3

@main
struct JournalDBChecks {
    static var failed = 0
    static func check(_ ok: Bool, _ what: String) { if !ok { failed += 1; print("FAIL", what) } }

    static func exec(_ db: OpaquePointer?, _ sql: String) { check(sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK, "sql: \(sql.prefix(40))") }

    static func main() {
        // pure rules
        check(JournalDBRules.current(syncInode: 5, syncOffset: 10, fileInode: 5, fileSize: 10), "same inode, all read")
        check(!JournalDBRules.current(syncInode: 5, syncOffset: 10, fileInode: 6, fileSize: 10), "another inode")
        check(!JournalDBRules.current(syncInode: 5, syncOffset: 10, fileInode: 5, fileSize: 20), "behind the file")
        check(!JournalDBRules.current(syncInode: 0, syncOffset: 0, fileInode: 0, fileSize: 0), "never synced")
        check(!JournalDBRules.current(syncInode: 5, syncOffset: 10, fileInode: 5, fileSize: 10, syncMtime: 100, fileMtime: 200), "rewritten in place")
        check(JournalDBRules.current(syncInode: 5, syncOffset: 10, fileInode: 5, fileSize: 10, syncMtime: 100, fileMtime: 100), "same write time")
        var asked = false
        let off = JournalDBRules.pick(on: false, db: { asked = true; return [["text": "db"]] }, jsonl: { [["text": "file"]] })
        check(!asked && !off.fromDB && off.rows.first?["text"] as? String == "file", "off: JSONL only, the database is never asked")
        let on = JournalDBRules.pick(on: true, db: { [["text": "db"]] }, jsonl: { [["text": "file"]] })
        check(on.fromDB && on.rows.first?["text"] as? String == "db", "on: the database")
        let behind = JournalDBRules.pick(on: true, db: { nil }, jsonl: { [["text": "file"]] })
        check(!behind.fromDB && behind.rows.first?["text"] as? String == "file", "on but behind: JSONL")

        // a database in a temporary folder
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("journal-db-test-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("takes.jsonl"), dbURL = dir.appendingPathComponent("journal.sqlite")
        let lines = [#"{"id":"a","t":1700000000.1234567,"text":"first made-up take"}"#,
                     #"{"id":"b","t":1700000001.5,"text":"second made-up take"}"#,
                     #"{"id":"c","t":1700000002.25,"text":"third made-up take"}"#]
        try? (lines.joined(separator: "\n") + "\n").write(to: file, atomically: false, encoding: .utf8)
        let read = JournalDBRead(dbURL)
        check(read.newest("takes", file: file, n: 10) == nil, "no database: nil")

        var db: OpaquePointer?
        sqlite3_open(dbURL.path, &db)
        exec(db, "CREATE TABLE meta(key TEXT PRIMARY KEY, val TEXT); INSERT INTO meta VALUES('schema_version','1');")
        exec(db, "CREATE TABLE sync(name TEXT PRIMARY KEY, path TEXT, inode INTEGER, size INTEGER, offset INTEGER, tail BLOB, lines INTEGER, mtime_ns INTEGER, synced_at REAL);")
        exec(db, "CREATE TABLE rows(rid INTEGER PRIMARY KEY, store TEXT, line BLOB, seq INTEGER, removed_at REAL);")
        for (i, l) in lines.enumerated() {
            exec(db, "INSERT INTO rows(store, line, seq, removed_at) VALUES('takes', CAST('\(l)' AS BLOB), \(i), NULL);")
        }
        exec(db, "INSERT INTO rows(store, line, seq, removed_at) VALUES('takes', CAST('{\"id\":\"gone\",\"t\":1}' AS BLOB), 9, 5);")
        let attrs = try? FileManager.default.attributesOfItem(atPath: file.path)
        let inode = (attrs?[.systemFileNumber] as? NSNumber)?.int64Value ?? 0, size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
        exec(db, "INSERT INTO sync(name, inode, size, offset, lines) VALUES('takes', \(inode), \(size), \(size), 3);")

        let rows = read.newest("takes", file: file, n: 2)
        check(rows?.map { $0["id"] as? String ?? "" } == ["c", "b"], "newest first, limited, removed row left out: \(String(describing: rows))")
        check((rows?.last?["t"] as? Double) == 1700000001.5, "t as parsed from the line")
        let whole = read.newest("takes", file: file, n: 10)
        check(whole?.map { $0["id"] as? String ?? "" } == ["c", "b", "a"], "all live rows")
        // same rows as JSONLFollow gives from the file
        let follow = JSONLFollow(file, keep: 10); follow.refresh()
        check(NSArray(array: follow.newest(10)).isEqual(to: whole ?? []), "the database rows equal the JSONL rows")

        // the engine is behind: a line appended
        if let h = try? FileHandle(forWritingTo: file) { h.seekToEndOfFile(); h.write(Data(#"{"id":"d","t":3}"#.utf8 + [0x0A])); try? h.close() }
        check(read.newest("takes", file: file, n: 10) == nil, "behind the file: nil")
        // another schema
        exec(db, "UPDATE sync SET offset = offset + 17; UPDATE meta SET val='2';")
        check(read.newest("takes", file: file, n: 10) == nil, "another schema: nil")
        exec(db, "UPDATE meta SET val='1';")
        check(read.newest("takes", file: file, n: 10) != nil, "current again")
        sqlite3_close(db)

        print(failed == 0 ? "journal db: all checks passed" : "journal db: \(failed) failed")
        exit(failed == 0 ? 0 : 1)
    }
}

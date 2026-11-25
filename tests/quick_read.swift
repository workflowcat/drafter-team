// swiftc -parse-as-library app/QuickRead.swift app/DraftCaptureRules.swift app/Entry.swift app/PictureLookRules.swift app/ClipRules.swift app/QuickRules.swift tests/quick_read.swift -o app/build/quick-read-test && app/build/quick-read-test
// The followed reads of the history files (speed round, 15 November 2026): FileMark.plan and cut, JSONLFollow over
// appends, a line still being written, a rewrite through a temporary file, a rewrite in place, a shorter file; and
// QuickReader gives the same rows read step by step as read whole. Made-up rows only, in a temporary folder.
import Foundation

@main
struct QuickReadChecks {
    static var failed = 0
    static func check(_ ok: Bool, _ what: String, line: Int = #line) { if !ok { failed += 1; print("FAIL line \(line): \(what)") } }

    static func line(_ o: [String: Any]) -> String { String(data: try! JSONSerialization.data(withJSONObject: o), encoding: .utf8)! + "\n" }
    static func append(_ u: URL, _ s: String) {
        if !FileManager.default.fileExists(atPath: u.path) { try! s.write(to: u, atomically: false, encoding: .utf8); return }
        let h = try! FileHandle(forWritingTo: u); h.seekToEndOfFile(); h.write(s.data(using: .utf8)!); try! h.close()
    }
    static func texts(_ f: JSONLFollow) -> [String] { f.rows.map { $0["text"] as? String ?? "?" } }

    static func main() {
        // MARK: plan
        var m = FileMark()
        check(FileMark.plan(m, inode: 5, size: 100, tailNow: nil) == .full, "never read: whole")
        m = FileMark(inode: 5, offset: 100, tail: Data("abc\n".utf8))
        check(FileMark.plan(m, inode: 5, size: 100, tailNow: Data("abc\n".utf8)) == .same, "same size, same tail: nothing")
        check(FileMark.plan(m, inode: 5, size: 150, tailNow: Data("abc\n".utf8)) == .append(from: 100), "grew: from the mark")
        check(FileMark.plan(m, inode: 6, size: 150, tailNow: Data("abc\n".utf8)) == .full, "another file: whole")
        check(FileMark.plan(m, inode: 5, size: 90, tailNow: nil) == .full, "shorter: whole")
        check(FileMark.plan(m, inode: 5, size: 150, tailNow: Data("xbc\n".utf8)) == .full, "bytes before the mark changed: whole")

        // MARK: cut
        var c = FileMark.cut(Data("a\nbb\n\ncc".utf8))
        check(c.lines.map { String(decoding: $0, as: UTF8.self) } == ["a", "bb"] && c.used == 6, "whole lines only, empty dropped, the part line left")
        c = FileMark.cut(Data("no newline yet".utf8))
        check(c.lines.isEmpty && c.used == 0, "a line being written is left")
        let tailSlice = Data("zzz\nq\nr".utf8).dropFirst(4)   // a slice with a non-zero start
        c = FileMark.cut(tailSlice)
        check(c.lines.map { String(decoding: $0, as: UTF8.self) } == ["q"] && c.used == 2, "a slice: counts from its own start")

        // MARK: follow
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("quick-read-test-\(getpid())")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let u = dir.appendingPathComponent("rows.jsonl")
        append(u, (0..<5).map { line(["t": Double($0), "text": "рядок \($0) made-up"]) }.joined())
        let f = JSONLFollow(u, keep: 4)
        check(f.refresh() && f.last.full, "first read: whole")
        check(texts(f) == (1..<5).map { "рядок \($0) made-up" }, "keeps the last 4, oldest first")
        check(!f.refresh() && !f.last.full && f.last.bytes == 0, "unchanged: nothing read")
        append(u, line(["t": 5.0, "text": "new five"]))
        check(f.refresh() && !f.last.full, "append: read the new bytes only")
        check(texts(f) == ["рядок 2 made-up", "рядок 3 made-up", "рядок 4 made-up", "new five"], "appended, trimmed to 4")
        check(f.newest(2).map { $0["text"] as? String ?? "" } == ["new five", "рядок 4 made-up"], "newest first")
        // a line still being written: left for the next read
        append(u, #"{"t": 6, "text": "half"#)
        check(!f.refresh() && texts(f).last == "new five", "a part line is not read")
        append(u, "\"}\n")
        check(f.refresh() && texts(f).last == "half" && !f.last.full, "the rest of the line: read then")
        // a rewrite through a temporary file (History.rewrite, compactClipboard): a new inode
        let tmp = dir.appendingPathComponent(".rows.tmp")
        try! (line(["t": 1.0, "text": "kept a"]) + line(["t": 2.0, "text": "kept b"])).write(to: tmp, atomically: false, encoding: .utf8)
        _ = try! FileManager.default.replaceItemAt(u, withItemAt: tmp)
        check(f.refresh() && f.last.full && texts(f) == ["kept a", "kept b"], "rewritten file: read whole")
        // a rewrite in place to the same length or longer: the bytes before the mark differ
        let h = try! FileHandle(forWritingTo: u); try! h.truncate(atOffset: 0)
        h.write((line(["t": 1.0, "text": "kept A"]) + line(["t": 2.0, "text": "kept B"]) + line(["t": 3.0, "text": "kept C"])).data(using: .utf8)!); try! h.close()
        check(f.refresh() && f.last.full && texts(f) == ["kept A", "kept B", "kept C"], "rewritten in place: read whole")
        // shorter
        try! FileHandle(forWritingTo: u).truncate(atOffset: 0)
        append(u, line(["t": 9.0, "text": "z"]))
        check(f.refresh() && texts(f) == ["z"], "shorter: read whole")
        // a short append after a short first read: the mark's tail joins the old and new bytes
        let g = JSONLFollow(dir.appendingPathComponent("short.jsonl"), keep: 10)
        append(g.url, "{\"text\":\"a\"}\n"); g.refresh()
        append(g.url, "{\"text\":\"b\"}\n"); g.refresh()
        append(g.url, "{\"text\":\"c\"}\n")
        check(g.refresh() && !g.last.full && texts(g) == ["a", "b", "c"], "small appends stay incremental")
        // missing file
        let gone = JSONLFollow(dir.appendingPathComponent("none.jsonl"), keep: 3)
        check(!gone.refresh() && gone.rows.isEmpty, "no file: no rows")
        // parsed strings are native and equal
        check((f.rows.first?["text"] as? String) == "z", "values kept")

        // MARK: QuickReader read step by step = read whole
        let files = QuickReader.Files(clip: dir.appendingPathComponent("clipboard.jsonl"), typed: dir.appendingPathComponent("typed.jsonl"),
                                      drafts: dir.appendingPathComponent("drafts.jsonl"), takes: dir.appendingPathComponent("takes.jsonl"),
                                      hidden: dir.appendingPathComponent("drafts-hidden.json"))
        try! #"{"hidden":[{"kind":"sent","t":3}]}"#.write(to: files.hidden, atomically: true, encoding: .utf8)
        let secrets = QuickRules.secretRules(QuickRules.defaultSecrets)
        let step = QuickReader(files, clipText: { _ in "" })
        func feed(_ k: Int) {
            let t = Double(k)
            append(files.typed, line(["t": t, "text": "message \(k) повідомлення", "app": "a\(k % 2)"]))
            append(files.drafts, line(["t": t - 0.5, "text": "message \(k)", "app": "a\(k % 2)"]))
            append(files.takes, line(["t": t, "text": "take \(k)", "app": "b"]))
            append(files.clip, line(["t": t, "text": k % 3 == 0 ? "same copy" : "copy \(k)", "app": "c", "kind": "text"]))
            if k == 7 { append(files.clip, line(["t": t + 0.1, "text": "sk-ant-api03-abcdefghijklmnopqrstuvwxyz0123456789", "app": "c"])) }
            if k == 8 { append(files.typed, line(["t": t + 0.2, "text": "a test ⟦drafter-test⟧ row", "app": "a0"])) }
        }
        for k in 0..<12 { feed(k); for i in 0..<3 { step.read(i, max: 50, days: 0, secrets: secrets, now: 100) } }
        let whole = QuickReader(files, clipText: { _ in "" }, incremental: false)
        for i in 0..<3 { whole.read(i, max: 50, days: 0, secrets: secrets, now: 100) }
        func sig(_ r: QuickReader) -> [[String]] { r.parts.map { $0.map { "\($0.kind.rawValue)|\($0.at)|\($0.text)" } } }
        check(sig(step) == sig(whole), "step by step equals whole")
        check(step.typed.last.full == false, "the last steps were appends")
        check(!step.parts[0].contains { $0.text.hasPrefix("sk-ant") }, "a secret is not listed")
        check(step.parts[0].filter { $0.text == "same copy" }.count == 1, "a repeated copy once")
        check(!step.parts[1].contains { $0.text.contains("drafter-test") }, "test rows are not listed")
        check(!step.parts[1].contains { $0.text == "message 3 повідомлення" }, "a hidden sent row is not listed")
        check(step.folded.values.contains { $0.contains("message 5") }, "drafts fold into their message")
        // the setting grows: read whole once
        step.read(2, max: 80, days: 0, secrets: secrets, now: 100)
        check(step.takes.last.full, "a larger max reads whole")
        // byte search and digest
        check(QuickReader.has("ab ⟦drafter-test⟧ cd", "⟦drafter-test⟧") && !QuickReader.has("ab", "⟦drafter-test⟧"), "byte search")
        check(QuickReader.digest("Їжак") == QuickReader.digest("Їжак") && QuickReader.digest("a") != QuickReader.digest("b"), "digest")

        print(failed == 0 ? "quick read: all passed" : "quick read: \(failed) failed")
        exit(failed == 0 ? 0 : 1)
    }
}

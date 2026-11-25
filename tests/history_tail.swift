// swift-runner: skip (built by tests/test_history_tail.py)
import Foundation

// Compiled by tests/test_history_tail.py with History.tail cut out of app/History.swift (Argon 24).
@main
struct TailChecks {
    static func main() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("drafter-tail-\(getpid())")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let f = dir.appendingPathComponent("rows.jsonl")
        var text = ""
        for i in 0..<400 { text += "{\"t\": \(i), \"text\": \"рядок \(i) made-up\"}\n" }
        try! text.write(to: f, atomically: true, encoding: .utf8)
        var bad = 0
        func check(_ ok: Bool, _ what: String) { if !ok { print("FAIL: " + what); bad += 1 } }
        check(History.tail(f, bytes: 1_000_000) == nil, "a small file is read whole")
        for cut in [100, 101, 102, 103, 999] {
            guard let t = History.tail(f, bytes: cut) else { check(false, "tail \(cut)"); continue }
            check(text.hasSuffix(t), "the tail is the end of the file (\(cut))")
            check(t.isEmpty || t.hasPrefix("{"), "from the start of a row (\(cut))")
            check(t.hasSuffix("399 made-up\"}\n"), "ends with the last row (\(cut))")
        }
        try? FileManager.default.removeItem(at: dir)
        if bad > 0 { exit(1) }
        print("history tail: all passed")
    }
}

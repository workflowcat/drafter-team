import Foundation

// swiftc -O -parse-as-library app/PasteTrail.swift tests/paste_trail.swift -o app/build/paste-trail-test && app/build/paste-trail-test
// The paste trail in a temp folder: no text kept, a double paste kept once, clips matched to where they went.
@main
struct PasteTrailTest {
    static var failed = 0
    static func check(_ ok: Bool, _ what: String) { if !ok { failed += 1; print("FAIL " + what) } }
    static func main() {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("paste-trail-\(getpid())")
        try? FileManager.default.removeItem(at: dir)
        let url = dir.appendingPathComponent("paste-trail.jsonl")
        let text = "Room 4.12, second floor, the door on the left"
        let h = PasteTrail.hash(text)
        check(h == PasteTrail.hash("room 4.12,  second floor, the door on the LEFT") && h != PasteTrail.hash("Room 4.13"), "hash: words, case")
        let p = PasteTrail.Paste(t: 100, bundle: "com.apple.mail", app: "Mail", hash: h)
        check(PasteTrail.add(p, to: url, recent: []), "first paste kept")
        check(!PasteTrail.add(PasteTrail.Paste(t: 101, bundle: "com.apple.mail", app: "Mail", hash: h), to: url, recent: PasteTrail.read(url)), "the tap's ⌘V for Drafter's own paste: once")
        check(PasteTrail.add(PasteTrail.Paste(t: 200, bundle: "com.apple.Notes", app: "Notes", hash: h), to: url, recent: PasteTrail.read(url)), "another app kept")
        let raw = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        check(!raw.contains("Room") && !raw.contains("door") && raw.split(separator: "\n").count == 2, "no text in the file")
        let back = PasteTrail.read(url)
        check(back.count == 2 && back[0] == p, "read back")
        check(PasteTrail.read(url, since: 150).count == 1, "since")
        // matching: two copies of the same text; a paste belongs to the copy before it
        let other = PasteTrail.hash("something else")
        let pastes = [PasteTrail.Paste(t: 100, bundle: "b.mail", app: "Mail", hash: h), PasteTrail.Paste(t: 150, bundle: "b.notes", app: "Notes", hash: h),
                      PasteTrail.Paste(t: 160, bundle: "b.mail", app: "Mail", hash: h), PasteTrail.Paste(t: 400, bundle: "b.term", app: "Terminal", hash: h),
                      PasteTrail.Paste(t: 50, bundle: "b.notes", app: "Notes", hash: h), PasteTrail.Paste(t: 120, bundle: "b.x", app: "X", hash: other)]
        let d = PasteTrail.destinations(clips: [(90, h), (300, h), (110, other), (500, other)], pastes: pastes)
        check(d[0] == ["Mail", "Notes"], "first copy: Mail then Notes, each once: \(d[0])")
        check(d[1] == ["Terminal"], "second copy: its own paste")
        check(d[2] == ["X"] && d[3].isEmpty, "other text")
        // trim
        for i in 0..<30 { PasteTrail.add(PasteTrail.Paste(t: Double(1000 + i * 10), bundle: "b", app: "B", hash: "\(i)"), to: url, recent: []) }
        PasteTrail.trim(url, keep: 10)
        check(PasteTrail.read(url).count == 10, "trim")
        try? FileManager.default.removeItem(at: dir)
        print(failed == 0 ? "paste trail: all passed" : "paste trail: \(failed) failed")
        exit(failed == 0 ? 0 : 1)
    }
}

import Foundation

// swiftc -parse-as-library app/JournalStore.swift tests/journal_store.swift -o app/build/journal-store-test && app/build/journal-store-test
// The journal's own store in a temporary folder (never data/): a change beside the original, back to the original,
// Revert and its undo, a draft from Combine kept and read again, the time order of Combine.
@main
struct JournalStoreChecks {
    static var failures = 0
    static func check(_ ok: Bool, _ what: String) { if !ok { print("FAIL: " + what); failures += 1 } }

    static func archiveChecks(_ dir: URL) {
        let url = dir.appendingPathComponent("archive/journal.json")
        try! FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let legacy = #"{"changes":{"t:legacy":{"text":"Synthetic revision","at":1}},"items":[{"id":"draft-old","kind":"draft","text":"Synthetic note","at":2,"sources":[],"pinned":false}]}"#
        try! Data(legacy.utf8).write(to: url)
        let s = JournalStore(url: url)
        check(s.hidden.isEmpty && s.hiddenCount == 0, "legacy JSON has no hidden key")
        check(s.changed("t:legacy") == "Synthetic revision" && s.file.items.count == 1, "legacy content preserved")
        let history = ["history.jsonl", "typed.jsonl", "voice.jsonl"].map { url.deletingLastPathComponent().appendingPathComponent($0) }
        let original = Data("{\"text\":\"Synthetic history\"}\n".utf8)
        for file in history { try! original.write(to: file) }
        check(s.hide(["t:one", "v:two", "t:one", ""]) == ["t:one", "v:two"], "hide returns only newly hidden unique IDs")
        check(s.hiddenCount == 2 && s.isHidden("t:one") && !s.isHidden("unknown"), "hidden lookup and count")
        check(s.hide(["t:one"]).isEmpty, "repeated hide is a no-op")
        check(JournalStore(url: url).hidden == Set(["t:one", "v:two"]), "archive survives reload")
        let delta = s.hide(["t:one", "j:draft-old"])
        s.unhide(delta)
        check(s.hidden == Set(["t:one", "v:two"]), "undo hides only its delta, preserves previous archive")
        s.unhide(["t:one", "t:one", "missing"])
        check(s.hidden == ["v:two"], "unhide is idempotent")
        check(JournalStore(url: url).hidden == ["v:two"], "restore survives reload")
        s.unhide(["v:two"])
        check(JournalStore(url: url).hiddenCount == 0, "full hide/unhide round-trip")
        check(s.changed("t:legacy") == "Synthetic revision" && s.file.items[0].text == "Synthetic note", "archive never edits text")
        let before = s.file
        let note = s.add(kind: "draft", text: "# Clean note\n\nSynthetic history", sources: ["t:one", "v:two"], pinned: false)
        let sources = s.hide(["t:one", "v:two"])
        s.hide(["j:" + note.id]); s.unhide(sources)
        check(s.file.changes == before.changes && s.file.items.contains(note), "merge undo preserves source edits and generated note")
        check(!s.isHidden("t:one") && !s.isHidden("v:two") && s.isHidden("j:" + note.id), "merge undo restores sources and archives output")
        for file in history { check((try! Data(contentsOf: file)) == original, "history bytes unchanged: \(file.lastPathComponent)") }
        let minimal = try! JSONDecoder().decode(JournalStore.File.self, from: Data("{}".utf8))
        check(minimal == JournalStore.File(), "missing optional store fields use empty defaults")
        let mem = JournalStore(url: nil)
        mem.hide(["t:memory"]); mem.unhide(["t:memory"])
        check(mem.hidden.isEmpty, "in-memory archives for previews")
    }

    static func main() {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("journal-store-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("journal.json")
        let s = JournalStore(url: url)
        check(s.changed("t:1") == nil, "nothing changed yet")
        s.change("t:1", to: "See you at the station at nine.", original: "see you at the station at 9")
        check(s.changed("t:1") == "See you at the station at nine.", "a change is kept")
        check(FileManager.default.fileExists(atPath: url.path), "written to the sidecar file")
        let again = JournalStore(url: url)
        check(again.changed("t:1") == "See you at the station at nine.", "read back from the file")
        s.change("t:1", to: "see you at the station at 9", original: "see you at the station at 9")
        check(s.changed("t:1") == nil, "back to the original: no change kept")
        s.change("t:1", to: "Changed text", original: "x")
        let gone = s.revert("t:1")
        check(gone?.text == "Changed text" && s.changed("t:1") == nil, "Revert drops the change and hands it back")
        if let gone { s.restore("t:1", gone) }
        check(s.changed("t:1") == "Changed text", "Undo of Revert puts the change back")
        check(s.revert("nothing") == nil, "Revert with no change: nothing")
        let text = JournalStore.combine([(300, "third"), (100, " first "), (200, "second"), (250, "  ")])
        check(text == "first\n\nsecond\n\nthird", "Combine: time order, blank lines, empty parts out: \(text)")
        let d = s.add(kind: "draft", text: text, sources: ["t:1", "c:2"], pinned: true)
        s.update(d.id, text: text + "\n\nfourth")
        let read = JournalStore(url: url)
        check(read.file.items.count == 1 && read.file.items[0].kind == "draft" && read.file.items[0].sources == ["t:1", "c:2"] && read.file.items[0].pinned, "a draft is kept with its sources")
        check(read.file.items[0].text.hasSuffix("fourth"), "a draft's later text is kept")
        read.pin(d.id, false)
        check(JournalStore(url: url).file.items[0].pinned == false, "Pin off is kept")
        if let gone = read.remove(d.id) {
            check(JournalStore(url: url).file.items.isEmpty, "Delete takes a draft out")
            read.put(gone)
            check(JournalStore(url: url).file.items.count == 1, "Undo of Delete puts it back")
        } else { check(false, "Delete finds the draft") }
        let mem = JournalStore(url: nil)
        mem.change("x", to: "y", original: "z")
        check(mem.changed("x") == "y", "in memory for the preview")
        archiveChecks(dir)
        if failures > 0 { print("\(failures) failed"); exit(1) }
        print("journal store: all passed")
    }
}

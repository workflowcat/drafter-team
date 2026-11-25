// The live insert check, one step per run (scripts/insert_check.sh; insert audit, 23 November 2026, docs/inserts.md).
// `open -n -W -a Drafter --args --insert-check <dir> <bundle> <kind> <n> <line>` starts a second Drafter process that
// does one insert the way the app does it, into the field in front, reads the field back through Accessibility and
// writes <dir>/result-<n>.txt. Keys it posts (ghost, snippet) are unmarked, so the running Drafter answers them as his.
// It acts only when: <dir> is its own temp folder, the app in front is <bundle> and one of TextEdit, Chrome or Safari,
// and the focused field holds ⟦drafter-test⟧ (InsertCheckRules). It never presses Return, never sends, puts his
// clipboard back, and does not read or write data/ (the app's log line aside).
import AppKit
import ApplicationServices

enum InsertCheck {
    static func run(_ a: [String]) {
        guard a.count >= 5 else { print("usage: --insert-check <dir> <bundle> <kind> <n> [line]"); exit(64) }
        let dir = a[0], bundle = a[1], kind = a[2], n = a[3], line = a.count > 4 ? a[4] : ""
        guard InsertCheckRules.dirOK(dir, tmp: NSTemporaryDirectory()) else { print("refused: not its temp folder"); exit(64) }
        let t0 = Date()
        func finish(_ verdict: String, _ code: Int32 = 0) -> Never {
            let ms = Int(Date().timeIntervalSince(t0) * 1000)
            try? "\(verdict)\t\(ms)\n".write(toFile: dir + "/result-\(n).txt", atomically: true, encoding: .utf8)
            exit(code)
        }
        func spin(_ s: Double) { RunLoop.main.run(until: Date().addingTimeInterval(s)) }
        func front() -> String? { NSWorkspace.shared.frontmostApplication?.bundleIdentifier }
        guard InsertCheckRules.targets.contains(bundle) else { finish("refused: \(bundle) is not a test target", 64) }
        if let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == bundle }) { Focus.wake(app) }
        spin(0.2)
        /// The field's whole text: its value, else its text markers (a contenteditable box in Chrome).
        func field() -> String? {
            guard let el = Focus.focused() else { return nil }
            if let v: String = Focus.attr(el, kAXValueAttribute), !v.isEmpty { return v }
            if let (b, af, _) = Focus.markers(el) { return b + af }
            return Focus.attr(el, kAXValueAttribute)
        }
        // the app first: a field of any other app is never read
        func ready() -> Bool {
            guard front() == bundle, InsertCheckRules.targets.contains(bundle) else { return false }
            return InsertCheckRules.mayAct(front: front(), expected: bundle, field: field())
        }
        // a password field cannot hold the marker: read only, on its own page (the window title holds the marker), nothing written
        if kind == "guard-password" {
            for _ in 0..<15 where front() != bundle { spin(0.2) }
            guard front() == bundle, let app = NSWorkspace.shared.frontmostApplication,
                  Focus.windowTitle(app).contains("drafter-insert-check") || Focus.windowTitle(app).contains(InsertRules.marker)
            else { finish("stopped: not its window", 3) }
            spin(1.0)
            let why = Focus.spot(skip: []).1
            finish(why == "password field" || why == "secure input" ? "ok (stopped by guard: \(why))" : "GUARD MISSING (\(why))")
        }
        // a browser builds its Accessibility tree a moment after Focus.wake: wait up to 3 s, only while the app is in front
        for _ in 0..<15 where front() == bundle && !ready() { spin(0.2) }
        guard ready() else { finish(front() == bundle ? "stopped: no test marker in the field" : "stopped: \(front() ?? "?") in front", 3) }
        let src = CGEventSource(stateID: .hidSystemState)
        func key(_ code: CGKeyCode, _ flags: CGEventFlags = [], marked: Bool = false) {
            for down in [true, false] {
                let e = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: down); e?.flags = flags
                if marked { e?.setIntegerValueField(.eventSourceUserData, value: Focus.mark) }
                e?.post(tap: .cghidEventTap); Thread.sleep(forTimeInterval: 0.01)
            }
        }
        func typeKeys(_ s: String) {   // as his own keys: no Return, no control character
            for ch in s where !(ch.unicodeScalars.first.map { $0.value < 0x20 } ?? true) {
                guard ready() else { finish("stopped: front app or marker changed while typing", 3) }
                var u = Array(String(ch).utf16)
                for down in [true, false] {
                    let e = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: down); e?.flags = []
                    e?.keyboardSetUnicodeString(stringLength: u.count, unicodeString: &u); e?.post(tap: .cghidEventTap)
                }
                Thread.sleep(forTimeInterval: 0.05)
            }
        }
        // his clipboard, put back at the end (each insert puts it back itself too)
        let pb = NSPasteboard.general
        let saved = pb.pasteboardItems?.map { item -> NSPasteboardItem in
            let c = NSPasteboardItem(); for t in item.types { if let d = item.data(forType: t) { c.setData(d, forType: t) } }; return c
        } ?? []
        let savedCount = pb.changeCount
        func giveBack() {
            guard pb.changeCount != savedCount else { return }
            pb.clearContents(); if !saved.isEmpty { pb.writeObjects(saved) }
        }
        if kind == "end" { key(125, .maskCommand, marked: true); spin(0.2); finish("ok") }   // the caret to the end of the text
        if kind == "close" {   // ⌘W on its own page or document: the window title holds the marker too
            let app = NSWorkspace.shared.frontmostApplication
            guard let app, Focus.windowTitle(app).contains(InsertRules.marker) || Focus.windowTitle(app).contains("drafter-insert-check") else { finish("stopped: not its window", 3) }
            key(13, .maskCommand, marked: true); spin(0.5); finish("ok")
        }
        let before = field() ?? ""
        var changedOnly = false
        switch kind {
        case "insert":        // Tab accept, the ; picker's insert, Quick, Capture.put, voice put: Focus.insert at the spot
            guard let s = Focus.spot(skip: []).0 else { finish("stopped by guard (\(Focus.spot(skip: []).1))") }
            _ = Focus.insert(line, at: s)
        case "paste":         // every ⌘V with his clipboard saved and back (rework, mention fallback, journal paste)
            Focus.paste(line)
        case "voice-paste":   // a voice piece with no clean spot: pasted, his clipboard left with the take
            guard Focus.pasteTarget(Focus.spot(skip: []).1) || Focus.spot(skip: []).0 != nil else { finish("stopped by guard") }
            Focus.paste(line + " ", restore: false)
        case "type":          // live voice typing, snippets, autocorrect: key events
            Focus.typeText(line)
        case "deck-text":     // the capture deck, a caption step
            ShotSend.paste(steps: [.text(line)], pngs: [], urls: [])
        case "deck-picture":  // the capture deck, a card: its picture, then its caption
            ShotSend.paste(steps: [.picture(0), .text(line)], pngs: [picture()], urls: [])
        case "picture":       // Capture.put(picture:) and the Quick panel's image row
            Focus.paste("", write: Capture.pictureWriter(picture())); changedOnly = true
        case "ghost":         // the running Drafter's ghost: type the line's start as his keys, then Tab
            typeKeys(line); spin(2.5)
            guard ready() else { finish("stopped: front app or marker changed", 3) }
            let typed = field() ?? ""
            key(48); spin(1.2)
            let after = field()
            giveBack()
            finish(after == typed ? "nothing (no ghost shown?)" : (after.map { ($0 as NSString).length > (typed as NSString).length } ?? false) ? "ok (+\((after! as NSString).length - (typed as NSString).length) chars)" : "wrong text")
        case "snippet":       // the running Drafter's ; picker: type the trigger as his keys, then Tab (the first row)
            typeKeys(line); spin(1.5)
            guard ready() else { finish("stopped: front app or marker changed", 3) }
            let typed = field() ?? ""
            key(48); spin(1.5)
            let after = field() ?? ""
            giveBack()
            finish(after == typed ? "nothing (no picker?)" : !after.hasSuffix(line) ? "ok (\((after as NSString).length - (before as NSString).length) chars)" : "wrong text")
        default:
            finish("unknown kind \(kind)", 64)
        }
        // read back until it shows or 3 s pass; the inserts' own clipboard give-back runs in this loop too
        var after = field()
        let until = Date().addingTimeInterval(3)
        while Date() < until {
            spin(0.1); after = field()
            if InsertCheckRules.verdict(before: before, after: after, line: line, changed: changedOnly).hasPrefix("ok") { break }
        }
        let ms = Int(Date().timeIntervalSince(t0) * 1000)
        spin(2.0)   // the deck holds a picture 1.6 s before his clipboard comes back
        after = field()
        giveBack()
        let v = InsertCheckRules.verdict(before: before, after: after, line: line, changed: changedOnly)
        try? "\(v)\t\(ms)\n".write(toFile: dir + "/result-\(n).txt", atomically: true, encoding: .utf8)
        exit(0)
    }

    /// A made-up 64 x 32 picture: two bands of colour.
    static func picture() -> Data {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 64, pixelsHigh: 32, bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        for x in 0..<64 { for y in 0..<32 { rep.setColor(x < 32 ? .systemTeal : .systemOrange, atX: x, y: y) } }
        return rep.representation(using: .png, properties: [:]) ?? Data()
    }
}

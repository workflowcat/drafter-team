// The screenshot tool's journal renders (PREVIEW_ONLY=shotjournal, and in the full --ui-preview run): the gallery with
// three made-up shots (one with a note and pins, sent to Claude; one with an answer; one plain), hovered (the sent
// word), a search by a note's word, the reader with the shot's keys. Pictures are drawn here into a temporary folder;
// nothing is read from or written to data/shots.
import AppKit
import SwiftUI

extension UIShots {
    /// Three made-up shot packs in a temporary folder: (id, picture with its pins, pack). Returns the history rows'
    /// entries for them.
    static func sampleShots(now: Double) throws -> [Entry] {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("drafter-preview-shots", isDirectory: true)
        try? FileManager.default.removeItem(at: root)
        ShotJournal.root = root
        func draw(_ title: String, pins: [(CGFloat, CGFloat)], box: NSRect?) -> Data? {
            let img = NSImage(size: NSSize(width: 1280, height: 800), flipped: true) { r in
                NSColor(white: 0.97, alpha: 1).setFill(); r.fill()
                NSColor(white: 0.90, alpha: 1).setFill(); NSRect(x: 0, y: 0, width: 1280, height: 70).fill()
                for (i, c) in [NSColor.systemRed, .systemYellow, .systemGreen].enumerated() { c.setFill(); NSBezierPath(ovalIn: NSRect(x: 24 + i * 26, y: 26, width: 16, height: 16)).fill() }
                let big: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 40, weight: .semibold), .foregroundColor: NSColor.black]
                let body: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 26), .foregroundColor: NSColor.darkGray]
                (title as NSString).draw(at: NSPoint(x: 60, y: 120), withAttributes: big)
                for k in 0..<4 { NSColor(white: 0.84, alpha: 1).setFill(); NSRect(x: 60, y: 210 + k * 60, width: 760 - k * 110, height: 22).fill() }
                ("Continue" as NSString).draw(at: NSPoint(x: 900, y: 600), withAttributes: body)
                NSColor.systemBlue.setFill(); NSBezierPath(roundedRect: NSRect(x: 880, y: 650, width: 200, height: 36), xRadius: 8, yRadius: 8).fill()
                if let b = box { let p = NSBezierPath(rect: b); p.lineWidth = 6; NSColor.systemRed.setStroke(); p.stroke() }
                for (n, c) in pins.enumerated() {   // numbered pins, drawn into the picture as the capture side does
                    let o = NSRect(x: c.0 - 26, y: c.1 - 26, width: 52, height: 52)
                    NSColor.systemRed.setFill(); NSBezierPath(ovalIn: o).fill()
                    let a: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 30, weight: .bold), .foregroundColor: NSColor.white]
                    let s = "\(n + 1)" as NSString, sz = s.size(withAttributes: a)
                    s.draw(at: NSPoint(x: c.0 - sz.width / 2, y: c.1 - sz.height / 2), withAttributes: a)
                }
                return true
            }
            guard let t = img.tiffRepresentation, let rep = NSBitmapImageRep(data: t) else { return nil }
            return rep.representation(using: .png, properties: [:])
        }
        let cal = TapeBuild.cal
        let today = cal.startOfDay(for: Date(timeIntervalSince1970: now))
        func at(_ h: Int, _ m: Int) -> Double { cal.date(byAdding: .minute, value: h * 60 + m, to: today)!.timeIntervalSince1970 }
        var a = ShotPack(id: "20261114-124010-0a01", t: at(12, 40), app: "Safari", window: "Lantern checkout", width: 1280, height: 800)
        a.note = "The Continue button sits too low, and 2 should say what the total is"
        a.marks = [ShotMark(kind: "pin", x: 980, y: 668, n: 1, text: "too low"), ShotMark(kind: "pin", x: 300, y: 330, n: 2),
                   ShotMark(kind: "box", x: 860, y: 580, w: 240, h: 130)]
        a.sent = [ShotSent(to: .claude, t: at(12, 41))]
        var b = ShotPack(id: "20261114-121502-0b02", t: at(12, 15), app: "Notes", window: "Station plan", width: 1280, height: 800)
        b.note = "Why does the lift plan show two levels?"
        b.answer = "## Two levels\nThe plan draws level 2 twice: once as the platform and once as the lift hall.\nPick one."
        b.sent = [ShotSent(to: .ask, t: at(12, 16))]
        let c = ShotPack(id: "20261114-113000-0c03", t: at(11, 30), app: "Finder", width: 1280, height: 800)
        var out: [Entry] = []
        for (p, title, pins, box) in [(a, "Checkout", [(CGFloat(980), CGFloat(668)), (300, 330)], NSRect(x: 860, y: 580, width: 240, height: 130) as NSRect?),
                                      (b, "Station plan, level 2", [], nil), (c, "Order form v3", [], nil)] {
            let d = ShotJournal.dir(p.id)
            try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
            if let png = draw(title, pins: pins, box: box) { try png.write(to: d.appendingPathComponent("shot.png")) }
            let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            try enc.encode(p).write(to: d.appendingPathComponent("shot.json"))
            var e = Entry(id: "s-" + p.id, when: Date(timeIntervalSince1970: p.t), app: p.app, text: "Image · 1280 × 800", audio: "")
            e.clip = .image; e.shot = p.id
            out.append(e)
        }
        return out
    }

    static func shotJournalShots(_ folder: String, dark: Bool) throws {
        let cal = TapeBuild.cal
        let now = cal.date(from: DateComponents(year: 2026, month: 11, day: 14, hour: 12, minute: 45))!.timeIntervalSince1970
        Entities.previewStore = sampleEntities()
        let keepRoot = ShotJournal.root
        defer { Entities.previewStore = nil; ShotJournal.root = keepRoot }
        TapeBuild.tagCache = [:]
        let m = WindowModel(); m.preview = true; m.now = now
        sampleTape(m, now: now, days: 30, perDay: 3)
        m.clips = (try sampleShots(now: now) + m.clips).sorted { $0.when > $1.when }
        m.rebuildTape()
        let host = NSHostingView(rootView: WindowView(titlebar: true).environmentObject(m).environment(\.colorScheme, dark ? .dark : .light))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 1000), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        host.frame = NSRect(x: 0, y: 0, width: 1280, height: 1000); m.width = 1280
        func shot(_ name: String, wait: Double = 0.3) throws {
            RunLoop.current.run(until: Date().addingTimeInterval(wait)); try save(host, folder + "/" + name + ".png")
        }
        func pick(_ id: String, open: Bool = false) { if let r = m.rows.first(where: { $0.entry?.shot == id }) { m.choose(r.id); m.nav.region = .list; m.open = open ? r.id : nil } }
        let shots = m.rows.filter { $0.shot != nil }.count
        print("shot journal: \(shots) of 3 made-up shots read from shot.json")
        pick("20261114-124010-0a01"); try shot("shotjournal-stream", wait: 0.5)
        m.query = "lift plan"; m.flushSearch(); try shot("shotjournal-search", wait: 0.4); m.query = ""
        pick("20261114-121502-0b02", open: true); try shot("shotjournal-open", wait: 0.4)
    }
}

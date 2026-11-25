// swift-runner: skip (manual: tests/render_note_preview.sh)
// Manual native render harness: zsh tests/render_note_preview.sh
// The bundle must set DrafterHome below this checkout's app/build; output is local and synthetic only.
import AppKit
import SwiftUI

@main struct NotePreviewVisual {
    static func main() throws {
        let build = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("app/build")
        precondition(Home.root.path.hasPrefix(build.path + "/"), "A scratch DrafterHome is required")
        let dark = CommandLine.arguments.contains("--dark")
        let out = build.appendingPathComponent("wave7-previews/" + (dark ? "dark" : "light"))
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        NSApp.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        TagPrefs.shared.preview(); Favicons.forcedOffline = true
        Entities.previewStore = EntityStore()
        let m = WindowModel(); m.preview = true
        m.now = TapeBuild.cal.date(from: DateComponents(year: 2026, month: 11, day: 23, hour: 12))!.timeIntervalSince1970
        m.settings.journalView = "gallery"; m.settings.cardSize = 1; m.settings.journalFold = "older"
        let dir = Home.root.appendingPathComponent("sample-recording")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let image = NSImage(size: NSSize(width: 640, height: 360))
        image.lockFocus()
        Native.paper.setFill(); NSRect(x: 0, y: 0, width: 640, height: 360).fill()
        Native.well.setFill(); NSBezierPath(roundedRect: NSRect(x: 32, y: 32, width: 576, height: 296), xRadius: 12, yRadius: 12).fill()
        NSAttributedString(string: "Sample review", attributes: [.font: Native.text(28, .semibold), .foregroundColor: Native.ink]).draw(at: NSPoint(x: 62, y: 260))
        for i in 0..<4 {
            Native.blue.withAlphaComponent(0.25 + Double(i) * 0.15).setFill()
            NSRect(x: 62 + i * 126, y: 70, width: 90, height: 70 + i * 25).fill()
        }
        image.unlockFocus()
        let png = NSBitmapImageRep(data: image.tiffRepresentation!)!.representation(using: .png, properties: [:])!
        try png.write(to: dir.appendingPathComponent("shot.png"))
        // Presence-only video fixture exercises async badge discovery. This harness never plays media.
        try Data().write(to: dir.appendingPathComponent("screen.mp4"))
        var rich = CallDoc(id: dir.path)
        rich.call = true; rich.title = "Sample planning review"; rich.app = "Google Meet"
        rich.started = Date(timeIntervalSince1970: m.now - 60); rich.secs = 754
        rich.people = ["Sample Person", "Demo Person"]; rich.meSecs = 280; rich.themSecs = 474
        rich.points = ["The sample is ready for review.", "Use one clear title and keep the next steps visible.", "Check the preview in both themes before the next review."]
        rich.todos = ["Review the sample", "Check the narrow pane", "Share a revised outline"]
        rich.mine = "## Review notes\n- Keep the short version.\n- Leave room for the next step."
        rich.turns = [Turn(id: 0, who: "me", start: 0, text: "The sample is ready for review."),
                      Turn(id: 1, who: "Speaker 2", start: 12, text: "The title is clear. Please keep the next steps close to the summary."),
                      Turn(id: 2, who: "me", start: 35, text: "I will check the narrow pane as well."),
                      Turn(id: 3, who: "Speaker 2", start: nil, text: "That should cover the remaining points.")]
        rich.speakers = ["Speaker 2": "Sample Person"]
        rich.shots = [Shot(t: 20, file: "shot.png", app: "Notes", title: "Sample review"), Shot(t: 45, file: "shot.png", app: "Notes", title: "Sample plan")]
        m.docs = [rich]
        for i in 1..<17 {
            var d = CallDoc(id: Home.root.appendingPathComponent("sample-\(i)").path)
            d.call = true; d.title = "Review \(i)"; d.app = i % 2 == 0 ? "Zoom" : ""
            d.started = Date(timeIntervalSince1970: m.now - Double([1, 3, 9, 20, 40, 400][i % 6] * 86400 + i * 120))
            d.secs = Double(60 + i); d.mine = i % 3 == 0 ? "One useful note." : ""
            if i % 3 == 1 { d.turns = [Turn(id: 0, who: "me", start: 0, text: "Okay"), Turn(id: 1, who: "me", start: 1, text: "The first sample is ready for another review.")] }
            if i % 3 == 2 { d.points = ["A short summary."] }
            m.docs.append(d)
        }
        let note = "# Sample plan\n\nA short paragraph explains what changed and why the next step matters.\n\n## Next steps\n- Review the sample\n- Keep the language simple\n1. Check the result\n\n### Local command\n```sh\nprintf 'sample ready\\n'\n```\n\nThe original text stays editable."
        m.typed = [Entry(id: "sample-note", when: Date(timeIntervalSince1970: m.now - 30), app: "Notes", text: note, audio: "", secs: 18),
                   Entry(id: "sample-title", when: Date(timeIntervalSince1970: m.now - 45), app: "Notes", text: "Sample outline\n\nKeep a clear title above the body of this draft.", audio: "", secs: 0)]
        m.rebuildTape()
        let host = NSHostingView(rootView: GalleryList(m: m).background(UIInk.paper).environment(\.colorScheme, dark ? .dark : .light))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 940), styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = host
        func settle() { RunLoop.current.run(until: Date().addingTimeInterval(0.4)); host.layoutSubtreeIfNeeded() }
        func check(_ ok: Bool, _ why: String) { precondition(ok, why) }
        func galleryShot(_ name: String, _ width: CGFloat, _ height: CGFloat = 940) throws {
            window.setContentSize(NSSize(width: width, height: height)); host.frame.size = NSSize(width: width, height: height)
            settle(); try UIShots.save(host, out.appendingPathComponent(name + ".png").path)
        }
        try galleryShot("gallery-wide", 1100)
        check(RecordingPreviewMedia.hasVideo(rich, onReady: {}), "Video discovery completed off the draw path")
        if let gallery = m.galleryView {
            let heights = gallery.placed.compactMap { placed -> (String, CGFloat)? in
                guard case .card(let line) = placed.block, let doc = m.rows[gallery.snap.lines[line].item].doc else { return nil }
                return (doc.id, placed.rect.height)
            }
            let tall = heights.first { $0.0 == rich.id }!.1
            check(heights.contains { $0.0 != rich.id && $0.1 < tall - 80 }, "Short recordings use less height than rich recordings")
        }
        m.setFilter(.kind("call")); settle()
        check(m.results == 17, "17 synthetic recordings match")
        check(m.lines.filter { $0.kind == .row }.count == 17, "Sparse dates expose all 17 recordings")
        guard let folded = m.lines.first(where: { $0.kind == .chunk && $0.title != "Today" }) else { fatalError("No date group") }
        m.toggleFold(folded.id); settle()
        check(m.lines.first(where: { $0.id == folded.id })?.open == false, "Manual fold stays closed")
        m.reflow(); settle()
        check(m.lines.first(where: { $0.id == folded.id })?.open == false, "Reflow preserves manual fold")
        m.toggleFold(folded.id); settle()
        check(m.lines.filter { $0.kind == .row }.count == 17, "Manual unfold restores all cards")
        try galleryShot("recordings-sparse", 1100)
        try galleryShot("gallery-narrow", 390, 850)
        m.setFilter(.all); settle()
        func readerShot(_ id: String, _ name: String, _ width: CGFloat, _ height: CGFloat) throws {
            m.choose(id)
            let reader = NSHostingView(rootView: JournalReader().environmentObject(m).environment(\.colorScheme, dark ? .dark : .light))
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height), styleMask: .borderless, backing: .buffered, defer: false)
            w.contentView = reader; reader.frame.size = NSSize(width: width, height: height)
            RunLoop.current.run(until: Date().addingTimeInterval(0.5)); reader.layoutSubtreeIfNeeded()
            try UIShots.save(reader, out.appendingPathComponent(name + ".png").path)
        }
        let recID = m.rows.first { $0.doc?.id == rich.id }!.id
        try readerShot(recID, "recording-reader", 580, 1250)
        try readerShot(recID, "recording-reader-narrow", 360, 1100)
        let noteID = m.rows.first { $0.entry?.id == "sample-note" }!.id
        m.searchSide.shown = "sample"
        try readerShot(noteID, "note-reader", 640, 780)
        try readerShot(noteID, "note-reader-narrow", 360, 850)
        print("note preview visual: 17 sparse cards, manual fold/unfold, wide/narrow renders passed (\(dark ? "dark" : "light"))")
    }
}

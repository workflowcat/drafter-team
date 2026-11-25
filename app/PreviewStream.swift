// The stream's renders (stream round, 23 November 2026) on made-up rows (UIShots.sampleTape, sampleDocs): the column,
// an open text with its buttons, a voice note with the player, a recording opened in place, editing, Combine, Go to,
// the Record control while recording, the notice with Undo, the scope words. PREVIEW_ONLY=stream renders them alone;
// the full run renders them inside windowShots.
import AppKit
import SwiftUI

/// The preview's window says it is key, so controls draw as in the window he works in (the accent on prominent buttons).
final class PreviewKeyWindow: NSWindow { override var isKeyWindow: Bool { true } }

extension UIShots {
    static func streamShots(_ folder: String, dark: Bool) throws {
        let cal = TapeBuild.cal
        let now = cal.date(from: DateComponents(year: 2026, month: 11, day: 14, hour: 12, minute: 45))!.timeIntervalSince1970
        Entities.previewStore = sampleEntities()
        defer { Entities.previewStore = nil }
        TapeBuild.tagCache = [:]
        let model = WindowModel(); model.preview = true; model.now = now
        sampleTape(model, now: now, days: 420, perDay: 5)
        var docs = try sampleDocs()
        docs[0].started = cal.date(bySettingHour: 11, minute: 48, second: 0, of: Date(timeIntervalSince1970: now))!
        docs[0].secs = 92 * 60 / 10
        docs[1].started = Date(timeIntervalSince1970: now - 86400 + 3600); docs[1].secs = 4 * 60 + 10
        docs[2].started = Date(timeIntervalSince1970: now - 3 * 86400)
        model.docs = docs
        model.previewPins = ["t:t6"]
        model.rebuildTape()
        let host = NSHostingView(rootView: WindowView(titlebar: true).environmentObject(model).environment(\.colorScheme, dark ? .dark : .light))
        let window = PreviewKeyWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 1000), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host; host.frame = NSRect(x: 0, y: 0, width: 1280, height: 1000); model.width = 1280
        func shot(_ name: String, _ wait: Double) throws { RunLoop.current.run(until: Date().addingTimeInterval(wait)); try save(host, folder + "/" + name + ".png") }
        try streamScenes(model, host: host, shot: shot)
        model.show(.settings); try shot("settings", 0.3)
        print("stream previews: " + folder)
    }

    /// The stream's scenes on a model already filled with made-up rows and recordings.
    static func streamScenes(_ model: WindowModel, host: NSView, shot: (String, Double) throws -> Void) throws {
        func id(_ entry: String) -> String? { model.rows.first { $0.entry?.id == entry || $0.id == entry }?.id }
        func pick(_ entry: String, open: Bool = false) {
            guard let i = id(entry) else { return }
            model.choose(i); model.nav.region = .list; model.open = open ? i : nil
        }
        func q(_ s: String) { model.query = s; model.flushSearch(); RunLoop.current.run(until: Date().addingTimeInterval(0.3)); model.open = nil }
        func reset() { model.editing = nil; model.picked = []; model.open = nil; model.stream.notice = nil; model.status = ""; model.nav.region = .list }
        // the column: newest first under day headings, a draft chosen
        pick("t4"); try shot("stream", 0.5)
        // semantic zoom (zoom round, 24 November 2026): weeks, days, sessions, compact and detailed rows; the level he
        // keeps is put back after
        let kept = model.stream.zoom
        for l in [StreamZoomRules.Level.weeks, .days, .sessions, .compact, .detailed] {
            model.stream.zoom = l; model.stream.zoomAnchor = model.chosen.flatMap { model.cardKey(of: $0) }
            try shot("stream-zoom-" + l.name.lowercased(), 0.5)
        }
        model.stream.zoom = kept
        // topics round (24 November 2026): the list by topic, then one topic open; past days folded (the "stream" shot)
        let keptTopic = model.stream.byTopic
        model.stream.zoom = .normal; model.stream.byTopic = true; try shot("stream-topics", 0.5)
        if let first = model.streamTopics.topics.first { model.stream.openTopics = [first.id] }
        try shot("stream-topics-open", 0.5)
        model.stream.openTopics = []; model.stream.byTopic = keptTopic; model.stream.zoom = kept
        // past days folded: a row four days back chosen, so its day is open between folded ones
        let keptFold = model.stream.foldPast
        model.stream.foldPast = true
        q("in:slack "); model.chosen = nil
        try shot("stream-folded", 0.6)
        q("")
        model.stream.foldPast = keptFold
        pick("t4")
        // an open text: Insert (prominent), Copy, Edit, More, Pin, Delete, each with its key
        pick("t1", open: true); try shot("stream-open-text", 0.3)
        // a voice note with the player, paused at 0:07 (the line there marked)
        pick("v1", open: true); if let i = id("v1") { model.stream.pausedAt[i] = 7 }
        try shot("stream-voice-player", 0.3)
        // a recording opened in place: points, the player, its lines (the one at 0:31 marked)
        if let d = model.docs.first { pick("d:" + d.id, open: true); model.stream.pausedAt["d:" + d.id] = 33 }
        try shot("stream-recording-open", 0.3)
        // the recording's title and points in the editor
        model.edit(); model.stream.docPoints += "\n• Send the new strip drawing tonight"; try shot("stream-recording-edit", 0.3)
        model.cancelEdit(); reset()
        // a transcript line being edited
        if let d = model.docs.first { pick("d:" + d.id, open: true); model.stream.lineEdit = .init(doc: "d:" + d.id, index: 1, text: "I see. Where does it show that both sides are recorded?"); model.nav.region = .editor }
        try shot("stream-line-edit", 0.3)
        model.stream.lineEdit = nil; reset()
        // editing a text in place
        pick("t5", open: true); model.edit(); model.draft += " Both themes, please."; try shot("stream-editing", 0.3)
        model.saveEdit(); try shot("stream-saved-notice", 0.2)
        model.undoLast(); reset()
        // three rows picked, then combined
        pick("t1"); model.extend(1); model.extend(1); try shot("stream-combine-pick", 0.3)
        model.combine(); try shot("stream-combine", 0.3)
        model.cancelEdit(); reset()
        // a delete with Undo in the notice
        pick("c2"); model.delete(); try shot("stream-delete-undo", 0.2); model.undoLast(); reset()
        // a picture row open, and the screens scope (its rows keep the row height, the thumbnail as their mark)
        pick("c5", open: true); try shot("stream-picture-open", 0.4)
        q("screens "); try shot("stream-screens", 0.3)
        // recording: the Record control with the time, the meter, Pause and Stop
        q(""); pick("t4")
        model.stream.previewRecording = .init(call: true, seconds: 754, paused: false, title: "Design review: voice strip", me: 0.62, them: 0.38)
        try shot("stream-recording-live", 0.3)
        model.stream.previewRecording?.paused = true; try shot("stream-recording-paused", 0.2)
        model.stream.previewRecording = nil
        // Go to (⌘T)
        model.openPalette(); model.palette = "tues"; try shot("stream-goto", 0.3); model.closePalette()
        // the search: best first, words marked in the open row
        q("station")
        if let f = model.lines.first { model.choose(f.id); model.open = f.id; model.nav.region = .list }
        try shot("stream-search", 0.4)
        q("@mila "); try shot("stream-person", 0.3)
        q("links "); try shot("stream-links", 0.3)
        q("calls "); try shot("stream-calls", 0.3)
        q("in:telegram "); try shot("stream-app", 0.3)
        q("zzqx"); try shot("stream-empty", 0.3)
        q("")
        model.startCommand(); model.command = "book 30 min with Mila tomorrow"
        model.options = [["chip": "Book «Design review» tomorrow 10:00-10:30"], ["chip": "Find a free 30 min slot tomorrow"]]
        model.status = "Haiku · click to run"
        try shot("stream-command", 0.2)
        model.commandMode = false; model.command = ""; model.options = []; model.status = ""
        let frame = host.frame, w = model.width
        host.frame = NSRect(x: 0, y: 0, width: 760, height: 900); model.width = 760
        pick("t1", open: true); try shot("stream-narrow", 0.3)
        host.frame = frame; model.width = w; reset()
    }
}

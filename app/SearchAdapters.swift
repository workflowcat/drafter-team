// From the app's rows to the search core (search round, 14 November 2026): an Entry (copy, typed message, voice take),
// a CallDoc (call or long note) or a QuickItem (the Quick panel) as a SearchDoc, and the hits back as row indices with
// ranges to mark. Pure (Foundation): bench/search_bench.swift uses the same mapping on the real stores.
import Foundation

extension SearchDoc {
    /// A copy, a typed message or a voice take. `id` is the row's own id (the window's TapeItem.id).
    static func entry(_ e: Entry, kind: SearchKind, id: String, time: Double? = nil) -> SearchDoc {
        let text = e.text.isEmpty ? e.raw : e.text
        var d = SearchDoc.text(id: id, kind: kind, time: time ?? e.when.timeIntervalSince1970, app: e.app, text: text)
        if !e.raw.isEmpty, !e.text.isEmpty, e.raw != e.text { d.body += (d.body.isEmpty ? "" : "\n") + e.raw }   // words a clean-up cut
        switch e.clip {
        case .link: d.link = ClipRules.searchExtra(.link, text: e.text, title: e.clipTitle, ocr: "")
        case .file: d.link = ClipRules.searchExtra(.file, text: e.text, title: "", ocr: "")
        case .image: d.picture = true; d.ocr = e.ocr; d.title = ""; d.body = e.pictureWords   // its kind and labels (PictureLookRules)
        case .text: break
        }
        return d
    }

    /// A screenshot kept as a shot pack: its note (the card's line, so the title the search marks), the marks' words,
    /// the window title and the answer (ShotJournalRules.searchText) are searched with the picture's read text.
    mutating func addShot(_ text: String) {
        guard !text.isEmpty else { return }
        title = String(SearchRules.firstLine(text).0.prefix(400))
        body = body.isEmpty ? text : text + "\n" + body
        titleInBody = true
    }

    /// A call or a long note: title, people as tags, summary and to-dos, what was said.
    static func call(_ c: CallDoc, id: String? = nil) -> SearchDoc {
        var d = SearchDoc(id: id ?? "d:" + c.id, kind: .recording, time: c.started.timeIntervalSince1970, app: c.app)
        d.recTitle = c.event.isEmpty || c.event == c.title ? c.title : c.title + " · " + c.event
        d.tags = c.people
        d.summary = (c.points + c.todos).joined(separator: "\n")
        d.transcript = c.turns.map(\.text).joined(separator: "\n")
        return d
    }

    /// A Quick panel row, with QuickRules' learned signal (puts of the item and its app) as `uses`.
    static func quick(_ it: QuickItem, uses: QuickUses = QuickUses(), now: Double = Date().timeIntervalSince1970) -> SearchDoc {
        let kind: SearchKind = it.kind == .copied ? .clip : it.kind == .typed ? .draft : .voice
        var d = SearchDoc.text(id: it.id, kind: kind, time: it.at, app: it.app, text: it.text)
        switch it.clip {
        case .link: d.link = ClipRules.searchExtra(.link, text: it.text, title: it.title, ocr: "")
        case .file: d.link = ClipRules.searchExtra(.file, text: it.text, title: "", ocr: "")
        case .image: d.picture = true; d.ocr = it.ocr; d.title = ""; d.body = ""
        case .text: break
        }
        d.pinned = it.pinned
        d.uses = SearchRules.useSignal(item: uses.items[it.id] ?? [], app: uses.apps[it.appID] ?? [], now: now)
        return d
    }
}

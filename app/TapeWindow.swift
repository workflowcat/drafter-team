// The journal's items (code names keep "tape"): what one item is (TapeItem), the build off the main thread (TapeBuild:
// rows merged, sessions, tags cached per row, chunks of time), one line of the stream (JLine), an action with its key
// (RowAction) and the journal's words (JournalWords). Since the stream round (23 November 2026) the window draws the
// items as one calm column (app/Stream.swift); the gallery, the drawn list, the sidebar and the reader are gone.
// Display rules: app/TapeRules.swift, app/TimeChunkRules.swift. Tags: JournalTags. Search: JournalSearch. His changes
// and drafts: JournalStore.
import AppKit
import SwiftUI

/// One item in the journal.
struct TapeItem: Identifiable, Equatable {
    let id: String
    let kind: TapeKind
    let at: Double
    let app: String
    let line: String           // the text on one line, as stored
    var entry: Entry?
    var doc: CallDoc?
    // set by `TapeBuild.dress` (display only)
    var shown = ""             // what the closed row says (a chat export's message, a web page's lead)
    var tags: [TapeTag] = []   // what it is related to, at most 2
    var repeats = 1            // the same text this many times within a few minutes, folded into this row
    var took: Double?          // how long it took, in seconds
    var pinned = false
    var change: String?        // his own change of the text (JournalStore); the stored row keeps the original
    var chunk = ""             // the chunk of time it sits in (TimeChunks id)
    var hay = ""               // what the search looks in, lower case (set once per build)
    // soft round (display only): the other records of the same text, what happened to it, where it went
    var also: [JournalMeta.Also] = []
    var fate: String?          // "sent in Claude", "in Claude", "copied"
    var to: [String] = []      // the apps a clip was pasted into (PasteTrail), or where a merged text went
    var est = false            // a draft whose start is an estimate
    var shot: ShotPack?        // a capture kept as a shot pack (shot.json, read on the build queue, ShotJournal.pack)
    /// The kind for marks and colours: spoken, typed, copied, call, picture, link, file.
    var kindId: String { doc != nil ? "call" : JournalMeta.kindId(kind.word, clip: entry?.clip.rawValue ?? "text") }
    var quick: QuickKind? { switch kind { case .copied: return .copied; case .typed: return .typed; case .said: return .voice; case .call: return nil } }
    /// The stored text (a take with no final text: its live words).
    var text: String { if let e = entry { return e.text.isEmpty ? e.raw : e.text }; return doc?.title ?? "" }
    /// What Insert and Copy take: his change, else the stored text.
    var current: String { change ?? text }
    /// A journal draft (Combine, kept in JournalStore), not a row of the history files.
    var ownDraft: Bool { id.hasPrefix("j:") }
    static func == (a: TapeItem, b: TapeItem) -> Bool {
        a.id == b.id && a.entry == b.entry && a.doc == b.doc && a.repeats == b.repeats && a.tags == b.tags && a.pinned == b.pinned && a.change == b.change
            && a.also == b.also && a.to == b.to && a.shot == b.shot
    }
    var facet: TapeFacet {
        TapeFacet(kind: kind.word, clip: entry?.clip.rawValue ?? "text", app: app, at: at, tags: tags, pinned: pinned)
    }
    /// The one chip a row shows: the first tag that says more than the app column does.
    var chip: TapeTag? { tags.first { $0.kind != "app" && TagPrefs.shared.shows($0) } }   // main thread (TagPrefs)
    /// Its kind for people, one: "Voice note", "Clip", "Link", "Recording".
    var noun: String {
        if let d = doc { return d.call ? "Recording" : "Voice note" }
        return TapeRules.one(kind.word, clip: entry?.clip.rawValue ?? "text")
    }
    var glyph: String {
        if let d = doc { return d.call ? "phone" : "waves" }
        return entry.flatMap { TapeDraw.clipMark($0.clip) } ?? kind.mark
    }

    static func flat(_ s: String) -> String {
        if !s.contains(where: \.isNewline) { return s.trimmingCharacters(in: .whitespaces) }   // one line: most rows
        return s.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: " ")
    }
}

/// One line of the outline: a chunk of time, a day, week, month or year, a part of the day (a quiet label), a
/// session, an item; or (Group by Related to or App) a group.
struct JLine: Equatable {
    enum Kind: Equatable { case chunk, head, part, session, row }
    let kind: Kind
    let id: String
    var depth = 0
    var title = ""
    var sub = ""
    var open = true
    var item = -1           // row: its index in the items; session: its first item
    var session = -1        // session: its index
    var chunk = ""          // the chunk it sits in
    var parent: String?     // the header above it (← goes there)
    var inSession = false   // a row under a session line
    var foldable: Bool { kind != .row && kind != .part }
    var selectable: Bool { kind != .part }
}

/// What the off-main build hands over: the items (dressed, repeats folded inside sessions, newest first), the sessions
/// (indices into the items, newest first), each session's facts and path in time.
struct JournalBuild {
    var items: [TapeItem] = []
    var sessions: [[Int]] = []
    var facts: [TapeRules.SessionFacts] = []
    var paths: [[TimeChunks.Key]] = []
    var itemSession: [Int] = []
    var now: Double = 0
    var ms: Double = 0
    var missing: [Int] = []     // items whose tags are not known yet (worked out after the first paint, `fillTags`)
}

enum TapeBuild {
    /// His calendar: Monday starts the week.
    static let cal: Calendar = { var c = Calendar.current; c.firstWeekday = 2; c.locale = Locale(identifier: "en_GB"); return c }()
    /// One queue for every build: the tag cache is only touched there.
    static let queue = DispatchQueue(label: "drafter.journal", qos: .userInitiated)

    /// All kinds merged, newest first. Pure: runs off the main thread.
    static func rows(takes: [Entry], clips: [Entry], typed: [Entry], docs: [CallDoc], own: [JournalStore.Item] = []) -> [TapeItem] {
        var out: [TapeItem] = []
        out.reserveCapacity(takes.count + clips.count + typed.count + docs.count + own.count)
        for e in clips {
            out.append(TapeItem(id: "c:\(Int(e.when.timeIntervalSince1970 * 1000)):\(e.text.count)", kind: .copied, at: e.when.timeIntervalSince1970, app: e.app, line: TapeItem.flat(e.text), entry: e))
        }
        for e in typed {
            let t = (e.touched ?? e.when).timeIntervalSince1970
            out.append(TapeItem(id: "t:" + e.id, kind: .typed, at: t, app: e.app, line: TapeItem.flat(e.text.isEmpty ? e.summary : e.text), entry: e))
        }
        for e in takes where !e.audioOnly {
            out.append(TapeItem(id: "v:" + e.id, kind: .said, at: e.when.timeIntervalSince1970, app: e.app, line: TapeItem.flat(e.summary), entry: e))
        }
        for d in docs {
            out.append(TapeItem(id: "d:" + d.id, kind: .call, at: d.started.timeIntervalSince1970, app: d.app, line: d.title, doc: d))
        }
        for o in own {   // his drafts from Combine
            let e = Entry(id: o.id, when: Date(timeIntervalSince1970: o.at), app: "Journal", text: o.text, audio: "")
            var it = TapeItem(id: "j:" + o.id, kind: .typed, at: o.at, app: "Journal", line: TapeItem.flat(o.text), entry: e)
            it.pinned = o.pinned
            out.append(it)
        }
        out.sort { $0.at > $1.at }
        return out
    }

    /// One row for one text kept as several kinds (JournalMeta.merge): the row where it began keeps the others as
    /// `also`, what happened to it as `fate`. Display only: every stored row stays.
    static func mergeKinds(_ rows: [TapeItem]) -> [TapeItem] {
        let mr = rows.map { r in
            JournalMeta.Row(kind: r.ownDraft || r.entry?.clip != nil && r.entry?.clip != .text ? "own" : r.kind.word, at: r.at,
                            text: r.kind == .said ? (r.entry?.summary ?? "") : r.text, app: r.app, sent: r.entry?.sent ?? false)
        }
        let g = JournalMeta.merge(mr)
        guard !g.isEmpty else { return rows }
        var out = rows, drop = Set<Int>()
        for (o, others) in g {
            out[o].also = others.sorted { mr[$0].at < mr[$1].at }.map { JournalMeta.Also(kind: mr[$0].kind, app: mr[$0].app, at: mr[$0].at, sent: mr[$0].sent) }
            out[o].fate = JournalMeta.fate(others.map { mr[$0] })
            var to: [String] = []
            for j in others where mr[j].kind == "typed" && !mr[j].app.isEmpty && !to.contains(mr[j].app) { to.append(mr[j].app) }
            out[o].to = to
            drop.formUnion(others)
        }
        return out.enumerated().filter { !drop.contains($0.offset) }.map(\.element)
    }

    /// Where each clip went: the paste trail's apps for the clip's text (PasteTrail.destinations).
    static func trail(_ rows: inout [TapeItem], pastes: [PasteTrail.Paste]) {
        guard !pastes.isEmpty else { return }
        let idx = rows.indices.filter { rows[$0].kind == .copied && rows[$0].entry != nil }
        let d = PasteTrail.destinations(clips: idx.map { (rows[$0].at, PasteTrail.hash(rows[$0].text)) }, pastes: pastes)
        for (k, i) in idx.enumerated() where !d[k].isEmpty { rows[i].to = d[k].filter { $0 != rows[i].app || d[k].count == 1 } }
    }

    /// Tags per row, kept between builds in memory and on disk (`TagDisk`, data/journal-tags.json). Only on `queue`
    /// (or on the main thread in the preview).
    static var tagCache: [String: [TapeTag]] = [:]
    static var disk: TagDisk?
    static var diskURL: URL? { Home.data.appendingPathComponent("journal-tags.json") }

    static func tagKey(_ it: TapeItem) -> String { it.id + "|\(it.doc.map { $0.people.count } ?? it.text.count)" }
    static func cachedTags(_ key: String) -> [TapeTag]? {
        if let t = tagCache[key] { return t }
        if let t = disk?.get(key) { tagCache[key] = t; return t }
        return nil
    }
    /// What an item is related to (JournalTags), worked out now; kept in memory and on disk.
    static func computeTags(_ it: TapeItem, store: EntityStore) -> [TapeTag] {
        let t: [TapeTag]
        if let d = it.doc { t = JournalTags.tags(text: d.title, clip: "text", app: it.app, chat: nil, people: d.people, store: store) }
        else if let e = it.entry {
            let d = TapeRules.display(it.kind == .said ? e.summary : it.text, kind: it.kind.word, clip: e.clip.rawValue, title: e.clipTitle)
            t = JournalTags.tags(text: d.chat != nil ? d.line : it.text, clip: e.clip.rawValue, app: it.app, chat: d.chat, store: store)
        } else { t = [] }
        let k = tagKey(it)
        tagCache[k] = t; disk?.put(k, t)
        return t
    }

    /// The journal, built: merged, in sessions, repeats folded inside each session, dressed, each session's facts
    /// and chunk path. Off the main thread. `deferTags`: tags not in the cache are left for `fillTags`, so the list
    /// paints first.
    static func journal(takes: [Entry], clips: [Entry], typed: [Entry], docs: [CallDoc], own: [JournalStore.Item], changes: [String: String],
                        now: Double, store: EntityStore, diskURL url: URL? = nil, deferTags: Bool = false, pastes: [PasteTrail.Paste] = []) -> JournalBuild {
        let t0 = Date()
        let sign = TagDisk.sign(store)
        if disk == nil || disk?.file.sign != sign || disk?.url != url {
            if disk?.file.sign != sign { tagCache.removeAll() }
            disk = TagDisk(url: url, sign: sign)
        }
        let shotRows = ShotJournalRules.newestPerShot(clips.map { ($0.shot, $0.when.timeIntervalSince1970) }).map { clips[$0] }
        var rows = mergeKinds(rows(takes: takes, clips: shotRows, typed: typed, docs: docs, own: own))
        trail(&rows, pastes: pastes)
        let tz = cal.timeZone
        let raw = TapeRules.sessions(rows.map { r in
            (r.kind.word, r.app, r.at, Int(floor((r.at + Double(tz.secondsFromGMT(for: Date(timeIntervalSince1970: r.at)))) / 86400)))
        })
        var b = JournalBuild(); b.now = now
        b.items.reserveCapacity(rows.count)
        let frame = TimeChunks.Frame(now: now, cal: cal)
        for s in raw {
            let sub = s.map { rows[$0] }
            let groups = TapeRules.collapse(sub.map { ($0.kind.word, $0.app, $0.at, $0.kind == .call ? "" : $0.text) })
            var members: [Int] = []
            for g in groups {
                var it = dress(sub[g[0]], store: store)
                if let t = cachedTags(tagKey(it)) { it.tags = t }
                else if deferTags { b.missing.append(b.items.count) }
                else { it.tags = computeTags(it, store: store) }
                it.repeats = g.count
                it.change = changes[it.id]
                if let e = it.entry {
                    it.hay = [e.text, e.raw, e.app, e.title, ClipRules.searchExtra(e.clip, text: e.text, title: e.clipTitle, ocr: e.ocr), e.pictureWords, it.change ?? "",
                              it.shot.map(ShotJournalRules.searchText) ?? ""].joined(separator: "\n").lowercased()
                }
                members.append(b.items.count)
                b.items.append(it)
                b.itemSession.append(b.sessions.count)
            }
            b.sessions.append(members)
        }
        facts(&b)
        for (si, m) in b.sessions.enumerated() {
            let path = frame.path(b.facts[si].to)
            b.paths.append(path)
            for i in m { b.items[i].chunk = path[0].id }
        }
        if tagCache.count > 40_000 { tagCache.removeAll() }
        if b.missing.isEmpty { keepDisk(b) }
        b.ms = Date().timeIntervalSince(t0) * 1000
        return b
    }

    /// Each session's facts (its tag among them) from its items.
    static func facts(_ b: inout JournalBuild) {
        let facets = b.items.map(\.facet), took = b.items.map(\.took)
        b.facts = b.sessions.map { TapeRules.sessionFacts(facets, took: took, rows: $0) }
    }

    /// The tags the first paint left out, worked out (off the main thread), the session facts again, the disk file
    /// written.
    static func fillTags(_ b: inout JournalBuild, store: EntityStore) {
        for i in b.missing { b.items[i].tags = computeTags(b.items[i], store: store) }
        facts(&b)
        keepDisk(b)
    }
    private static func keepDisk(_ b: JournalBuild) {
        guard let d = disk else { return }
        d.keep(Set(b.items.map(tagKey)))
        d.save()
    }

    /// One row as the window shows it: the line to show, how long it took (tags: `computeTags`). Display only: the
    /// stored row is not changed.
    static func dress(_ r: TapeItem, store: EntityStore) -> TapeItem {
        var it = r
        if let d = it.doc {
            it.shown = d.title.isEmpty ? (d.call ? "Recording" : "Voice note") : d.title
            it.took = TapeRules.took(kind: "call", secs: d.secs, live: d.live)
            return it
        }
        guard let e = it.entry else { return it }
        // a draft cut by the old tail window shows from its first whole word (DraftCaptureRules.shownText)
        let src = it.kind == .said ? e.summary : it.kind == .typed && !it.ownDraft ? DraftCaptureRules.shownText(it.text, sent: e.sent) : it.text
        let d = TapeRules.display(src, kind: it.kind.word, clip: e.clip.rawValue, title: e.clipTitle)
        it.shown = e.pictureLine ?? d.line
        it.est = e.est
        if !e.shot.isEmpty, let p = ShotJournal.pack(e.shot) { it.shot = p; it.shown = ShotJournalRules.cardLine(p, fallback: it.shown) }
        switch it.kind {
        case .said: it.took = TapeRules.took(kind: "spoken", secs: e.secs)
        case .typed: it.took = TapeRules.took(kind: "typed", secs: 0, from: e.started?.timeIntervalSince1970, to: (e.touched ?? e.when).timeIntervalSince1970)
        default: break
        }
        return it
    }

    /// The two sides of a call (one for a long note): who, the face, the colour and how long each spoke.
    struct Side { let name: String; let face: String; let me: Bool; let secs: Double }
    static func sides(_ d: CallDoc) -> [Side] {
        var me = 0.0, them = 0.0
        if d.timed {
            for (i, t) in d.turns.enumerated() {
                guard let s = t.start else { continue }
                let next = d.turns[(i + 1)...].first { $0.start != nil }?.start ?? max(d.secs, s)
                let len = min(120, max(0, next - s))
                if t.who == "Вони" { them += len } else { me += len }
            }
        } else {
            let a = d.turns.filter { $0.who != "Вони" }.reduce(0) { $0 + $1.text.count }, b = d.turns.filter { $0.who == "Вони" }.reduce(0) { $0 + $1.text.count }
            let all = Double(max(1, a + b))
            me = d.secs * Double(a) / all; them = d.secs * Double(b) / all
            if a + b == 0 { me = d.call ? d.meSecs : d.secs; them = d.call ? d.themSecs : 0 }
        }
        let other = d.people.first.map { $0.split(separator: " ").first.map(String.init) ?? $0 } ?? "them"
        var out = [Side(name: "me", face: "short", me: true, secs: me)]
        if d.call { out.append(Side(name: other, face: d.people.isEmpty ? "person" : "bob", me: false, secs: them)) }
        return out
    }

    static func clock(_ s: Double) -> String { TapeRules.clock(s) }
}

/// One action on an item: its key, its name (a verb), what it does (the tooltip) and the action.
struct RowAction { let key: String; let word: String; let tip: String; let run: () -> Void }

/// A menu item that runs a closure; parses "⇧⌘C" into a key and its modifiers for the menu's key hint.
final class MenuRun: NSObject {
    let run: () -> Void
    init(_ run: @escaping () -> Void) { self.run = run }
    @objc func go(_ s: NSMenuItem) { run() }
    static func attach(_ item: NSMenuItem, _ run: @escaping () -> Void) { let r = MenuRun(run); item.target = r; item.representedObject = r }
    static func parse(_ key: String) -> (String, NSEvent.ModifierFlags) {
        var mods: NSEvent.ModifierFlags = [], rest = ""
        for c in key {
            switch c {
            case "⌘": mods.insert(.command); case "⇧": mods.insert(.shift); case "⌥": mods.insert(.option); case "⌃": mods.insert(.control)
            default: rest.append(c)
            }
        }
        switch rest {
        case "↵": return ("\r", mods)
        case "⌫": return (String(UnicodeScalar(8)), mods)
        default: return (rest.lowercased(), mods)
        }
    }
}

/// The journal's words in one place, so the list, the reader, the tooltips and Help say the same thing.
enum JournalWords {
    /// The facts line of an item: "Voice note · 13:19:04 · 0:42 · Claude · 128 characters".
    static func facts(_ it: TapeItem) -> String {
        var out = [it.noun, exact(it.at)]
        if let t = it.took { out.append(TapeRules.clock(t)) }
        if !it.app.isEmpty { out.append(it.app) }
        out.append("\(it.current.count) characters")
        if it.repeats > 1 { out.append("×\(it.repeats) within 5 min") }
        if it.change != nil { out.append("Changed") }
        if let e = it.entry, e.incomplete { out.append(e.outcome == "timeout" ? "transcript incomplete" : "no final text") }
        return out.joined(separator: " · ")
    }
    private static let exactF: DateFormatter = { let f = DateFormatter(); f.locale = Locale(identifier: "en_GB"); f.dateFormat = "EEEE d MMMM yyyy, HH:mm:ss"; return f }()
    /// "Monday 23 November 2026, 14:02:11".
    static func exact(_ t: Double) -> String { exactF.string(from: Date(timeIntervalSince1970: t)) }
}

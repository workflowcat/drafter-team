// The stream's side of the window model (stream round, 23 November 2026): Go to a day (⌘T), back and forward (⌘[ ⌘]),
// editing in place with save, cancel and undo, Combine, the inline player, the Record control, and the notice with
// Undo. Rules: app/StreamRules.swift (pure, tested). Views: app/Stream.swift. Everything writes through the paths the
// journal already had: JournalStore for his changes and drafts (the stored history is never rewritten), History.forget
// after the 8 s of a Delete, CallDoc.saveMeta for a recording's title and edited points, Talk and MeetingNotes for
// recording.
import AppKit
import AVFoundation
import SwiftUI

/// The stream's own state.
final class StreamState: ObservableObject {
    @Published var limit = 160                      // rows drawn (Show more adds 300)
    @Published var ranked = false                   // best first (words searched), else newest first under day headings
    @Published var notice: Notice?                  // what just happened, with Undo while it can be undone
    @Published var pausedAt: [String: Double] = [:] // a player paused or scrubbed while stopped, per item
    @Published var entryPlaying: String?            // a voice note playing (recordings: WindowModel.playing)
    @Published var docTitle = ""                    // the open recording's editor
    @Published var docPoints = ""
    @Published var lineEdit: LineEdit?              // one transcript line in the editor
    @Published var tidyOpen = false                 // Tidy topics (the ⋯ menu)
    /// Semantic zoom (zoom round, 24 November 2026; StreamZoomRules): weeks, days, sessions, then rows in three densities.
    @Published var zoom = StreamZoomRules.Level(rawValue: UserDefaults.standard.object(forKey: "stream.zoom") as? Int ?? StreamZoomRules.start.rawValue) ?? StreamZoomRules.start {
        didSet { UserDefaults.standard.set(zoom.rawValue, forKey: "stream.zoom") }
    }
    @Published var zoomAnchor: String?              // the card to show after a step (its key)
    var pinch = StreamZoomRules.Pinch()
    /// Topics round (24 November 2026, StreamGroupRules): the list by topic instead of by time, and past days folded
    /// into one summary line each (both kept).
    @Published var byTopic = UserDefaults.standard.bool(forKey: "stream.byTopic") { didSet { UserDefaults.standard.set(byTopic, forKey: "stream.byTopic") } }
    @Published var foldPast = UserDefaults.standard.object(forKey: "stream.foldPast") as? Bool ?? true {
        didSet { UserDefaults.standard.set(foldPast, forKey: "stream.foldPast") }
    }
    @Published var openedDays: Set<String> = []     // past days he unfolded (this window session)
    @Published var openTopics: Set<String> = []     // topics shown with their rows
    var topicCache: (key: String, topics: [TopicCluster], loose: [String])?
    var dayTopicCache: [String: [String]] = [:]
    /// Topics and day lines are worked out on `groupQueue` (review 25 November 2026: they ran inside the view's body);
    /// the list shows the last answer until the new one lands, then `groupTick` redraws it.
    @Published var groupTick = 0
    var topicsAsked = "", daysAsked = ""
    static let groupQueue = DispatchQueue(label: "drafter.stream.topics", qos: .userInitiated)
    var rowIdx: (key: String, idx: [String: Int]) = ("", [:])
    var cardCache: (key: String, cards: [StreamZoomRules.Card])?
    /// Every level's cards for the current rows, built off the main thread after the rows change (zoom round two,
    /// 25 November 2026: a step built its cards, then drew them, in one frame), with the day and week groups.
    var cardsAhead: (key: String, byLevel: [Int: [StreamZoomRules.Card]])?
    var cardsAsked = ""
    var lastPinchStep = Date.distantPast
    struct CardGroup { let key: String; let title: String; var cards: [StreamZoomRules.Card] }
    var groupCache: (key: String, groups: [CardGroup])?
    var noticeWork: DispatchWorkItem?
    var entryTimer: Timer?
    var previewRecording: PreviewRecording?          // the preview's made-up recording (no microphone)

    struct Notice: Equatable { var text: String; var undo: Bool; var id = 0 }
    struct LineEdit: Equatable { var doc: String; var index: Int; var text: String }
    struct PreviewRecording { var call: Bool; var seconds: Int; var paused: Bool; var title: String; var me: CGFloat; var them: CGFloat }
}

extension WindowModel {
    // MARK: semantic zoom (zoom round, 24 November 2026)

    /// One step nearer (+) or farther (-); the chosen row stays chosen and its card or row is shown.
    func zoom(by d: Int) {
        let to = StreamZoomRules.step(stream.zoom, by: d)
        guard to != stream.zoom else { return }
        open = nil
        setZoom(to)
    }
    func zoomReset() { guard stream.zoom != StreamZoomRules.start else { return }; setZoom(StreamZoomRules.start) }
    /// The step itself: instant. A cross-fade (tried 25 November 2026) made some steps take over a second to draw in
    /// --stream-bench; with the cards built ahead the plain swap is the smooth one.
    private func setZoom(_ to: StreamZoomRules.Level) {
        stream.zoom = to
        anchorZoom()
    }
    /// A card clicked (or ↵ on it): one step in, its newest row chosen.
    func zoomInto(_ c: StreamZoomRules.Card) {
        if let id = c.ids.first { choose(id); nav.region = .list }
        setZoom(StreamZoomRules.into(stream.zoom))
    }
    private func anchorZoom() {
        let id = chosen
        if stream.zoom.summary { stream.zoomAnchor = id.flatMap { cardKey(of: $0) } }
        else if let id {
            // the rows: make sure the chosen one is drawn, then bring it into view
            if let i = lines.firstIndex(where: { $0.item >= 0 && $0.item < rows.count && rows[$0.item].id == id }), i >= stream.limit { stream.limit = i + 40 }
            DispatchQueue.main.async { self.chosen = nil; self.chosen = id }
        }
    }
    /// A pinch steps one level at a time, at most one step per `pinchGap` (it skipped levels in one fast pinch), and
    /// what is pinched meanwhile is dropped, so the level under the fingers is always the one drawn.
    func pinchZoom(_ m: Double) {
        let n = stream.pinch.add(m)
        guard n != 0 else { return }
        let now = Date()
        guard now.timeIntervalSince(stream.lastPinchStep) >= StreamZoomRules.pinchGap else { stream.pinch = StreamZoomRules.Pinch(); return }
        stream.lastPinchStep = now
        zoom(by: n > 0 ? 1 : -1)
    }

    /// The zoom's items for the rows the list shows, newest first.
    private func zoomItems() -> [StreamZoomRules.Item] {
        var items: [StreamZoomRules.Item] = []
        items.reserveCapacity(lines.count)
        for l in lines where l.item >= 0 && l.item < rows.count {
            let it = rows[l.item]
            let line = it.doc?.title ?? (it.shown.isEmpty ? it.current : it.shown)
            items.append(.init(id: it.id, at: it.at, kind: it.kindId, app: it.app, line: line,
                               secs: it.doc?.secs ?? it.entry?.secs ?? 0, pinned: it.pinned))
        }
        items.sort { $0.at > $1.at }
        return items
    }
    private var cardsKey: String { "\(lines.count)|\(rows.count)|\(lines.first?.id ?? "")|\(lines.last?.id ?? "")|\(searchVersion)" }
    /// Builds every level's cards off the main thread for these rows, so a step only draws (called as the rows change).
    func warmCards() {
        let key = cardsKey
        guard !preview, stream.cardsAsked != key, !lines.isEmpty else { return }
        stream.cardsAsked = key
        let items = zoomItems()
        StreamState.groupQueue.async { [weak self] in
            var by: [Int: [StreamZoomRules.Card]] = [:]
            for lv in [StreamZoomRules.Level.sessions, .days, .weeks] { by[lv.rawValue] = StreamZoomRules.cards(items, level: lv) }
            DispatchQueue.main.async { guard let self, self.cardsKey == key else { return }; self.stream.cardsAhead = (key, by) }
        }
    }
    /// The cards of the current zoom for the rows the list shows: built ahead when it could be, else now (and kept).
    var zoomCards: [StreamZoomRules.Card] {
        let lv = stream.zoom
        guard lv.summary else { return [] }
        let base = cardsKey
        if let a = stream.cardsAhead, a.key == base, let c = a.byLevel[lv.rawValue] { return c }
        let key = "\(lv.rawValue)|" + base
        if let c = stream.cardCache, c.key == key { return c.cards }
        let cards = StreamZoomRules.cards(zoomItems(), level: lv)
        stream.cardCache = (key, cards)
        return cards
    }
    /// Days under their week, sessions under their day (kept with the cards: worked out once per level and rows).
    func zoomGroups(_ cards: [StreamZoomRules.Card], level: StreamZoomRules.Level) -> [StreamState.CardGroup] {
        let key = "\(level.rawValue)|\(cards.count)|\(cards.reduce(0) { $0 + $1.ids.count })|\(cards.first?.key ?? "")|\(cards.last?.key ?? "")|\(Int(now / 3600))"
        if let g = stream.groupCache, g.key == key { return g.groups }
        var out: [StreamState.CardGroup] = []
        let nowDate = Date(timeIntervalSince1970: now)
        for c in cards {
            let k: String
            if level == .days { k = StreamZoomRules.weekKey(c.end, cal: .current) } else { k = String(c.key.prefix(10)) }
            if out.last?.key == k { out[out.count - 1].cards.append(c); continue }
            let title = level == .days ? StreamZoomRules.weekTitle(c, now: now) : StreamRules.dayTitle(Date(timeIntervalSince1970: c.end), now: nowDate)
            out.append(.init(key: k, title: title, cards: [c]))
        }
        stream.groupCache = (key, out)
        return out
    }
    func cardKey(of id: String) -> String? { zoomCards.first { $0.ids.contains(id) }?.key }
    /// ↑↓ between cards: the next card's newest row chosen.
    func moveCard(_ d: Int) {
        let cards = zoomCards
        guard !cards.isEmpty else { return }
        let i = chosen.flatMap { id in cards.firstIndex { $0.ids.contains(id) } }
        let j = i.map { max(0, min(cards.count - 1, $0 + d)) } ?? 0
        if let id = cards[j].ids.first { choose(id) }
        nav.region = .list
        stream.zoomAnchor = cards[j].key
    }

    // MARK: topics and folded days (topics round, 24 November 2026)

    private var listKey: String { "\(lines.count)|\(rows.count)|\(lines.first?.id ?? "")|\(lines.last?.id ?? "")|\(searchVersion)" }
    /// What a row is about, for the topic rules: a recording's title and points, a picture's line, else its text.
    func streamTopicInput(_ it: TapeItem) -> TopicInput {
        let text: String
        if let d = it.doc { text = ([d.title] + d.points).joined(separator: "\n") }
        else if it.entry?.clip == .image { text = it.shown }
        else { text = it.current }
        return TopicInput(id: it.id, kind: it.kind.word, text: text, app: it.app, at: it.at, tags: it.tags, pinned: it.pinned)
    }
    /// The topics of the rows the list shows (a search narrows them), and the rows in none. Worked out off the main
    /// thread; until the answer for these rows lands, the last answer (or nothing) shows. The preview works it out at once.
    var streamTopics: (topics: [TopicCluster], loose: [String]) {
        let key = listKey
        if let c = stream.topicCache, c.key == key { return (c.topics, c.loose) }
        let items = lines.compactMap { l in l.item >= 0 && l.item < rows.count ? streamTopicInput(rows[l.item]) : nil }
        if preview { let r = StreamGroupRules.topics(items); stream.topicCache = (key, r.topics, r.loose); return r }
        if stream.topicsAsked != key {
            stream.topicsAsked = key
            StreamState.groupQueue.async { [weak self] in
                let r = StreamGroupRules.topics(items)
                DispatchQueue.main.async {
                    guard let self, self.listKey == key else { return }
                    self.stream.topicCache = (key, r.topics, r.loose); self.stream.groupTick += 1
                }
            }
        }
        return stream.topicCache.map { ($0.topics, $0.loose) } ?? ([], [])
    }
    /// Whether the topics shown are for other rows (the new answer is on its way).
    var topicsPending: Bool { stream.topicCache?.key != listKey }
    /// A past day's summary: its biggest topics. Every day of the list is worked out in one pass off the main thread;
    /// a day not done yet shows its first thing (the fold line's own fallback).
    func dayTopics(_ day: String, _ ls: [JLine]) -> [String] {
        let key = day + "|" + listKey
        if let t = stream.dayTopicCache[key] { return t }
        func inputs(_ ls: [JLine]) -> [TopicInput] { ls.compactMap { l in l.item >= 0 && l.item < rows.count ? streamTopicInput(rows[l.item]) : nil } }
        if preview { let t = StreamGroupRules.dayTopics(inputs(ls)); stream.dayTopicCache[key] = t; return t }
        let lk = listKey
        if stream.daysAsked != lk {
            stream.daysAsked = lk
            var byDay: [String: [TopicInput]] = [:]
            for l in lines where l.item >= 0 && l.item < rows.count {
                let it = rows[l.item]
                byDay[StreamZoomRules.dayKey(it.at, cal: .current), default: []].append(streamTopicInput(it))
            }
            StreamState.groupQueue.async { [weak self] in
                var out: [String: [String]] = [:]
                for (d, items) in byDay { out[d + "|" + lk] = StreamGroupRules.dayTopics(items) }
                DispatchQueue.main.async {
                    guard let self, self.listKey == lk else { return }
                    self.stream.dayTopicCache = out; self.stream.groupTick += 1
                }
            }
        }
        return []
    }
    /// A shown row by id (the topics list holds ids).
    func row(id: String) -> TapeItem? {
        let key = listKey
        if stream.rowIdx.key != key {
            var idx: [String: Int] = [:]
            for l in lines where l.item >= 0 && l.item < rows.count { idx[rows[l.item].id] = l.item }
            stream.rowIdx = (key, idx)
        }
        return stream.rowIdx.idx[id].map { rows[$0] }
    }

    // MARK: the notice

    /// One line at the foot of the column for 8 s: what happened, and Undo (⌘Z) when the last step can be undone.
    func notice(_ text: String, undo: Bool? = nil) {
        status = text
        stream.noticeWork?.cancel()
        let id = (stream.notice?.id ?? 0) + 1
        stream.notice = StreamState.Notice(text: text, undo: undo ?? !undos.isEmpty, id: id)
        let w = DispatchWorkItem { [weak self] in if self?.stream.notice?.id == id { self?.stream.notice = nil } }
        stream.noticeWork = w
        if !preview { DispatchQueue.main.asyncAfter(deadline: .now() + 8, execute: w) }
    }
    func undoFromNotice() { undoLast() }

    // MARK: back and forward

    var place: JournalLayout.Place { .init(chosen: chosen, filter: "", group: "", query: query, view: "stream") }
    /// Keeps where he is (a pick within 1.5 s replaces the last one).
    func record() {
        guard !historyMuted else { return }
        history = JournalLayout.record(history, place, at: Date().timeIntervalSince1970)
    }
    func historyStep(_ back: Bool) {
        record()
        let (h, p) = back ? JournalLayout.goBack(history) : JournalLayout.goForward(history)
        guard let p else { notice(back ? "Nothing before this" : "Nothing after this", undo: false); return }
        history = h
        historyMuted = true
        defer { historyMuted = false }
        if query != p.query { query = p.query; flushSearch() } else { refilter() }
        if let c = p.chosen, lines.contains(where: { $0.id == c }) { choose(c); nav.region = .list }
        tapeTick += 1
    }
    var canBack: Bool { history.canBack || (history.current != nil && history.current != place) }
    var canForward: Bool { history.canForward }

    // MARK: Go to (⌘T)

    func openPalette() { palette = ""; paletteIndex = 0; nav.region = .palette }
    func closePalette() { palette = nil; if nav.region == .palette { nav.region = .list } }
    /// What Go to offers for its text: a date first (English or Ukrainian), then the days in the stream, the scopes,
    /// the people and projects, the apps.
    var paletteResults: [GoTo.Candidate] {
        let q = palette ?? ""
        var out: [GoTo.Candidate] = []
        if let s = GoTo.date(q, now: preview ? now : Date().timeIntervalSince1970, cal: .current) {
            out.append(.init(kind: "date", title: s.title, id: "d|\(s.from)|\(s.to)", glyph: "calendar"))
        }
        var all: [GoTo.Candidate] = []
        var seen = Set<String>()
        let cal = Calendar.current, now = Date(timeIntervalSince1970: self.now)
        for l in lines.prefix(4000) where l.item >= 0 && l.item < rows.count {
            let d = Date(timeIntervalSince1970: rows[l.item].at), k = l.chunk
            if seen.insert(k).inserted, seen.count <= 40 {
                let day = cal.startOfDay(for: d).timeIntervalSince1970
                all.append(.init(kind: "day", title: StreamRules.dayTitle(d, now: now, cal: cal), id: "d|\(day)|\(day + 86400)", glyph: "calendar"))
            }
        }
        for s in StreamRules.scopes where !s.token.isEmpty { all.append(.init(kind: "kind", title: s.name, id: "q|" + s.token + " ", glyph: s.glyph)) }
        for p in topPeople(8) { all.append(.init(kind: "person", title: p, id: "q|" + StreamRules.setting(who: p, in: ""), glyph: "user")) }
        var apps: [String: Int] = [:]
        for r in rows.prefix(3000) where !r.app.isEmpty { apps[r.app, default: 0] += 1 }
        for a in apps.sorted(by: { $0.value > $1.value }).prefix(10).map(\.key) {
            all.append(.init(kind: "app", title: a, id: "q|in:" + a.lowercased().replacingOccurrences(of: " ", with: "") + " ", glyph: "app"))
        }
        out += GoTo.rank(q, all)
        return out
    }
    func paletteGo(_ c: GoTo.Candidate? = nil) {
        let list = paletteResults
        guard let c = c ?? (paletteIndex < list.count ? list[paletteIndex] : nil) else { closePalette(); return }
        closePalette()
        record()
        if c.id.hasPrefix("d|") {
            let p = c.id.split(separator: "|"); let from = Double(p[1]) ?? 0, to = Double(p[2]) ?? 0
            goToTime(from: from, to: to, title: c.title)
        } else if c.id.hasPrefix("q|") {
            query = String(c.id.dropFirst(2)); flushSearch(); focusField += 1
        }
        record()
    }
    /// The newest item inside the span, else the nearest older one; the field is cleared when it hides that item.
    func goToTime(from: Double, to: Double, title: String) {
        func hit() -> String? {
            let ids = lines.compactMap { l -> (String, Double)? in l.item >= 0 && l.item < rows.count ? (l.id, rows[l.item].at) : nil }
            return ids.first { $0.1 >= from && $0.1 < to }?.0 ?? ids.first { $0.1 < from }?.0
        }
        var id = hit()
        if id == nil || !(rows.first { $0.id == id }.map { $0.at >= from && $0.at < to } ?? false), !query.isEmpty {
            query = ""; flushSearch(); id = hit()
        }
        guard let id, let at = item(id)?.at else { notice("Nothing from \(title)", undo: false); return }
        if let i = lines.firstIndex(where: { $0.id == id }), i >= stream.limit { stream.limit = i + 60 }
        choose(id); nav.region = .list
        notice("\(title) · " + JournalWords.exact(at), undo: false)
    }
    /// From another page (Names, a person's card): the item in the stream, chosen and open; the field is cleared.
    func reveal(_ id: String) {
        page = .tape
        if !query.isEmpty { query = ""; flushSearch() }
        guard let i = lines.firstIndex(where: { $0.id == id }) else { return }
        if i >= stream.limit { stream.limit = i + 60 }
        choose(id); open = id; nav.region = .list
    }
    /// ⌘↑ ⌘↓: the first row of the day before or after the chosen one.
    func jumpDay(_ d: Int) {
        guard let c = chosen, let i = lines.firstIndex(where: { $0.id == c }) else { if let f = lines.first { choose(f.id) }; return }
        let day = lines[i].chunk
        var j = i
        if d > 0 {
            while j < lines.count, lines[j].chunk == day { j += 1 }
            guard j < lines.count else { return }
        } else {
            while j > 0, lines[j - 1].chunk == day { j -= 1 }   // the start of this day
            guard j > 0 else { return }
            let prev = lines[j - 1].chunk
            j -= 1
            while j > 0, lines[j - 1].chunk == prev { j -= 1 }
        }
        if j >= stream.limit { stream.limit = j + 60 }
        choose(lines[j].id)
    }

    /// The people and projects met most often in the rows.
    func topPeople(_ n: Int) -> [String] {
        var c: [String: Int] = [:]
        for r in rows.prefix(1500) { for t in r.tags where ["person", "chat", "project"].contains(t.kind) { c[t.name, default: 0] += 1 } }
        return c.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.prefix(n).map(\.key)
    }

    // MARK: editing in place

    /// What the open row is, for the keys.
    func openKind(_ it: TapeItem) -> StreamKeys.Open {
        if it.doc != nil { return .recording }
        if it.shot != nil { return .other }
        if it.kind == .said { return .voice }
        if let c = it.entry?.clip, c != .text { return .other }
        return .text
    }
    func hasAudio(_ it: TapeItem) -> Bool { it.doc?.hasAudio == true || it.entry?.audio.isEmpty == false }

    /// ↵ or E on an open row: its text (or a recording's title and points) in an editor in place.
    func edit() {
        guard let it = current else { return }
        open = it.id
        if let d = it.doc {
            stream.docTitle = d.title; stream.docPoints = d.points.map { "• " + $0 }.joined(separator: "\n")
            editing = it.id; nav.region = .editor; return
        }
        guard openKind(it) == .text || openKind(it) == .voice else { return }
        editing = it.id; draft = it.current; showOriginal = false
        nav.region = .editor
    }
    /// Esc: the editor goes, nothing is stored.
    func cancelEdit() {
        guard let id = editing else { return }
        editing = nil; stream.lineEdit = nil; nav.region = .list
        if id == "new" { combineSources = []; notice("Combine cancelled · the items are as they were", undo: false) }
        focusField += 1
    }
    /// ⌘↵: the edit is kept. An item's text: his change beside the original (JournalStore; the history file is never
    /// rewritten); a journal draft: its text; a Combine: a new draft; a recording: its title and points (meta.json).
    /// ⌘Z (or the notice's Undo) takes it back.
    func saveEdit() {
        guard let id = editing else { return }
        editing = nil; nav.region = .list; focusField += 1
        if id == "new" { saveCombine(); return }
        if let it = item(id), let d = it.doc { saveDoc(d); return }
        guard let i = rows.firstIndex(where: { $0.id == id }) else { return }
        let it = rows[i]
        if it.ownDraft {
            let key = String(id.dropFirst(2)), before = it.text
            guard draft != before else { return }
            journalStore.update(key, text: draft)
            undos.append(("Edit", { [weak self] in self?.journalStore.update(key, text: before); self?.rebuildTape(); self?.notice("Your edit is undone", undo: false) }))
            rebuildTape(); notice("Saved · ⌘Z Undo"); return
        }
        let before = journalStore.changed(id)
        switch StreamRules.save(original: it.text, before: before, draft: draft) {
        case .keep: return
        case .change(let t): journalStore.change(id, to: t, original: it.text)
        case .original: journalStore.revert(id)
        }
        rows[i].change = journalStore.changed(id)
        let original = it.text
        undos.append(("Edit", { [weak self] in
            guard let self else { return }
            switch StreamRules.undo(original: original, before: before) {
            case .change(let t): self.journalStore.change(id, to: t, original: original)
            default: self.journalStore.revert(id)
            }
            if let j = self.rows.firstIndex(where: { $0.id == id }) { self.rows[j].change = self.journalStore.changed(id) }
            self.buildTick += 1; self.refilter(); self.notice("Your edit is undone", undo: false)
        }))
        buildTick += 1; refilter()
        notice(rows[i].change == nil ? "The original again · ⌘Z Undo" : "Saved · the original is kept · ⌘Z Undo")
    }
    /// Old name for a save without a word (topic tidy saves a pending edit first).
    func leaveEditor() { saveEdit() }

    /// A recording's title (meta.json "title", as the page's Details) and its points (meta.json "points", shown in place
    /// of the note's; the note file is the engine's and stays as written).
    func saveDoc(_ d: CallDoc) {
        let title = stream.docTitle.trimmingCharacters(in: .whitespaces)
        let pts = StreamRules.points(stream.docPoints)
        let titleChanged = !title.isEmpty && title != d.title, pointsChanged = pts != d.points
        guard titleChanged || pointsChanged else { return }
        guard !preview else { patchDoc(d.id) { if titleChanged { $0.title = title }; if pointsChanged { $0.points = pts } }; notice("Saved · ⌘Z Undo"); return }
        let meta = (try? JSONSerialization.jsonObject(with: Data(contentsOf: d.dir.appendingPathComponent("meta.json")))) as? [String: Any] ?? [:]
        let oldTitle = meta["title"], oldPoints = meta["points"]
        var set: [String: Any?] = [:]
        if titleChanged { set["title"] = title == d.event ? "" : title }
        if pointsChanged { set["points"] = pts }
        do { try CallDoc.saveMeta(d.dir, set); log("recording: edited in place in \(d.dir.lastPathComponent)") }
        catch { notice("Could not save: \(error.localizedDescription)", undo: false); return }
        undos.append(("Edit", { [weak self] in
            var back: [String: Any?] = [:]
            if titleChanged { back["title"] = oldTitle }
            if pointsChanged { back["points"] = oldPoints }
            try? CallDoc.saveMeta(d.dir, back)
            self?.loadDocs(); self?.notice("Your edit is undone", undo: false)
        }))
        loadDocs()
        notice("Saved · ⌘Z Undo")
    }
    /// One transcript line of a recording, changed (meta.json "lineEdits": the line, what it was and what it is now;
    /// lines.json stays as the reading wrote it).
    func saveLine() {
        guard let e = stream.lineEdit, let it = item(e.doc), let d = it.doc, e.index < d.turns.count else { stream.lineEdit = nil; return }
        stream.lineEdit = nil; nav.region = .list
        let was = d.turns[e.index].text, now = e.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !now.isEmpty, now != was else { return }
        guard !preview else { patchDoc(d.id) { $0.turns[e.index] = Turn(id: $0.turns[e.index].id, who: $0.turns[e.index].who, start: $0.turns[e.index].start, text: now) }; notice("Line saved · ⌘Z Undo"); return }
        let meta = (try? JSONSerialization.jsonObject(with: Data(contentsOf: d.dir.appendingPathComponent("meta.json")))) as? [String: Any] ?? [:]
        let old = meta["lineEdits"] as? [[String: Any]] ?? []
        let next = CallDoc.lineEdit(old, index: e.index, was: CallDoc.originalLine(old, index: e.index) ?? was, now: now)
        do { try CallDoc.saveMeta(d.dir, ["lineEdits": next]) } catch { notice("Could not save the line", undo: false); return }
        undos.append(("Edit", { [weak self] in try? CallDoc.saveMeta(d.dir, ["lineEdits": old]); self?.loadDocs(); self?.notice("The line is back", undo: false) }))
        loadDocs(); notice("Line saved · ⌘Z Undo")
    }
    /// The preview changes its made-up recording in memory.
    private func patchDoc(_ id: String, _ f: (inout CallDoc) -> Void) {
        guard let k = docs.firstIndex(where: { $0.id == id }) else { return }
        f(&docs[k]); if let r = rows.firstIndex(where: { $0.doc?.id == id }) { rows[r].doc = docs[k] }
        tapeTick += 1
    }

    /// ⇧⌘A: the open item for Claude or Codex, on the clipboard: a recording points at its folder (sendToAgent), a
    /// screenshot at its files, any other item is its text under one line saying what and when it was.
    func copyForAgent() {
        guard let it = current else { return }
        if let d = it.doc { sendToAgent(d); return }
        if it.shot != nil { copyShotForAgent(); return }
        let head = "From my Drafter journal: \(it.noun.lowercased())" + (it.app.isEmpty ? "" : " in \(it.app)") + ", " + JournalWords.exact(it.at) + "."
        History.copy(head + "\n\n" + it.current)
        notice("For an agent, on the clipboard · \(it.current.count) characters", undo: false)
    }

    // MARK: Combine

    /// ⌘⇧E (or the selection bar): the picked texts, oldest first, as one new draft in the editor at the top.
    func combine() {
        let its = picked.compactMap(item).filter { $0.doc == nil && $0.shot == nil }
        guard StreamRules.canCombine(picked.count, texts: its.count) else { notice("Pick two or more texts to combine (⇧↑ ⇧↓ or ⌘-click)", undo: false); return }
        draft = JournalStore.combine(its.map { ($0.at, $0.current) })
        combineSources = its.map(\.id)
        editing = "new"; nav.region = .editor
        status = "Combined draft · \(its.count) items, oldest first · ⌘↵ save · esc cancel"
    }
    private func saveCombine() {
        let t = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        let d = journalStore.add(kind: "draft", text: t, sources: combineSources, pinned: false)
        let n = combineSources.count
        combineSources = []; picked = []
        undos.append(("Combine", { [weak self] in
            guard let self else { return }
            _ = self.journalStore.remove(d.id); self.rebuildTape(); self.notice("Combine undone · the draft is gone", undo: false)
        }))
        chosen = "j:" + d.id
        rebuildTape()
        notice("Draft from \(n) items · in the journal · ⌘Z Undo")
    }
    /// ⌘-click: a row joins or leaves the pick.
    func togglePick(_ id: String) {
        if picked.isEmpty, let c = chosen, c != id { picked = [c] }
        if let i = picked.firstIndex(of: id) { picked.remove(at: i) } else { picked.append(id) }
        chosen = id; open = nil
        status = picked.count > 1 ? "\(picked.count) picked · ⌘⇧E Combine" : ""
    }

    // MARK: the inline player

    /// Playing now, where, and how long, for a row with audio.
    func playState(_ it: TapeItem) -> (playing: Bool, at: Double, total: Double) {
        if let d = it.doc {
            let on = playing == d.id
            return (on, on ? playhead : stream.pausedAt[it.id] ?? 0, max(d.secs, 0.1))
        }
        let total = max(it.entry?.secs ?? 0, player?.duration ?? 0, 0.1)
        let on = stream.entryPlaying == it.id && player?.isPlaying == true
        return (on, on ? playhead : stream.pausedAt[it.id] ?? 0, stream.entryPlaying == it.id ? max(player?.duration ?? total, 0.1) : max(it.entry?.secs ?? 0, 0.1))
    }
    /// Space, or the play button.
    func playPause(_ it: TapeItem) {
        let s = playState(it)
        if s.playing { pausePlayer(it); return }
        let from = s.at >= s.total - 0.2 ? 0 : s.at
        startPlayer(it, from: from)
    }
    func pausePlayer(_ it: TapeItem) {
        let s = playState(it)
        stream.pausedAt[it.id] = s.at
        if it.doc != nil { stopPlaying() } else { stopEntry() }
    }
    func startPlayer(_ it: TapeItem, from t: Double) {
        stopEntry(); if playing != nil { stopPlaying() }
        if let d = it.doc {
            guard !preview else { playing = d.id; playhead = t; return }
            play(d, from: t); return
        }
        guard let e = it.entry, !e.audio.isEmpty else { return }
        stream.entryPlaying = it.id
        guard !preview else { playhead = t; return }
        let url = e.audio.hasSuffix(".wav") ? URL(fileURLWithPath: e.audio) : URL(fileURLWithPath: e.audio).appendingPathComponent("me.wav")
        guard FileManager.default.fileExists(atPath: url.path), let p = try? AVAudioPlayer(contentsOf: url) else {
            stream.entryPlaying = nil; notice("Audio is no longer available (voice clips are kept for 14 days)", undo: false); return
        }
        p.enableRate = true; p.rate = playbackRate; p.currentTime = PlayerRules.clamp(t, total: p.duration); p.prepareToPlay(); p.play()
        player = p; playhead = p.currentTime
        let id = it.id
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            guard let self, let p = self.player, self.stream.entryPlaying == id else { return }
            if p.isPlaying { self.playhead = p.currentTime } else { self.stream.pausedAt[id] = 0; self.stopEntry() }
        }
        stream.entryTimer = timer; RunLoop.main.add(timer, forMode: .common)
    }
    func stopEntry() {
        stream.entryTimer?.invalidate(); stream.entryTimer = nil
        player?.stop()
        if stream.entryPlaying != nil { stream.entryPlaying = nil }
    }
    /// The scrubber, a transcript line, or ±10 s.
    func seek(_ it: TapeItem, to t: Double) {
        let s = playState(it), to = PlayerRules.clamp(t, total: s.total)
        if s.playing {
            if it.doc != nil { startPlayer(it, from: to) } else { player?.currentTime = to; playhead = to }
        } else { stream.pausedAt[it.id] = to; if stream.entryPlaying == it.id || playing == it.doc?.id { playhead = to } }
        tapeTick += 1
    }
    func skip(_ it: TapeItem, by d: Double) { let s = playState(it); seek(it, to: PlayerRules.skip(s.at, by: d, total: s.total)) }
    func nextSpeed() {
        playbackRate = PlayerRules.nextSpeed(playbackRate)
        if let p = player { p.enableRate = true; p.rate = playbackRate }
        objectWillChange.send()
    }

    // MARK: recording

    /// What records now: (call, seconds, paused, title), or nil.
    var recordingNow: (call: Bool, seconds: Int, paused: Bool, title: String)? {
        if let p = stream.previewRecording { return (p.call, p.seconds, p.paused, p.title) }
        guard !preview, Talk.shared.recording else { return nil }
        let live = RecordLive.shared
        return (Talk.shared.isCall, Talk.shared.recSeconds, Talk.shared.paused, live.active ? live.title : (Talk.shared.isCall ? "Call" : "Long note"))
    }
    /// The same job as ⇧ Right Option: a call when a call app holds the microphone, else a long note.
    func startLongNote() {
        guard !preview else { return }
        guard Talk.shared.state == .idle else { notice("Finish the voice take first", undo: false); return }
        Talk.shared.key(down: true, long: true)
        log("window: long note or call started from the window")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.loadDocs() }
    }
    /// The menu bar's first item: meeting notes for the event on now (the call, or in person).
    func startMeetingNotes() {
        guard !preview else { return }
        MeetingNotes.toggle(from: "the window")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.loadDocs() }
    }
    func togglePauseRecording() {
        if var p = stream.previewRecording { p.paused.toggle(); stream.previewRecording = p; return }
        guard !preview, Talk.shared.recording else { return }
        Talk.shared.setPaused(!Talk.shared.paused)
        RecordLive.shared.paused = Talk.shared.paused
        objectWillChange.send()
    }
}

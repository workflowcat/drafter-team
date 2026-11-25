// The journal's search: ONE boundary (`JournalSearch.run`), so the views never see what is behind it. Since the
// search round (14 November 2026) the search core is behind it (SearchRules, SearchIndex: both languages, stems, the
// other layout, typos, filters as words, ranking); the index lives on its own queue (`JournalEngine`), is built once off
// the main thread when the window opens and follows the rows as they change. Until it is built, today's search answers
// (`JournalSearch.scan`: every word in the item's text, app, title, link, read text or recording, any order and case).
// Ranges are what the views mark in the row and in the reader (`JournalSearch.ranges`, from the core's marker).
import Foundation

struct JournalHit: Equatable { let index: Int; let ranges: [NSRange] }

/// What the window can draw beside the search field, as plain data (nothing has to draw it: the typed words work).
struct JournalSearchView: Equatable {
    var chips: [SearchChip] = []          // filters in the query (kind:, app:, with:, in:, before:, after:, has:, is:)
    var suggestions: [SearchOffer] = []   // date words standing alone, offered as a filter, not applied
    var didYouMean: String?               // the query with the other layout or a typo fixed, when that found more
    var didYouMeanWhy = ""                // "layout" or "typo"
    var kindTotals: [String: Int] = [:]   // per TapeKind word ("copied", "typed", "said", "call") in the found set
    var chunkTotals: [String: Int] = [:]  // per TimeChunks id (TapeItem.chunk) in the found set
    var ready = false                     // the index is built (before that, the plain search answered)
    var ms = 0.0                          // the last search, in the core
}

enum JournalSearch {
    /// The query as the core reads it (chips, offers, words), with a fixed clock for previews.
    static func parse(_ query: String, now: Double? = nil) -> SearchQuery {
        SearchQueryRules.parse(query, clock: now.map { SearchClock(now: $0) } ?? SearchClock())
    }

    /// The search, asynchronous: `done` gets the hits on the main thread, best first, with the core's result, or is
    /// never called when a newer query came first. Until the index is built, the plain search answers at once (in time
    /// order, no result). `version` changes whenever the rows do (the engine re-reads only then).
    static func run(_ query: String, _ rows: [TapeItem], version: Int, engine: JournalEngine, now: Double? = nil,
                    done: @escaping ([JournalHit], SearchResult?) -> Void) {
        engine.update(version: version, count: rows.count, id: { rows[$0].id }, sig: { rows[$0].searchSig }, doc: { rows[$0].searchDoc })
        if !engine.ready { done(scan(query, rows, marks: false, now: now), nil) }
        engine.search(query, now: now) { r in
            marker = (query, r.marker)
            let at = engine.rowIndex(version: version, count: rows.count, id: { rows[$0].id })
            done(r.hits.compactMap { h in at[h.id].map { JournalHit(index: $0, ranges: h.ranges[.title] ?? h.ranges[.body] ?? []) } }, r)
        }
    }

    // MARK: the plain search (the fallback while the index builds; the views' marks when the core has not answered)

    /// The items that match, in their order, with the ranges to mark in each item's shown line. Filters typed as words
    /// (kind:voice in:"last week") apply here too, by the row's kind, time and app.
    static func scan(_ query: String, _ rows: [TapeItem], marks: Bool = true, now: Double? = nil) -> [JournalHit] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return rows.indices.map { JournalHit(index: $0, ranges: []) } }
        let pq = parse(q, now: now)
        let text = words(of: pq)
        let terms = CallDoc.terms(text)
        let low = text.lowercased().split(whereSeparator: \.isWhitespace)   // the same words Entry.matches looks for
        var out: [JournalHit] = []
        for (i, r) in rows.enumerated() {
            guard pq.filters.allSatisfy({ passes(r, $0) }) else { continue }
            let ok: Bool
            if low.isEmpty { ok = true }
            else if let d = r.doc { ok = d.matches(terms) }
            else if !r.hay.isEmpty { ok = low.allSatisfy { r.hay.contains($0) } }
            else if let e = r.entry { ok = e.matches(text) || (r.change.map { has(text, in: $0) } ?? false) }
            else { ok = has(text, in: r.line) }
            if ok { out.append(JournalHit(index: i, ranges: marks ? plain(text, in: r.change.map(TapeItem.flat) ?? r.shown) : [])) }
        }
        return out
    }

    /// The query's searched words without its filters (what the plain search and plain marks look for).
    static func words(of q: SearchQuery) -> String {
        var raw = q.raw as NSString
        for c in q.chips.sorted(by: { $0.range.location > $1.range.location }) where NSMaxRange(c.range) <= raw.length {
            raw = raw.replacingCharacters(in: c.range, with: " ") as NSString
        }
        return (raw as String).replacingOccurrences(of: "\"", with: " ").replacingOccurrences(of: "«", with: " ")
            .replacingOccurrences(of: "»", with: " ").split(whereSeparator: \.isWhitespace).filter { !$0.hasPrefix("-") }.joined(separator: " ")
    }

    static func kind(_ k: TapeKind) -> SearchKind {
        switch k { case .copied: return .clip; case .typed: return .draft; case .said: return .voice; case .call: return .recording }
    }

    /// A typed filter on a row, without the index (the fallback).
    static func passes(_ r: TapeItem, _ f: SearchFilter) -> Bool {
        switch f {
        case .kind(let ks): return ks.contains(kind(r.kind))
        case .time(let lo, let hi): return r.at >= lo && r.at < hi
        case .app(let a): return SearchRules.fold(r.app).contains(a)
        case .has(let h):
            switch h {
            case .pin: return r.pinned
            case .change: return r.change != nil
            case .link: return r.entry?.clip == .link
            case .picture: return r.entry?.clip == .image
            default: return (SearchMarkStore.shared.stored(id: r.id)?.bits ?? 0) & h.bit != 0   // stored marks only: no detector per key
            }
        case .mentions(let lo, let hi):
            return SearchMarkStore.shared.stored(id: r.id)?.days.contains { $0 >= lo && $0 < hi } ?? false
        case .with(let v): return r.doc.map { d in d.people.contains { SearchRules.fold($0).contains(SearchRules.fold(v)) } } ?? false
        }
    }

    private static func has(_ q: String, in text: String) -> Bool {
        let t = text.lowercased()
        return q.lowercased().split(whereSeparator: \.isWhitespace).allSatisfy { t.contains($0) }
    }

    // MARK: marks

    /// The marker of the query the core answered last (main thread): every word form it found, for any row.
    static var marker: (query: String, marker: SearchMarker)?

    /// Where the query's words stand in a text: the core's marker for the query it answered (stems, the other layout,
    /// typos), else each typed word as it stands (case and diacritics ignored). In order, not overlapping.
    static func ranges(_ query: String, in text: String) -> [NSRange] {
        if let m = marker, m.query == query { return m.marker.ranges(in: text) }
        return plain(words(of: parse(query)), in: text)
    }

    static func plain(_ query: String, in text: String) -> [NSRange] {
        let ns = text as NSString
        var out: [NSRange] = []
        for w in query.split(whereSeparator: \.isWhitespace) where w.count >= 1 {
            var from = 0
            while from < ns.length {
                let r = ns.range(of: String(w), options: [.caseInsensitive, .diacriticInsensitive], range: NSRange(location: from, length: ns.length - from))
                if r.location == NSNotFound { break }
                out.append(r); from = r.location + max(1, r.length)
                if out.count > 200 { break }
            }
        }
        return out.sorted { $0.location < $1.location }
    }
}

// MARK: - the rows as documents

extension TapeItem {
    /// What the search index holds for this row: his change first (it is what the row shows), the stored text after it.
    /// Wire round: what the detector finds in it marks the document (has:date..., mentions:); a call is read in its
    /// summary and the start of what was said.
    var searchDoc: SearchDoc {
        var d = JournalEngine.doc(id: id, kind: JournalSearch.kind(kind), at: at, app: app, line: line, entry: entry, call: doc, change: change, pinned: pinned,
                                  shot: shot.map(ShotJournalRules.searchText) ?? "")
        let text = doc != nil ? d.summary + "\n" + d.transcript : d.body.isEmpty ? d.ocr : d.body
        let m = SearchMarkStore.shared.marks(id: id, text: text, written: at)   // once per id and text
        d.found = m.bits; d.mentions = m.days
        return d
    }
    /// Changes when what the index holds for the row changes.
    var searchSig: Int {
        var h = Hasher()
        h.combine(change); h.combine(pinned); h.combine(text.count); h.combine(entry?.ocr.count ?? -1); h.combine(doc?.turns.count ?? -1)
        h.combine(doc?.points.count ?? -1); h.combine(doc?.title)
        h.combine(shot.map(ShotJournalRules.searchText))
        return h.finalize()
    }
}

/// The search's state for one window (WindowModel is declared in Window.swift; its extensions keep this here).
final class JournalSearchSide {
    static var all: [ObjectIdentifier: JournalSearchSide] = [:]
    var engine: JournalEngine?
    var view = JournalSearchView()
    var cache: (query: String, version: Int, hits: [Int])?
    var rankedFor = ""                 // the query whose best item was chosen
    /// Keys closer than this are one burst: answered once, after it (WindowModel.queryChanged).
    static let burst = 0.09
    var lastKey = 0.0
    var pending: DispatchWorkItem?
    var burstInPreview = false         // the speed harness times a burst
    /// The query the shown list answers: the cards and lines mark its words (a key typed since redraws nothing).
    var shown = ""
    /// The last hits shown, so a pin or a delete redraws the stream without a search (WindowModel.reflow).
    var last: (hits: [Int], ranked: Bool) = ([], false)
}

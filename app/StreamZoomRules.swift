// Semantic zoom for the stream (zoom round, 24 November 2026; the user: "the semantic zoom on timing and details").
// One ladder, far to near: weeks, days, sessions (one card each: when, how much of what, where, the main things), then
// the rows themselves in three densities: compact, normal, detailed. ⌘− and ⌘+ step along it, ⌘0 goes back to normal,
// a pinch steps once per `pinchStep`. The summaries are local and cheap: counts, apps and the first sentence of the
// rows that say most; no model, no network. Pure (Foundation), tests/stream_zoom_rules.swift.
import Foundation

enum StreamZoomRules {
    enum Level: Int, CaseIterable, Comparable {
        case weeks, days, sessions, compact, normal, detailed
        static func < (a: Level, b: Level) -> Bool { a.rawValue < b.rawValue }
        var name: String { ["Weeks", "Days", "Sessions", "Compact", "Rows", "Detailed"][rawValue] }
        /// Zoomed out to cards of time (nil: the rows, at this density 0-2).
        var summary: Bool { self < .compact }
        var density: Int { Swift.max(0, rawValue - Level.compact.rawValue) }
    }
    static let start = Level.normal

    /// `d` steps nearer (+) or farther (-), held at both ends.
    static func step(_ l: Level, by d: Int) -> Level {
        Level(rawValue: Swift.max(0, Swift.min(Level.allCases.count - 1, l.rawValue + d))) ?? l
    }
    /// One step in from a card of time: weeks → days, days → sessions, sessions → the rows.
    static func into(_ l: Level) -> Level { l == .sessions ? start : step(l, by: 1) }

    // MARK: the pinch

    static let pinchStep = 0.22
    static let pinchGap = 0.22   // seconds between two steps of one pinch
    struct Pinch: Equatable {
        var sum = 0.0
        /// Adds one event's magnification; returns the levels to move now (+ nearer, - farther) and keeps the rest.
        mutating func add(_ m: Double) -> Int {
            sum += m
            let n = Int((sum / StreamZoomRules.pinchStep).rounded(.towardZero))
            sum -= Double(n) * StreamZoomRules.pinchStep
            return n
        }
    }

    // MARK: cards of time

    /// One row as the zoom sees it.
    struct Item: Equatable {
        var id: String
        var at: Double
        var kind: String        // spoken, typed, copied, call, link, picture, file
        var app: String
        var line: String        // what the row shows
        var secs: Double = 0    // a take's or recording's length
        var pinned = false
    }

    struct Card: Equatable {
        var key: String
        var start: Double       // the oldest item's time
        var end: Double         // the newest item's time
        var ids: [String]       // newest first
        var counts: [(kind: String, n: Int)]
        var apps: [String]      // most used first, at most 4
        var lines: [String]     // the main things, at most `perCard`
        var secs: Double        // spoken and recorded time
        var perDay: [Int] = []  // a week's items per day, Monday first (7 numbers; empty for days and sessions)
        static func == (a: Card, b: Card) -> Bool {
            a.key == b.key && a.ids == b.ids && a.lines == b.lines && a.apps == b.apps && a.secs == b.secs
                && a.counts.map(\.kind) == b.counts.map(\.kind) && a.counts.map(\.n) == b.counts.map(\.n)
        }
    }

    /// Two items further apart than this start a new session.
    static let sessionGap = 45.0 * 60
    static let perCard = 3

    /// The items (newest first) as cards: one per week (Monday first), day or session, newest first.
    static func cards(_ items: [Item], level: Level, cal: Calendar = .current) -> [Card] {
        guard level.summary else { return [] }
        var out: [Card] = []
        var cur: [Item] = []
        var curKey = ""
        func flush() { if !cur.isEmpty { out.append(card(curKey, cur)); cur = [] } }
        var lastAt = Double.infinity
        var session = 0
        for it in items {
            let key: String
            switch level {
            case .weeks: key = weekKey(it.at, cal: cal)
            case .days: key = dayKey(it.at, cal: cal)
            default:
                let day = dayKey(it.at, cal: cal)
                if !curKey.hasPrefix(day) || lastAt - it.at > sessionGap { session += 1 }
                key = day + "#" + String(session)
            }
            if key != curKey { flush(); curKey = key }
            cur.append(it); lastAt = it.at
        }
        flush()
        if level == .weeks {
            var mc = cal; mc.firstWeekday = 2
            let byId = Dictionary(items.map { ($0.id, $0.at) }, uniquingKeysWith: { a, _ in a })
            for i in out.indices {
                var n = [Int](repeating: 0, count: 7)
                for id in out[i].ids { if let t = byId[id] { n[(mc.component(.weekday, from: Date(timeIntervalSince1970: t)) + 5) % 7] += 1 } }
                out[i].perDay = n
            }
        }
        return out
    }

    static func dayKey(_ t: Double, cal: Calendar) -> String {
        let c = cal.dateComponents([.year, .month, .day], from: Date(timeIntervalSince1970: t))
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }
    static func weekKey(_ t: Double, cal: Calendar) -> String {
        var c = cal; c.firstWeekday = 2; c.minimumDaysInFirstWeek = 4
        let w = c.dateComponents([.yearForWeekOfYear, .weekOfYear], from: Date(timeIntervalSince1970: t))
        return String(format: "%04d-W%02d", w.yearForWeekOfYear ?? 0, w.weekOfYear ?? 0)
    }

    static let kindOrder = ["call", "spoken", "typed", "copied", "picture", "link", "file"]

    static func card(_ key: String, _ items: [Item]) -> Card {
        var n: [String: Int] = [:], apps: [String: Int] = [:], secs = 0.0
        for it in items {
            n[it.kind, default: 0] += 1
            if !it.app.isEmpty { apps[it.app, default: 0] += 1 }
            if it.kind == "call" || it.kind == "spoken" { secs += it.secs }
        }
        let counts = n.sorted { (kindOrder.firstIndex(of: $0.key) ?? 99, -$0.value) < (kindOrder.firstIndex(of: $1.key) ?? 99, -$1.value) }
            .map { (kind: $0.key, n: $0.value) }
        let topApps = apps.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.prefix(4).map(\.key)
        return Card(key: key, start: items.map(\.at).min() ?? 0, end: items.map(\.at).max() ?? 0, ids: items.map(\.id),
                    counts: counts, apps: topApps, lines: highlights(items), secs: secs)
    }

    /// The main things in a card: recordings first, then pinned rows, then the rows with most words (a take, a typed
    /// message, a picture's line); one sentence each, no two the same, newest first among equals.
    static func highlights(_ items: [Item], max: Int = perCard) -> [String] {
        func rank(_ it: Item) -> Int {
            if it.kind == "call" { return 10_000 + Int(it.secs) }
            if it.pinned { return 5_000 }
            // words in the first 600 characters are enough to rank (a long draft cost a whole split per row)
            let words = it.line.prefix(600).split(whereSeparator: \.isWhitespace).count
            return it.kind == "copied" || it.kind == "link" || it.kind == "file" ? Swift.min(words, 6) : words
        }
        var seen = Set<String>(), out: [String] = []
        // each rank once (25 November 2026: ranked inside the sort, 20,000 word splits for a week of 1,000 rows)
        let ranked = items.enumerated().map { (r: rank($0.element), o: $0.offset, it: $0.element) }
        for it in ranked.sorted(by: { ($0.r, -$0.o) > ($1.r, -$1.o) }).map(\.it) {
            let s = summary(it.line)
            guard s.count >= 4 else { continue }
            let k = s.lowercased()
            if seen.insert(k).inserted { out.append(s) }
            if out.count >= max { break }
        }
        return out
    }

    /// One line: the first line with words, cut at its first sentence end after a few words, else at a word before
    /// `max` characters, with an ellipsis.
    static func summary(_ text: String, max: Int = 90) -> String {
        // only the head matters (25 November 2026: the whole text was split and rescanned per sentence end, 0.5 s a level)
        let line = text.prefix(Swift.max(400, max * 4)).split(whereSeparator: \.isNewline).lazy
            .map { $0.split(whereSeparator: \.isWhitespace).joined(separator: " ") }
            .first { !$0.isEmpty } ?? ""
        var s = line
        let ends: [Character] = [".", "!", "?", "…"]
        var i = s.startIndex, words = 0, prevSpace = true
        while i < s.endIndex {
            let n = s.index(after: i)
            if s[i] == " " { prevSpace = true } else if prevSpace { words += 1; prevSpace = false }
            if ends.contains(s[i]), n == s.endIndex || s[n] == " " {
                if words >= 4 { s = String(s[...i]); break }
            }
            i = n
        }
        if s.count > max {
            let cut = s.prefix(max)
            let at = cut.lastIndex(of: " ") ?? cut.endIndex
            s = String(cut[..<at]).trimmingCharacters(in: .punctuationCharacters.union(.whitespaces)) + "…"
        }
        return s
    }

    // MARK: words on a card

    /// One DateFormatter per format, calendar and time zone, kept (25 November 2026: a new one per line drawn cost
    /// most of a zoom step's redraw). Locked: the cards are also built off the main thread.
    private static var formatters: [String: DateFormatter] = [:]
    private static let fmtLock = NSLock()
    static func formatter(_ format: String, cal: Calendar, locale: String? = nil) -> DateFormatter {
        let key = format + "|" + cal.identifier.debugDescription + "|" + cal.timeZone.identifier + "|" + (locale ?? "")
        fmtLock.lock(); defer { fmtLock.unlock() }
        if let f = formatters[key] { return f }
        let f = DateFormatter(); f.calendar = cal; f.timeZone = cal.timeZone; f.dateFormat = format
        if let locale { f.locale = Locale(identifier: locale) }
        formatters[key] = f
        return f
    }

    static func noun(_ kind: String, _ n: Int) -> String {
        let one: [String: String] = ["call": "recording", "spoken": "take", "typed": "typed", "copied": "copy", "picture": "picture",
                                     "link": "link", "file": "file"]
        let many: [String: String] = ["call": "recordings", "spoken": "takes", "typed": "typed", "copied": "copies", "picture": "pictures",
                                      "link": "links", "file": "files"]
        return "\(n) " + ((n == 1 ? one[kind] : many[kind]) ?? kind)
    }
    /// "4 takes · 12 typed · 3 copies", at most `max` kinds.
    static func countLine(_ c: Card, max: Int = 4) -> String {
        c.counts.prefix(max).map { noun($0.kind, $0.n) }.joined(separator: " · ")
    }
    /// "09:12–10:40" (one time when start and end are the same minute).
    static func span(_ c: Card, cal: Calendar = .current) -> String {
        let f = formatter("HH:mm", cal: cal)
        let a = f.string(from: Date(timeIntervalSince1970: c.start)), b = f.string(from: Date(timeIntervalSince1970: c.end))
        return a == b ? a : a + "–" + b
    }
    /// A week's title: "This week", "Last week", else "16–22 Nov" (or across months "30 Nov – 6 Dec").
    static func weekTitle(_ c: Card, now: Double, cal: Calendar = .current) -> String {
        let k = weekKey(c.end, cal: cal)   // a week's card, or a day's (days sit under their week)
        if weekKey(now, cal: cal) == k { return "This week" }
        if weekKey(now - 7 * 86400, cal: cal) == k { return "Last week" }
        var mc = cal; mc.firstWeekday = 2; mc.minimumDaysInFirstWeek = 4
        guard let iv = mc.dateInterval(of: .weekOfYear, for: Date(timeIntervalSince1970: c.end)) else { return c.key }
        let first = iv.start, last = iv.end.addingTimeInterval(-1)
        let d = formatter("d MMM", cal: cal, locale: "en_GB")
        let sameMonth = cal.component(.month, from: first) == cal.component(.month, from: last)
        if sameMonth { return "\(cal.component(.day, from: first))–" + d.string(from: last) }
        return d.string(from: first) + " – " + d.string(from: last)
    }
    /// Spoken and recorded time: "1 h 05 min", "12 min", "" under a minute.
    static func duration(_ s: Double) -> String {
        let m = Int(s / 60)
        guard m >= 1 else { return "" }
        return m >= 60 ? String(format: "%d h %02d min", m / 60, m % 60) : "\(m) min"
    }
}

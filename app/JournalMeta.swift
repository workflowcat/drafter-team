// Each fact once per view, and one row for one text kept as several kinds (soft round, 14 November 2026; the user:
// "you can see some of the duplicates here", "cleaning up the meta"). The reader of a voice note said its kind, time,
// length and app in a header, again in a sub-line and again in a footer; a row inside a session of Claude said
// "Claude" again; a row under "Wednesday 11 November" said "Wed 10:31". And a voice note Drafter put into a field came
// back as a draft or a sent line, a paste as a clip. Pure rules, display only: nothing here changes a stored row.
// Tested in tests/journal_meta.swift with made-up rows.
import Foundation

/// What the headers above a row already say.
struct MetaContext: Equatable {
    var day = false           // under a day, a part of a day, or a session: the date is said, the row shows the clock
    var app: String? = nil    // inside a session of this app, or grouped by this app
    var tag: String? = nil    // grouped by Related to this name
}

enum JournalMeta {
    // MARK: kinds: one mark, one colour, one glyph (the same in the gallery, the list and the left pane)

    /// The kind marks. The colour is a mark, never the colour of text, and never the only cue: each kind has its own
    /// glyph. series: blue, mint, violet, coral (the theme's four series colours) or neutral.
    static let kinds: [(id: String, glyph: String, series: String)] = [
        ("spoken", "waves", "violet"), ("typed", "keys", "mint"), ("copied", "copy", "blue"), ("call", "phone", "coral"),
        ("picture", "image", "neutral"), ("link", "globe", "neutral"), ("file", "file", "neutral")]
    static func series(_ kind: String) -> String { kinds.first { $0.id == kind }?.series ?? "neutral" }
    static func glyph(_ kind: String) -> String { kinds.first { $0.id == kind }?.glyph ?? "list" }
    /// A row's kind id from its stored kind and clip kind.
    static func kindId(_ kind: String, clip: String) -> String {
        guard kind == "copied" else { return kind }
        return clip == "image" ? "picture" : clip == "link" ? "link" : clip == "file" ? "file" : "copied"
    }

    // MARK: one outline at a time (wire round, 15 November 2026; the user: less blue)

    /// The accent outlines of a pane and the item chosen in it. The pane that has the keys shows its line only while
    /// nothing in it is chosen; a chosen card or row shows the accent ring only while its pane has the keys (else a
    /// neutral ring). So at most one accent outline shows in a pane, and never two around the same thing.
    static func outline(keys: Bool, chosen: Bool) -> (pane: Bool, accentItem: Bool) {
        (keys && !chosen, keys && chosen)
    }

    // MARK: things in a card (wire round): the chips from the detector

    /// One glyph per kind of thing found in a text (DetectKind raw values), the same in the cards, the reader and the
    /// search chips.
    static func foundGlyph(_ kind: String) -> String {
        switch kind {
        case "date", "dateRange": return "calendar"
        case "link": return "external"
        case "money", "iban": return "coin"
        case "email": return "at"
        case "phone": return "phone"
        case "address": return "map"
        case "path": return "folder"
        case "command", "code": return "terminal"
        default: return "hash"
        }
    }

    /// Where a card's chips go. Under the text when the text leaves a chip row free; else in the foot line's free
    /// room; else nowhere: the chips go first, the text is never pushed out. Returns how many fit and where.
    static func chipFit(widths: [Double], textHeight: Double, room: Double, chipH: Double, rowWidth: Double, footFree: Double,
                        gap: Double = 6) -> (count: Int, under: Bool) {
        func fit(_ w: Double) -> Int {
            var used = 0.0, n = 0
            for c in widths { let need = used + (n > 0 ? gap : 0) + c; if need > w { break }; used = need; n += 1 }
            return n
        }
        guard !widths.isEmpty else { return (0, false) }
        if textHeight + 4 + chipH <= room { let n = fit(rowWidth); if n > 0 { return (n, true) } }
        return (fit(footFree), false)
    }

    /// A site's round mark: one of the four series colours, picked from the host by a stable hash (FNV-1a), and the
    /// host's first letter ("www." dropped). No network, no favicon.
    static func siteMark(_ host: String) -> (series: Int, letter: String) {
        var h = host.lowercased()
        if h.hasPrefix("www.") { h = String(h.dropFirst(4)) }
        var x: UInt32 = 2166136261
        for b in h.utf8 { x = (x ^ UInt32(b)) &* 16777619 }
        return (Int(x % 4), h.first.map { String($0).uppercased() } ?? "?")
    }

    // MARK: what a row shows given its group

    enum Part: Equatable { case tag(String), app(String), length(String) }

    /// The trailing cluster, left to right: the tag, the app (or where the text went), the length. The app is left out
    /// inside a session or group of that app; the tag is left out under its own Related to group, and otherwise shown
    /// only when the row is chosen or under the pointer (`reveal`), or when grouped by Related to (its other tag).
    static func cluster(took: String?, app: String, fate: String? = nil, tag: String?, in c: MetaContext, reveal: Bool = false) -> [Part] {
        var out: [Part] = []
        if let t = tag, !t.isEmpty, t.lowercased() != c.tag?.lowercased(), reveal || c.tag != nil { out.append(.tag(t)) }
        let sameApp = c.app.map { $0.lowercased() == app.lowercased() } ?? false
        if let f = fate, !f.isEmpty { out.append(.app(sameApp ? f.replacingOccurrences(of: " in " + app, with: "") : f)) }
        else if !app.isEmpty, !sameApp { out.append(.app(app)) }
        if let l = took, !l.isEmpty { out.append(.length(l)) }
        return out
    }

    /// What drops first when the room is short: the tag, then the app, then the length. The text never drops.
    /// `widths`: each part's width, in the order of `parts`; `room`: what the cluster may take; `gap` between parts.
    static func fit(_ parts: [Part], widths: [Double], room: Double, gap: Double = 10) -> [Part] {
        var keep = Array(zip(parts, widths))
        func total() -> Double { keep.reduce(0) { $0 + $1.1 } + gap * Double(max(0, keep.count - 1)) }
        for drop in ["tag", "app", "length"] {
            while total() > room, let i = keep.firstIndex(where: { name($0.0) == drop }) { keep.remove(at: i) }
        }
        return keep.map(\.0)
    }
    static func name(_ p: Part) -> String { switch p { case .tag: return "tag"; case .app: return "app"; case .length: return "length" } }

    // MARK: the reader

    /// The reader's one quiet header line: kind, how long ago, length, where it went (or the app). The exact date and
    /// time and the characters live in the tooltip and in Details.
    static func header(noun: String, ago: String, took: String?, app: String, fate: String?) -> String {
        var out = [noun, ago]
        if let t = took { out.append(t) }
        if let f = fate { out.append(f) } else if !app.isEmpty { out.append(app) }
        return out.joined(separator: " · ")
    }

    /// One more record of the same text (a draft, a sent line, a clip), for Details.
    struct Also: Equatable { let kind: String; let app: String; let at: Double; var sent = false }

    /// Details, one line each: the exact moment, the characters, repeats, a change, an estimate, the other records.
    static func details(exact: String, chars: Int, repeats: Int = 1, changed: Bool = false, est: Bool = false, also: [Also] = [],
                        clock: (Double) -> String) -> [String] {
        var out = [exact, "\(chars) character" + (chars == 1 ? "" : "s")]
        if repeats > 1 { out.append("The same text \(repeats) times within 5 minutes") }
        if changed { out.append("Changed by you; the original is kept") }
        if est { out.append("Estimated start: shown from the first whole word") }
        for a in also {
            let what = a.kind == "typed" ? (a.sent ? "Sent line" : "Draft") : a.kind == "copied" ? "Clip" : a.kind == "spoken" ? "Voice note" : "Record"
            out.append("\(what)" + (a.app.isEmpty ? "" : " in \(a.app)") + ", \(clock(a.at))")
        }
        return out
    }

    // MARK: the status line

    /// The status line's words: a result count only while searching, the filter only when the left pane cannot show
    /// it, the grouping only when it is not Time. Nothing the sticky chunk header says.
    static func status(query: String, results: Int, filter: String?, sidebarShows: Bool, group: String?, picked: Int) -> String {
        var out: [String] = []
        if !query.isEmpty { out.append("\(results) result\(results == 1 ? "" : "s")") }
        if let f = filter, !sidebarShows { out.append(f) }
        if let g = group { out.append("grouped by " + g) }
        if picked > 1 { out.append("\(picked) picked") }
        return out.joined(separator: " · ")
    }

    // MARK: one text, several kinds

    struct Row: Equatable {
        let kind: String     // spoken, typed, copied, call
        let at: Double
        let text: String
        let app: String
        var sent = false     // a typed row that is a sent line
    }

    /// Where a text began: a voice note before a draft before a clip. Recordings never merge.
    static func rank(_ kind: String) -> Int? { ["spoken": 0, "typed": 1, "copied": 2][kind] }

    /// Lower case, letters and digits, one space.
    static func norm(_ s: String) -> [Character] {
        var out: [Character] = [], space = true
        for c in s.lowercased() {
            if c.isLetter || c.isNumber { out.append(c); space = false } else if !space { out.append(" "); space = true }
        }
        if out.last == " " { out.removeLast() }
        return out
    }

    /// The same text, allowing small edits: equal; or the shorter (12+ characters) inside the longer and at least 80 %
    /// of it; or, of near length, at most 10 % of the first 400 characters different.
    static func same(_ a: [Character], _ b: [Character]) -> Bool {
        if a.isEmpty || b.isEmpty { return false }
        if a == b { return true }
        let (s, l) = a.count <= b.count ? (a, b) : (b, a)
        guard s.count >= 12, Double(s.count) >= 0.8 * Double(l.count) else { return false }
        if contains(l, s) { return true }
        let x = Array(a.prefix(400)), y = Array(b.prefix(400))
        return Double(distance(x, y)) <= 0.1 * Double(max(x.count, y.count))
    }
    static func contains(_ l: [Character], _ s: [Character]) -> Bool {
        guard s.count <= l.count else { return false }
        var i = 0
        while i + s.count <= l.count { if l[i] == s[0], Array(l[i..<(i + s.count)]) == s { return true }; i += 1 }
        return false
    }
    static func distance(_ a: [Character], _ b: [Character]) -> Int {
        if a.isEmpty { return b.count }
        var prev = Array(0...b.count), cur = prev
        for i in 1...a.count {
            cur[0] = i
            for j in 1...max(1, b.count) where j <= b.count { cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1)) }
            swap(&prev, &cur)
        }
        return prev[b.count]
    }

    /// Rows -> origin index -> the other records of the same text within `within` seconds. The origin is where the
    /// text began (a voice note, then a draft, then a clip); a record joins one origin at most; the same kind never
    /// merges here (repeats fold elsewhere). Display only.
    static func merge(_ rows: [Row], within: Double = 600) -> [Int: [Int]] {
        let order = rows.indices.sorted { rows[$0].at < rows[$1].at }
        let times = order.map { rows[$0].at }
        var normed: [Int: [Character]] = [:]
        func n(_ i: Int) -> [Character] { if let v = normed[i] { return v }; let v = norm(rows[i].text); normed[i] = v; return v }
        var taken = Set<Int>(), out: [Int: [Int]] = [:]
        for r in 0...1 {
            for (p, i) in order.enumerated() where rank(rows[i].kind) == r && !taken.contains(i) {
                var lo = p
                while lo > 0, rows[i].at - times[lo - 1] <= within { lo -= 1 }
                var hi = p
                while hi + 1 < order.count, times[hi + 1] - rows[i].at <= within { hi += 1 }
                for q in lo...hi {
                    let j = order[q]
                    guard j != i, !taken.contains(j), out[j] == nil, let rj = rank(rows[j].kind), rj > r, same(n(i), n(j)) else { continue }
                    out[i, default: []].append(j); taken.insert(j)
                }
            }
        }
        return out
    }

    /// What happened to a text, as a quiet detail: "sent in Claude", "in Claude", "copied". nil: nothing known.
    static func fate(_ others: [Row]) -> String? {
        if let s = others.first(where: { $0.kind == "typed" && $0.sent }) { return s.app.isEmpty ? "sent" : "sent in " + s.app }
        if let d = others.first(where: { $0.kind == "typed" }) { return d.app.isEmpty ? "in a field" : "in " + d.app }
        if others.contains(where: { $0.kind == "copied" }) { return "copied" }
        return nil
    }
}

// MARK: card text (the gallery)

extension JournalMeta {
    /// Text that reads as code or a command: shown in mono on a clip card.
    static func codeLike(_ s: String) -> Bool {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return false }
        let lines = t.split(separator: "\n", omittingEmptySubsequences: false)
        let marks = t.filter { "{}[];=<>$|\\`".contains($0) }.count
        let indented = lines.filter { $0.hasPrefix("  ") || $0.hasPrefix("\t") }.count
        let words = t.split(whereSeparator: { $0 == " " || $0 == "\n" }).count
        if indented >= 2 { return true }
        if t.hasPrefix("$ ") || t.hasPrefix("git ") || t.hasPrefix("cd ") || t.hasPrefix("npm ") || t.hasPrefix("swiftc ") { return true }
        return words > 0 && Double(marks) / Double(words) >= 0.5 && marks >= 3
    }
    /// Where a card's text starts so the first match shows: 0 when the match is near the top (inside `room`
    /// characters), else a word start about `lead` characters before it (the card puts "…" in front).
    static func window(_ s: String, match: Int?, room: Int, lead: Int = 40) -> Int {
        guard let m = match, m > room else { return 0 }
        let chars = Array(s.utf16)
        var i = max(0, m - lead)
        while i > 0, i < chars.count, chars[i - 1] != 32, chars[i - 1] != 10, m - i < lead * 2 { i -= 1 }
        return i
    }
    /// The first sentence (a card shows it a step stronger when the text is long).
    static func firstSentence(_ s: String, long: Int = 140) -> Int? {
        guard s.count > long else { return nil }
        let u = Array(s.utf16)
        for i in 0..<min(u.count, 220) where [46, 33, 63, 10].contains(u[i]) {   // . ! ? newline
            if u[i] == 10 || i + 1 >= u.count || u[i + 1] == 32 || u[i + 1] == 10 { return i + 1 }
        }
        return nil
    }
}

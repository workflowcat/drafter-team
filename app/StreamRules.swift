// The stream (one calm column, search first; chosen 23 November 2026, Andrii: "c feels right, but with some better
// controls over recording and editing especially"). Pure rules, tested in tests/stream_rules.swift; the views are
// app/Stream.swift, the model's side app/StreamModel.swift.
// - The field: scope words ("@mila", "links", "calls", "screens", "in:slack", "today", "pinned", ...) narrow the
//   stream; everything else (the words, quotes, the core's own filters such as kind: or with:) goes to the journal's
//   search (JournalSearch, the index with its ranking). `parse` splits the two; `coreText` is what the search gets.
// - The keys: `StreamKeys.route`, transition by transition (like QuickKeys.route in app/QuickRules.swift).
// - The player: time math for the inline player (skip, scrub, the line playing, speeds).
// - Editing: what a save stores and what its undo puts back.
import Foundation

enum StreamRules {
    /// What the field asks for: a kind, a person or project ("@ana"), an app ("in:slack"), a day, and the words left.
    struct Query: Equatable {
        var kind: String?          // spoken, typed, copied, call, link, picture, file, pinned
        var who: [String] = []     // "@ana" -> ["ana"]: a tag whose name has a word starting with it
        var app: String?           // "in:slack" -> "slack"
        var day: String?           // today, yesterday
        var words: [String] = []   // the rest, lower case (shown words; the search reads `coreText`)
        var isEmpty: Bool { kind == nil && who.isEmpty && app == nil && day == nil && words.isEmpty }
        /// A scope was typed (not only words).
        var scoped: Bool { kind != nil || !who.isEmpty || app != nil || day != nil }
    }

    /// The scope words and what they mean. A word is a scope only as a whole token; quote it to search for it.
    static let kindWords: [String: String] = [
        "links": "link", "link": "link",
        "screens": "picture", "screen": "picture", "shots": "picture", "pictures": "picture", "images": "picture",
        "files": "file", "file": "file",
        "calls": "call", "recordings": "call", "meetings": "call",
        "voice": "spoken", "said": "spoken",
        "drafts": "typed", "typed": "typed",
        "clips": "copied", "copied": "copied",
        "pinned": "pinned",
    ]
    static let dayWords: Set<String> = ["today", "yesterday"]

    /// The scopes the menu offers, in order: (token, name, symbol). ⌘1-⌘9 pick them in this order.
    static let scopes: [(token: String, name: String, glyph: String)] = [
        ("", "Everything", "list"), ("pinned", "Pinned", "pin"), ("drafts", "Drafts", "keys"), ("voice", "Voice notes", "waves"),
        ("calls", "Recordings", "phone"), ("clips", "Clips", "copy"), ("links", "Links", "globe"),
        ("screens", "Screens and pictures", "image"), ("files", "Files", "file")]

    /// `in:` followed by a time ("in:today", "in:\"last week\"", "in:2026-11") is the search's own time filter; any
    /// other `in:` names an app.
    static func inIsTime(_ v: String) -> Bool {
        let w = v.lowercased()
        if w.isEmpty || w.first == "\"" || w.first == "«" || w.first?.isNumber == true { return true }
        let words: Set<String> = ["today", "yesterday", "week", "month", "year", "last", "this", "morning", "evening", "afternoon",
                                  "сьогодні", "вчора", "учора", "тиждень", "місяць", "рік"]
        if words.contains(w) || w.hasPrefix("last-") || w.hasPrefix("this-") { return true }
        let months = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"]
        let days = ["mon", "tue", "wed", "thu", "fri", "sat", "sun"]
        return w.count >= 3 && (months + days).contains { w.hasPrefix($0) && isNameOf(w, $0) }
    }
    /// "monday", "mon", "november", "nov" but not "monzo": the word is a prefix of the full name.
    private static func isNameOf(_ w: String, _ short: String) -> Bool {
        let full = ["jan": "january", "feb": "february", "mar": "march", "apr": "april", "may": "may", "jun": "june", "jul": "july",
                    "aug": "august", "sep": "september", "oct": "october", "nov": "november", "dec": "december",
                    "mon": "monday", "tue": "tuesday", "wed": "wednesday", "thu": "thursday", "fri": "friday", "sat": "saturday", "sun": "sunday"][short] ?? short
        return full.hasPrefix(w)
    }

    /// The field's tokens: (text as typed, quoted).
    static func tokens(_ s: String) -> [(String, Bool)] {
        var quoted = false, cur = ""
        var toks: [(String, Bool)] = []
        for ch in s {
            if ch == "\"" { if !cur.isEmpty || quoted { toks.append((cur, quoted)) }; cur = ""; quoted.toggle(); continue }
            if ch == " " && !quoted { if !cur.isEmpty { toks.append((cur, false)) }; cur = ""; continue }
            cur.append(ch)
        }
        if !cur.isEmpty { toks.append((cur, quoted)) }
        return toks
    }

    /// One token is a stream scope (it never reaches the search).
    static func isScope(_ raw: String, quoted: Bool) -> Bool {
        guard !quoted else { return false }
        let t = raw.lowercased()
        if t.hasPrefix("@"), t.count > 1 { return true }
        if t.hasPrefix("in:"), t.count > 3 { return !inIsTime(String(t.dropFirst(3))) }
        return kindWords[t] != nil || dayWords.contains(t)
    }

    static func parse(_ s: String) -> Query {
        var q = Query()
        for (raw, lit) in tokens(s) {
            let t = raw.lowercased()
            if lit { q.words.append(t); continue }
            if t.hasPrefix("@"), t.count > 1 { q.who.append(String(t.dropFirst())); continue }
            if t.hasPrefix("in:"), t.count > 3, !inIsTime(String(t.dropFirst(3))) { q.app = String(t.dropFirst(3)); continue }
            if q.kind == nil, let k = kindWords[t] { q.kind = k; continue }
            if q.day == nil, dayWords.contains(t) { q.day = t; continue }
            q.words.append(t)
        }
        return q
    }

    /// What the journal's search gets: the field without the stream's scope words (quotes and the core's filters kept as
    /// typed). Empty: no search, the stream in time order.
    static func coreText(_ s: String) -> String {
        var kind = false, day = false, out: [String] = []
        for (raw, lit) in tokens(s) {
            let t = raw.lowercased()
            if !lit {
                if t.hasPrefix("@"), t.count > 1 { continue }
                if t.hasPrefix("in:"), t.count > 3, !inIsTime(String(t.dropFirst(3))) { continue }
                if !kind, kindWords[t] != nil { kind = true; continue }
                if !day, dayWords.contains(t) { day = true; continue }
            }
            out.append(lit ? "\"" + raw + "\"" : raw)
        }
        return out.joined(separator: " ")
    }

    /// The field with one scope word put in place of the scope it had (the scope menu writes the field, so the field
    /// stays the one place the scope lives).
    static func setting(kindToken: String, in s: String) -> String {
        let keep = s.split(separator: " ").map(String.init).filter { kindWords[$0.lowercased()] == nil }
        return ([kindToken].filter { !$0.isEmpty } + keep).joined(separator: " ") + (keep.isEmpty && !kindToken.isEmpty ? " " : "")
    }
    static func setting(who name: String, in s: String) -> String {
        let keep = s.split(separator: " ").map(String.init).filter { !$0.hasPrefix("@") }
        let first = name.split(separator: " ").first.map { "@" + $0.lowercased() } ?? ""
        return ([first] + keep).joined(separator: " ") + " "
    }
    /// ⌘1-⌘9: the n-th scope (1 = Everything).
    static func scopeToken(digit n: Int) -> String? { n >= 1 && n <= scopes.count ? scopes[n - 1].token : nil }

    /// One row's facts the stream filters on.
    struct Facts {
        var kindId: String          // spoken, typed, copied, call, link, picture, file
        var pinned: Bool
        var app: String
        var tags: [String]          // tag names
        var at: Double
        var hay: String             // lower case
        var shot = false            // a screenshot capture (ShotJournal), whatever its row kind
    }

    /// The scope only (kind, person, app, day); the words are the search's.
    static func inScope(_ f: Facts, _ q: Query, now: Double, cal: Calendar = .current) -> Bool {
        if let k = q.kind {
            switch k {
            case "pinned": if !f.pinned { return false }
            case "copied": if !["copied", "link", "picture", "file"].contains(f.kindId) || f.shot { return false }
            case "picture": if f.kindId != "picture" && !f.shot { return false }
            default: if f.kindId != k || f.shot { return false }
            }
        }
        if let a = q.app, !f.app.lowercased().hasPrefix(a) && !f.app.lowercased().contains(" " + a) { return false }
        for w in q.who {
            let hit = f.tags.contains { name in name.lowercased().split(whereSeparator: { $0 == " " || $0 == "." || $0 == "-" }).contains { $0.hasPrefix(w) } }
            if !hit { return false }
        }
        if let d = q.day {
            let today = cal.startOfDay(for: Date(timeIntervalSince1970: now)).timeIntervalSince1970
            let start = d == "today" ? today : cal.date(byAdding: .day, value: -1, to: Date(timeIntervalSince1970: today))!.timeIntervalSince1970
            if f.at < start || f.at >= start + 86400 { return false }
        }
        return true
    }

    /// The scope and the plain words (the fallback when there is no index; tests).
    static func matches(_ f: Facts, _ q: Query, now: Double, cal: Calendar = .current) -> Bool {
        guard inScope(f, q, now: now, cal: cal) else { return false }
        for w in q.words where !f.hay.contains(w) { return false }
        return true
    }

    /// The day heading: "Today", "Yesterday", a weekday this week, else "13 November" (with the year when not this one).
    static func dayTitle(_ day: Date, now: Date, cal: Calendar = .current) -> String {
        let a = cal.startOfDay(for: day), b = cal.startOfDay(for: now)
        let n = cal.dateComponents([.day], from: a, to: b).day ?? 0
        if n == 0 { return "Today" }
        if n == 1 { return "Yesterday" }
        if n < 7 { return StreamZoomRules.formatter("EEEE d MMMM", cal: cal, locale: "en_GB").string(from: day) }
        let fmt = cal.component(.year, from: day) == cal.component(.year, from: now) ? "EEEE d MMMM" : "d MMMM yyyy"
        return StreamZoomRules.formatter(fmt, cal: cal, locale: "en_GB").string(from: day)
    }

    /// Short words under the field when it is empty: what can be typed.
    static let hints = ["@mila", "links", "calls", "screens", "in:slack", "today"]

    /// What a scope says back above the stream ("Links · 18"), or nil for plain words.
    static func scopeLine(_ q: Query) -> String? {
        var parts: [String] = []
        if let k = q.kind { parts.append(scopes.first { kindWords[$0.token] == k || $0.token == k }?.name ?? k) }
        for w in q.who { parts.append("@" + w) }
        if let a = q.app { parts.append("in " + a.capitalized) }
        if let d = q.day { parts.append(d.capitalized) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    // MARK: editing

    /// What a save of an edited item stores: nothing (the text is what it was), a change kept beside the original, or
    /// the change dropped (the text is the original again). The undo is the same kind of step back to `before`.
    enum Store: Equatable { case keep, change(String), original }
    static func save(original: String, before: String?, draft: String) -> Store {
        let shown = before ?? original
        if draft == shown { return .keep }
        return draft == original ? .original : .change(draft)
    }
    static func undo(original: String, before: String?) -> Store {
        guard let b = before, b != original else { return .original }
        return .change(b)
    }
    /// The bullet points as he typed them in the editor: one per line, list marks and blank lines dropped.
    static func points(_ text: String) -> [String] {
        text.split(whereSeparator: \.isNewline).map { l in
            var s = l.trimmingCharacters(in: .whitespaces)
            for m in ["• ", "- ", "* ", "– "] where s.hasPrefix(m) { s = String(s.dropFirst(m.count)) }
            return s.trimmingCharacters(in: .whitespaces)
        }.filter { !$0.isEmpty }
    }
    /// Combine: enough items to make one draft (recordings and screenshots are not text).
    static func canCombine(_ picked: Int, texts: Int) -> Bool { picked >= 2 && texts >= 2 }
}

// MARK: - the player

enum PlayerRules {
    /// Speeds the inline player cycles through.
    static let speeds: [Float] = [1, 1.5, 2]
    static func nextSpeed(_ r: Float) -> Float {
        guard let i = speeds.firstIndex(of: r) else { return speeds[0] }
        return speeds[(i + 1) % speeds.count]
    }
    static func speedLabel(_ r: Float) -> String { r == Float(Int(r)) ? "\(Int(r))×" : String(format: "%.1f×", r) }
    /// A skip (±10 s) or a scrub, kept inside the audio.
    static func clamp(_ t: Double, total: Double) -> Double { max(0, min(t, max(0, total))) }
    static func skip(_ at: Double, by: Double, total: Double) -> Double { clamp(at + by, total: total) }
    /// "1:05", "1:02:03".
    static func clock(_ s: Double) -> String {
        let n = Int(max(0, s).rounded(.down))
        return n >= 3600 ? String(format: "%d:%02d:%02d", n / 3600, n / 60 % 60, n % 60) : String(format: "%d:%02d", n / 60, n % 60)
    }
    /// The line playing at `t`: the last one starting at or before it (nil before the first).
    static func line(at t: Double, starts: [Double?]) -> Int? {
        var out: Int?
        for (i, s) in starts.enumerated() { if let s, s <= t + 0.05 { out = i } }
        return out
    }
    /// A voice note has no times per sentence: each sentence's start is guessed from its place in the text (characters
    /// spoken at an even pace). Marked as a guess where it shows.
    static func sentences(_ text: String) -> [String] {
        var out: [String] = [], cur = ""
        for ch in text {
            cur.append(ch)
            if ".!?…".contains(ch) { let s = cur.trimmingCharacters(in: .whitespacesAndNewlines); if !s.isEmpty { out.append(s) }; cur = "" }
            else if ch.isNewline { let s = cur.trimmingCharacters(in: .whitespacesAndNewlines); if !s.isEmpty { out.append(s) }; cur = "" }
        }
        let s = cur.trimmingCharacters(in: .whitespacesAndNewlines); if !s.isEmpty { out.append(s) }
        return out
    }
    static func guessedStarts(_ lines: [String], total: Double) -> [Double] {
        let n = lines.reduce(0) { $0 + max(1, $1.count) }
        guard n > 0, total > 0 else { return lines.map { _ in 0 } }
        var at = 0.0, out: [Double] = []
        for l in lines { out.append(at); at += total * Double(max(1, l.count)) / Double(n) }
        return out
    }
}

// MARK: - the keys

/// The stream's keys. One place has the keys at a time: the search field, the stream (the chosen row, open or not),
/// the editor of the open row, Go to.
enum StreamKeys {
    enum Region: Equatable { case search, list, editor, palette }
    enum Key: Equatable {
        case up, down, pageUp, pageDown, left, right, tab, backTab, ret, esc
        case letter, e, space
        case shiftUp, shiftDown
        case cmdUp, cmdDown                 // the day before or after
        case combine                        // ⌘⇧E
        case insert                         // ⌘↵ (in the editor: save)
        case goTo                           // ⌘T
        case back, forward                  // ⌘[ ⌘]
        case digit(Int)                     // ⌘1-⌘9: a scope
    }
    enum Effect: Equatable {
        case none, pass
        case move(Int)                      // 0: the chosen row (or the first) gets the keys
        case open, close, openPage          // in place; a recording's full page (Call Studio)
        case edit, save, cancel
        case insert, combine
        case extend(Int), single
        case jumpDay(Int)
        case clearSearch, endCommand, plan, closeWindow, typeInSearch
        case openPalette, closePalette, palettePick, paletteMove(Int)
        case historyBack, historyForward
        case scope(Int)
        case playPause
    }
    /// What the open row is.
    enum Open: Equatable { case none, text, voice, recording, other }
    struct State: Equatable {
        var region: Region = .search
        var rows = 0, row = 0
        var open = Open.none          // the chosen row, open in place (none: closed)
        var audio = false             // the chosen row has audio to play
        var picked = 1
        var query = false
        var command = false
        var editable: Bool { open == .text || open == .voice || open == .recording }
    }

    static func route(_ s0: State, _ k: Key) -> (State, Effect) {
        var s = s0
        if s.region == .editor {
            switch k {
            case .esc: s.region = .list; return (s, .cancel)
            case .insert: s.region = .list; return (s, .save)
            default: return (s, .pass)
            }
        }
        if s.region == .palette {
            switch k {
            case .up, .down: return (s, .paletteMove(k == .up ? -1 : 1))
            case .pageUp, .pageDown: return (s, .paletteMove(k == .pageUp ? -8 : 8))
            case .ret: s.region = .list; return (s, .palettePick)
            case .esc, .goTo: s.region = .list; return (s, .closePalette)
            case .letter, .e, .space, .left, .right: return (s, .pass)
            default: return (s, .none)
            }
        }
        switch k {
        case .goTo: s.region = .palette; return (s, .openPalette)
        case .back, .forward: return (s, k == .back ? .historyBack : .historyForward)
        case .digit(let n): return (s, n >= 1 && n <= 9 ? .scope(n) : .none)
        case .combine:
            guard s.picked >= 2 else { return (s, .none) }
            s.region = .editor
            return (s, .combine)
        case .insert: return (s, s.rows > 0 ? .insert : .none)
        case .tab, .backTab:
            if s.command { return (s, .pass) }
            s.region = s.region == .search && s.rows > 0 ? .list : .search
            return (s, s.region == .list ? .move(0) : .none)
        case .letter: if s.region == .search { return (s, .pass) }; s.region = .search; return (s, .typeInSearch)
        case .e:
            if s.region == .search { return (s, .pass) }
            if s.open != .none, s.editable { s.region = .editor; return (s, .edit) }
            s.region = .search; return (s, .typeInSearch)
        case .space:
            guard s.region == .list, s.rows > 0 else { return (s, .pass) }
            if s.audio { return (s, .playPause) }
            return (s, s.open == .none ? .open : .close)
        case .cmdUp, .cmdDown:
            if s.region == .search { return (s, .pass) }
            guard s.rows > 0 else { return (s, .none) }
            s.region = .list
            return (s, .jumpDay(k == .cmdUp ? -1 : 1))
        case .shiftUp, .shiftDown:
            guard s.rows > 0, !s.command else { return (s, s.region == .search ? .pass : .none) }
            s.region = .list
            return (s, .extend(k == .shiftUp ? -1 : 1))
        case .up, .down, .pageUp, .pageDown:
            let by = k == .up ? -1 : k == .down ? 1 : k == .pageUp ? -8 : 8
            if s.region == .search {
                if s.command { return (s, .pass) }
                guard s.rows > 0, by > 0 else { return (s, .none) }
                s.region = .list
                return (s, .move(by > 1 ? by : 0))   // the first ↓ lands on the chosen (best) row
            }
            if by < 0, s.row == 0 { s.region = .search; return (s, .none) }   // ↑ on the first row: back to the field
            return (s, .move(by))
        case .left:
            if s.region == .search { return (s, .pass) }
            return (s, s.open != .none ? .close : .none)
        case .right:
            if s.region == .search { return (s, .pass) }
            return (s, s.open == .none && s.rows > 0 ? .open : .none)
        case .ret:
            if s.region == .search, s.command { return (s, .plan) }
            guard s.rows > 0 else { return (s, .none) }
            s.region = .list
            if s.open == .none { return (s, .open) }
            if s.open == .recording { return (s, .openPage) }
            if s.editable { s.region = .editor; return (s, .edit) }
            return (s, .close)
        case .esc:
            if s.region == .search {
                if s.command { return (s, .endCommand) }
                if s.query { return (s, .clearSearch) }
                if s.rows > 0 { s.region = .list }
                return (s, .none)
            }
            if s.picked > 1 { return (s, .single) }
            if s.open != .none { return (s, .close) }
            return (s, .closeWindow)
        }
    }

    /// The keys of the place in focus, for the status line.
    static func hints(_ s: State) -> String {
        switch s.region {
        case .search: return s.command ? "↵ ask · esc back" : "↓ results · ↵ open the best · esc " + (s.query ? "clear" : "leave")
        case .editor: return "⌘↵ save · esc cancel · ⌘Z undo after save"
        case .palette: return "↑↓ pick · ↵ go · esc close"
        case .list:
            if s.picked > 1 { return "\(s.picked) picked · ⌘⇧E combine · esc one" }
            switch s.open {
            case .none: return "↑↓ move · ↵ open · ⇧↑↓ pick · ⌘T go to a day"
            case .recording: return "space play · ↵ open the page · E edit · ⌘C copy · ⇧⌘A for agent · esc close"
            case .voice: return "space play · E edit · ⌘↵ insert · ⌘C copy · ⌘⌫ delete · esc close"
            case .text: return "E or ↵ edit · ⌘↵ insert · ⌘C copy · ⌘P pin · ⌘⌫ delete · esc close"
            case .other: return "⌘↵ insert · ⌘C copy · ⌘P pin · esc close"
            }
        }
    }
}

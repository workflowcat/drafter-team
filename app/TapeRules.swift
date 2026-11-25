// The window's tape, the second window round (14 November 2026, Andrii: "kinda hard to navigate", "we're wasting a lot
// of space", "name stuff", "say how long something took", "classify all the copies by what they're related to").
// Pure rules, display only: nothing here changes or deletes a stored row. Tested in tests/tape_rules.swift with
// made-up rows; compiles with ClipRules.swift and EntityRules.swift only.
//
// - what a row says: a chat export's "[date, time] Name:" head becomes a tag, a copied web page loses its navigation
// - what it is related to: at most 2 tags (a person, project or tool the entity matcher finds; a link's site or a
//   file's folder; the app it came from)
// - repeats: the same text (or a strict prefix of the next one) in a row within a few minutes folds into one, "×3"
// - how long it took: a take's audio, a call's length, a typed message from its first to last stamp
// - the sidebar: named entries with counts; filters; sections by time, by what it is related to, or by app
import Foundation

/// What a row is related to. kind: person, project, tool, site, folder, chat (a name from a chat export), app.
struct TapeTag: Hashable {
    let name: String
    let kind: String
    /// The word a tooltip uses for the kind.
    var kindWord: String {
        switch kind {
        case "person", "chat": return "person"
        case "site": return "website"
        default: return kind
        }
    }
    /// The symbol name for the kind.
    var glyph: String {
        switch kind {
        case "person", "chat": return "user"
        case "project", "folder": return "folder"
        case "tool": return "terminal"
        case "site": return "globe"
        default: return "list"
        }
    }
}

/// The facts the filters and the sections need about one row.
struct TapeFacet: Equatable {
    var kind: String          // copied, typed, spoken, call
    var clip: String = "text" // for a copy: text, link, file, image
    var app: String = ""
    var at: Double = 0
    var tags: [TapeTag] = []
    var pinned = false
}

enum TapeRules {
    // MARK: what a row says

    /// "[14.11.26, 12:41] Mila Synthetic: text" (Telegram, WhatsApp and Beeper exports, with or without seconds, the
    /// date in any order): the name and the text after it. nil when the text does not start that way.
    static func chatHeader(_ s0: String) -> (name: String, rest: String)? {
        let s = s0.trimmingCharacters(in: .whitespacesAndNewlines)
        guard s.first == "[", let close = s.firstIndex(of: "]") else { return nil }
        let stamp = s[s.index(after: s.startIndex)..<close]
        guard stamp.count >= 5, stamp.count <= 32, stamp.contains(where: \.isNumber),
              stamp.allSatisfy({ $0.isNumber || " .,:/-APMapm".contains($0) }) else { return nil }
        let after = s[s.index(after: close)...].drop { $0 == " " }
        guard let colon = after.firstIndex(of: ":") else { return nil }
        let name = after[..<colon].trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, name.count <= 40, name.split(separator: " ").count <= 4, name.first?.isLetter == true,
              !name.contains("\n") else { return nil }
        let rest = after[after.index(after: colon)...].trimmingCharacters(in: .whitespacesAndNewlines)
        // a second header later is the next message: the row shows the first message's text
        return (name, rest)
    }

    /// Words a site's navigation is made of (English and Ukrainian), folded to lower case.
    static let navWords: Set<String> = [
        "skip", "to", "content", "main", "menu", "navigation", "home", "about", "us", "products", "product", "services",
        "pricing", "blog", "news", "contact", "contacts", "sign", "in", "up", "log", "login", "register", "search",
        "cart", "account", "subscribe", "english", "docs", "help", "support", "careers", "jobs", "shop", "more",
        "features", "solutions", "resources", "company", "toggle", "close", "open", "back", "next", "previous", "share",
        "головна", "про", "нас", "новини", "контакти", "увійти", "вхід", "пошук", "меню", "перейти", "до", "вмісту",
        "послуги", "продукти", "блог", "ціни", "кошик", "підписатися", "українська", "реєстрація", "допомога", "ще"]

    private static func words(_ s: Substring) -> [String] {
        s.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "'" }).map(String.init)
    }
    private static func isNavLine(_ l: Substring) -> Bool {
        let w = words(l)
        guard !w.isEmpty, w.count <= 3 else { return false }
        if w.allSatisfy({ navWords.contains($0) }) { return true }
        // a short menu item: few letters, no sentence mark
        return l.count <= 24 && !l.contains(where: { ".!?,;".contains($0) })
    }
    private static func sentence(_ s: Substring) -> String {
        var t = s.trimmingCharacters(in: .whitespaces)
        for end in [". ", "! ", "? "] {
            if let r = t.range(of: end), t.distance(from: t.startIndex, to: r.lowerBound) >= 20 { t = String(t[..<r.lowerBound]) + String(end.first!); break }
        }
        return t
    }

    /// A copied web page that starts with its site's navigation: the first sentence-like span after it. nil when the
    /// text does not start with navigation (then the row shows the text as it is).
    static func pageLead(_ text: String) -> String? {
        let lines = text.prefix(6000).split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if lines.count >= 4 {
            var k = 0
            while k < lines.count, isNavLine(Substring(lines[k])) { k += 1 }
            let navHits = lines.prefix(k).filter { words(Substring($0)).contains { navWords.contains($0) } }.count
            if k >= 3, navHits >= 2, k < lines.count,
               let body = lines[k...].first(where: { words(Substring($0)).count >= 5 }) {
                return sentence(Substring(body))
            }
            return nil
        }
        // flattened to one line: four or more navigation words in front
        let parts = text.prefix(2000).split(separator: " ", omittingEmptySubsequences: true)
        var k = 0
        while k < parts.count, let w = words(parts[k]).first, words(parts[k]).count == 1, navWords.contains(w) { k += 1 }
        guard k >= 4, parts.count - k >= 5 else { return nil }
        return sentence(Substring(parts[k...].joined(separator: " ")))
    }

    /// What a row shows on its one line and the chat name it found (a tag). `title`: a page or link title the
    /// pasteboard gave, which wins over the guess.
    static func display(_ text: String, kind: String, clip: String, title: String = "") -> (line: String, chat: String?) {
        // one line (most rows): trimmed; else the lines joined
        let flat = text.contains(where: \.isNewline)
            ? text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: " ")
            : text.trimmingCharacters(in: .whitespaces)
        guard clip == "text" else { return (flat, nil) }
        if text.first(where: { !$0.isWhitespace }) == "[", let h = chatHeader(text) {
            let rest = h.rest.split(whereSeparator: \.isNewline).first.map(String.init) ?? h.rest
            return (rest.isEmpty ? flat : rest, h.name)
        }
        if kind == "copied", pageLead(text) != nil {
            let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
            return (t.isEmpty ? pageLead(text)! : t, nil)
        }
        return (flat, nil)
    }

    // MARK: what a row is related to

    static let entityKinds: Set<String> = ["person", "project", "tool"]

    /// At most `max` tags, most telling first: the chat name; people, projects and tools (`found`: names and kinds the
    /// entity matcher resolved in the text, first seen first); a link's site or a file's folder; the app.
    static func tags(text: String, clip: String, app: String, chat: String? = nil, found: [(name: String, kind: String)], max: Int = 2) -> [TapeTag] {
        var out: [TapeTag] = []
        func add(_ t: TapeTag) {
            guard out.count < max, !t.name.isEmpty, !out.contains(where: { $0.name.lowercased() == t.name.lowercased() }) else { return }
            out.append(t)
        }
        if let chat {   // a chat named after a known person is that person: one sidebar entry, not two
            let who = found.first { $0.kind == "person" && $0.name.lowercased() == chat.lowercased() }
            add(TapeTag(name: who?.name ?? chat, kind: who == nil ? "chat" : "person"))
        }
        for f in found where entityKinds.contains(f.kind) { add(TapeTag(name: f.name, kind: f.kind)) }
        switch clip {
        case "link": add(TapeTag(name: ClipRules.parts(text).host, kind: "site"))
        case "file":
            let folder = ClipRules.fileParts(text).folder
            let last = folder == "~" ? "Home" : folder.split(separator: "/").last.map(String.init) ?? folder
            add(TapeTag(name: last, kind: "folder"))
        default: break
        }
        add(TapeTag(name: app, kind: "app"))
        return out
    }

    // MARK: repeats

    static func norm(_ s: String) -> String {
        s.replacingOccurrences(of: "\u{A0}", with: " ").split(whereSeparator: { $0.isWhitespace }).joined(separator: " ").lowercased()
    }

    /// Rows newest first (kind, app, time, text): groups of indices, each newest first. A row folds into the group of
    /// the same kind and app before it when it came within `within` seconds of that group's oldest row and says the
    /// same (exactly, after spaces and case) or is a strict start of the group's text. Calls never fold.
    static func collapse(_ rows: [(kind: String, app: String, at: Double, text: String)], within: Double = 300) -> [[Int]] {
        if rows.count == 1 { return [[0]] }
        var groups: [[Int]] = []
        var open: [String: Int] = [:]   // kind|app -> its newest group
        var reps: [String?] = [], first: [Int] = [], oldest: [Double] = []   // the text of a group, worked out when needed
        for (i, r) in rows.enumerated() {
            let key = r.kind + "|" + r.app
            if r.kind != "call", let g = open[key], oldest[g] - r.at <= within, oldest[g] >= r.at {
                let n = norm(r.text)
                if reps[g] == nil { reps[g] = norm(rows[first[g]].text) }
                let rep = reps[g]!
                if !n.isEmpty, rep == n || (rep.hasPrefix(n) && n.count < rep.count) {
                    groups[g].append(i); oldest[g] = r.at
                    continue
                }
                open[key] = groups.count
                groups.append([i]); reps.append(n); first.append(i); oldest.append(r.at)
                continue
            }
            open[key] = groups.count
            groups.append([i]); reps.append(nil); first.append(i); oldest.append(r.at)
        }
        return groups
    }

    // MARK: sessions

    /// Rows newest first (kind, app, time, day key): sessions as groups of indices, newest first, each newest first.
    /// A session is a stretch in one app with gaps under `gap` seconds, inside one day. A recording is a session of
    /// its own. A clip inside the stretch belongs to it, whatever app it came from; a stretch that so far holds only
    /// clips takes the app of the first draft or voice note that joins it.
    static func sessions(_ rows: [(kind: String, app: String, at: Double, day: Int)], gap: Double = 600) -> [[Int]] {
        var out: [[Int]] = []
        var cur: [Int] = [], app: String? = nil, last = -Double.infinity, day = Int.min
        func close() { if !cur.isEmpty { out.append(cur.reversed()) }; cur = []; app = nil }
        for i in rows.indices.reversed() {   // oldest first
            let r = rows[i]
            if r.kind == "call" { close(); out.append([i]); last = -Double.infinity; continue }
            if !cur.isEmpty, r.at - last >= gap || r.day != day { close() }
            if cur.isEmpty { cur = [i]; app = r.kind == "copied" ? nil : r.app }
            else if r.kind == "copied" { cur.append(i) }
            else if app == nil || app == r.app { cur.append(i); app = r.app }
            else { close(); cur = [i]; app = r.app }
            last = r.at; day = r.day
        }
        close()
        return out.reversed()
    }

    /// A session's line: from, to, its app, the related tag most of its rows share, how long it took, its items.
    /// `took`: each row's own length (a voice note's audio: it started that long before it was kept).
    struct SessionFacts: Equatable { let from: Double; let to: Double; let app: String; let tag: TapeTag?; let took: Double; let items: Int; let recordings: Int }
    static func sessionFacts(_ f: [TapeFacet], took: [Double?], rows: [Int]) -> SessionFacts {
        var from = Double.infinity, to = -Double.infinity, n: [TapeTag: Int] = [:], apps: [String: Int] = [:], rec = 0
        for i in rows {
            from = min(from, f[i].at - (took[i] ?? 0)); to = max(to, f[i].at)
            for t in f[i].tags where t.kind != "app" { n[t, default: 0] += 1 }
            if f[i].kind != "copied" || apps.isEmpty { apps[f[i].app, default: 0] += f[i].kind == "copied" ? 0 : 1 }
            if f[i].kind == "call" { rec += 1 }
        }
        let app = apps.max { $0.value != $1.value ? $0.value < $1.value : $0.key > $1.key }?.key ?? f[rows.first ?? 0].app
        let tag = n.max { $0.value != $1.value ? $0.value < $1.value : $0.key.name > $1.key.name }?.key
        return SessionFacts(from: from, to: to, app: app, tag: tag, took: max(0, to - from), items: rows.count, recordings: rec)
    }

    // MARK: how long it took

    /// Seconds a row took, or nil (shown as nothing): a spoken take its audio, a call its length (not while it
    /// records), a typed message from its first to its last stamp (1 s to 30 min; longer means he left and came back).
    /// A copy took no time.
    static func took(kind: String, secs: Double, from: Double? = nil, to: Double? = nil, live: Bool = false) -> Double? {
        switch kind {
        case "spoken", "call": return !live && secs >= 1 ? secs : nil
        case "typed":
            guard let a = from, let b = to else { return nil }
            let d = b - a
            return d >= 1 && d <= 1800 ? d : nil
        default: return nil
        }
    }

    /// "0:08", "1:32", "1:02:05".
    static func clock(_ s: Double) -> String {
        let n = Int(s.rounded())
        return n >= 3600 ? String(format: "%d:%02d:%02d", n / 3600, n / 60 % 60, n % 60) : String(format: "%d:%02d", n / 60, n % 60)
    }

    // MARK: the sidebar

    enum Filter: Hashable {
        case all, pinned, kind(String), tag(TapeTag), app(String)
        case when(String)     // a chunk of time: picking it moves the list there, it filters nothing
        func matches(_ f: TapeFacet) -> Bool {
            switch self {
            case .all, .when: return true
            case .pinned: return f.pinned
            case .kind(let k):
                switch k {
                case "picture": return f.kind == "copied" && f.clip == "image"
                case "link": return f.kind == "copied" && f.clip == "link"
                case "file": return f.kind == "copied" && f.clip == "file"
                default: return f.kind == k
                }
            case .tag(let t): return f.tags.contains { $0.name.lowercased() == t.name.lowercased() }
            case .app(let a): return f.app == a
            }
        }
    }

    struct Entry: Equatable {
        let filter: Filter
        let title: String
        let glyph: String
        let count: Int
        let group: String     // "" for All and Pinned, else Kinds, Related to, Apps
        let tip: String
        var depth = 0         // clip subtypes, or expanded older dates
        var unfolds = false   // Older: picking it shows or hides the months and years
        var open = false
    }

    /// The horizontal When bar: recent chunks, then one
    /// "Older" entry (its count: all of them) that unfolds to the months and years, one step in. `chunks`: the chunks
    /// of time newest first (TimeChunks ids "c:today", "c:m:…", "c:y:…").
    static let recentChunks: Set<String> = ["today", "yesterday", "week", "lastweek", "month"]
    static func when(_ chunks: [(id: String, title: String, count: Int, tip: String)], olderOpen: Bool) -> [Entry] {
        var out: [Entry] = [], older: [Entry] = [], n = 0
        for c in chunks where c.count > 0 {
            let p = c.id.split(separator: ":"), kind = p.count >= 2 ? String(p[1]) : c.id   // as TimeChunks.chunkKind
            let title = kind == "week" ? "This week" : kind == "month" ? "This month" : c.title
            let e = Entry(filter: .when(c.id), title: title, glyph: "calendar", count: c.count, group: "When", tip: c.tip)
            if recentChunks.contains(kind) { out.append(e) } else {
                older.append(Entry(filter: e.filter, title: e.title, glyph: e.glyph, count: e.count, group: e.group, tip: e.tip, depth: 1)); n += c.count
            }
        }
        guard !older.isEmpty else { return out }
        out.append(Entry(filter: .when(olderId), title: "Older", glyph: "calendar", count: n, group: "When",
                         tip: (olderOpen ? "Hide" : "Show") + " the months and years before this month", unfolds: true, open: olderOpen))
        if olderOpen { out += older }
        return out
    }
    static let olderId = "older"

    /// The kinds as people read them: nouns (Andrii, 14 November: "why do we have past tense verbs everywhere?").
    /// The stored kind values (copied, typed, spoken, call) do not change.
    static let kindList: [(id: String, title: String, one: String, glyph: String)] = [
        ("copied", "Clips", "Clip", "copy"), ("picture", "Pictures", "Picture", "image"), ("link", "Links", "Link", "globe"),
        ("file", "Files", "File", "file"), ("typed", "Drafts", "Draft", "keys"), ("spoken", "Voice notes", "Voice note", "waves"),
        ("call", "Recordings", "Recording", "phone")]
    static let groups = ["Kinds", "Apps", "Related to"]
    static let clipSubtypes: Set<String> = ["picture", "link", "file"]
    /// All, Pinned, then kinds in display order, even when a group is folded.
    static func shortcut(_ f: Filter) -> Int? {
        if f == .all { return 1 }
        if f == .pinned { return 2 }
        return kindList.firstIndex { .kind($0.id) == f }.map { $0 + 3 }
    }
    /// A kind's name for one row ("Voice note"); a picture, link or file clip by what it is.
    static func one(_ kind: String, clip: String = "text", call: Bool = true) -> String {
        if kind == "copied", clip != "text" { return clip == "image" ? "Picture" : clip == "link" ? "Link" : "File" }
        if kind == "call", !call { return "Recording" }
        return kindList.first { $0.id == kind }?.one ?? kind
    }

    /// Every sidebar entry with its count over `facets` (the rows the search left): All, Pinned, the kinds, the top
    /// tags (not apps), the top apps. Kinds with no rows stay (a known place); tags and apps only with rows.
    /// Related to comes after Apps (Andrii, 17 November 2026: the automatic tags quieter and lower): pinned tags first,
    /// then the tags `TagRules.related` lets through, at most `relatedTop`.
    static func sidebar(_ facets: [TapeFacet], top: Int = 8, relatedTop: Int = 5, prefs: TagRules.Prefs = TagRules.Prefs(),
                        appGlyph: (String) -> String = { _ in "list" }) -> [Entry] {
        var kindN: [String: Int] = [:], tagN: [TapeTag: Int] = [:], tagLast: [TapeTag: Double] = [:], appN: [String: Int] = [:]
        var pinned = 0
        for f in facets {
            kindN[f.kind, default: 0] += 1
            if f.kind == "copied" { kindN[f.clip == "image" ? "picture" : f.clip, default: 0] += 1 }
            if f.pinned { pinned += 1 }
            for t in f.tags where t.kind != "app" { tagN[t, default: 0] += 1; tagLast[t] = max(tagLast[t] ?? 0, f.at) }
            if !f.app.isEmpty { appN[f.app, default: 0] += 1 }
        }
        var out: [Entry] = [
            Entry(filter: .all, title: "All", glyph: "list", count: facets.count, group: "", tip: "Everything in the journal"),
            Entry(filter: .pinned, title: "Pinned", glyph: "pin", count: pinned, group: "", tip: "Pinned items, also on top of the Quick panel")]
        for k in kindList {
            out.append(Entry(filter: .kind(k.id), title: k.title, glyph: k.glyph, count: kindN[k.id] ?? 0, group: "Kinds", tip: kindTip(k.id), depth: clipSubtypes.contains(k.id) ? 1 : 0))
        }
        for (a, n) in appN.sorted(by: { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }).prefix(top) {
            out.append(Entry(filter: .app(a), title: a, glyph: appGlyph(a), count: n, group: "Apps", tip: "Items from \(a)"))
        }
        for (t, n) in TagRules.related(tagN, last: tagLast, prefs: prefs, top: relatedTop) {
            let pin = prefs.pinned.contains(TagRules.key(t))
            out.append(Entry(filter: .tag(t), title: t.name, glyph: t.glyph, count: n, group: "Related to",
                             tip: "Items related to \(t.name), a \(t.kindWord)" + (pin ? " · pinned" : TagRules.auto(t) ? " · found by name" : "")))
        }
        return out
    }
    static func kindTip(_ k: String) -> String {
        switch k {
        case "copied": return "Clips: text, links, files and pictures on the clipboard"
        case "typed": return "Drafts: text you wrote in an app, one item per message"
        case "spoken": return "Voice notes: your dictation takes"
        case "call": return "Recordings: calls and long voice notes"
        case "picture": return "Pictures: picture clips and captures"
        case "link": return "Links: link clips"
        default: return "Files: file clips"
        }
    }
    /// The entries a key reaches, in order: groups he folded away are skipped.
    static func visible(_ entries: [Entry], folded: Set<String>) -> [Entry] { entries.filter { !folded.contains($0.group) } }

    /// The active filter in words, for the status line.
    static func words(_ f: Filter) -> String {
        switch f {
        case .all, .when: return "everything"
        case .pinned: return "pinned"
        case .kind(let k): return (kindList.first { $0.id == k }?.title ?? k).lowercased()
        case .tag(let t): return "related to \(t.name)"
        case .app(let a): return "from \(a)"
        }
    }

    // MARK: sections

    enum Group: String, CaseIterable { case time, topics, related, app
        var title: String { switch self { case .time: return "Time"; case .topics: return "Topics"; case .related: return "Related to"; case .app: return "App" } }
    }
    struct Section: Equatable { let title: String; let rows: [Int] }

    /// The rows (indices into `facets`, newest first) in sections. Time: a section per day (`day` names it). Related to:
    /// by the first tag that is not the app, else the app; App: by app. Those two: the biggest section first, rows
    /// newest first inside.
    static func sections(_ facets: [TapeFacet], rows: [Int], by g: Group, day: (Double) -> (key: Int, title: String)) -> [Section] {
        switch g {
        case .time:
            var out: [Section] = [], cur: [Int] = [], key = Int.min, title = ""
            for i in rows {
                let d = day(facets[i].at)
                if d.key != key, !cur.isEmpty { out.append(Section(title: title, rows: cur)); cur = [] }
                key = d.key; title = d.title; cur.append(i)
            }
            if !cur.isEmpty { out.append(Section(title: title, rows: cur)) }
            return out
        case .topics:
            // Facets have no text. JournalModel supplies TopicClusterRules sections with the full rows.
            return rows.isEmpty ? [] : [Section(title: "Standalone", rows: rows)]
        case .related, .app:
            var by: [String: [Int]] = [:], order: [String] = []
            for i in rows {
                let f = facets[i]
                let k: String
                if g == .app { k = f.app.isEmpty ? "No app" : f.app }
                else { k = f.tags.first(where: { $0.kind != "app" })?.name ?? (f.app.isEmpty ? "Nothing found" : f.app) }
                if by[k] == nil { order.append(k) }
                by[k, default: []].append(i)
            }
            return order.enumerated().sorted { a, b in
                let na = by[a.element]!.count, nb = by[b.element]!.count
                return na != nb ? na > nb : a.offset < b.offset
            }.map { Section(title: $0.element, rows: by[$0.element]!) }
        }
    }

    /// A section's counts in words: "4 drafts · 2 clips · 1 voice note · 1 recording".
    static func summary(_ facets: [TapeFacet], rows: [Int]) -> String {
        var n: [String: Int] = [:]
        for i in rows { n[facets[i].kind, default: 0] += 1 }
        return [("typed", "draft", "drafts"), ("copied", "clip", "clips"), ("spoken", "voice note", "voice notes"), ("call", "recording", "recordings")]
            .compactMap { k, one, many in n[k].map { "\($0) \($0 == 1 ? one : many)" } }.joined(separator: " · ")
    }
}

/// What a tag looks like and when it shows (tags round, 17 November 2026). Pure (Foundation).
/// - auto: a name the entity matcher found in the text (person, project, tool, org): a guess, shown quietly and only
///   once it holds `minAuto` items or he pinned it. A site, a folder, a chat and an app are facts.
/// - Prefs: tags he hid (never shown: rows, reader, sidebar) or pinned (always in the sidebar, first); by `key`.
enum TagRules {
    static let minAuto = 3
    static func auto(_ t: TapeTag) -> Bool { ["person", "project", "tool", "org"].contains(t.kind) }
    /// One key per tag: the kind and the name in lower case ("chat" counts as a person).
    static func key(_ t: TapeTag) -> String { (t.kind == "chat" ? "person" : t.kind) + "\t" + t.name.lowercased() }

    struct Prefs: Codable, Equatable {
        var hidden: [String] = []
        var pinned: [String] = []
        init(hidden: [String] = [], pinned: [String] = []) { self.hidden = hidden; self.pinned = pinned }
        init(from d: Decoder) throws {   // a file from a later round with more keys still loads
            let c = try d.container(keyedBy: CodingKeys.self)
            hidden = (try? c.decode([String].self, forKey: .hidden)) ?? []
            pinned = (try? c.decode([String].self, forKey: .pinned)) ?? []
        }
        func isHidden(_ t: TapeTag) -> Bool { hidden.contains(TagRules.key(t)) }
        func isPinned(_ t: TapeTag) -> Bool { pinned.contains(TagRules.key(t)) }
        /// Hide: out of the pinned too. Pin: back from hidden.
        mutating func hide(_ t: TapeTag) { let k = TagRules.key(t); pinned.removeAll { $0 == k }; if !hidden.contains(k) { hidden.append(k) } }
        mutating func pin(_ t: TapeTag, _ on: Bool) {
            let k = TagRules.key(t); hidden.removeAll { $0 == k }; pinned.removeAll { $0 == k }; if on { pinned.append(k) }
        }
        mutating func showAll() { hidden = [] }
    }

    /// The tags a row keeps: the hidden ones dropped.
    static func shown(_ tags: [TapeTag], prefs: Prefs) -> [TapeTag] { prefs.hidden.isEmpty ? tags : tags.filter { !prefs.isHidden($0) } }

    /// May a tag stand on a row or in the reader: a fact, a pinned tag, or a guess with at least `minAuto` items.
    static func sure(_ t: TapeTag, count: Int, prefs: Prefs, minAuto: Int = minAuto) -> Bool {
        if prefs.isHidden(t) { return false }
        return !auto(t) || prefs.isPinned(t) || count >= minAuto
    }

    /// The sidebar's Related to: pinned first (in the order he pinned them), then the others `sure` lets through, by
    /// count, then the newest; at most `top` besides the pinned.
    static func related(_ n: [TapeTag: Int], last: [TapeTag: Double] = [:], prefs: Prefs, top: Int, minAuto: Int = minAuto) -> [(TapeTag, Int)] {
        var pinned: [(TapeTag, Int)] = [], rest: [(TapeTag, Int)] = []
        for (t, c) in n where !prefs.isHidden(t) {
            if prefs.isPinned(t) { pinned.append((t, c)) } else if sure(t, count: c, prefs: prefs, minAuto: minAuto) { rest.append((t, c)) }
        }
        pinned.sort { (prefs.pinned.firstIndex(of: key($0.0)) ?? 0) < (prefs.pinned.firstIndex(of: key($1.0)) ?? 0) }
        rest.sort { a, b in
            a.1 != b.1 ? a.1 > b.1 : (last[a.0] ?? 0) != (last[b.0] ?? 0) ? (last[a.0] ?? 0) > (last[b.0] ?? 0) : a.0.name < b.0.name
        }
        return pinned + rest.prefix(top)
    }

    /// Initials for a person without a picture: the first letters of the first two words ("Mila Synthetic" → "MS"),
    /// one word: its first letter.
    static func initials(_ name: String) -> String {
        let w = name.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).filter { $0.first?.isLetter == true }
        return w.prefix(2).compactMap(\.first).map { String($0).uppercased() }.joined()
    }

    /// A site's address as a tag holds it ("example.org"), checked: letters, digits, dots and dashes, a dot inside,
    /// not a local or bare IP address. nil when it is not one (then no fetch).
    static func host(_ s: String) -> String? {
        let h = s.lowercased().trimmingCharacters(in: .whitespaces)
        guard h.count >= 4, h.count <= 120, h.contains("."), !h.hasPrefix("."), !h.hasSuffix("."),
              h.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "-") }),
              !h.hasSuffix(".local"), !h.hasSuffix(".localhost"), !h.hasSuffix(".internal"),
              h.contains(where: \.isLetter) else { return nil }
        return h
    }
    /// Where a site's icon is asked for, once, from the site itself (no third-party icon service).
    static func faviconURLs(_ host: String) -> [URL] {
        ["https://\(host)/favicon.ico", "https://\(host)/apple-touch-icon.png"].compactMap(URL.init(string:))
    }
    /// What a site tag opens: the item's own link when it is on that site, else the site.
    static func open(_ t: TapeTag, link: String?) -> URL? {
        guard t.kind == "site", let h = host(t.name) else { return nil }
        if let l = link, let u = URL(string: l.trimmingCharacters(in: .whitespacesAndNewlines)), ["http", "https"].contains(u.scheme ?? ""),
           let uh = u.host?.lowercased(), uh == h || uh == "www." + h { return u }
        return URL(string: "https://" + h)
    }
}

// The one `;` picker (17 November 2026, docs/plans/2026-11-17-spec.md "Cut, merge, fix"), pure: no AppKit. Snippets,
// quick starts, lookups, people and other cards in one list with a label on each row; Right ⌘ twice opens it with an
// empty query, `;` + 2 letters in a field opens it with what the user typed. The panel and its sources: app/Commands.swift.
// Test: tests/command_rules.swift.
import Foundation

enum CommandKind: String, CaseIterable {
    case snippet, preset, lookup, person, card
    case action              // something Drafter does itself: meeting notes (`;meet`, `;notes`, app/MeetingNotes.swift)
}

struct CommandItem: Equatable {
    let kind: CommandKind
    let key: String          // the trigger (";sig", ";meet", ";docs") or, for people and cards, "" (found by name)
    let title: String        // what the row says first: the snippet's text, the quick start's title, the person's name
    var detail = ""          // the grey end of the row: a host, a company
    var on = true            // off: shown with "off", picking it says how to turn it on
    var ref = ""             // what the pick needs: a snippet key, a url, a lookup kind, a record index
}

enum CommandRules {
    /// Rows shown at most.
    static let most = 8

    /// Hidden aliases: a typed key that means another one when nothing owns it exactly. `;doc` is the new-doc quick
    /// start when one exists; otherwise it means the `;docs` lookup. `;e` means `;en`, `;u` `;uk` (translate, when a
    /// translate item exists).
    static let aliases: [String: String] = [";doc": ";docs", ";e": ";en", ";u": ";uk", ";notes": ";meet"]

    /// Row labels in the field's language: Ukrainian when the keyboard is Ukrainian or the line is in Cyrillic.
    static func label(_ k: CommandKind, uk: Bool) -> String {
        switch k {
        case .snippet: return uk ? "заготовка" : "snippet"
        case .preset: return uk ? "відкрити" : "open"
        case .lookup: return uk ? "пошук" : "search"
        case .person: return uk ? "людина" : "person"
        case .card: return uk ? "картка" : "card"
        case .action: return uk ? "почати" : "start"
        }
    }
    static func offWord(uk: Bool) -> String { uk ? "вимкнено" : "off" }
    static func emptyWord(uk: Bool) -> String { uk ? "нічого не знайдено" : "nothing found" }

    /// true when the line reads as Ukrainian: more Cyrillic letters than Latin ones in its last 40 characters.
    static func cyrillic(_ line: String) -> Bool {
        var cy = 0, la = 0
        for u in line.suffix(40).unicodeScalars where CharacterSet.letters.contains(u) {
            if (0x0400...0x04FF).contains(u.value) { cy += 1 } else if u.isASCII { la += 1 }
        }
        return cy > la
    }

    /// What the user typed in a field: `;` after a space or the line start, a letter, then 1-29 more. nil = not a picker query.
    /// `old` is what a pick takes out of the field; `query` has no `;`.
    static func typed(_ before: String) -> (old: String, query: String)? {
        let line = before.components(separatedBy: "\n").last ?? ""
        guard let m = rx.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
              let o = Range(m.range(at: 1), in: line), let q = Range(m.range(at: 2), in: line) else { return nil }
        return (String(line[o]), String(line[q]))
    }
    private static let rx = try! NSRegularExpression(pattern: #"(?:^|[\s(\[«"'])(;([\p{L}][\p{L}\p{N}'’ʼ._-]{1,29}))$"#)

    /// The rows for a query, best first: an exact key (or its alias), then a key that starts with it, then a title
    /// word that starts with it, then a title holding it. On rows before off rows of the same rank; else list order.
    /// An empty query: every row, list order, cut at `most`.
    static func filter(_ items: [CommandItem], _ query: String) -> [CommandItem] {
        let q = query.lowercased().trimmingCharacters(in: .whitespaces)
        let bare = q.hasPrefix(";") ? String(q.dropFirst()) : q
        if bare.isEmpty { return Array(items.prefix(most)) }
        let key = ";" + bare
        let ownsExact = items.contains { $0.key.lowercased() == key }
        let alias = ownsExact ? nil : aliases[key]
        func rank(_ it: CommandItem) -> Int? {
            let k = it.key.lowercased(), t = it.title.lowercased()
            if !k.isEmpty && (k == key || k == alias) { return 0 }
            if !k.isEmpty && k.hasPrefix(key) { return 1 }
            let words = t.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
            if words.contains(where: { $0.hasPrefix(bare) }) { return 2 }
            if t.contains(bare) || (!k.isEmpty && k.contains(bare)) { return 3 }
            return nil
        }
        let scored = items.enumerated().compactMap { i, it in rank(it).map { (r: $0, off: it.on ? 0 : 1, i: i, it: it) } }
        return scored.sorted { ($0.r, $0.off, $0.i) < ($1.r, $1.off, $1.i) }.prefix(most).map(\.it)
    }

    /// Voice mode rows (research item 3): `;mode` lists Raw, Clean, Polished and the user's named modes; a pick sets the voice
    /// mode for the app in front (Talk.pickMode). `current`: the name in use there, marked "now".
    static func voiceModeRows(modes: [String], current: String, uk: Bool) -> [CommandItem] {
        let names = ["Raw", "Clean", "Polished"] + modes.sorted()
        return names.map { n in
            let slug = n.lowercased().replacingOccurrences(of: " ", with: "-")
            let detail = n.lowercased() == current.lowercased() ? (uk ? "зараз" : "now") : (["Raw", "Clean", "Polished"].contains(n) ? (uk ? "голос" : "voice") : (uk ? "мій режим" : "my mode"))
            return CommandItem(kind: .action, key: ";mode-" + slug, title: (uk ? "Режим голосу: " : "Voice mode: ") + n, detail: detail, ref: "voice-mode:" + n)
        }
    }

    /// Ready `;free` rows (availability round 2): `;fr`… also offers the lookup with a day and a length already set, in
    /// the field's language; a pick types the key and the `;free` lookup runs as typed (engine/lookup.py reads
    /// "30 tomorrow", "60 next week"). Nothing for other queries or an empty one.
    static let freeVariants: [(key: String, uk: String, en: String)] = [
        (";free 30 tomorrow", "Вільний час: завтра, 30 хв", "Free times: tomorrow, 30 min"),
        (";free 30 this week", "Вільний час: цей тиждень, 30 хв", "Free times: this week, 30 min"),
        (";free 30 next week", "Вільний час: наступний тиждень, 30 хв", "Free times: next week, 30 min"),
        (";free 60 next week", "Вільний час: наступний тиждень, 1 год", "Free times: next week, 1 hour"),
    ]
    static func freeRows(_ query: String, uk: Bool, on: Bool) -> [CommandItem] {
        let q = query.lowercased().trimmingCharacters(in: .whitespaces)
        let bare = q.hasPrefix(";") ? String(q.dropFirst()) : q
        guard bare.count >= 2, "free".hasPrefix(bare) || bare.hasPrefix("free") else { return [] }
        return freeVariants.map { CommandItem(kind: .lookup, key: $0.key, title: uk ? $0.uk : $0.en, on: on, ref: ";free") }
    }

    /// One row's first line as it shows: no line breaks, at most 60 characters.
    static func short(_ s: String, _ n: Int = 60) -> String {
        let one = s.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        return one.count > n ? String(one.prefix(n - 1)) + "…" : one
    }
}

/// Right ⌘ twice (coordinator rules, 17 November 2026): Right ⌘ only (keycode 54); each tap under 0.25 s; the second
/// press within 0.35 s of the first release; no other key, click or modifier between or during the taps; never while a
/// mouse button is down (a ⌘-drag). The caller feeds every event; `fire` is true on the release that completes it.
struct RightCommandTaps {
    static let tapMost = 0.25, gapMost = 0.35
    private var down: Double?       // the current press, when clean
    private var firstUp: Double?    // the first clean tap's release

    /// Right ⌘ went down or up. `others` = another modifier is held; `mouse` = a mouse button is down.
    mutating func rightCommand(down isDown: Bool, at t: Double, others: Bool, mouse: Bool) -> Bool {
        if others || mouse { reset(); return false }
        if isDown {
            if let u = firstUp, t - u > Self.gapMost { firstUp = nil }
            down = t; return false
        }
        guard let d = down, t - d < Self.tapMost else { reset(); return false }
        down = nil
        if firstUp != nil { firstUp = nil; return true }
        firstUp = t; return false
    }

    /// Any other event (a key, a click, another modifier): the taps start over.
    mutating func other() { reset() }
    private mutating func reset() { down = nil; firstUp = nil }
}

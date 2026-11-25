// Reader check before sending (roadmap item 4, 17 November 2026; docs/rounds/2026-11-17-reader.md): when to ask the
// engine's `/reader` for a last look at a chat message, and what the one chip says. Pure, so it compiles alone in tests.
// It never holds or delays Enter, never sends, never edits by itself: the chip is shown only when the answer comes
// before his next key, and any key but Tab drops it (Keys: any other key drops the ghost and goes to the app).
import Foundation

enum ReaderRules {
    static let marker = "⟦drafter-test⟧"
    static let budget = 1.0          // an answer later than this is not shown (he may be pressing Enter by then)
    static let rest = 1.0            // a pause this long after 3+ words counts as finished
    static let ended = 0.15          // after . ! ? … : almost at once

    /// The reader runs in chat boxes, and in a field holding the test marker (the live check, any app).
    static func applies(kind: String, value: String) -> Bool { kind == "chat" || value.contains(marker) }

    /// Seconds to wait before asking, or nil (too short to be a message yet). `text` is the message so far.
    static func wait(_ text: String) -> Double? {
        let body = text.replacingOccurrences(of: marker, with: "")
        let t = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.split(whereSeparator: { $0.isWhitespace }).count >= 3 else { return nil }
        var s = Substring(t)
        while let c = s.last, "\"'»”)".contains(c) { s = s.dropLast() }
        return s.last.map { ".!?…".contains($0) } == true ? ended : rest
    }

    /// The text the engine checks: the message without the test marker (offsets stay in the field's own text, so a
    /// marker is only allowed at the very start of the message).
    static func message(_ span: String) -> (text: String, offset: Int)? {
        guard let r = span.range(of: marker) else { return (span, 0) }
        guard r.lowerBound == span.startIndex else { return nil }
        var rest = span[r.upperBound...]
        while let c = rest.first, c == " " { rest = rest.dropFirst() }
        return (String(rest), (span as NSString).length - (String(rest) as NSString).length)
    }

    /// In a test field, lines above the message that start with "Вони: " or "Я: " stand in for the chat on screen.
    static func testContext(_ before: String, span: String) -> String {
        guard before.contains(marker), before.hasSuffix(span) else { return "" }
        let above = before.dropLast(span.count)
        return above.split(separator: "\n").map(String.init).filter { $0.hasPrefix("Вони: ") || $0.hasPrefix("Я: ") }.joined(separator: "\n")
    }

    struct Edit: Equatable { let at: Int; let len: Int; let old: String; let new: String }

    /// Fixes the Mac does not call right already: a one-word fix of a word the spellchecker knows is dropped (as
    /// app/Fixer.swift does); splits and joins stay (the engine checked them against his own word pairs).
    static func keep(_ e: Edit, known: (String) -> Bool) -> Bool {
        if e.old.contains(" ") || e.new.contains(" ") { return true }
        return !known(e.old)
    }

    /// The edits moved by `offset` UTF-16 units (the marker in a test field).
    static func shifted(_ es: [Edit], by offset: Int) -> [Edit] { es.map { Edit(at: $0.at + offset, len: $0.len, old: $0.old, new: $0.new) } }

    /// The chip, or nil when there is nothing to say. Fixes first (Tab puts them in), then the open question.
    static func label(_ es: [Edit], ask: String) -> String? {
        var parts: [String] = []
        if !es.isEmpty { parts.append("⇥ Fix \(es.count) · " + es.map { "\($0.old) → \($0.new)" }.joined(separator: ", ")) }
        if !ask.isEmpty { parts.append("↩ " + ask) }
        guard !parts.isEmpty else { return nil }
        let s = parts.joined(separator: " · ")
        return s.count > 70 ? String(s.prefix(68)) + "…" : s
    }

    /// Still worth showing: no key since the ask, the same field text, within the budget.
    static func fresh(sentSeq: Int, nowSeq: Int, sentBefore: String, nowBefore: String, elapsed: Double) -> Bool {
        sentSeq == nowSeq && sentBefore == nowBefore && elapsed <= budget
    }
}

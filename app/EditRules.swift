// Edit mode (roadmap item 8, "side cursors"; 17 November 2026, docs/rounds/2026-11-17-editing.md; setting `editMarks`).
// When the user edits rather than writes (a selection of 20+ characters, or the caret moved inside a 40+ character field and
// no letter typed for 1.5 s), the paragraph goes to the engine's `/marks` (engine/marks.py, local, no model). Each mark
// is a place where one key applies a fix: Tab or a click puts its new text in, Esc puts it away (twice: all of them).
// ⌥⇧Tab (or the "my style" pill) asks `/mystyle` for the paragraph in the user's own voice from the local model.
// Pure, so it compiles alone in tests (tests/edit_rules.swift); the UI is app/EditMarks.swift.
import Foundation

enum EditRules {
    static let marker = "⟦drafter-test⟧"
    static let minSelection = 20     // UTF-16 units selected before a selection counts as "a paragraph to look at"
    static let minField = 40         // a field this long, caret not at its end: the user is editing, not writing on
    static let rest = 1.5            // seconds after the last move with no letter typed
    static let maxSpan = 3000        // the engine looks at this much at most
    static let escTwice = 0.6        // a second Esc within this: every mark goes

    enum Trigger: String { case selection, editing }

    /// The text to look at, and where it starts in the field's value (UTF-16).
    struct Span: Equatable { let text: String; let offset: Int; let trigger: Trigger }

    /// Edit mode may start here: setting on, no secure input, not a password field, not a skipped app.
    static func allowed(on: Bool, secure: Bool, password: Bool, skipped: Bool) -> Bool { on && !secure && !password && !skipped }

    /// Due to look: the last move (click, arrow, delete) came after the last letter, and `rest` seconds have passed.
    static func due(lastMove: Double?, lastLetter: Double?, now: Double) -> Bool {
        guard let m = lastMove else { return false }
        if let l = lastLetter, l >= m { return false }
        return now - m >= rest
    }

    /// Which text to send. `value` is the whole field, `caret`/`selLen` its selected range (UTF-16).
    /// A selection of `minSelection`+ wins; else the caret's paragraph (between line breaks) when the field is
    /// `minField`+ long and the caret is not at its end. nil: nothing to look at.
    static func span(value: String, caret: Int, selLen: Int) -> Span? {
        let ns = value as NSString
        guard caret >= 0, caret + max(selLen, 0) <= ns.length else { return nil }
        if selLen >= minSelection {
            let t = ns.substring(with: NSRange(location: caret, length: min(selLen, maxSpan)))
            return t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : Span(text: t, offset: caret, trigger: .selection)
        }
        guard selLen == 0, ns.length >= minField else { return nil }
        // the caret at the end (only spaces or line breaks after it): the user is writing on, not editing
        if ns.substring(from: caret).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return nil }
        let (t, at) = paragraph(value, caret: caret)
        let body = t.replacingOccurrences(of: marker, with: "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard (body as NSString).length >= minSelection else { return nil }
        return Span(text: t, offset: at, trigger: .editing)
    }

    /// The line (paragraph) holding the caret, and its start (UTF-16).
    static func paragraph(_ value: String, caret: Int) -> (String, Int) {
        let ns = value as NSString
        let c = min(max(caret, 0), ns.length)
        var start = ns.range(of: "\n", options: .backwards, range: NSRange(location: 0, length: c)).location
        start = start == NSNotFound ? 0 : start + 1
        var end = ns.range(of: "\n", options: [], range: NSRange(location: c, length: ns.length - c)).location
        if end == NSNotFound { end = ns.length }
        if end - start > maxSpan {   // a huge line: the part around the caret
            let lo = max(start, c - maxSpan / 2)
            return (ns.substring(with: NSRange(location: lo, length: min(maxSpan, end - lo))), lo)
        }
        return (ns.substring(with: NSRange(location: start, length: end - start)), start)
    }

    /// The test marker at the start of a span is not text to check: cut it, offset moved past it.
    static func trimmed(_ s: Span) -> Span {
        guard s.text.hasPrefix(marker) else { return s }
        var rest = Substring(s.text.dropFirst(marker.count))
        while rest.first == " " { rest = rest.dropFirst() }
        let r = String(rest)
        return Span(text: r, offset: s.offset + (s.text as NSString).length - (r as NSString).length, trigger: s.trigger)
    }

    struct Mark: Equatable {
        var at: Int, len: Int          // UTF-16, in the field's value once placed
        let old: String, new: String, kind: String, why: String
    }

    /// Engine marks (offsets into the span) moved into the field (span start + at), in reading order; a mark that does
    /// not match the span's own text is dropped.
    static func place(_ ms: [Mark], in span: Span) -> [Mark] {
        let ns = span.text as NSString
        return ms.compactMap { m -> Mark? in
            guard m.at >= 0, m.len >= 0, m.at + m.len <= ns.length, ns.substring(with: NSRange(location: m.at, length: m.len)) == m.old else { return nil }
            var p = m; p.at += span.offset; return p
        }.sorted { $0.at < $1.at }
    }

    /// The marks left after `done` was applied: it goes, those after it move by the change in length.
    static func after(applying done: Mark, _ ms: [Mark]) -> [Mark] {
        let d = (done.new as NSString).length - done.len
        return ms.filter { $0 != done }.compactMap { m in
            if m.at >= done.at + done.len { var p = m; p.at += d; return p }
            if m.at + m.len <= done.at { return m }
            return nil   // overlapped it (the engine sends none; kept safe)
        }
    }

    /// Tab: the mark the caret is in (or touches), else the hovered one, else the shown one, else the first after the
    /// caret, else the first. nil only with no marks.
    static func tabTarget(_ ms: [Mark], caret: Int?, hovered: Int?, shown: Int?) -> Int? {
        guard !ms.isEmpty else { return nil }
        if let c = caret, let i = ms.firstIndex(where: { c >= $0.at && c <= $0.at + $0.len }) { return i }
        if let h = hovered, ms.indices.contains(h) { return h }
        if let s = shown, ms.indices.contains(s) { return s }
        if let c = caret, let i = ms.firstIndex(where: { $0.at >= c }) { return i }
        return 0
    }

    enum Esc: Equatable { case dismiss(Int), all, pass }

    /// Esc: with a chip shown, that mark goes (the key is ours); again within `escTwice`, every mark goes. With no chip
    /// up, the marks go and the Esc still reaches the app (`pass`; the caller clears them).
    static func esc(shown: Int?, sinceLastEsc: Double?) -> Esc {
        if let t = sinceLastEsc, t <= escTwice { return .all }
        if let s = shown { return .dismiss(s) }
        return .pass
    }

    /// The chip: "old → new · why", or "remove «old»" for an empty new text; at most 80 characters.
    static func label(_ m: Mark) -> String {
        func cut(_ s: String, _ n: Int) -> String { s.count > n ? String(s.prefix(n - 1)) + "…" : s }
        let what = m.new.isEmpty ? "remove «\(cut(m.old.trimmingCharacters(in: .whitespaces), 20))»"
                                 : "\(cut(m.old, 24)) → \(cut(m.new, 24))"
        return cut(what + (m.why.isEmpty ? "" : " · " + m.why), 80)
    }

    /// The "my style" pill and its answer.
    static let styleLabel = "Rewrite in my style ⌥⇧Tab"
    static func styleResult(_ text: String) -> String {
        let one = text.replacingOccurrences(of: "\n", with: " ")
        return "⇥ " + (one.count > 76 ? String(one.prefix(75)) + "…" : one)
    }

    /// A key that ends edit mode: a letter or a line break typed (the user is writing again). Arrows, Tab, Esc, shift and
    /// command keys do not.
    static func writes(code: Int, typed: String, command: Bool) -> Bool {
        if command { return false }
        if [36, 76].contains(code) { return true }
        return typed.unicodeScalars.contains { $0.value >= 0x20 && $0.value != 0x7F && !(0xF700...0xF8FF).contains($0.value) }
    }

    /// A key that moves the caret or deletes: the start of an editing rest (arrows, Home, End, Page keys, delete).
    static func moves(code: Int) -> Bool { [51, 117, 123, 124, 125, 126, 115, 119, 116, 121].contains(code) }
}

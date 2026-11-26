// The pause rewrite (17 November 2026, the user's design; setting `pauseRewrite`, off, cloud mark): when to offer Claude's
// rewrite of the paragraph before the caret, what the chip says and which words it marks. Pure, so it compiles alone
// in tests (tests/pause_rewrite_rules.swift). The engine side is engine/pause_rewrite.py; the app side app/PauseRewrite.swift.
// Numbers from docs/research/2026-11-17-claude-writer.md (made-up lines): Haiku answers a rewrite of this size in
// ~0.8 s p50, so a 1.5 s rest shows the chip ~2.3 s after the user's last key, after the user has stopped, not while the user types.
import Foundation

enum PauseRewriteRules {
    static let marker = "⟦drafter-test⟧"
    static let pause = 1.5           // seconds with no key before Claude is asked (the user's starting point; the numbers keep it)
    static let budget = 8.0          // an answer later than this is not shown: the user has moved on
    static let minWords = 6          // engine/pause_rewrite.py MIN_WORDS
    static let maxChars = 800        // the span (app/Proof.swift span) and engine/pause_rewrite.py MAX_CHARS
    static let chipChars = 280       // the chip shows at most this much of the rewrite, in up to 3 lines
    static let loading = "◌ rewriting…"

    /// Where a chip may appear at all: the switch on, a caret at a line end, no secure input, not a skipped app, not a
    /// password field (Focus.spot already gives no spot there; checked again here, AGENTS.md "Never").
    static func allowed(on: Bool, secure: Bool, skipped: Bool, password: Bool, mid: Bool) -> Bool {
        on && !secure && !skipped && !password && !mid
    }

    /// The part to rewrite: the span without the test marker, and where it starts in the span (UTF-16 units).
    /// nil: a marker that is not at the very start (offsets would not hold).
    static func message(_ span: String) -> (text: String, offset: Int)? {
        guard let r = span.range(of: marker) else { return (span, 0) }
        guard r.lowerBound == span.startIndex else { return nil }
        var rest = span[r.upperBound...]
        while let c = rest.first, c == " " { rest = rest.dropFirst() }
        return (String(rest), (span as NSString).length - (String(rest) as NSString).length)
    }

    static func words(_ s: Substring) -> Int { s.split(whereSeparator: { $0.isWhitespace }).count }

    /// Worth asking: 6+ words, at most 800 characters, and a finished sentence of 3+ words of its own (the engine
    /// checks the same; this one only saves the request).
    static func ready(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard words(Substring(t)) >= minWords, (t as NSString).length <= maxChars else { return false }
        var start = t.startIndex, i = t.startIndex
        while i < t.endIndex {
            let c = t[i], next = t.index(after: i)
            if ".!?…".contains(c), i > t.startIndex, !t[t.index(before: i)].isWhitespace,
               next == t.endIndex || t[next].isWhitespace || "\"'»”)".contains(t[next]) {
                if words(t[start...i]) >= 3 { return true }
                start = next
            }
            i = next
        }
        return false
    }

    /// The chip: the rewrite (cut at chipChars with "…") and the changed words as NSRanges in it. `marks` are
    /// [start, length] pairs in UTF-16 units of the rewrite (engine/pause_rewrite.py marks); ones past the cut are dropped.
    static func label(_ new: String, marks: [[Int]]) -> (text: String, marks: [NSRange]) {
        let ns = new as NSString
        var text = new, limit = ns.length
        if new.count > chipChars {
            let cut = String(new.prefix(chipChars - 1))
            limit = (cut as NSString).length
            text = cut + "…"
        }
        let ranges = marks.compactMap { m -> NSRange? in
            guard m.count == 2, m[0] >= 0, m[1] > 0, m[0] + m[1] <= limit else { return nil }
            return NSRange(location: m[0], length: m[1])
        }
        return (text, ranges)
    }

    /// Still worth showing: no key since the ask, the same text before the caret, within the budget.
    static func fresh(sentSeq: Int, nowSeq: Int, sentBefore: String, nowBefore: String, elapsed: Double) -> Bool {
        sentSeq == nowSeq && sentBefore == nowBefore && elapsed <= budget
    }

    static func norm(_ s: String) -> String { s.replacingOccurrences(of: "\u{A0}", with: " ") }

    /// Tab may put it in: the field still ends with the text that was rewritten.
    static func stillEnds(before: String, text: String) -> Bool {
        let t = norm(text)
        return !t.isEmpty && norm(before).hasSuffix(t)
    }
}

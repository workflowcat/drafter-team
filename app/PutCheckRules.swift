// After a voice paste: did the text land in the field? (17 November 2026)
// The old check looked for the text's last 40 characters in the field's Accessibility value. In Claude and Codex
// (Electron) that missed 81% and 86% of pastes that did land, so the take also went to the clipboard and the strip said
// "Could not see it in the field". Here: whitespace and quote forms do not count, a field that grew by about the text
// counts, an Electron field that reads empty or unchanged counts (its tree lags the page), and only what is left after
// two checks is a miss: a native field that did not change, or a field that changed without the text. A miss after a
// paste only goes to the log: no pill, no clipboard (outcome). Pure: no AppKit, no Accessibility.

enum PutCheckRules {
    enum Verdict: String { case seen, grew, unreadable, stale, miss }

    /// Text as a field may give it back: no whitespace of any kind (NBSP, zero width, line and paragraph breaks), no
    /// embedded-object marks, curly quotes and long dashes as plain ones.
    static func squash(_ s: String) -> String {
        var out = ""
        out.unicodeScalars.reserveCapacity(s.unicodeScalars.count)
        for u in s.unicodeScalars {
            if u.properties.isWhitespace || [0x200B, 0x200C, 0x200D, 0x2060, 0xFEFF, 0xFFFC].contains(u.value) { continue }
            switch u.value {
            case 0x2018, 0x2019, 0x02BC: out.unicodeScalars.append("'")
            case 0x201C, 0x201D, 0x00AB, 0x00BB: out.unicodeScalars.append("\"")
            case 0x2013, 0x2014: out.unicodeScalars.append("-")
            default: out.unicodeScalars.append(u)
            }
        }
        return out
    }

    /// One check. `before`: the field's value read before the paste (nil: not read). `after`: read now (nil: no field).
    /// `web`: an Electron or Chromium app, which takes a paste (Focus.isWeb).
    static func verdict(text: String, before: String?, after: String?, web: Bool) -> Verdict {
        let t = squash(text)
        if t.isEmpty { return .seen }
        guard let after else { return .unreadable }
        let a = squash(after)
        if a.contains(String(t.suffix(24))) { return .seen }
        if let before {
            let grown = a.count - squash(before).count
            if grown >= max(1, t.count * 6 / 10) { return .grew }
        }
        // empty: an Electron field that does not give its value, or a message he already sent (Return empties the box)
        if a.isEmpty { return .unreadable }
        // Chromium's Accessibility tree can lag the page: the same value as before the paste is a stale read there, not
        // a miss (the paste went to a focused text field; it was checked before the paste).
        if web, let before, squash(before) == a { return .stale }
        return .miss
    }

    /// A miss is read again once (the second read waits for a slow Electron tree); either way it only goes to the log.
    static func needsSecondCheck(_ v: Verdict) -> Bool { v == .miss }
    static func landed(_ v: Verdict) -> Bool { v != .miss }

    /// Per app and verdict, for the log: "voice put: com.x seen 12 grew 3 unreadable 1 miss 1 (6% miss)".
    typealias Tally = [String: [Verdict: Int]]
    static func count(_ t: inout Tally, app: String, _ v: Verdict) -> String {
        let id = app.isEmpty ? "?" : app
        t[id, default: [:]][v, default: 0] += 1
        let c = t[id]!
        let n = c.values.reduce(0, +), miss = c[.miss] ?? 0
        let parts = [Verdict.seen, .grew, .unreadable, .stale, .miss].map { "\($0.rawValue) \(c[$0] ?? 0)" }.joined(separator: " ")
        return "voice put: \(id) \(parts) (\(n == 0 ? 0 : miss * 100 / n)% miss)"
    }

    /// What he sees after a voice put (17 November 2026, Andrii: "just remove this note, it's always happening").
    /// `notPutWhy` nil: the paste went to a focused text field, so no pill and no clipboard, whatever the read-back says
    /// (the take stays in History). Else a real miss (no field, secure input, a skipped app, a password field): the text
    /// goes to the clipboard and the strip says why, with "⌘V to paste".
    enum Outcome: Equatable { case quiet, clipboard(String) }
    static func outcome(notPutWhy: String?) -> Outcome {
        guard let why = notPutWhy, !why.isEmpty else { return .quiet }
        return .clipboard(why + " · ⌘V to paste")
    }

    /// The log line when the read-back could not find the text (counts and the app only).
    static func unsureLine(app: String) -> String { "voice flow: put in, read-back unsure (\(app.isEmpty ? "?" : app))" }

    /// Numbers only, for the log: the lengths and which test passed. Never the text.
    static func detail(text: String, before: String?, after: String?) -> String {
        let t = squash(text), a = after.map(squash), b = before.map(squash)
        let tail = a.map { $0.contains(String(t.suffix(24))) } ?? false
        let short = a.map { $0.contains(String(t.suffix(8))) } ?? false
        return "text \(t.count) before \(b.map { String($0.count) } ?? "-") after \(a.map { String($0.count) } ?? "-")"
            + " tail24 \(tail ? 1 : 0) tail8 \(short ? 1 : 0) same \(a != nil && a == b ? 1 : 0)"
    }
}

import Foundation

/// Synonyms in the ⌥Tab list (2026-11-15, engine/synonyms.py): which selections ask for them and which row a digit
/// picks. Pure, no AppKit; tests/synonym_rules.swift.
///
/// With synonyms shown, rows are: synonyms (1...S), then the commands (S+1...), then "type what to do". A digit picks
/// the row with that number; commands past 9 are reached with the arrows. Without synonyms nothing changes: 1-7 are
/// the commands as before.
enum SynonymRules {
    static let maxWords = 3, maxChars = 40, maxShown = 6

    /// One word or a 2-3 word phrase of letters (an apostrophe or hyphen inside is fine): no digits, no line breaks.
    static func asks(_ selection: String) -> Bool {
        let t = selection.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: ".,;:!?…)»\""))
        guard !t.isEmpty, t.count <= maxChars, !t.contains("\n") else { return false }
        let words = t.split(separator: " ", omittingEmptySubsequences: true)
        guard words.count <= maxWords else { return false }
        return t.unicodeScalars.allSatisfy { CharacterSet.letters.contains($0) || " '’-".unicodeScalars.contains($0) }
            && t.unicodeScalars.contains { CharacterSet.letters.contains($0) }
    }

    enum Pick: Equatable { case synonym(Int), command(Int) }

    /// Row `row` (0-based, synonyms first) -> what it is; nil for the "type what to do" row or past it.
    static func row(_ row: Int, synonyms: Int, commands: Int) -> Pick? {
        if row < 0 { return nil }
        if row < synonyms { return .synonym(row) }
        if row < synonyms + commands { return .command(row - synonyms) }
        return nil
    }

    /// Digit 1-9 -> the row with that number.
    static func digit(_ d: Int, synonyms: Int, commands: Int) -> Pick? {
        guard (1...9).contains(d) else { return nil }
        return row(d - 1, synonyms: synonyms, commands: commands)
    }

    /// The number drawn on a row (1-9), or nil past 9.
    static func label(_ row: Int) -> String? { row < 9 ? "\(row + 1)" : nil }

    /// The log line for one use: numbers only, never the words. picked: 1-based, 0 = none taken.
    static func logLine(shown: Int, picked: Int, ms: Int) -> String { "synonyms: shown \(shown), picked \(picked), \(ms) ms" }
}

// The keyboard error model of the ranked typo fix (app/TypoRules.swift, part c), pure. What a slip costs depends on
// what it is: a neighbour key on the layout he was typing on, two letters swapped, a doubled or dropped double letter,
// a missing or extra letter, the other apostrophe, і/ї/є/ґ for their plain twins. Costs are rough minus-log odds
// (lower = more likely); the round notes say where they came from.
import Foundation

struct TypoKeyboard {
    /// ABC rows; Ukrainian-PC sits on the same keys (app/Layout.swift reads both from macOS; engine/words.py TO_UK).
    static let enRows = ["`1234567890-=", "qwertyuiop[]", "asdfghjkl;'", "zxcvbnm,./"]
    static let ukOf: [Character: Character] = Dictionary(uniqueKeysWithValues: zip("`qwertyuiop[]asdfghjkl;'zxcvbnm,./", "'йцукенгшщзхїфівапролджєячсмитьбю."))
    static let stagger: [Double] = [0, 0.5, 0.75, 1.25]
    let pos: [Character: (Double, Double)]

    /// `toUk`: the live map from KeyLayout.maps when the app has it; the fixed map otherwise.
    init(toUk: [Character: Character] = TypoKeyboard.ukOf) {
        var p: [Character: (Double, Double)] = [:]
        for (r, row) in Self.enRows.enumerated() {
            for (c, ch) in row.enumerated() {
                let at = (Double(r), Double(c) + Self.stagger[r])
                p[ch] = at
                if let u = toUk[ch] ?? Self.ukOf[ch], p[u] == nil { p[u] = at }
            }
        }
        pos = p
    }

    func near(_ a: Character, _ b: Character) -> Bool {
        guard let x = pos[a], let y = pos[b], a != b else { return false }
        let dr = x.0 - y.0, dc = x.1 - y.1
        return dr * dr + dc * dc <= 1.6
    }

    static let twins: [Set<Character>] = [["і", "ї"], ["е", "є"], ["г", "ґ"], ["и", "і"], ["'", "’"], ["'", "ʼ"], ["’", "ʼ"]]
    static func twin(_ a: Character, _ b: Character) -> Bool { twins.contains { $0.contains(a) && $0.contains(b) } }
    static func apostrophe(_ c: Character) -> Bool { TypoRules.apostrophes.contains(c) }

    // edit costs
    static let swap = 0.9, nearKey = 1.0, farKey = 2.4, twinCost = 0.4, apostropheCost = 0.1
    static let doubled = 0.7, extraNear = 1.1, extraFar = 2.2, extraApostrophe = 0.3
    static let droppedDouble = 0.7, missing = 1.4, missingApostrophe = 0.2, firstLetter = 0.9

    func sub(_ t: Character, _ w: Character) -> Double {
        if t == w { return 0 }
        if Self.apostrophe(t) && Self.apostrophe(w) { return Self.apostropheCost }
        if Self.twin(t, w) { return Self.twinCost }
        return near(t, w) ? Self.nearKey : Self.farKey
    }

    /// Cost of an extra letter typo[i] that the word does not have.
    func extra(_ t: [Character], _ i: Int) -> Double {
        let c = t[i]
        if Self.apostrophe(c) { return Self.extraApostrophe }
        if (i > 0 && t[i - 1] == c) || (i + 1 < t.count && t[i + 1] == c) { return Self.doubled }
        if (i > 0 && near(t[i - 1], c)) || (i + 1 < t.count && near(t[i + 1], c)) { return Self.extraNear }
        return Self.extraFar
    }

    /// Cost of the word's letter w[j] missing from the typo.
    func missing(_ w: [Character], _ j: Int) -> Double {
        let c = w[j]
        if Self.apostrophe(c) { return Self.missingApostrophe }
        if (j > 0 && w[j - 1] == c) || (j + 1 < w.count && w[j + 1] == c) { return Self.droppedDouble }
        return Self.missing
    }

    /// Weighted Damerau (optimal string alignment) cost of typing `word` as `typo`.
    func cost(_ typo: String, _ word: String) -> Double {
        let t = Array(typo), w = Array(word)
        if t.isEmpty || w.isEmpty { return Double(max(t.count, w.count)) * Self.missing }
        var d = [[Double]](repeating: [Double](repeating: 0, count: w.count + 1), count: t.count + 1)
        for i in 1...t.count { d[i][0] = d[i - 1][0] + extra(t, i - 1) }
        for j in 1...w.count { d[0][j] = d[0][j - 1] + missing(w, j - 1) }
        for i in 1...t.count {
            for j in 1...w.count {
                var v = min(d[i - 1][j] + extra(t, i - 1), d[i][j - 1] + missing(w, j - 1), d[i - 1][j - 1] + sub(t[i - 1], w[j - 1]))
                if i > 1, j > 1, t[i - 1] == w[j - 2], t[i - 2] == w[j - 1], t[i - 1] != t[i - 2] { v = min(v, d[i - 2][j - 2] + Self.swap) }
                d[i][j] = v
            }
        }
        var total = d[t.count][w.count]
        if let a = t.first, let b = w.first, a != b, !Self.twin(a, b) { total += Self.firstLetter }
        return total
    }

    /// The kind of a one-edit slip, for logs and reports: swap, neighbour, wrong key, doubled, extra, dropped double,
    /// missing, apostrophe, letter twin; "2 edits" or "other" beyond that.
    func kind(_ typo: String, _ word: String) -> String {
        let t = Array(typo), w = Array(word)
        if t == w { return "same" }
        if t.count == w.count {
            let diff = (0..<t.count).filter { t[$0] != w[$0] }
            if diff.count == 2, diff[1] == diff[0] + 1, t[diff[0]] == w[diff[1]], t[diff[1]] == w[diff[0]] { return "swap" }
            if diff.count == 1 {
                let (a, b) = (t[diff[0]], w[diff[0]])
                if Self.apostrophe(a) && Self.apostrophe(b) { return "apostrophe" }
                if Self.twin(a, b) { return "letter twin" }
                return near(a, b) ? "neighbour" : "wrong key"
            }
            return "2 edits"
        }
        if t.count == w.count + 1, let i = (0..<t.count).first(where: { Array(t[..<$0] + t[($0 + 1)...]) == w }) {
            if Self.apostrophe(t[i]) { return "apostrophe" }
            return (i > 0 && t[i - 1] == t[i]) || (i + 1 < t.count && t[i + 1] == t[i]) ? "doubled" : "extra"
        }
        if w.count == t.count + 1, let j = (0..<w.count).first(where: { Array(w[..<$0] + w[($0 + 1)...]) == t }) {
            if Self.apostrophe(w[j]) { return "apostrophe" }
            return (j > 0 && w[j - 1] == w[j]) || (j + 1 < w.count && w[j + 1] == w[j]) ? "dropped double" : "missing"
        }
        return abs(t.count - w.count) <= 2 ? "2 edits" : "other"
    }
}

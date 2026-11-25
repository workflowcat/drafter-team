// The two typo fixes as pure functions over closures, so the app, the bench and the tests run the same code:
// `system` is the fix of 31 October (macOS's correction or his nearest frequent word), `ranked` the one of 15 November.
import Foundation

enum TypoDecide {
    struct Tables {
        var index: TypoRank.DeleteIndex, bigrams: TypoRank.Bigrams, keyboard: TypoKeyboard, gate: TypoRank.Gate
    }
    struct Decision { let word: String; let outcome: TypoRank.Outcome; let p: Double; let features: [Double]; let kind: String }

    /// Today's rule (Autocorrect.check before 15 November), unchanged: `core` is lowercase letters, 3-24 long.
    static func system(_ core: String, uk: Bool, known: (String) -> Bool, spellKnown: (String, String) -> Bool,
                       correction: (String, String) -> String?, ownIndex: CorrectionRules.Index) -> String? {
        let lang = uk ? "uk" : "en"
        guard !known(core), !spellKnown(core, lang) else { return nil }
        let russian = CharacterSet(charactersIn: "ыэъёЫЭЪЁ")
        if let own = CorrectionRules.candidate(core, index: ownIndex, ukrainian: uk), own.unicodeScalars.allSatisfy({ !russian.contains($0) }) {
            return own
        }
        guard let c = correction(core, lang), c != core, c == c.lowercased(), c.allSatisfy({ $0.isLetter || "'’".contains($0) }),
              c.unicodeScalars.allSatisfy({ !russian.contains($0) }), CorrectionRules.distance(core, c) <= (uk ? 1 : 2),
              c.first == core.first, core.count > 3 || (c.count == 3 && Set(c) == Set(core)) else { return nil }
        return c
    }

    /// Candidates the ranked fix may weigh: same script, lowercase letters, no Russian letters, close enough
    /// (one edit; two from 8 letters), and for a 3-letter word only the same letters swapped.
    static func eligible(_ typo: String, _ word: String, uk: Bool) -> Bool {
        let maxD = typo.count >= 8 ? 2 : 1
        guard word != typo, word == word.lowercased(), TypoRules.letters(word), TypoRules.isUkrainian(word) == uk,
              !word.contains(where: { TypoRules.russian.contains($0) }), abs(word.count - typo.count) <= maxD else { return false }
        if typo.count == 3 { return word.count == 3 && word.sorted() == typo.sorted() }
        return CorrectionRules.distance(typo, word) <= maxD
    }

    /// The ranked fix for one word at Space. nil = he typed a word, or nothing fits. `lazy`: his own words first, and
    /// macOS's guesses (5-13 ms a call on this Mac) only when they leave the gate short of sure.
    static func ranked(_ core: String, prev: String, appKind: String, mode: String, known: (String) -> Bool,
                       spell: (String, String) -> Bool, guesses: (String, String) -> [String], tables: Tables, lazy: Bool = true) -> Decision? {
        guard !TypoRules.isWord(core, known: known, spell: spell) else { return nil }
        let uk = TypoRules.isUkrainian(core)
        func decide(_ cands: [TypoRank.Candidate]) -> Decision? {
            let ranked = TypoRank.rank(core, cands, prev: prev.lowercased(), keyboard: tables.keyboard, bigrams: tables.bigrams)
            guard let best = ranked.first else { return nil }
            let f = TypoRank.features(ranked, typo: core, uk: uk, appKind: appKind)
            let p = tables.gate.p(f)
            return Decision(word: best.word, outcome: TypoRank.outcome(p, gate: tables.gate, mode: mode), p: p, features: f,
                            kind: tables.keyboard.kind(core, best.word))
        }
        var cands: [TypoRank.Candidate] = []
        for hit in tables.index.lookup(core, maxDistance: core.count >= 8 ? 2 : 1) where eligible(core, hit.word, uk: uk) {
            cands.append(.init(word: hit.word, count: hit.count, macRank: nil))
        }
        if lazy, let own = decide(cands), own.p >= tables.gate.fixAt { return own }
        for (i, g) in guesses(core, uk ? "uk" : "en").prefix(6).enumerated() where g == g.lowercased() && eligible(core, g, uk: uk) {
            let count = tables.index.words.firstIndexSorted(g).map { tables.index.counts[$0] } ?? 0
            cands.append(.init(word: g, count: count, macRank: i))
        }
        return decide(cands)
    }

    /// Numbers only, for the log line of an offer or a fix: " f=cost,count,...;p=0.83".
    static func logTail(_ d: Decision) -> String {
        " f=" + d.features.map { String(format: "%.2f", $0) }.joined(separator: ",") + String(format: ";p=%.2f", d.p)
    }
}

extension Array where Element == String {
    /// Binary search in a sorted array.
    func firstIndexSorted(_ s: String) -> Int? {
        var lo = 0, hi = count
        while lo < hi { let m = (lo + hi) / 2; if self[m] < s { lo = m + 1 } else { hi = m } }
        return lo < count && self[lo] == s ? lo : nil
    }
}

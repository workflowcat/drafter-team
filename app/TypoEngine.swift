// The ranked typo fix in the app (15 November 2026, setting `typoEngine`: "ranked", or "system" for the macOS-only fix
// of 31 October). The rules are pure (TypoRules, TypoKeyboard, TypoRank, TypoDecide); this file feeds them his words
// (Autocorrect's lists), the Mac's spellchecker, and the nightly tables (data/typo-bigrams.tsv, data/typo-gate.json from
// engine/typos.py), read off the main thread. Each offer and fix logs its numbers, no words, for the nightly refit.
import AppKit

enum TypoEngine {
    /// The last decision, for apply() (fix by itself or offer) and the log line.
    static var last: (new: String, d: TypoDecide.Decision)?
    static let keyboard = TypoKeyboard(toUk: KeyLayout.maps.toUk.isEmpty ? TypoKeyboard.ukOf : KeyLayout.maps.toUk)
    private static let files = LocalSnapshot<TypoDecide.Tables>(["myword-counts.json", "mywords.txt", "typo-bigrams.tsv", "typo-gate.json"].map { Home.data.appendingPathComponent($0) }) { d in
        var counts = (try? JSONDecoder().decode([String: Int].self, from: d[0] ?? Data())) ?? [:]
        for w in String(decoding: d[1] ?? Data(), as: UTF8.self).split(separator: "\n") {
            let s = w.lowercased(); if counts[s] == nil { counts[s] = 3 }
        }
        return TypoDecide.Tables(index: .init(counts), bigrams: .init(tsv: String(decoding: d[2] ?? Data(), as: UTF8.self)),
                                 keyboard: TypoKeyboard(), gate: TypoRank.Gate.load(d[3]))
    }

    static func guesses(_ w: String, _ lang: String) -> [String] {
        Spell.checker.guesses(forWordRange: NSRange(location: 0, length: (w as NSString).length), in: w, language: lang, inSpellDocumentWithTag: 0) ?? []
    }

    /// The fix for the last token of `line` (no space at its end), or nil: stay quiet.
    static func check(_ token: String, line: String, app: String, kind: String, typosUk: Bool) -> (old: String, new: String, kind: String)? {
        last = nil
        guard !TypoRules.codeApps.contains(app), !TypoRules.inCode(line), let p = TypoRules.core(token),
              typosUk || !TypoRules.isUkrainian(p.core), var tables = files.read() else { return nil }
        tables.keyboard = keyboard
        let words = line.split(separator: " ")
        let prev = words.count > 1 ? (TypoRules.core(String(words[words.count - 2]))?.core ?? "") : ""
        guard let d = TypoDecide.ranked(p.core, prev: prev, appKind: kind, mode: Drafter.shared.settings.autocorrectMode,
                                        known: Autocorrect.known, spell: Spell.known, guesses: guesses, tables: tables) else { return nil }
        if d.outcome == .quiet {
            if debugLog { log("typo quiet" + TypoDecide.logTail(d)) }
            return nil
        }
        let new = p.lead + d.word + p.tail + " "
        last = (new, d)
        return (token + " ", new, "typo")
    }

    /// Typo hold (TypoHold): the ranked fix has a candidate for this word, whatever its outcome. False until the
    /// tables are read (the hold then stays off rather than wait for the disk).
    static func hasFix(_ core: String, prev: String, kind: String) -> Bool {
        guard var tables = files.read() else { return false }
        tables.keyboard = keyboard
        return TypoDecide.ranked(core, prev: prev, appKind: kind, mode: Drafter.shared.settings.autocorrectMode,
                                 known: Autocorrect.known, spell: Spell.known, guesses: guesses, tables: tables) != nil
    }

    /// Typo hold: one of the words he writes starts with these letters (his counts, sorted, so a binary search).
    static func hisStart(_ letters: String) -> Bool {
        guard let words = files.read()?.index.words else { return false }
        var lo = 0, hi = words.count
        while lo < hi { let m = (lo + hi) / 2; if words[m] < letters { lo = m + 1 } else { hi = m } }
        return lo < words.count && words[lo].hasPrefix(letters) && words[lo].count > letters.count
            || lo + 1 < words.count && words[lo] == letters && words[lo + 1].hasPrefix(letters)
    }

    /// The ranked fix was sure enough to go in by itself (only in the "sure" or "replace" modes).
    static func sure(_ new: String) -> Bool { last?.new == new && last?.d.outcome == .fix }
    /// " f=...;p=..." for the log line of this fix, "" for anything else.
    static func tail(_ new: String) -> String { last?.new == new ? TypoDecide.logTail(last!.d) : "" }
}

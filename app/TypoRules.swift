// Ranked typo fix at a word end (15 November 2026, setting `typoEngine` "ranked"; "system" is the macOS-only fix of
// 31 October). Pure: no app, no spellchecker; the speller and his words come in as closures and tables, so every rule
// here has a test with made-up words (tests/typo_rules.swift). The parts, each its own rule:
//   a. is it a word: never touch his words, names, words either Mac dictionary knows, code-like tokens, code fields
//   b. candidates: macOS's guesses plus a delete index (SymSpell) over the words he writes, with his counts
//   c. a keyboard error model: what an edit costs depends on what it is (neighbour key, swap, doubled letter...)
//   d. context: how often he wrote the candidate after the word before it (a bigram table built nightly)
//   e. a gate: one logistic model over a handful of numbers, refit nightly on what he took (engine/typos.py)
//   f. three outcomes: stay quiet, offer "→ word", or fix by itself when the evidence is overwhelming
// Round notes and numbers: docs/rounds/2026-11-15-correction.md.
import Foundation

enum TypoRules {
    static let apostrophes: Set<Character> = ["'", "’", "ʼ"]
    static let russian: Set<Character> = ["ы", "э", "ъ", "ё"]
    static let cyrillic: Set<Character> = Set("абвгґдеєжзиіїйклмнопрстуфхцчшщьюя")

    // MARK: a. Is it a word?

    static func letters(_ w: String) -> Bool { !w.isEmpty && w.allSatisfy { $0.isLetter || apostrophes.contains($0) } }
    static func isUkrainian(_ w: String) -> Bool { w.lowercased().contains { cyrillic.contains($0) } }
    static func mixedScript(_ w: String) -> Bool {
        let low = w.lowercased()
        return low.contains { cyrillic.contains($0) } && low.contains { $0.isASCII && $0.isLetter }
    }

    /// A token that is not prose (code, a path, a link, a handle, an emoji code, a number): never touched.
    static func codeLike(_ token: String) -> Bool {
        if token.contains(where: { $0.isNumber }) { return true }
        if token.contains("://") || token.hasPrefix("www.") || token.contains("@") || token.hasPrefix("#") { return true }
        if token.contains(where: { "_/\\=<>{}[]|~$%^&*+`".contains($0) }) { return true }
        if token.hasPrefix(":") || token.dropLast().hasSuffix(":") && token.hasPrefix(":") { return true }
        // a dot inside the word (file.swift, e.g., v.2), camelCase, or two capitals in a row (API, iOS)
        let inner = token.trimmingCharacters(in: .punctuationCharacters)
        if inner.contains(".") { return true }
        let chars = Array(inner)
        for i in 1..<max(chars.count, 1) where chars[i].isUppercase && (chars[i - 1].isLowercase || chars[i - 1].isUppercase) { return true }
        return false
    }

    /// The caret is inside code: an open ``` block above it, or an odd number of backticks on its line.
    static func inCode(_ before: String) -> Bool {
        if before.components(separatedBy: "```").count % 2 == 0 { return true }
        let line = before.components(separatedBy: "\n").last ?? ""
        return line.filter { $0 == "`" }.count % 2 == 1
    }

    /// Apps where every field is code: no typo fix there.
    static let codeApps: Set<String> = ["com.apple.Terminal", "com.googlecode.iterm2", "com.apple.dt.Xcode", "com.microsoft.VSCode",
                                        "com.todesktop.230313mzl4w4u92", "dev.zed.Zed", "dev.warp.Warp-Stable", "com.mitchellh.ghostty"]

    /// The same word with the other apostrophe: he and the dictionary may use ' or ’ or ʼ.
    static func apostropheForms(_ w: String) -> [String] {
        guard w.contains(where: { apostrophes.contains($0) }) else { return [w] }
        return ["'", "’", "ʼ"].map { a in String(w.map { apostrophes.contains($0) ? Character(a) : $0 }) }
    }

    /// A word for him: his words or names (any case form, any apostrophe), or a word the Mac dictionary of its script
    /// knows (English for Latin letters, Ukrainian for Cyrillic; asked the other way, the Mac's checker passes any word
    /// of the other script, so that answer means nothing).
    static func isWord(_ w: String, known: (String) -> Bool, spell: (String, String) -> Bool) -> Bool {
        for f in apostropheForms(w.lowercased()) where known(f) { return true }
        let lang = isUkrainian(w) ? "uk" : "en"
        return apostropheForms(w).contains { spell($0, lang) }
    }

    /// What the ranked fix may look at: the word without quotes in front and punctuation after it, all lowercase
    /// letters (a capital means a name or a sentence start he chose; left alone as today), 3 to 24 letters, one script,
    /// no Russian letters. nil = stay quiet.
    static func core(_ token: String) -> (lead: String, core: String, tail: String)? {
        guard !codeLike(token) else { return nil }
        let lead = token.prefix { "(\"«'„“".contains($0) }, rest = token.dropFirst(lead.count)
        let core = String(rest.reversed().drop { ",.!?;:)»\"”".contains($0) }.reversed())
        guard core.count >= 3, core.count <= 24, core == core.lowercased(), letters(core), !mixedScript(core),
              !core.contains(where: { russian.contains($0) }) else { return nil }
        return (String(lead), core, String(rest.dropFirst(core.count)))
    }
}

// MARK: g. Typo hold (15 November 2026; Cotypist Pro): no grey text while the word just typed is a suspected typo

/// A ghost after a typo is asked for with the typo in its context and mostly goes on from the wrong word. So while the
/// caret sits right after a suspected typo (still typing it, or after the space following it, or inside the next word)
/// Keys asks the engine for no ghost (a mid-word fix "→ word" still comes) and hides a plain ghost. Fixing the word,
/// taking the offered fix, or typing on past the next word (its space) ends the hold. tests/typo_hold.swift.
enum TypoHold {
    /// Where the caret sits: `word` right after the suspected word (no space yet), `after` after it and its space,
    /// `next` inside the word after it.
    enum At: String { case none, word, after, next }

    /// `suspect(core, prev, complete)`: is this word (lowercase core, see `core`) a suspected typo? `complete` is false
    /// while he may still be typing it (no space or punctuation after it yet). `len` is the held word's length, for the
    /// log line (numbers only).
    static func at(_ before: String, suspect: (_ core: String, _ prev: String, _ complete: Bool) -> Bool) -> (at: At, len: Int) {
        let line = before.replacingOccurrences(of: "\u{A0}", with: " ").components(separatedBy: "\n").last ?? ""
        let trailing = line.reversed().prefix { $0 == " " }.count
        let tokens = line.split(separator: " ").map(String.init)
        guard let last = tokens.last else { return (.none, 0) }
        func prevCore(_ i: Int) -> String { i >= 0 ? (TypoRules.core(tokens[i])?.core ?? "") : "" }
        if trailing > 0 {
            if let p = TypoRules.core(last), suspect(p.core, prevCore(tokens.count - 2), true) { return (.after, p.core.count) }
            return (.none, 0)
        }
        if let p = TypoRules.core(last), suspect(p.core, prevCore(tokens.count - 2), !p.tail.isEmpty) { return (.word, p.core.count) }
        if tokens.count >= 2, let p = TypoRules.core(tokens[tokens.count - 2]), suspect(p.core, prevCore(tokens.count - 3), true) {
            return (.next, p.core.count)
        }
        return (.none, 0)
    }

    /// The typo check's answer for one word. Never his words, names or a word either Mac dictionary knows (`isWord`),
    /// never a word he took a fix back on (`spared`). A whole word is a typo when the typo fix has a candidate for it
    /// (`hasFix`: the ranked decision, any outcome); a word still being typed when no word starts with its letters
    /// (`starts`: the Mac's words, his words and names).
    static func suspect(_ core: String, complete: Bool, spared: (String) -> Bool, known: (String) -> Bool,
                        spell: (String, String) -> Bool, starts: (String) -> Bool, hasFix: (String) -> Bool) -> Bool {
        guard !spared(core), !TypoRules.isWord(core, known: known, spell: spell) else { return false }
        return complete ? hasFix(core) : !starts(core)
    }

    /// One "ghost hold typo" line per hold: a hold is the held word's place (line and word number), so the same hold
    /// seen again at the next key, after its space or inside the next word logs nothing. nil: no hold.
    static func key(_ before: String, _ at: At) -> String? {
        guard at != .none else { return nil }
        let lines = before.replacingOccurrences(of: "\u{A0}", with: " ").components(separatedBy: "\n")
        let words = (lines.last ?? "").split(separator: " ").count
        return "\(lines.count):\(at == .next ? words - 1 : words)"
    }
}

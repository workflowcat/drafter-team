import Foundation

// swiftc -parse-as-library app/TypoRules.swift tests/typo_hold.swift -o app/build/typo-hold-test && app/build/typo-hold-test
// Typo hold (15 November 2026): no grey text while the caret sits after a suspected typo. Made-up words only.

@main struct TypoHoldTests {
    static var failed = 0
    static func check(_ ok: Bool, _ what: String, line: Int = #line) { if !ok { failed += 1; print("FAIL line \(line): \(what)") } }

    // a made-up world: "zorbo", "plinth", "quavel" are words; "zorbx" and "qvael" have a fix; "blarg" is a start
    static let words: Set<String> = ["zorbo", "plinth", "quavel", "and", "the", "mox"]
    static let fixes: Set<String> = ["zorbx", "qvael", "plinht"]
    static let starts: Set<String> = ["blarg", "zor", "pli", "plin", "qua", "quav"]

    static func suspect(spared: Set<String> = []) -> (String, String, Bool) -> Bool {
        { core, _, complete in
            TypoHold.suspect(core, complete: complete, spared: { spared.contains($0) }, known: { words.contains($0) },
                             spell: { _, _ in false }, starts: { w in starts.contains(w) || words.contains { $0.hasPrefix(w) && $0 != w } },
                             hasFix: { fixes.contains($0) })
        }
    }

    static func at(_ before: String, spared: Set<String> = []) -> TypoHold.At { TypoHold.at(before, suspect: suspect(spared: spared)).at }

    static func main() {
        // the suspect rule
        let s = suspect()
        check(!s("zorbo", "", true), "his word is no typo")
        check(s("zorbx", "", true), "a whole word with a fix is a typo")
        check(!s("frumbleqx", "", true), "a whole non-word with no candidate: not held (a new word of his)")
        check(s("zqx", "", false) == true, "letters no word starts with, still typing: a typo")
        check(!s("blarg", "", false), "letters a word starts with: he may still be typing it")
        check(!s("zor", "", false), "the start of his own word")
        check(!suspect(spared: ["zorbx"])("zorbx", "", true), "a fix he took back is not a typo")

        // where the caret sits
        check(at("the zorbx") == .word, "no space yet: held when no word starts with the letters")
        check(at("the blarg") == .none, "no space yet, a word starts with them: he may still be typing it")
        check(at("the zor") == .none, "the start of his word: the finisher may finish it")
        check(at("the zqx") == .word, "right after a word no word starts with")
        check(at("the zorbx ") == .after, "right after the space following a typo")
        check(at("the zorbx   ") == .after, "after several spaces")
        check(at("the zorbx, ") == .after, "punctuation stuck to the typo")
        check(at("the zorbx,") == .word, "a typo with punctuation and no space is whole: held at the word")
        check(at("the zorbx a") == .next, "inside the next word")
        check(at("the zorbx and ") == .none, "typed on past the next word: ghosts come back")
        check(at("the zorbo ") == .none, "fixed: ghosts come back")
        check(at("the zorbo a") == .none, "fixed, next word")
        check(at("the zorbx ", spared: ["zorbx"]) == .none, "taken back: not held")
        check(at("") == .none, "empty")
        check(at("   ") == .none, "spaces only")
        check(at("zorbx\n") == .none, "a new line starts clean")
        check(at("zorbx\nthe ") == .none, "the typo on the line above does not hold")
        check(at("the zorbx\u{A0}") == .after, "no-break space counts as a space")
        check(at("the Zorbx ") == .none, "a capital is a name or a choice: left alone, as the fix does")
        check(at("see file.swft ") == .none, "code-like tokens are never typos")
        check(at("the qvael plinht ") == .after, "two typos in a row: the last one holds")
        check(at("the qvael plinth ") == .none, "the word after the typo is fine and finished")

        // the length logged and one log key per hold
        check(TypoHold.at("the zorbx ", suspect: s).len == 5, "len is the held word's length")
        check(TypoHold.at("the zorbx a", suspect: s).len == 5, "len in the next word is still the typo's")
        check(TypoHold.key("the zqx", .word) == TypoHold.key("the zqx ", .after), "the same hold after its space")
        check(TypoHold.key("the zqx ", .after) == TypoHold.key("the zqx a", .next), "the same hold inside the next word")
        check(TypoHold.key("the zqx a", .next) != TypoHold.key("the zqx a qvael ", .after), "another word: another hold")
        check(TypoHold.key("one zqx", .word) != TypoHold.key("one\nzqx", .word), "another line: another hold")
        check(TypoHold.key("the zqx", .none) == nil, "no hold, no key")

        print(failed == 0 ? "typo hold: all passed" : "typo hold: \(failed) failed")
        exit(failed == 0 ? 0 : 1)
    }
}

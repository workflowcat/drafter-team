import Foundation

// swiftc -parse-as-library app/SynonymRules.swift tests/synonym_rules.swift -o app/build/synonym-rules-test && app/build/synonym-rules-test
// Synonyms in the ⌥Tab list with made-up words: which selections ask, digits and rows with and without synonyms,
// the numbers-only log line.
@main
struct SynonymRuleChecks {
    static var failures = 0
    static func eq<T: Equatable>(_ a: T, _ b: T, _ what: String) { if a != b { print("FAIL: \(what)\n  got:  \(a)\n  want: \(b)"); failures += 1 } }

    static func main() {
        // which selections ask
        for s in ["швидкий", " Fast, ", "look up", "будь-який", "don't", "дуже швидко їхати"] { eq(SynonymRules.asks(s), true, "asks: \(s)") }
        for s in ["", "  ", "15:00", "a b c d", "line\nbreak", "word2", String(repeating: "a", count: 41), "...", "a+b=c"] {
            eq(SynonymRules.asks(s), false, "does not ask: \(s.debugDescription)")
        }
        // rows: 6 synonyms, 7 commands
        eq(SynonymRules.digit(1, synonyms: 6, commands: 7), .synonym(0), "1 is the first synonym")
        eq(SynonymRules.digit(6, synonyms: 6, commands: 7), .synonym(5), "6 is the last synonym")
        eq(SynonymRules.digit(7, synonyms: 6, commands: 7), .command(0), "7 is the first command")
        eq(SynonymRules.digit(9, synonyms: 6, commands: 7), .command(2), "9 is the third command")
        eq(SynonymRules.digit(0, synonyms: 6, commands: 7), nil, "0 picks nothing")
        eq(SynonymRules.row(12, synonyms: 6, commands: 7), .command(6), "the last command by arrows")
        eq(SynonymRules.row(13, synonyms: 6, commands: 7), nil, "the typed row")
        eq(SynonymRules.label(8), "9", "row 9 has a number"); eq(SynonymRules.label(9), nil, "row 10 has none")
        // no synonyms: as before
        for d in 1...7 { eq(SynonymRules.digit(d, synonyms: 0, commands: 7), .command(d - 1), "no synonyms: \(d) is command \(d)") }
        eq(SynonymRules.digit(8, synonyms: 0, commands: 7), nil, "no synonyms: 8 picks nothing")
        // two synonyms
        eq(SynonymRules.digit(3, synonyms: 2, commands: 7), .command(0), "two synonyms: 3 is the first command")
        // log: numbers only
        eq(SynonymRules.logLine(shown: 6, picked: 2, ms: 14), "synonyms: shown 6, picked 2, 14 ms", "log line")
        print(failures == 0 ? "synonym rules: all passed" : "synonym rules: \(failures) failed")
        exit(failures == 0 ? 0 : 1)
    }
}

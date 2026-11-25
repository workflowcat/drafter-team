import Foundation

// swiftc -parse-as-library app/TypoRules.swift app/TypoKeyboard.swift app/TypoRank.swift app/TypoDecide.swift app/CorrectionRules.swift tests/typo_rules.swift -o app/build/typo-rules-test && app/build/typo-rules-test

@main struct TypoRulesTests {
    static var failed = 0
    static func check(_ ok: Bool, _ what: String, line: Int = #line) { if !ok { failed += 1; print("FAIL line \(line): \(what)") } }

    static func main() {
        // a. is it a word
        for t in ["v2", "file.swift", "https://x.io", "@zorbo", "#tag", "snake_case", "camelCase", "API", ":smile:", "a/b", "x=1"] { check(TypoRules.codeLike(t), "code-like \(t)") }
        for t in ["zorbo", "зорбо,", "word.", "don't"] { check(!TypoRules.codeLike(t), "prose \(t)") }
        check(TypoRules.inCode("text `glorp"), "inline code")
        check(TypoRules.inCode("```\nglorp"), "code block")
        check(!TypoRules.inCode("```\nx\n```\nglorp"), "closed block")
        check(TypoRules.core("(blorf),")?.core == "blorf", "core strips quotes and punctuation")
        check(TypoRules.core("Blorf") == nil, "capital left alone")
        check(TypoRules.core("blоrf") == nil, "mixed script left alone")      // Cyrillic о inside
        check(TypoRules.core("ыщрф") == nil, "Russian letters left alone")
        check(TypoRules.core("ab") == nil, "short")
        let his: Set<String> = ["шоб", "zorbo", "м'ята"]
        let known = { (w: String) in his.contains(w) }
        let none = { (_: String, _: String) in false }
        check(TypoRules.isWord("zorbo", known: known, spell: none), "his word")
        check(TypoRules.isWord("м’ята", known: known, spell: none), "his word with the other apostrophe")
        check(TypoRules.isWord("glimmer", known: { _ in false }, spell: { w, l in w == "glimmer" && l == "en" }), "Mac word")
        check(TypoRules.isWord("глимер", known: { _ in false }, spell: { w, l in w == "глимер" && l == "uk" }), "Mac Ukrainian word")
        check(!TypoRules.isWord("глимер", known: { _ in false }, spell: { _, l in l == "en" }), "the English checker passes Cyrillic: not asked")

        // c. keyboard error model
        let k = TypoKeyboard()
        check(k.near("s", "d") && k.near("і", "в") && !k.near("q", "p"), "neighbours on both layouts")
        check(k.kind("zrobo", "zorbo") == "swap", "swap")
        check(k.kind("zprbo", "zorbo") == "neighbour", "neighbour \(k.kind("zprbo", "zorbo"))")
        check(k.kind("zmrbo", "zorbo") == "wrong key", "wrong key")
        check(k.kind("zorrbo", "zorbo") == "doubled", "doubled")
        check(k.kind("zorbbo", "zorbo") == "doubled", "doubled after")
        check(k.kind("blaber", "blabber") == "dropped double", "dropped double")
        check(k.kind("zrbo", "zorbo") == "missing", "missing")
        check(k.kind("zoqrbo", "zorbo") == "extra", "extra")
        check(k.kind("мята", "м'ята") == "apostrophe", "apostrophe")
        check(k.kind("пирiг", "пиріг") != "", "any")
        check(k.kind("їжак", "іжак") == "letter twin", "twin")
        check(k.cost("zrobo", "zorbo") < k.cost("zmrbo", "zorbo"), "swap cheaper than a far key")
        check(k.cost("zprbo", "zorbo") < k.cost("zmrbo", "zorbo"), "neighbour cheaper than a far key")
        check(k.cost("blaber", "blabber") < k.cost("blaer", "blabber"), "dropped double cheaper than a missing letter")
        check(k.cost("мята", "м'ята") < 0.5 && k.cost("м’ята", "м'ята") < 0.2, "apostrophes are cheap")
        check(k.cost("xorbo", "zorbo") > k.cost("zorbp", "zorbo"), "first letter costs more")
        check(k.cost("zorbo", "zorbo") == 0, "same is free")

        // b. delete index
        let counts = ["zorbo": 40, "zorba": 2, "glimmerish": 9, "квасоля": 12, "квасолі": 3, "м'ята": 7]
        let idx = TypoRank.DeleteIndex(counts)
        check(Set(idx.lookup("zorbp", maxDistance: 1).map { $0.word }) == ["zorbo", "zorba"], "distance 1 \(idx.lookup("zorbp", maxDistance: 1))")
        check(idx.lookup("glimerisch", maxDistance: 2).map { $0.word } == ["glimmerish"], "distance 2 for long words")
        check(idx.lookup("glimerisch", maxDistance: 1).isEmpty, "not at distance 1")
        check(idx.lookup("квасол", maxDistance: 1).count == 2, "Ukrainian")
        check(idx.lookup("zrobo", maxDistance: 1).map { $0.word } == ["zorbo"], "swap found")

        // d. context
        let bi = TypoRank.Bigrams(tsv: "fresh\tzorba\t9\nfresh\tother\t1\nbad line")
        check(bi.count("fresh", "zorba") == 9 && bi.total("fresh") == 10, "bigram counts")
        check(bi.lift("fresh", "zorba", share: 0.001) > 2, "context lifts")
        check(bi.lift("", "zorba", share: 0.001) == 0 && bi.lift("stale", "zorba", share: 0.001) == 0, "no context, no lift")

        // ranking: his count wins without context, context can turn it
        let none2 = TypoRank.Bigrams()
        let r1 = TypoRank.rank("zorbp", [.init(word: "zorbo", count: 40), .init(word: "zorba", count: 2)], prev: "", keyboard: k, bigrams: none2)
        check(r1.first?.word == "zorbo", "count decides")
        let r2 = TypoRank.rank("zorbp", [.init(word: "zorbo", count: 3), .init(word: "zorba", count: 2)], prev: "fresh", keyboard: k, bigrams: bi)
        check(r2.first?.word == "zorba", "context decides")

        // e. gate and f. outcome
        let g = TypoRank.Gate(bias: 0, weights: Array(repeating: 0, count: 9), offerAt: 0.6, fixAt: 0.95, labels: 50)
        check(abs(g.p(Array(repeating: 1, count: 9)) - 0.5) < 1e-9, "zero gate is a coin")
        check(g.p([1]) == 0, "wrong size never fires")
        check(TypoRank.outcome(0.5, gate: g, mode: "replace") == .quiet, "quiet below")
        check(TypoRank.outcome(0.97, gate: g, mode: "offer") == .offer, "offer mode never fixes by itself")
        check(TypoRank.outcome(0.97, gate: g, mode: "sure") == .fix && TypoRank.outcome(0.8, gate: g, mode: "sure") == .offer, "sure mode")
        check(TypoRank.outcome(0.7, gate: g, mode: "replace") == .fix, "replace mode")
        check(TypoRank.Gate.load(nil) == .fallback, "missing file")
        check(TypoRank.Gate.load(Data("{}".utf8)) == .fallback, "broken file")
        let few = try! JSONEncoder().encode(TypoRank.Gate(bias: 1, weights: g.weights, offerAt: 0.5, fixAt: 0.9, labels: 10))
        check(TypoRank.Gate.load(few) == .fallback, "too few labels")
        let ok = try! JSONEncoder().encode(g)
        check(TypoRank.Gate.load(ok) == g, "fitted gate loads")

        // the whole decision; a known word is never changed
        let tables = TypoDecide.Tables(index: idx, bigrams: bi, keyboard: k, gate: .fallback)
        let guesses = { (w: String, _: String) -> [String] in w == "zorbp" ? ["zorbo", "Zorbas"] : [] }
        let d = TypoDecide.ranked("zorbp", prev: "", appKind: "chat", mode: "offer", known: { _ in false }, spell: none, guesses: guesses, tables: tables)
        check(d?.word == "zorbo" && d?.outcome != .quiet, "typo fixed \(String(describing: d?.word)) \(String(describing: d?.p))")
        check(d.map { TypoDecide.logTail($0).hasPrefix(" f=") && !TypoDecide.logTail($0).contains("zorb") } ?? false, "log tail has numbers only")
        for w in counts.keys { check(TypoDecide.ranked(w, prev: "", appKind: "ai", mode: "replace", known: { counts[$0] != nil }, spell: none, guesses: guesses, tables: tables) == nil, "known \(w) never changed") }
        check(TypoDecide.ranked("glimmer", prev: "", appKind: "ai", mode: "replace", known: { _ in false }, spell: { w, _ in w == "glimmer" }, guesses: { _, _ in ["glimmers"] }, tables: tables) == nil, "Mac word never changed")
        check(TypoDecide.ranked("квасолл", prev: "", appKind: "ai", mode: "offer", known: { _ in false }, spell: none, guesses: { _, _ in [] }, tables: tables)?.word == "квасоля", "Ukrainian typo")
        check(TypoDecide.ranked("qqqq", prev: "", appKind: "ai", mode: "offer", known: { _ in false }, spell: none, guesses: { _, _ in [] }, tables: tables) == nil, "nothing fits")
        check(TypoDecide.eligible("zor", "orz", uk: false) && !TypoDecide.eligible("zor", "zop", uk: false), "3 letters: swaps only")

        // today's rule is kept as it was
        let own = CorrectionRules.Index(["zorbo": 40])
        check(TypoDecide.system("zorbp", uk: false, known: { _ in false }, spellKnown: none, correction: { _, _ in nil }, ownIndex: own) == "zorbo", "system: own word")
        check(TypoDecide.system("zorbp", uk: false, known: { $0 == "zorbp" }, spellKnown: none, correction: { _, _ in nil }, ownIndex: own) == nil, "system: known")

        print(failed == 0 ? "PASS: typo rules" : "\(failed) failed")
        if failed > 0 { exit(1) }
    }
}

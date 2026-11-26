// swiftc -parse-as-library app/DictRules.swift tests/dict_rules.swift -o app/build/dict-rules-test && app/build/dict-rules-test
// The Dictionary page's rules (app/DictRules.swift): groups and their order, search over words and heard forms, the
// heard field. Made-up words only.
import Foundation

@main struct Checks {
    static func check(_ ok: Bool, _ what: String) { if !ok { print("FAIL: " + what); exit(1) } }

    static func main() {
        let file: [String: Any] = [
            "words": [
                ["text": "Zorvox", "source": "menu"],
                ["text": "Brumblex", "source": "edits", "heard": ["brum blacks", "brumbl"]],
                ["text": "ауралінк", "source": "typing"],
                ["text": "zorvox", "source": "typing"],          // the same word twice: one row
                ["text": "  ", "source": "menu"],
            ],
            "loose_heard": ["kwill": "Quillo", "": "Empty"],
        ]
        let waiting: [[String: Any]] = [
            ["heard": "fennik", "fixed": "Fennick", "count": 1],
            ["heard": "glo mer", "fixed": "Glimmer", "count": 4],
            ["heard": "", "fixed": "Nothing", "count": 9],
        ]
        let rows = DictRules.rows(file, waiting: waiting)
        check(rows.map(\.group) == [.learn, .learn, .pair, .pair, .word, .word], "groups in order: \(rows.map(\.group))")
        check(rows[0].text == "Glimmer" && rows[0].count == 4, "Words to learn: most often first")
        check(rows[2].text == "Brumblex" && rows[3].text == "Quillo" && rows[3].loose, "pairs alphabetically, loose ones too")
        check(rows[4].text == "Zorvox" || rows[4].text == "ауралінк", "plain words")
        check(Set(rows.map(\.id)).count == rows.count, "each row its own key")
        check(rows[0].id == "learn:glo mer→Glimmer" && rows[3].id == "loose:kwill" && rows[2].id == "word:brumblex", "keys")

        // search: the word or a heard form, every query word, no case or accents
        check(DictRules.filter(rows, query: "").count == rows.count, "empty query shows all")
        check(DictRules.filter(rows, query: "BLACKS").map { rows[$0].text } == ["Brumblex"], "a heard form finds its word")
        check(DictRules.filter(rows, query: "brum blex").map { rows[$0].text } == ["Brumblex"], "every query word")
        check(DictRules.filter(rows, query: "АУРА").map { rows[$0].text } == ["ауралінк"], "Cyrillic, no case")
        check(DictRules.filter(rows, query: "glo").map { rows[$0].group } == [.learn], "Words to learn are searched too")
        check(DictRules.filter(rows, query: "nothinghere").isEmpty, "no match")
        check(DictRules.fold("Café’s") == "cafe's", "fold")

        // the heard field
        check(DictRules.heard("Brum Blocks, brum   blocks; brumblex ,, brumbl ", word: "Brumblex") == ["brum blocks", "brumbl"],
              "heard: lower case, once, never the word")
        check(DictRules.heard("", word: "x").isEmpty, "empty heard field")
        check(DictRules.valid(" Zorvox ") && !DictRules.valid("   ") && !DictRules.valid(String(repeating: "a", count: 61)), "valid words")

        let c = DictRules.counts(rows, Array(rows.indices))
        check(c[.learn] == 2 && c[.pair] == 2 && c[.word] == 2, "counts per group")
        check(DictRules.title(.learn) == "Words to learn", "the top group's title")
        print("dict rules: all checks passed (\(rows.count) rows)")
    }
}

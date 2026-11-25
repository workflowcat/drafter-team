// swiftc -O -parse-as-library app/SnippetRules.swift app/SpokenSnippetRules.swift tests/spoken_snippet_rules.swift -o app/build/spoken-snippet-rules-test && app/build/spoken-snippet-rules-test
// Spoken snippets (plan A2). Made-up keys and values only.
import Foundation

@main struct Checks {
    static func main() {
        let snippets = [";linkedin": "https://example.test/in/someone", ";mail": "someone@example.test",
                        ";addr": "1 Made-up Street", ";sig": "Someone\n{date}", ";ок": "", ";порт": "https://example.test/folio"]
        let cues = SpokenSnippetRules.cues(snippets: snippets, meta: [";addr": ["my address", "моя адреса"], ";sig": ["sign it"]])
        func say(_ k: String) -> [String] { cues.first { $0.key == k }?.say ?? [] }
        precondition(say(";linkedin") == ["my linkedin"])
        precondition(say(";addr").contains("моя адреса") && say(";addr").contains("my addr"))
        precondition(say(";порт").contains("мій порт"))
        precondition(cues.allSatisfy { $0.key != ";ок" })             // an empty value has no cue
        let typing = [SnippetCue(keys: [";mail"], pattern: #"(?i)\bmy\s+e-?mail(\s+is)?[\s:—-]*$"#)]
        let table: [(String, String, [String])] = [
            ("My LinkedIn.", "https://example.test/in/someone", [";linkedin"]),
            ("Here is the link, my LinkedIn.", "Here is the link, https://example.test/in/someone", [";linkedin"]),
            ("Моя адреса.", "1 Made-up Street", [";addr"]),
            ("Send it here, my address, thanks.", "Send it here, 1 Made-up Street, thanks.", [";addr"]),
            // ordinary mentions stay words
            ("My LinkedIn is broken.", "My LinkedIn is broken.", []),
            ("I updated my LinkedIn yesterday.", "I updated my LinkedIn yesterday.", []),
            // the typing cue adds the value after it
            ("Write to me, my email is.", "Write to me, my email is someone@example.test", [";mail"]),
            ("My email is broken.", "My email is broken.", []),
            // at most two
            ("My LinkedIn, my address, my LinkedIn.", "https://example.test/in/someone, 1 Made-up Street, my LinkedIn.", [";linkedin", ";addr"]),
        ]
        for (input, want, keys) in table {
            let got = SpokenSnippetRules.expand(input, cues: cues, snippets: snippets, typingCues: typing)
            precondition(got.text == want && got.keys == keys, "«\(input)» -> «\(got.text)» \(got.keys)")
        }
        // fields resolved by the given fill; the value is reported as it went in
        let filled = SpokenSnippetRules.expand("Sign it.", cues: cues, snippets: snippets, fill: { $0.replacingOccurrences(of: "{date}", with: "01.01.2030") })
        precondition(filled.text == "Someone\n01.01.2030" && filled.values == ["Someone\n01.01.2030"], filled.text)
        // no snippets, nothing changes
        precondition(SpokenSnippetRules.expand("My LinkedIn.", cues: cues, snippets: [:]).text == "My LinkedIn.")
        print("PASS spoken snippet rules (\(table.count) rows)")
    }
}

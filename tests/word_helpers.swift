// swift-runner: skip (built by tests/test_word_helpers.py)
// Compiled by test_word_helpers.py with the actual Keys.nextWord method extracted into a pure wrapper.
// (by test_word_helpers.py, not the runner) swiftc -module-cache-path app/build/module-cache -parse-as-library app/GhostRules.swift WRAPPER.swift
//   tests/word_helpers.swift -o TEST; TEST tests/fixtures/word_helpers.json
import Foundation

private struct WordCase: Decodable { let text: String; let word: String }
private struct Fixtures: Decodable { let words: [WordCase] }

@main struct WordHelpers {
    static func main() throws {
        let cases = try JSONDecoder().decode(Fixtures.self, from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])))
        let words = cases.words.map { ParityKeys.nextWord($0.text) }
        for (test, word) in zip(cases.words, words) { precondition(word == test.word) }
        var request = GhostRules.runBody(mode: "sentence", words: true, minWords: 3, maxWords: 5,
                                        guess: true, shade: true, strict: false)!
        request["min_letters"] = GhostRules.minLetters(minGhost: 5, short: true, minShort: 3)
        let out: [String: Any] = ["words": words, "request": request]
        print(String(data: try JSONSerialization.data(withJSONObject: out, options: [.sortedKeys]), encoding: .utf8)!)
    }
}

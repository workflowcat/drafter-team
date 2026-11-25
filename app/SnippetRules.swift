// Pure matching rules. Values come from local data, never from the model.
import Foundation

struct SnippetMatch {
    let old: String
    let new: String
    let key: String
}
struct SnippetCue: Decodable {
    let keys: [String]; let pattern: String; let regex: NSRegularExpression?
    init(keys: [String], pattern: String) { self.keys = keys; self.pattern = pattern; regex = try? NSRegularExpression(pattern: pattern) }
    enum CodingKeys: String, CodingKey { case keys, pattern }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(keys: try c.decode([String].self, forKey: .keys), pattern: try c.decode(String.self, forKey: .pattern))
    }
}

enum SnippetRules {
    static func word(_ before: String) -> String { String(before.split(whereSeparator: { $0.isWhitespace }).last ?? "") }
    static func exact(_ given: String, snippets: [String: String], replacements: [String: String]) -> SnippetMatch? {
        let before = given.replacingOccurrences(of: "\u{A0}", with: " ")   // Chromium rich boxes: a trailing no-break space
        guard before.hasSuffix(" ") else { return nil }
        let typed = word(String(before.dropLast()))
        guard !typed.isEmpty, before.hasSuffix(typed + " ") else { return nil }
        if let value = replacements[typed], !value.isEmpty {
            return SnippetMatch(old: typed + " ", new: value + " ", key: typed)
        }
        let key = typed == "AU" ? emailKey(snippets) : snippets.keys.sorted().first { $0.lowercased() == typed.lowercased() && typed.hasPrefix(";") }
        guard let key, let value = snippets[key] else { return nil }
        return SnippetMatch(old: typed + " ", new: value + " ", key: key)
    }
    static func emailKey(_ snippets: [String: String]) -> String? {
        [";mail", ";email", ";e"].first { snippets[$0]?.isEmpty == false }
    }
    static func offer(_ before: String, snippets: [String: String], cues: [SnippetCue]) -> SnippetMatch? {
        let line = before.components(separatedBy: "\n").last ?? ""
        let typed = word(line)
        if !typed.isEmpty, line.hasSuffix(typed) {
            if typed.hasPrefix(";"), typed.count >= 2 {
                let keys = snippets.keys.filter { $0.lowercased().hasPrefix(typed.lowercased()) }.sorted { ($0.count, $0) < ($1.count, $1) }
                if let key = keys.first { return SnippetMatch(old: typed, new: snippets[key]!, key: key) }
            }
            if typed.count >= 2, let key = emailKey(snippets), let email = snippets[key],
               (typed == "AU" || email.lowercased().hasPrefix(typed.lowercased())), typed != email {
                return SnippetMatch(old: typed, new: email, key: key)
            }
        }
        for cue in cues {
            guard cue.regex?.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil,
                  let key = cue.keys.first(where: { snippets[$0]?.isEmpty == false }) else { continue }
            return SnippetMatch(old: "", new: (line.last?.isWhitespace == true ? "" : " ") + snippets[key]!, key: key)
        }
        return nil
    }
}

/// Exact words observed repeatedly, never invented grammar or changed endings.
struct UkrainianEndings {
    private var words: [String: Int] = [:]
    private static let rx = try! NSRegularExpression(pattern: "[А-Яа-яІіЇїЄєҐґ]+(?:['’ʼ][А-Яа-яІіЇїЄєҐґ]+)*")
    private static let prefixRX = try! NSRegularExpression(pattern: "^[А-Яа-яІіЇїЄєҐґ'’ʼ]+$")
    mutating func add(_ text: String) {
        for match in Self.rx.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            if let range = Range(match.range, in: text) { words[String(text[range]).lowercased(), default: 0] += 1 }
        }
    }
    func suffix(_ before: String) -> String? {
        let prefix = SnippetRules.word(before)
        guard prefix.count >= 4, before.hasSuffix(prefix),
              Self.prefixRX.firstMatch(in: prefix, range: NSRange(prefix.startIndex..., in: prefix)) != nil else { return nil }
        let lower = prefix.lowercased()
        // Already-complete words and ambiguous endings stay with the contextual model.
        guard words[lower] == nil else { return nil }
        let matches = words.filter { $0.value >= 3 && $0.key.hasPrefix(lower) }
        guard matches.count == 1, let word = matches.first?.key else { return nil }
        let suffix = String(word.dropFirst(prefix.count))
        return prefix == prefix.uppercased() ? suffix.uppercased() : suffix
    }
}

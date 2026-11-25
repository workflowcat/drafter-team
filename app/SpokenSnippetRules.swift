// Spoken snippets (17 November 2026, plan A2; Wispr Flow's voice snippets): a snippet's spoken cue said as a whole
// clause puts its text in, in place of the cue. Cues: each one-word key gets "my <word>" / "мій <word>" by itself
// (";linkedin" -> "my linkedin"), more come from data/snippet-meta.json {";key": {"say": ["…"]}}; the typing cues
// (dictionary/snippet-cues.json, "my email is") add the value after them, as typing does. At most 2 per take; a cue
// inside a longer clause ("my linkedin is broken", "I updated my linkedin") stays words. Pure:
// tests/spoken_snippet_rules.swift.
import Foundation

struct SpokenCue: Equatable {
    let key: String
    let say: [String]
}

enum SpokenSnippetRules {
    static let limit = 2

    /// The cues for a set of snippets: the said forms from the meta file, and "my <word>" for keys of letters only.
    static func cues(snippets: [String: String], meta: [String: [String]]) -> [SpokenCue] {
        var out: [SpokenCue] = []
        for key in snippets.keys.sorted() where !(snippets[key] ?? "").isEmpty {
            var say = (meta[key] ?? []).map(fold).filter { !$0.isEmpty }
            let word = key.hasPrefix(";") ? String(key.dropFirst()).lowercased() : ""
            if word.count >= 3, word.allSatisfy(\.isLetter) {
                say += ["my " + word]
                if word.unicodeScalars.contains(where: { (0x0400...0x04FF).contains($0.value) }) { say += ["мій " + word, "моя " + word, "моє " + word] }
            }
            if !say.isEmpty { out.append(SpokenCue(key: key, say: Array(Set(say)).sorted())) }
        }
        return out
    }

    /// Lower case, one kind of apostrophe, no punctuation, single spaces.
    static func fold(_ s: String) -> String {
        let t = s.lowercased().replacingOccurrences(of: "’", with: "'").replacingOccurrences(of: "ʼ", with: "'")
        let kept = t.map { $0.isLetter || $0.isNumber || $0 == "'" || $0 == "@" || $0 == "." ? $0 : " " }
        return String(kept).split(separator: " ").joined(separator: " ").trimmingCharacters(in: CharacterSet(charactersIn: "."))
    }

    /// The text with cues put in: the result text, the keys used, and each value as it went in (shape and style
    /// leave those spans alone). `fill` resolves {date}, {;key} and fields (their defaults: voice walks no fields).
    static func expand(_ text: String, cues: [SpokenCue], snippets: [String: String], typingCues: [SnippetCue] = [],
                       fill: (String) -> String = { $0 }) -> (text: String, keys: [String], values: [String]) {
        guard !text.isEmpty, !snippets.isEmpty else { return (text, [], []) }
        var keys: [String] = [], values: [String] = []
        // clauses with their marks: "Here is the link, my linkedin." -> ["Here is the link,", " my linkedin."]
        var parts: [String] = [], cur = ""
        for c in text {
            cur.append(c)
            if ",.!?;:\n".contains(c) { parts.append(cur); cur = "" }
        }
        if !cur.isEmpty { parts.append(cur) }
        var byCue: [String: String] = [:]
        for c in cues { for s in c.say { byCue[s] = byCue[s] ?? c.key } }
        for (i, p) in parts.enumerated() where keys.count < limit {
            let f = fold(p)
            guard !f.isEmpty, let key = byCue[f], let raw = snippets[key], !raw.isEmpty else { continue }
            let value = fill(raw)
            // keep the clause's leading space and its own end mark, unless the mark is a full stop after a link
            let lead = String(p.prefix { $0.isWhitespace })
            var mark = p.last.map { ",.!?;:\n".contains($0) ? String($0) : "" } ?? ""
            if mark == ".", i == parts.count - 1 { mark = "" }
            parts[i] = lead + value + mark
            keys.append(key); values.append(value)
        }
        var out = parts.joined()
        // the typing cues: "… my email is" at the very end gets the value after it
        if keys.count < limit {
            let trimmed = out.trimmingCharacters(in: CharacterSet(charactersIn: " .,!?…"))
            for cue in typingCues {
                guard cue.regex?.firstMatch(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed)) != nil,
                      let key = cue.keys.first(where: { snippets[$0]?.isEmpty == false }) else { continue }
                let value = fill(snippets[key]!)
                guard !out.contains(value) else { break }
                out = trimmed + " " + value
                keys.append(key); values.append(value)
                break
            }
        }
        return (out, keys, values)
    }
}

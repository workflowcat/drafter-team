// Voice-driven "Supertag" routing cues (Wave 8C, inspired by Tana Voice Supertags + Wispr Flow):
// crisp natural spoken cues at the start of a standalone voice take ("Task: …", "Idea: …",
// "Remember for <Name>: …", "Quick note: …", and their Ukrainian equivalents) classify and format
// the note for the Journal ("[Task] …", "[Idea] …", "[For Mila] …", "[Note] …") and produce a
// concise strip confirmation ("Saved as Task", "Saved as Idea", "Note for Mila", "Saved as Note").
// Normal dictation and mid-sentence occurrences are untouched (nil). Pure Foundation:
// tests/voice_supertag_rules.swift.
import Foundation

enum VoiceSupertagKind: String, CaseIterable {
    case task
    case idea
    case remember
    case note
}

struct VoiceSupertagMatch: Equatable {
    let kind: VoiceSupertagKind
    let targetPerson: String?
    let body: String
    let tagPrefix: String
}

enum VoiceSupertagRules {
    private static let minBodyLength = 3
    private static let maxPersonWords = 3
    private static let maxPersonLength = 40

    private static let rememberPrefixes = [
        "remember for",
        "remind for",
        "нагадай для",
        "запам'ятай для",
    ]

    private struct CueSpec {
        let phrase: String
        let kind: VoiceSupertagKind
        let allowBareSpace: Bool
        let allowComma: Bool
        let blockedNextWords: Set<String>
    }

    private static let directCues: [CueSpec] = [
        // Longer multi-word phrases first so they match before any shorter prefix.
        CueSpec(phrase: "note to self", kind: .note, allowBareSpace: true, allowComma: true,
                blockedNextWords: ["is", "was", "are", "were", "has", "have", "had", "will", "would"]),
        CueSpec(phrase: "quick note", kind: .note, allowBareSpace: true, allowComma: true,
                blockedNextWords: ["is", "was", "are", "were", "has", "have", "had", "will", "would"]),
        CueSpec(phrase: "to do", kind: .task, allowBareSpace: false, allowComma: true, blockedNextWords: []),
        CueSpec(phrase: "to-do", kind: .task, allowBareSpace: true, allowComma: true,
                blockedNextWords: ["list", "lists", "item", "items", "is", "was", "are", "were", "has", "have", "had", "will", "would"]),
        CueSpec(phrase: "todo", kind: .task, allowBareSpace: true, allowComma: false,
                blockedNextWords: ["list", "lists", "item", "items", "is", "was", "are", "were", "has", "have", "had", "will", "would"]),
        CueSpec(phrase: "task", kind: .task, allowBareSpace: false, allowComma: false, blockedNextWords: []),
        CueSpec(phrase: "задача", kind: .task, allowBareSpace: false, allowComma: false, blockedNextWords: []),
        CueSpec(phrase: "завдання", kind: .task, allowBareSpace: false, allowComma: false, blockedNextWords: []),
        CueSpec(phrase: "idea", kind: .idea, allowBareSpace: false, allowComma: false, blockedNextWords: []),
        CueSpec(phrase: "ідея", kind: .idea, allowBareSpace: false, allowComma: false, blockedNextWords: []),
        CueSpec(phrase: "нотатка", kind: .note, allowBareSpace: false, allowComma: false, blockedNextWords: []),
    ]

    private static let personStopWords: Set<String> = [
        "the", "a", "an", "that", "this", "it", "what", "when", "where", "why", "how", "all",
        "що", "це", "те", "той", "та", "тут", "там",
    ]

    private static let nameParticles: Set<String> = [
        "de", "da", "del", "van", "von", "la", "le", "di",
    ]

    /// Parses a leading spoken supertag cue from a finished voice take.
    /// Returns nil for normal prose, mid-sentence mentions, or bodies shorter than 3 characters.
    static func parse(_ text: String) -> VoiceSupertagMatch? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let normalized = normalizeApostrophes(trimmed)

        if let match = parseRemember(original: trimmed, normalized: normalized) {
            return match
        }
        return parseDirect(original: trimmed, normalized: normalized)
    }

    /// Formats a matched supertag for Journal storage so it is searchable, filterable, and clusters cleanly.
    static func formatForJournal(_ match: VoiceSupertagMatch) -> String {
        "\(match.tagPrefix) \(match.body)"
    }

    /// Concise Pill strip confirmation for a captured supertag.
    static func pillSummary(_ match: VoiceSupertagMatch) -> String {
        switch match.kind {
        case .task: return "Saved as Task"
        case .idea: return "Saved as Idea"
        case .remember:
            if let person = match.targetPerson, !person.isEmpty {
                return "Note for \(person)"
            }
            return "Saved as Note"
        case .note: return "Saved as Note"
        }
    }

    // MARK: - Parsing helpers

    private static func normalizeApostrophes(_ s: String) -> String {
        s.replacingOccurrences(of: "’", with: "'")
            .replacingOccurrences(of: "ʼ", with: "'")
    }

    /// Slices `original` after `prefixCount` characters if `normalized` starts with `prefix` (case-insensitive).
    private static func dropPrefix(_ prefix: String, original: String, normalized: String) -> Substring? {
        guard normalized.count >= prefix.count else { return nil }
        let normEnd = normalized.index(normalized.startIndex, offsetBy: prefix.count)
        guard normalized[..<normEnd].lowercased() == prefix else { return nil }
        let origEnd = original.index(original.startIndex, offsetBy: prefix.count)
        return original[origEnd...]
    }

    private static func parseDirect(original: String, normalized: String) -> VoiceSupertagMatch? {
        for spec in directCues {
            guard let afterCue = dropPrefix(spec.phrase, original: original, normalized: normalized) else { continue }
            guard let rawBody = extractBodyAfterCue(afterCue, allowBareSpace: spec.allowBareSpace, allowComma: spec.allowComma, blockedNextWords: spec.blockedNextWords) else {
                continue
            }
            guard let body = cleanBody(rawBody) else { return nil }
            let prefix: String
            switch spec.kind {
            case .task: prefix = "[Task]"
            case .idea: prefix = "[Idea]"
            case .note: prefix = "[Note]"
            case .remember: prefix = "[Remember]"
            }
            return VoiceSupertagMatch(kind: spec.kind, targetPerson: nil, body: body, tagPrefix: prefix)
        }
        return nil
    }

    private static func parseRemember(original: String, normalized: String) -> VoiceSupertagMatch? {
        for prefix in rememberPrefixes {
            guard let afterCue = dropPrefix(prefix, original: original, normalized: normalized) else { continue }
            // Must be followed by at least one horizontal space before <Name>.
            guard let first = afterCue.first, first == " " || first == "\t" else { continue }
            let rest = afterCue.drop(while: { $0 == " " || $0 == "\t" })
            guard let (rawPerson, rawBody) = splitPersonAndBody(rest) else { return nil }
            guard let person = cleanPerson(rawPerson), let body = cleanBody(rawBody) else { return nil }
            return VoiceSupertagMatch(kind: .remember, targetPerson: person, body: body, tagPrefix: "[For \(person)]")
        }
        return nil
    }

    /// Extracts the raw body slice after a direct cue, enforcing a clear pause separator
    /// (or bare space only for unambiguous command cues not followed by prose continuation words).
    private static func extractBodyAfterCue(_ after: Substring, allowBareSpace: Bool, allowComma: Bool, blockedNextWords: Set<String>) -> Substring? {
        guard let first = after.first else { return nil }
        let hadHorizontalSpace = first == " " || first == "\t"
        let trimmedLead = after.drop(while: { $0 == " " || $0 == "\t" })
        guard !trimmedLead.isEmpty else { return nil }

        if let afterSep = consumeSeparator(trimmedLead, allowComma: allowComma) {
            return afterSep
        }
        if hadHorizontalSpace, allowBareSpace {
            let firstWord = String(trimmedLead.prefix(while: { $0.isLetter || $0 == "'" || $0 == "’" || $0 == "-" })).lowercased()
            guard !firstWord.isEmpty, !blockedNextWords.contains(firstWord) else { return nil }
            return trimmedLead
        }
        return nil
    }

    /// Consumes a leading pause separator (`:`, `—`, `–`, `…`, `\n`, `- `, `. ` / `...`, and `,` only when allowed).
    /// Returns the remainder after the separator, or nil if no valid separator begins `s`.
    private static func consumeSeparator(_ s: Substring, allowComma: Bool) -> Substring? {
        guard let c = s.first else { return nil }
        let rest = s.dropFirst()
        switch c {
        case ":", "—", "–", "…", "\n", "\r":
            return rest
        case ",":
            return allowComma ? rest : nil
        case "-":
            // Require whitespace after ASCII hyphen so hyphenated compounds like "Task-based" never match.
            guard let next = rest.first, next.isWhitespace else { return nil }
            return rest
        case ".":
            // Require whitespace or ellipsis ("...") after period so filenames like "Task.swift" never match.
            guard let next = rest.first, next.isWhitespace || next == "." else { return nil }
            return rest
        default:
            return nil
        }
    }

    /// Splits `"<Name><sep><body>"` where `<Name>` is 1...3 words before `:`, `,`, `—`, `–`, `\n`, `…`, spaced `-`, or non-initial `.`.
    private static func splitPersonAndBody(_ rest: Substring) -> (Substring, Substring)? {
        var i = rest.startIndex
        while i < rest.endIndex {
            let c = rest[i]
            let nextIdx = rest.index(after: i)
            let isStrong: Bool
            switch c {
            case ":", ",", "—", "–", "…", "\n", "\r":
                isStrong = true
            case "-":
                let prevIsSpace = i > rest.startIndex && rest[rest.index(before: i)].isWhitespace
                let nextIsSpace = nextIdx < rest.endIndex && rest[nextIdx].isWhitespace
                isStrong = prevIsSpace || nextIsSpace
            case ".":
                // A single-letter initial like "J." before a surname is part of the name, not the end delimiter.
                let before = rest[..<i]
                let lastToken = before.split(whereSeparator: \.isWhitespace).last ?? ""
                let nextIsSpace = nextIdx < rest.endIndex && (rest[nextIdx].isWhitespace || rest[nextIdx] == ".")
                isStrong = nextIsSpace && lastToken.count >= 2
            default:
                isStrong = false
            }
            if isStrong {
                return (rest[..<i], rest[nextIdx...])
            }
            i = nextIdx
        }
        return nil
    }

    private static func cleanPerson(_ raw: Substring) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= maxPersonLength else { return nil }
        let words = trimmed.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty, words.count <= maxPersonWords else { return nil }

        let allowedPunct: Set<Character> = ["'", "’", "ʼ", "-", "."]
        for w in words {
            guard w.contains(where: \.isLetter) else { return nil }
            guard w.allSatisfy({ $0.isLetter || allowedPunct.contains($0) }) else { return nil }
        }
        let letterCount = trimmed.filter(\.isLetter).count
        guard letterCount >= 2 else { return nil }
        if words.count == 1, personStopWords.contains(words[0].lowercased()) { return nil }

        let formatted = words.enumerated().map { idx, w -> String in
            let lower = w.lowercased()
            if idx > 0, nameParticles.contains(lower), w == lower { return w }
            let hasUpper = w.contains(where: \.isUppercase)
            guard !hasUpper, let first = w.first, first.isLowercase else { return w }
            return String(first).uppercased() + w.dropFirst()
        }.joined(separator: " ")
        return formatted
    }

    private static func cleanBody(_ raw: Substring) -> String? {
        let sepChars: Set<Character> = [":", ",", "—", "–", "-", ".", "…"]
        var s = String(raw).trimmingCharacters(in: .whitespacesAndNewlines)
        while let first = s.first, sepChars.contains(first) || first.isWhitespace {
            s.removeFirst()
        }
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard s.count >= minBodyLength, s.contains(where: { $0.isLetter || $0.isNumber }) else { return nil }

        // Capitalize the first character if it is a lowercase letter and not a camel-cased brand (e.g. "iOS", "macOS").
        if let first = s.first, first.isLowercase {
            let secondIsUpper = s.dropFirst().first?.isUppercase ?? false
            if !secondIsUpper {
                s = String(first).uppercased() + s.dropFirst()
            }
        }
        return s
    }
}

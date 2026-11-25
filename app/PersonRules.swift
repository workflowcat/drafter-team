// Pure local contact matching. The pack contains only public-scope Aleph rows.
import Foundation

struct KnownPerson: Decodable {
    let name: String
    let kind: String
    let aliases: [String]
    let tokens: [String]
    let forms: [String]
    let heat: Double
    let handles: [String: [String]]
    let scope: String?
    var searchable: [String] { [name] + aliases + tokens + forms }
    var values: [(kind: String, value: String)] {
        ["email", "phone", "tg"].flatMap { key in
            (handles[key] ?? []).filter { !$0.isEmpty }.map { (key, $0) }
        }
    }
    var label: String {
        let parts = name.split(separator: " ")
        guard parts.count > 1, let last = parts.last?.first else { return name }
        return String(parts[0]) + " " + String(last) + "."
    }
}
struct PersonChoice {
    let person: KnownPerson
    let old: String
    let prefix: String
    let preferred: String?
}

enum PersonRules {
    private static let patterns: [(NSRegularExpression, String, Bool)] = ([
                (#"(?i)([\p{L}'’ʼ-]+(?:\s+[\p{L}'’ʼ-]+)*)['’]s\s+email\s*[:?]?\s*$"#, "email"),
                (#"(?i)\bemail of\s+([\p{L}'’ʼ-]+(?:\s+[\p{L}'’ʼ-]+)*)\s*[:?]?\s*$"#, "email"),
                (#"(?i)\bпошта\s+([\p{L}'’ʼ-]+(?:\s+[\p{L}'’ʼ-]+)*)\s*[:?]?\s*$"#, "email"),
                (#"(?i)\b(?:телефон|номер)\s+([\p{L}'’ʼ-]+(?:\s+[\p{L}'’ʼ-]+)*)\s*[:?]?\s*$"#, "phone")]) .enumerated().map { index, item in
        (try! NSRegularExpression(pattern: item.0), item.1, index == 0)
    }

    static func matches(_ before: String, people: [KnownPerson], reserved: Set<String> = []) -> [PersonChoice] {
        let line = before.components(separatedBy: "\n").last ?? ""
        let typed = String(line.split(whereSeparator: { $0.isWhitespace }).last ?? "")
        var query = "", old = "", prefix = "", preferred: String?, partial = false, possessive = false
        if typed.hasPrefix(";"), line.hasSuffix(typed) {
            guard !reserved.contains(where: { $0.lowercased().hasPrefix(typed.lowercased()) }) else { return [] }
            query = String(typed.dropFirst()); old = typed; partial = true
            guard query.count >= 2, query.allSatisfy({ $0.isLetter || "'’ʼ-".contains($0) }) else { return [] }
        } else {
            for (rx, kind, isPossessive) in patterns {
                guard let match = rx.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
                      let range = Range(match.range(at: 1), in: line) else { continue }
                query = String(line[range]); preferred = kind; possessive = isPossessive; break
            }
            guard !query.isEmpty else { return [] }
            prefix = line.last?.isWhitespace == true ? "" : " "
        }
        let q = query.lowercased()
        return people.filter { p in
            guard p.kind == "person", p.scope != "private", !p.values.isEmpty else { return false }
            if let preferred, p.handles[preferred]?.isEmpty != false { return false }
            return p.searchable.contains { value in
                let v = value.lowercased()
                if partial { return v.hasPrefix(q) }
                if !possessive { return v == q }
                // A full label/pair is unambiguous. A single name must be the whole
                // subject; strip only a small command vocabulary, never arbitrary names.
                var subject = q.split(whereSeparator: { $0.isWhitespace }).map(String.init)
                while let first = subject.first, ["please", "send", "share", "give", "me", "show"].contains(first) { subject.removeFirst() }
                let subjectName = subject.joined(separator: " ")
                let labels = ([p.name] + p.aliases).map { $0.lowercased() }
                if labels.contains(subjectName) { return v == subjectName }
                return subject.count == 1 && v == subjectName

            }
        }.sorted { $0.heat == $1.heat ? $0.name < $1.name : $0.heat > $1.heat }
            .map { PersonChoice(person: $0, old: old, prefix: prefix, preferred: preferred) }
    }
    static func wrap(_ index: Int, count: Int) -> Int { count == 0 ? 0 : (index % count + count) % count }
    static func action(_ choices: [PersonChoice], person: Int, handle: Int) -> [String: Any]? {
        guard !choices.isEmpty else { return nil }
        let choice = choices[wrap(person, count: choices.count)]
        let values = choice.person.values
        guard !values.isEmpty else { return nil }
        let base = choice.preferred.flatMap { key in values.firstIndex { $0.kind == key } } ?? 0
        let value = values[wrap(base + handle, count: values.count)]
        let label = value.kind == "tg" ? "Telegram" : value.kind
        return ["id": "person", "chip": choice.person.label + " · " + label + " · " + value.value,
                "run": ["kind": "expand", "old": choice.old, "new": choice.prefix + value.value, "key": "person"]]
    }
}

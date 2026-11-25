// The people his recordings name, kept on this Mac (17 November 2026, Andrii: match the speakers to people, give each
// person the nicknames and name forms used in the transcript). data/speakers.json: {"people": {"<name>": ["<form>", …]}}.
// The forms go to the reader as names to expect when that person is in the meeting (TalkRecord.transcribe). Pure
// Foundation: tests/people_book.swift.
import Foundation

struct PeopleBook {
    var people: [String: [String]] = [:]

    static func load(_ url: URL) -> PeopleBook {
        guard let d = try? Data(contentsOf: url), let j = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any],
              let p = j["people"] as? [String: [String]] else { return PeopleBook() }
        return PeopleBook(people: p)
    }
    func save(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: ["people": people], options: [.sortedKeys, .prettyPrinted]).write(to: url, options: .atomic)
    }

    /// "Міла, Mila S., міла" -> ["Міла", "Mila S."]: trimmed, the person's own name and repeats (any case) left out.
    static func forms(_ text: String, name: String) -> [String] {
        var out: [String] = []
        for f in text.split(whereSeparator: { $0 == "," || $0 == "\n" || $0 == ";" }) {
            let t = f.trimmingCharacters(in: .whitespaces)
            guard !t.isEmpty, t.lowercased() != name.lowercased(), !out.contains(where: { $0.lowercased() == t.lowercased() }) else { continue }
            out.append(t)
        }
        return out
    }

    mutating func add(_ name: String) { let n = name.trimmingCharacters(in: .whitespaces); if !n.isEmpty, people[n] == nil { people[n] = [] } }
    mutating func set(_ name: String, forms text: String) { add(name); people[name] = PeopleBook.forms(text, name: name) }

    /// Every name and form to expect for these people (the event's attendees, the speakers he named), each once.
    func expected(_ names: [String]) -> [String] {
        var out: [String] = []
        for n in names {
            let key = people.keys.first { $0.lowercased() == n.lowercased() } ?? n
            for x in [key] + (people[key] ?? []) where !out.contains(x) { out.append(x) }
        }
        return out
    }

    /// The people to offer for a speaker: the meeting's people first, then the ones named in recordings before, by name.
    static func suggestions(event: [String], named: [String], known: [String], me: Set<String>) -> [String] {
        var out: [String] = []
        for n in event + named + known.sorted() {
            let t = n.trimmingCharacters(in: .whitespaces)
            guard !t.isEmpty, !me.contains(t.lowercased()), !out.contains(where: { $0.lowercased() == t.lowercased() }) else { continue }
            out.append(t)
        }
        return out
    }
}

// Contact mentions from the keyboard (17 November 2026, the user; `@` dropped the same day: it clashes with the mention
// pickers of Notion, Claude, Slack and other apps), pure. Two ways in, both fully local (data/entities.json, the `;`
// card's store of contacts and people cards); nothing is sent.
// - `;ana` (3+ letters, the `;` family of snippets and quick starts): a small list of people; a number puts in one field of
//   the chosen one. The numbers never move: 1 name, 2 phone, 3 email, 4 address, 5 company, 6 a one-line card. So
//   `;ana 2` is always Ana's phone. Reserved words win: a snippet key, a quick start, `;ctx`
//   `;en` `;uk`, or any key the typed word begins. In AI assistants and coding agents a
//   plain `;ana` stays the `;` card (it attaches context); `;ana 2` works there too.
// - No trigger: a known person's name with a field word at the end of the line ("Ana's number", "email of Ana",
//   "номер Ані", "Ана пошта") offers that field as a chip; Tab puts it after the words.
import Foundation

struct MentionTyped: Equatable {
    let old: String      // what goes away when a field goes in: `@ana`, `@@ana `, `@ana 2`
    let query: String    // `ana`
    let pick: Int?       // `@ana 2` -> 2: put that field in at once
}

struct MentionSlot: Equatable {
    let key: Int         // 1...6
    let label: String
    let text: String?    // nil: this person has none
}

enum MentionRules {
    static let labels = ["name", "phone", "email", "address", "company", "card"]
    static let most = 5

    /// Here a plain `;name` is the `;` card's (context for an assistant or an agent), not the list.
    static func cardFirst(_ dest: String) -> Bool { dest == "ai" || dest == "agent" }
    static let reservedWords: Set<String> = [";ctx", ";en", ";uk"]

    private static let rx = try! NSRegularExpression(pattern: #"(?:^|[\s(\[«"'])(;([\p{L}][\p{L}'’ʼ-]{2,29}))( ([1-6])?)?$"#)

    /// The end of the line before the caret, read as a mention, or nil. `reserved`: snippet keys and quick starts.
    static func parse(_ before: String, reserved: Set<String> = []) -> MentionTyped? {
        let line = before.components(separatedBy: "\n").last ?? ""
        guard line.contains(";"),
              let m = rx.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
              let tok = Range(m.range(at: 1), in: line), let q = Range(m.range(at: 2), in: line) else { return nil }
        let typed = line[tok].lowercased()
        if reservedWords.union(reserved).contains(where: { $0.lowercased().hasPrefix(typed) || typed == $0.lowercased() }) { return nil }
        let pick = Range(m.range(at: 4), in: line).flatMap { Int(line[$0]) }
        return MentionTyped(old: String(line[tok.lowerBound...]), query: String(line[q]), pick: pick)
    }

    // MARK: no trigger: "Ana's number"

    /// A field word -> its key (2 phone, 3 email, 4 address, 5 company).
    static let fieldWords: [String: Int] = [
        "number": 2, "phone": 2, "mobile": 2, "номер": 2, "телефон": 2, "мобільний": 2, "мобілка": 2,
        "email": 3, "e-mail": 3, "mail": 3, "пошта": 3, "пошту": 3, "імейл": 3, "мейл": 3,
        "address": 4, "адреса": 4, "адресу": 4,
        "company": 5, "компанія": 5, "компанію": 5]

    /// The words that may name a person, and the field asked, from the end of the line: "<name>'s <field>",
    /// "<name> <field>", "<field> of <name>", "<field> <name>". Up to 3 name words.
    static func asked(_ before: String) -> (names: [String], key: Int)? {
        let line = before.components(separatedBy: "\n").last ?? ""
        let words = line.replacingOccurrences(of: #"[:?]\s*$"#, with: "", options: .regularExpression)
            .split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard words.count >= 2 else { return nil }
        func clean(_ w: String) -> String { w.trimmingCharacters(in: CharacterSet(charactersIn: ",.!\"«»()")) }
        let last = clean(words[words.count - 1]).lowercased()
        // "<name>('s) <field>"
        if let key = fieldWords[last] {
            var names: [String] = []
            for n in 1...3 where words.count - 1 - n >= 0 {
                var ws = Array(words[(words.count - 1 - n)..<(words.count - 1)]).map(clean)
                if let l = ws.last { ws[ws.count - 1] = l.replacingOccurrences(of: #"['’]s$"#, with: "", options: .regularExpression) }
                names.append(ws.joined(separator: " "))
            }
            return names.isEmpty ? nil : (names, key)
        }
        // "<field> (of) <name>"
        for n in 1...3 where words.count - n - 1 >= 0 {
            var at = words.count - n - 1
            let name = words[(at + 1)...].map(clean).joined(separator: " ")
            if words[at].lowercased() == "of", at >= 1 { at -= 1 }
            if let key = fieldWords[clean(words[at]).lowercased()] { return ([name], key) }
        }
        return nil
    }

    /// The chip for "Ana's number": the person (an exact name, alias or case form; people only, not private, one
    /// clear best) and the field. nil when no one or the field is empty.
    static func ask(_ before: String, in store: EntityStore) -> (index: Int, key: Int, text: String)? {
        guard let (names, key) = asked(before) else { return nil }
        for name in names.sorted(by: { $0.count > $1.count }) where name.count >= 2 {
            let f = EntityRules.fold(name)
            if store.surfaceFlags[f]?.ordinary == true { continue }   // a name that is also an ordinary word: no chip
            let hits = (store.surfaces[f] ?? []).map(\.index).filter {
                $0 < store.records.count && store.records[$0].kind == "person" && !store.records[$0].isPrivate
            }
            guard let i = hits.max(by: { (store.records[$0].heat ?? 0) < (store.records[$1].heat ?? 0) }) else { continue }
            guard let text = MentionRules.text(store.records[i], key: key) else { return nil }
            return (i, key, oneLine(text))
        }
        return nil
    }

    /// The people for a query: EntityRules.find's order (an exact name first, warmest next), people only, never one
    /// marked private.
    static func people(_ q: String, in store: EntityStore) -> [Int] {
        Array(EntityRules.find(q, in: store, limit: 12).filter {
            let e = store.records[$0]
            return e.kind == "person" && !e.isPrivate
        }.prefix(most))
    }

    /// The company: the contact's organisation, else the "at X" end of the who line.
    static func company(_ e: Entity) -> String? {
        if let o = e.org?.trimmingCharacters(in: .whitespaces), !o.isEmpty { return o }
        let who = e.whoLine
        if let r = who.range(of: #"(?:^|, )at (.+)$"#, options: .regularExpression) {
            let s = who[r].replacingOccurrences(of: #"^(?:, )?at "#, with: "", options: .regularExpression)
            return s.isEmpty ? nil : s
        }
        return nil
    }

    private static func first(_ e: Entity, _ key: String) -> String? {
        (e.handles?[key] ?? []).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.first { !$0.isEmpty }
    }

    /// The six fields, always in the same order.
    static func slots(_ e: Entity) -> [MentionSlot] {
        let phone = first(e, "phone"), email = first(e, "email"), address = first(e, "address").map(oneLine), org = company(e)
        var role = e.whoLine
        if role.isEmpty, let org { role = org }
        let card = [e.name, role, phone, email].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
        let texts: [String?] = [e.name, phone, email, address, org, card]
        return zip(labels, texts).enumerated().map { MentionSlot(key: $0.offset + 1, label: $0.element.0, text: $0.element.1) }
    }

    /// What field `key` puts in, or nil when this person has none.
    static func text(_ e: Entity, key: Int) -> String? {
        guard (1...labels.count).contains(key) else { return nil }
        return slots(e)[key - 1].text
    }

    /// Text with line breaks goes in as one line (a break in a chat box can send it).
    static func oneLine(_ s: String) -> String { s.split(whereSeparator: { $0.isNewline }).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: ", ") }
}

// swiftc -O -parse-as-library app/NameRules.swift tests/name_rules.swift -o app/build/name-rules-test && app/build/name-rules-test
// Made-up names only. Run from the repo root (reads tests/names_cases.json, the golden cases engine/names.py runs too).
import Foundation

@main struct Checks {
    static func norm(_ v: Any) -> String {
        String(decoding: try! JSONSerialization.data(withJSONObject: ["v": v], options: [.sortedKeys]), as: UTF8.self)
    }
    static func main() throws {
        let cases = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: "tests/names_cases.json"))) as! [[String: Any]]
        for c in cases {
            var es = c["entries"] as! [[String: Any]]
            NameRules.apply(&es, c["edits"] as! [[String: Any]])
            let fields = c["fields"] as! [String]
            var got: [String: Any] = [:]
            for e in es { got[e["id"] as! String] = Dictionary(uniqueKeysWithValues: fields.map { ($0, e[$0] ?? NSNull()) }) }
            precondition(norm(got) == norm(c["expect"]!), "case \(c["name"]!):\n\(norm(got))\n\(norm(c["expect"]!))")
        }
        // search: words of names and forms, mishearings, emails, phone digits; hidden ones only under "hidden"
        let es: [[String: Any]] = [
            ["id": "a", "kind": "person", "uk": "Ганна Квітка", "latin": "Hanna Kvitka", "forms": ["Ганною"], "heard": ["hana"], "phones": ["+380 00 000 0001"], "emails": ["hanna@example.test"]],
            ["id": "b", "kind": "project", "uk": "", "latin": "Bramblix", "hidden": true],
            ["id": "c", "kind": "company", "uk": "", "latin": "Larkspur Labs", "short": ["Larkspur"]]]
        precondition(NameRules.filter(es, kind: "", query: "") == [0, 2])
        precondition(NameRules.filter(es, kind: "", query: "ганною") == [0])
        precondition(NameRules.filter(es, kind: "", query: "HANA") == [0])
        precondition(NameRules.filter(es, kind: "", query: "example.test") == [0])
        precondition(NameRules.filter(es, kind: "", query: "000 0001") == [0])
        precondition(NameRules.filter(es, kind: "", query: "lark") == [2])
        precondition(NameRules.filter(es, kind: "company", query: "") == [2])
        precondition(NameRules.filter(es, kind: "hidden", query: "") == [1])
        precondition(NameRules.filter(es, kind: "", query: "zz") == [])
        precondition(NameRules.fold("  Ганна’s   X ") == "ганна's x")

        // kind edit op (golden twin of engine/names.py apply_edits)
        var kindEntries: [NameRules.Entry] = [
            ["id": "k1", "kind": "term", "uk": "", "latin": "Orchard Studio", "formed": true],
            ["id": "k2", "kind": "person", "uk": "Олена Коваль", "latin": "Olena Koval"],
        ]
        let appliedKind = NameRules.apply(&kindEntries, [
            ["op": "kind", "id": "k1", "kind": "company"],
            ["op": "kind", "id": "k2", "kind": "invalid_kind"],
            ["op": "kind", "id": "missing", "kind": "project"],
        ])
        precondition(appliedKind == 1, "only valid kind edit applies")
        precondition(NameRules.str(kindEntries[0], "kind") == "company")
        precondition(kindEntries[0]["edited"] as? Bool == true)
        precondition(kindEntries[0]["formed"] == nil)
        precondition(NameRules.str(kindEntries[1], "kind") == "person")

        // transliteration (Ukrainian Cyrillic -> Latin)
        precondition(NameRules.translitToLatin("Олена Коваль") == "olena koval")
        precondition(NameRules.translitToLatin("Olena Koval") == "olena koval")
        precondition(NameRules.translitToLatin("Тарас Мельник") == "taras melnyk")
        precondition(NameRules.translitToLatin("Щербак") == "shcherbak")
        precondition(NameRules.translitToLatin("Шевченко") == "shevchenko")
        precondition(NameRules.translitToLatin("Чорний") == "chornyi")
        precondition(NameRules.translitToLatin("Жук") == "zhuk")
        precondition(NameRules.translitToLatin("Хмельницький") == "khmelnytskyi")
        precondition(NameRules.translitToLatin("Цимбал") == "tsymbal")
        precondition(NameRules.translitToLatin("Юрій") == "yurii")
        precondition(NameRules.translitToLatin("Ярослав") == "yaroslav")
        precondition(NameRules.translitToLatin("Євген") == "yevhen")
        precondition(NameRules.translitToLatin("Їжак") == "yizhak")
        precondition(NameRules.translitToLatin("Київ") == "kyiv")
        precondition(NameRules.translitToLatin("Ґалаґан") == "galagan")
        precondition(NameRules.translitToLatin("Мар’яна") == "mariana")

        // duplicate detection
        let dupEntries: [NameRules.Entry] = [
            // same email (case-insensitive); target is e1 (higher weight)
            ["id": "e1", "kind": "person", "uk": "Олена Коваль", "latin": "Olena Koval", "emails": ["olena@example.test"], "weight": 40.0, "context": ["lines": 20, "chats": 2, "last_seen": "2026-11-10"]],
            ["id": "e2", "kind": "person", "uk": "", "latin": "O. Koval", "emails": ["OLENA@EXAMPLE.TEST"], "weight": 2.0, "context": ["lines": 1, "chats": 0, "last_seen": "2026-10-01"]],
            // same phone (last 9 digits)
            ["id": "p1", "kind": "person", "uk": "", "latin": "Taras Melnyk", "phones": ["+380 50 123 4567"], "weight": 15.0, "context": ["lines": 8, "chats": 1, "last_seen": "2026-11-12"]],
            ["id": "p2", "kind": "person", "uk": "", "latin": "Taras M", "phones": ["050-123-4567"], "weight": 1.0, "context": ["lines": 0, "chats": 0, "last_seen": ""]],
            // folded alias overlap
            ["id": "a1", "kind": "company", "uk": "", "latin": "Orchard Studio", "short": ["Orchard"], "weight": 30.0, "context": ["lines": 12, "chats": 1, "last_seen": "2026-11-05"]],
            ["id": "a2", "kind": "company", "uk": "", "latin": "Orchard", "weight": 3.0, "context": ["lines": 1, "chats": 0, "last_seen": "2026-10-02"]],
            // Ukrainian <-> Latin transliterated match
            ["id": "u1", "kind": "person", "uk": "Богдан Кравченко", "latin": "", "weight": 12.0, "context": ["lines": 6, "chats": 1, "last_seen": "2026-11-08"]],
            ["id": "u2", "kind": "person", "uk": "", "latin": "Bohdan Kravchenko", "weight": 4.0, "context": ["lines": 2, "chats": 0, "last_seen": "2026-10-15"]],
            // hidden entry must be ignored
            ["id": "h1", "kind": "person", "uk": "", "latin": "Bohdan Kravchenko", "emails": ["olena@example.test"], "hidden": true, "weight": 100.0],
        ]
        let dups = NameRules.findDuplicates(dupEntries)
        precondition(dups.count == 4, "expected 4 duplicate pairs, got \(dups)")
        precondition(dups[0] == NameRules.DuplicateSuggestion(id: "e2->e1", sourceId: "e2", targetId: "e1", reason: "Same email", score: 100))
        precondition(dups[1] == NameRules.DuplicateSuggestion(id: "p2->p1", sourceId: "p2", targetId: "p1", reason: "Same phone", score: 95))
        precondition(dups[2] == NameRules.DuplicateSuggestion(id: "a2->a1", sourceId: "a2", targetId: "a1", reason: "Shared name or alias", score: 90))
        precondition(dups[3] == NameRules.DuplicateSuggestion(id: "u2->u1", sourceId: "u2", targetId: "u1", reason: "Ukrainian / Latin match", score: 85))
        precondition(Set(dups.map(\.sourceId)).count == dups.count, "each sourceId appears at most once")

        // clutter detection
        let clutterEntries: [NameRules.Entry] = [
            ["id": "c_unused", "kind": "term", "uk": "", "latin": "Stale Term", "context": ["lines": 0, "chats": 0], "card": false],
            ["id": "c_card", "kind": "person", "uk": "", "latin": "Card Contact", "context": ["lines": 0, "chats": 0], "card": true],
            ["id": "c_edited", "kind": "term", "uk": "", "latin": "Kept Term", "context": ["lines": 0, "chats": 0], "edited": true],
            ["id": "c_hidden", "kind": "term", "uk": "", "latin": "Hidden Term", "context": ["lines": 0, "chats": 0], "hidden": true],
            ["id": "c_short", "kind": "term", "uk": "", "latin": "ok", "context": ["lines": 1, "chats": 0], "card": false],
            ["id": "c_url", "kind": "term", "uk": "", "latin": "https://example.test/page", "context": ["lines": 0, "chats": 0]],
            ["id": "c_handle", "kind": "term", "uk": "", "latin": "@orchard_bot", "context": ["lines": 1, "chats": 0]],
            ["id": "c_digits", "kind": "term", "uk": "", "latin": "2026-11-23", "context": ["lines": 0, "chats": 0]],
            ["id": "c_phone", "kind": "person", "uk": "", "latin": "Phone Only", "phones": ["+380 50 000 0000"], "context": ["lines": 0, "chats": 0]],
        ]
        let clutter = NameRules.findClutter(clutterEntries)
        let clutterById = Dictionary(uniqueKeysWithValues: clutter.map { ($0.id, $0.reason) })
        precondition(clutterById["c_unused"] == "Unused (0 mentions)")
        precondition(clutterById["c_short"] == "Noise / fragment")
        precondition(clutterById["c_url"] == "Noise / fragment")
        precondition(clutterById["c_handle"] == "Noise / fragment")
        precondition(clutterById["c_digits"] == "Noise / fragment")
        precondition(clutterById["c_card"] == nil && clutterById["c_edited"] == nil && clutterById["c_hidden"] == nil && clutterById["c_phone"] == nil)

        // sort modes
        let sortEntries: [NameRules.Entry] = [
            ["id": "s1", "kind": "person", "uk": "", "latin": "Zora Vale", "weight": 10.0, "context": ["last_seen": "2026-11-20"]],
            ["id": "s2", "kind": "person", "uk": "", "latin": "Alina Brook", "weight": 5.0, "context": ["last_seen": "2026-10-01"]],
            ["id": "s3", "kind": "person", "uk": "", "latin": "Mykola Pine", "weight": 30.0, "context": ["last_seen": "2026-11-05"]],
        ]
        precondition(NameRules.sort([0, 1, 2], in: sortEntries, by: .weight) == [2, 0, 1])
        precondition(NameRules.sort([0, 1, 2], in: sortEntries, by: .recent) == [0, 2, 1])
        precondition(NameRules.sort([0, 1, 2], in: sortEntries, by: .alpha) == [1, 2, 0])

        // performance guard: 2,000 entries under 50 ms
        var big: [NameRules.Entry] = []
        big.reserveCapacity(2000)
        for i in 0..<2000 {
            big.append(["id": "n\(i)", "kind": "person", "uk": "", "latin": "Person \(i)", "weight": Double(i % 50),
                        "emails": i % 100 == 0 ? ["shared\(i / 200)@example.test"] : [],
                        "context": ["lines": i % 10, "chats": 0, "last_seen": "2026-11-01"]])
        }
        let t0 = Date()
        let bigDups = NameRules.findDuplicates(big)
        let elapsedMs = Date().timeIntervalSince(t0) * 1000
        precondition(!bigDups.isEmpty && elapsedMs < 50, "findDuplicates(2000) took \(elapsedMs) ms")

        print("name rules: \(cases.count) golden cases, kind, translit, duplicates (\(String(format: "%.1f", elapsedMs)) ms / 2000), clutter, sort ok")
    }
}

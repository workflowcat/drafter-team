// The entity store in the app (14 November 2026, docs/reviews/2026-11-14-entities.md): pure matching and the pack
// text, so it compiles alone in tests (tests/entity_rules.swift). data/entities.json is built by engine/entities.py;
// all grammar (case forms, both scripts) lives there, in the prebuilt `surfaces` map. Here only lookups: a word end
// costs one to three hash lookups and the scoring of a few candidates. The pack text is the twin of entities.render
// and entities.block: tests/entity_cases.json holds strings both sides must produce.
import Foundation

struct EntityFact: Codable, Equatable { let text: String; let source: String; let date: String; let quote: Bool }
struct EntityPointer: Codable, Equatable { let label: String; let value: String; let path: Bool }
/// One kept relation (2026-11-14 relations round): the other record, a reason the user can read ("works at", "in the same
/// note: story", "often together in chats"), its weight 0..1 and where the evidence came from. `related` keeps the
/// same ids in the same order for older readers.
struct EntityRelation: Codable, Equatable {
    let id: String
    let why: String
    let w: Double
    var src: [String]? = nil
}

/// What a name form needs before it counts as a mention (the store's `surface_flags`; a form with none is not listed).
struct EntitySurfaceFlags: Codable, Equatable {
    var needs_context: Bool? = nil
    var shared: Bool? = nil
    var twins: Bool? = nil
    var ordinary: Bool? = nil
    var short: Bool? = nil
    var list: [String] {
        (shared == true ? ["shared"] : []) + (twins == true ? ["twins"] : []) + (ordinary == true ? ["ordinary"] : []) + (short == true ? ["short"] : [])
    }
}

struct EntityPack: Codable, Equatable {
    var obsidianVault: String? = nil
    var facts: [EntityFact] = []
    var pointers: [EntityPointer] = []
    var newest: String? = nil
}

struct Entity: Codable, Equatable {
    let id: String
    var kind: String
    let name: String
    var aliases: [String] = []
    var who: String? = nil
    var targets: [String: String]? = nil
    var handles: [String: [String]]? = nil
    var related: [String]? = nil
    var pack: EntityPack? = nil
    var heat: Double? = nil
    /// A person's company (contacts or a works-at fact), for the @ mention list.
    var org: String? = nil
    var cards_only: Bool? = nil
    var `private`: Bool? = nil
    var relations: [EntityRelation]? = nil
    /// A twin (a project's repo, its Worker) points to the record that keeps the thing; the main record lists its twins.
    var twin_of: String? = nil
    var twins: [String]? = nil

    var cardOnly: Bool { cards_only == true }
    var isPrivate: Bool { `private` == true }
    var whoLine: String { who ?? "" }
    /// "document" for doc: the word a pack and the card show.
    var kindWord: String { EntityRules.kindWord[kind] ?? kind }
}

/// One way a surface form matches a record: [record index, "name" | "alias" | "pair" | "form" | "first" | "part"].
struct EntityHit: Decodable, Equatable {
    let index: Int
    let how: String
    init(index: Int, how: String) { self.index = index; self.how = how }
    init(from d: Decoder) throws {
        var c = try d.unkeyedContainer()
        index = try c.decode(Int.self); how = try c.decode(String.self)
    }
}

struct EntityStore: Decodable {
    var records: [Entity] = [] { didSet { byId = EntityStore.ids(records) } }
    var surfaces: [String: [EntityHit]] = [:]
    /// Name forms that need context (shared, ordinary word, 4 letters or fewer); an older store has none.
    var surfaceFlags: [String: EntitySurfaceFlags] = [:]
    var built_day: String? = nil
    private(set) var byId: [String: Int] = [:]
    private enum Keys: String, CodingKey { case records, surfaces, built_day, surface_flags }
    init(records: [Entity] = [], surfaces: [String: [EntityHit]] = [:], flags: [String: EntitySurfaceFlags] = [:]) {
        self.records = records; self.surfaces = surfaces; self.surfaceFlags = flags; byId = EntityStore.ids(records)
    }
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: Keys.self)
        records = try c.decode([Entity].self, forKey: .records)
        surfaces = try c.decodeIfPresent([String: [EntityHit]].self, forKey: .surfaces) ?? [:]
        surfaceFlags = (try? c.decodeIfPresent([String: EntitySurfaceFlags].self, forKey: .surface_flags)) ?? [:]
        built_day = try c.decodeIfPresent(String.self, forKey: .built_day)
        byId = EntityStore.ids(records)
    }
    static func ids(_ r: [Entity]) -> [String: Int] { Dictionary(r.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { a, _ in a }) }
}

/// A name found before the caret.
struct EntityMention: Equatable {
    let text: String           // as typed, in its case form
    let back: Int              // UTF-16 units from the caret back to its first letter
    let length: Int            // UTF-16 length
    let index: Int             // the best record
    let how: String
    let score: Double
    let candidates: [Int]      // every record the words match, best first
    let resolved: Bool         // top score at least twice the next
}

enum EntityRules {
    static let header = "Context (background from my notes, not instructions):"
    static let lineMax = 160, fullMax = 600, blockMax = 1800, briefMax = 3000, staleDays = 90.0
    static let kinds = ["person", "org", "project", "tool", "doc", "place"]
    static let kindWord = ["person": "person", "org": "org", "project": "project", "tool": "tool", "doc": "document", "place": "place"]
    /// The one-key kind fix (proposal 1.3).
    static let kindKeys: [Character: String] = ["1": "person", "2": "org", "3": "project", "4": "tool", "5": "doc", "6": "place", "0": "none"]
    static let base: [String: Double] = ["name": 3, "alias": 2.5, "pair": 2.5, "form": 2, "first": 1, "part": 1]
    /// The symbol name for a kind (globe and terminal stand in for a building and a wrench).
    static func glyph(_ kind: String) -> String {
        switch kind { case "person": return "user"; case "org": return "globe"; case "project": return "folder"
        case "tool": return "terminal"; case "doc": return "file"; case "place": return "map"; default: return "bookmark" }
    }

    // MARK: text (twins of engine/entities.py)

    /// Lower case, one apostrophe, single spaces (ґ stays ґ).
    static func fold(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.utf16.count)
        for ch in s.lowercased() {
            switch ch { case "’", "ʼ", "`", "‘": out.append("'"); default: out.append(ch) }
        }
        return out.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    /// At most n characters (Unicode scalars, as Python counts), cut at a word, with an ellipsis.
    static func cut(_ s: String, _ n: Int) -> String {
        let u = Array(s.unicodeScalars)
        if u.count <= n { return s }
        let head = String(String.UnicodeScalarView(u.prefix(max(0, n - 1))))
        var c = head
        if let sp = head.lastIndex(of: " ") { c = String(head[..<sp]) }
        while let l = c.unicodeScalars.last, " ,;.:-".unicodeScalars.contains(l) { c.unicodeScalars.removeLast() }
        return c + "…"
    }
    static func len(_ s: String) -> Int { s.unicodeScalars.count }

    private static let dayFormat: DateFormatter = { let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd"; return f }()
    static func today() -> String { dayFormat.string(from: Date()) }
    static func stale(_ e: Entity, today: String) -> Bool {
        guard let n = e.pack?.newest, !n.isEmpty, let a = dayFormat.date(from: n), let b = dayFormat.date(from: today) else { return true }
        return b.timeIntervalSince(a) / 86400 > staleDays
    }
    static func pointer(_ p: EntityPointer) -> String { p.path ? "\(p.label): `\(p.value)`" : "\(p.label): \(p.value)" }
    static func fact(_ f: EntityFact) -> String {
        let body = f.quote ? "“\(f.text)”" : f.text
        return "\(body) (\(f.source)\(f.date.isEmpty ? "" : ", " + f.date))."
    }

    /// One bullet: level 2 = name, who, one pointer (<= 160); level 3 = full (<= 600); level 1 = nothing.
    static func render(_ e: Entity, level: Int, today: String, facts: [EntityFact]? = nil, pointers: [EntityPointer]? = nil, whoMax: Int? = nil) -> String {
        guard level >= 2 else { return "" }
        let ptrs = e.pack?.pointers ?? []
        var who = e.whoLine
        if let m = whoMax { who = m > 1 ? cut(who, m) : "" }
        if level == 2 {
            let tail = ptrs.first.map { " " + ($0.path ? "`\($0.value)`" : $0.value) } ?? ""
            let base = "- **\(e.name)**"
            if !who.isEmpty {
                let room = lineMax - len(base + " - ." + tail)
                who = room > 12 ? cut(who, room) : ""
            }
            return base + (who.isEmpty ? " (\(e.kindWord))." : " - \(who)" + (who.hasSuffix("…") ? "" : ".")) + tail
        }
        var fs = facts ?? e.pack?.facts ?? []
        var ps = pointers ?? ptrs
        let old = stale(e, today: today)
        while true {
            var body = "- **\(e.name)** (\(e.kindWord))" + (who.isEmpty ? "" : " - \(who)") + (old ? "; no recent notes." : who.hasSuffix("…") ? "" : ".")
            if !old { for f in fs { body += " " + fact(f) } }
            if !ps.isEmpty { body += " " + ps.map(pointer).joined(separator: " · ") }
            if len(body) <= fullMax { return body }
            if !fs.isEmpty && !old { fs.removeLast(); continue }
            if ps.count > 1 { ps = Array(ps.prefix(1)); continue }
            return cut(body, fullMax)
        }
    }

    struct Item { let entity: Entity; var level: Int; let mentions: Int }

    /// The one block at the end of a message. Over the budget: facts after the first two, pointers after the first,
    /// then whole entities step down to one line (least mentioned first), then their who lines. The name and the
    /// first pointer always stay.
    static func block(_ items0: [Item], today: String, limit: Int = blockMax) -> String {
        struct S { let e: Entity; var level: Int; let m: Int; var facts: [EntityFact]?; var ptrs: [EntityPointer]?; var who: Int? }
        var st = items0.filter { $0.level >= 2 }.map { S(e: $0.entity, level: $0.level, m: $0.mentions, facts: nil, ptrs: nil, who: nil) }
        guard !st.isEmpty else { return "" }
        func text() -> String {
            header + "\n" + st.map { render($0.e, level: $0.level, today: today, facts: $0.facts, pointers: $0.ptrs, whoMax: $0.who) }.joined(separator: "\n")
        }
        var t = text()
        if len(t) <= limit { return t }
        for i in st.indices where st[i].level == 3 { st[i].facts = Array((st[i].e.pack?.facts ?? []).prefix(2)) }
        t = text(); if len(t) <= limit { return t }
        for i in st.indices where st[i].level == 3 { st[i].ptrs = Array((st[i].e.pack?.pointers ?? []).prefix(1)) }
        t = text()
        let order = st.indices.sorted { st[$0].m != st[$1].m ? st[$0].m < st[$1].m : $0 > $1 }
        for i in order {
            if len(t) <= limit { return t }
            if st[i].level == 3 { st[i].level = 2; t = text() }
        }
        for i in order {
            if len(t) <= limit { return t }
            st[i].who = 0; t = text()
        }
        return t
    }

    /// "context for <name>": the entity in full, then its related ones (project first, then people, tools, documents).
    static func brief(_ e: Entity, store: EntityStore, today: String, limit: Int = briefMax) -> String {
        let ids = store.byId
        let rank = ["project": 0, "org": 1, "person": 2, "tool": 3, "doc": 4, "place": 5]
        let found: [Entity] = (e.related ?? []).compactMap { id -> Entity? in ids[id].map { store.records[$0] } }
        let rel = found.sorted { a, b -> Bool in
            let ra: Int = rank[a.kind] ?? 9, rb: Int = rank[b.kind] ?? 9
            if ra != rb { return ra < rb }
            return (a.heat ?? 0) > (b.heat ?? 0)
        }
        var out = header + "\n" + render(e, level: 3, today: today)
        for r in rel {
            let line = render(r, level: 2, today: today)
            if len(out) + 1 + len(line) > limit { break }
            out += "\n" + line
        }
        return out
    }

    // MARK: ambiguous forms (twin of entities.decide; tests/entity_cases.json "decide" holds cases both sides run)

    static let need: [String: Double] = ["shared": 1, "short": 1, "ordinary": 2, "twins": 0]
    /// What kind of thing the user names where (the destinations of RefRules.dest).
    static func expect(dest: String) -> [String] {
        switch dest { case "agent": return ["tool", "project"]; case "ai": return ["project", "tool"]
        case "chat": return ["person", "project", "org"]; case "mail": return ["person", "org"]; default: return [] }
    }
    struct Cand: Equatable {
        let i: Int; let how: String; let score: Double; let heat: Double
        var related = false, named = false, kind = false, chat = false
    }
    /// Chat box placeholders name the chat ("message bear on whatsapp"): the same patterns as entities.CHAT_PATTERNS,
    /// on folded text. The last one wins; nil when there is none.
    static let messengers = "whatsapp|telegram|signal|instagram|messenger|linkedin|imessage|sms|slack|discord|beeper|viber|teams|twitter|facebook|matrix|вайбері|вайбер|телеграмі|телеграм|ватсапі|ватсап|вотсапі|вотсап|сигналі|сигнал|інстаграмі|інстаграм|месенджері|месенджер"
    static let chatPatterns: [NSRegularExpression] = [
        #"(?:send a message to|message|write to|reply to|text) (.{1,40}?) (?:on|in|via) (?:"# + messengers + #")\b"#,
        #"(?:повідомлення|написати|напишіть|відповісти|відповідь)(?: для| до)? (.{1,40}?) (?:у|в|через) (?:"# + messengers + #")\b"#,
    ].map { try! NSRegularExpression(pattern: $0) }
    static func chatTarget(_ folded: String) -> String? {
        var best: (Int, String)? = nil
        let ns = folded as NSString
        for rx in chatPatterns {
            for m in rx.matches(in: folded, range: NSRange(location: 0, length: ns.length)) where m.numberOfRanges > 1 {
                let t = ns.substring(with: m.range(at: 1)).trimmingCharacters(in: CharacterSet(charactersIn: " .,:;'\""))
                if best == nil || m.range.location >= best!.0 { best = (m.range.location, t) }
            }
        }
        guard let b = best, !b.1.isEmpty else { return nil }
        return b.1
    }
    /// The form is the chat's name or one word of it.
    static func namesChat(_ key: String, _ target: String?) -> Bool {
        guard let t = target, !t.isEmpty else { return false }
        return key == t || t.split(separator: " ").contains(Substring(key)) || t.hasPrefix(key + " ")
    }
    static func heatBonus(_ h: Double) -> Double { min(1, log(1 + max(0, h - 1)) / log(20)) }
    /// A related thing named nearby 2, its own fuller name nearby 2, the chat's placeholder names this person 2, the
    /// kind expected here 1; then heat up to 1.
    /// Heat alone backs nothing.
    static func support(_ c: Cand) -> Double {
        let b = (c.related ? 2.0 : 0) + (c.named ? 2.0 : 0) + (c.chat ? 2.0 : 0) + (c.kind ? 1.0 : 0)
        return b > 0 ? b + heatBonus(c.heat) : 0
    }
    /// No flags: the old rule (best score; resolved at twice the next). A pick decides. Twins (one name, several
    /// records: a project and its repo): the record of the kind expected here. Shared: a stronger kind of match decides
    /// (2x); else the context must back one candidate with `need` and twice the next. Ordinary or short: the context
    /// must back it with `need`. If it does not, an ordinary or short form is no mention (nil) and a shared form stays
    /// open for the chooser.
    static func decide(_ cands: [Cand], flags flags0: [String], picked: Int? = nil) -> (index: Int?, resolved: Bool) {
        guard !cands.isEmpty else { return (nil, false) }
        if let p = picked, cands.contains(where: { $0.i == p }) { return (p, true) }
        let many = Set(cands.map { $0.i }).count > 1
        let flags = flags0.filter { ($0 != "shared" && $0 != "twins") || many }
        let order = cands.sorted { $0.score != $1.score ? $0.score > $1.score : $0.i < $1.i }
        let top = order[0], second = order.count > 1 ? order[1].score : 0
        if flags.isEmpty { return (top.i, second == 0 || top.score >= 2 * second) }
        let loose = flags.contains("ordinary") || flags.contains("short")
        if flags.contains("shared"), !loose, order.count > 1 {
            let bases: [(Double, Int)] = cands.map { c -> (Double, Int) in (base[c.how] ?? 1, c.i) }
            let sortedBases = bases.sorted { (x: (Double, Int), y: (Double, Int)) -> Bool in x.0 != y.0 ? x.0 < y.0 : x.1 < y.1 }
            let best = sortedBases[sortedBases.count - 1], next = sortedBases[sortedBases.count - 2]
            if best.0 >= 2 * next.0 { return (best.1, true) }
        }
        let needed = flags.map { need[$0] ?? 1 }.max() ?? 1
        let by = cands.sorted { a, b in
            let sa = support(a), sb = support(b)
            if sa != sb { return sa > sb }
            if a.kind != b.kind { return a.kind }
            return a.score != b.score ? a.score > b.score : a.i < b.i
        }
        let s1 = support(by[0]), s2 = by.count > 1 && flags.contains("shared") ? support(by[1]) : 0
        if s1 >= needed && s1 >= 2 * s2 { return (by[0].i, true) }
        if loose { return (nil, false) }
        return (top.i, false)
    }

    /// The user's corrections (data/entity-fixes.json), the twin of entities.add_fix: a new dictionary with one fix added.
    /// related / not_related / same / not_same: two record ids (order does not matter); not_this: a name form and the
    /// record it never means. A fix replaces its opposite. nil for an unknown kind.
    static let fixKinds = ["related", "not_related", "not_this", "same", "not_same"]
    static func addFix(_ fixes: [String: Any], what: String, a: String, b: String, why: String = "") -> [String: Any]? {
        guard fixKinds.contains(what) else { return nil }
        var out: [String: [[String]]] = [:]
        for k in fixKinds { out[k] = ((fixes[k] as? [[Any]]) ?? []).map { $0.map { "\($0)" } } }
        if what == "not_this" {
            let item = [fold(a), b]
            if !(out["not_this"] ?? []).contains(where: { Array($0.prefix(2)) == item }) { out["not_this", default: []].append(item) }
            return out
        }
        guard a != b else { return out }
        let key = [a, b].sorted()
        func same(_ x: [String]) -> Bool { x.count >= 2 && [x[0], x[1]].sorted() == key }
        let opposite = ["related": "not_related", "not_related": "related", "same": "not_same", "not_same": "same"][what]!
        out[opposite] = (out[opposite] ?? []).filter { !same($0) }
        out[what] = (out[what] ?? []).filter { !same($0) } + [key + (what == "related" && !why.isEmpty ? [why] : [])]
        return out
    }

    // MARK: finding

    /// The `;` card and the Quick panel's `@` query: an exact surface first, then a prefix of a name, an alias or one
    /// of their words; warmest first, contact-only cards last.
    static func find(_ q0: String, in store: EntityStore, limit: Int = 8) -> [Int] {
        var q = q0
        while let f = q.first, f == ";" || f == "@" { q.removeFirst() }
        q = fold(q)
        guard q.count >= 2 else { return [] }
        var scored: [(Int, Double)] = (store.surfaces[q] ?? []).filter { $0.index < store.records.count }.map { ($0.index, base[$0.how] ?? 1) }
        if scored.isEmpty {
            for (i, r) in store.records.enumerated() {
                for n in [r.name] + r.aliases {
                    let f = fold(n)
                    if f.hasPrefix(q) || f.split(separator: " ").contains(where: { $0.hasPrefix(q) }) { scored.append((i, 0.5)); break }
                }
            }
        }
        scored.sort { a, b in
            let ra = store.records[a.0], rb = store.records[b.0]
            if a.1 != b.1 { return a.1 > b.1 }
            if ra.cardOnly != rb.cardOnly { return !ra.cardOnly }
            if (ra.heat ?? 0) != (rb.heat ?? 0) { return (ra.heat ?? 0) > (rb.heat ?? 0) }
            return ra.name < rb.name
        }
        var seen = Set<Int>(), out: [Int] = []
        for (i, _) in scored where seen.insert(i).inserted { out.append(i); if out.count == limit { break } }
        return out
    }

    private static func isWordChar(_ c: Character) -> Bool { c.isLetter || c == "'" || c == "’" || c == "ʼ" || c == "-" }

    /// The name that ends right before the caret (after a space or a mark), the longest of the last 1-3 words that the
    /// map knows. `context`: the last few hundred characters and the window title, folded, for the related-entity
    /// bonus; `picks`: folded name -> record id the user picked here before (decides). nil when nothing matches.
    static func mention(before: String, store: EntityStore, context: String = "", picks: [String: String] = [:]) -> EntityMention? {
        mention(before: before, store: store, context: context, picks: picks, expect: [])
    }

    /// The same, with the kinds of thing expected in this app (`expect(dest:)`): a form marked in `surface_flags`
    /// (shared, an ordinary word, 4 letters or fewer) counts only when the context decides (`decide`).
    static func mention(before: String, store: EntityStore, context: String, picks: [String: String], expect: [String]) -> EntityMention? {
        // the text up to the last word, then the words, each with its UTF-16 distance from the caret
        let chars = Array(before.suffix(120))
        var end = chars.count
        while end > 0, !isWordChar(chars[end - 1]) { end -= 1 }
        guard end > 0 else { return nil }
        let tailUnits = String(chars[end...]).utf16.count
        var words: [(String, Int)] = []   // word, start index in chars
        var i = end
        while words.count < 3, i > 0 {
            var j = i
            while j > 0, isWordChar(chars[j - 1]) { j -= 1 }
            guard j < i else { break }
            words.insert((String(chars[j..<i]), j), at: 0)
            // only spaces between the words of one name
            var k = j
            while k > 0, chars[k - 1] == " " { k -= 1 }
            if k == j || k == 0 || !isWordChar(chars[k - 1]) { break }
            i = k
        }
        guard !words.isEmpty else { return nil }
        for n in stride(from: words.count, through: 1, by: -1) {
            let span = words.suffix(n)
            let startIdx = span.first!.1
            let text = String(chars[startIdx..<end])
            let key = fold(text)
            guard let hits = store.surfaces[key], !hits.isEmpty else { continue }
            let capital = text.first?.isUppercase == true
            // a sentence start: nothing but spaces, or . ! ? and a line break, before it
            var p = startIdx
            while p > 0, chars[p - 1] == " " { p -= 1 }
            let start = p == 0 || ".!?\n:".contains(chars[p - 1])
            var cands: [(Int, String, Double)] = []
            for h in hits where h.index < store.records.count {
                let r = store.records[h.index]
                if r.cardOnly { continue }
                // lower case matches only a name that is itself lower case (a repo or Worker slug), never a person
                if !capital && !(r.name == r.name.lowercased() && r.kind != "person" && (h.how == "name" || h.how == "alias")) { continue }
                var s = base[h.how] ?? 1
                if capital && !start { s += 0.5 }
                s += min(1, log(1 + max(0, (r.heat ?? 1) - 1)) / log(20))
                cands.append((h.index, h.how, s))
            }
            guard !cands.isEmpty else { continue }
            if cands.count > 1, !context.isEmpty {
                let ids = store.byId
                for c in cands.indices {
                    let rel = store.records[cands[c].0].related ?? []
                    if rel.contains(where: { id in ids[id].map { context.contains(fold(store.records[$0].name)) } ?? false }) { cands[c].2 += 1 }
                }
            }
            let back = String(chars[startIdx...]).utf16.count
            if let flags = store.surfaceFlags[key]?.list, !flags.isEmpty {
                let ids = store.byId
                let target = chatTarget(context)
                let dc: [Cand] = cands.map { c in
                    let r = store.records[c.0]
                    let rel = (r.related ?? []).contains { id in ids[id].map { j -> Bool in let n = fold(store.records[j].name); return n.count >= 3 && context.contains(n) } ?? false }
                    let named = ([r.name] + r.aliases).contains { n in let f = fold(n); return f.count >= 3 && f != key && context.contains(f) }
                    let chat = r.kind == "person" && namesChat(key, target)
                    return Cand(i: c.0, how: c.1, score: c.2, heat: r.heat ?? 1, related: rel, named: named, kind: expect.contains(r.kind) || chat, chat: chat)
                }
                let pick = picks[key].flatMap { id in cands.first(where: { store.records[$0.0].id == id })?.0 }
                let d = decide(dc, flags: flags, picked: pick)
                guard let got = d.index, let chosen = cands.first(where: { $0.0 == got }) else { continue }
                let rest = cands.filter { $0.0 != got }.sorted { $0.2 != $1.2 ? $0.2 > $1.2 : $0.0 < $1.0 }
                return EntityMention(text: text, back: back, length: back - tailUnits, index: got, how: chosen.1, score: chosen.2,
                                     candidates: [got] + rest.map { $0.0 }, resolved: d.resolved)
            }
            if let picked = picks[key], let k = cands.firstIndex(where: { store.records[$0.0].id == picked }) { cands[k].2 += 100 }
            cands.sort { $0.2 != $1.2 ? $0.2 > $1.2 : $0.0 < $1.0 }
            let top = cands[0], second = cands.count > 1 ? cands[1].2 : 0
            return EntityMention(text: text, back: back, length: back - tailUnits, index: top.0, how: top.1, score: top.2,
                                 candidates: cands.map { $0.0 }, resolved: second == 0 || top.2 >= 2 * second)
        }
        return nil
    }

    /// Every resolved name in a finished text (a dictated take): record indices, first seen first, no repeats. A longer
    /// name that grows over a shorter one ("Lantern" then "Lantern Labs") replaces it.
    static func mentions(in text: String, store: EntityStore) -> [Int] { mentions(in: text, store: store, expect: []) }

    /// The same, with the kinds expected in this app; the text itself is the context for flagged forms.
    static func mentions(in text: String, store: EntityStore, expect: [String]) -> [Int] {
        var found: [(start: Int, index: Int)] = []
        var prefix = "", units = 0
        let ctx = fold(text)
        func look() {
            guard let m = mention(before: prefix, store: store, context: store.surfaceFlags.isEmpty ? "" : ctx, picks: [:], expect: expect), m.resolved else { return }
            let start = units - m.back
            if let last = found.last, start <= last.start { found.removeLast() }
            if found.last?.start != start { found.append((start, m.index)) }
        }
        for ch in text {
            if !isWordChar(ch), let last = prefix.last, isWordChar(last) { look() }
            prefix.append(ch); units += String(ch).utf16.count
        }
        if let last = prefix.last, isWordChar(last) { look() }
        var seen = Set<Int>()
        return found.map { $0.index }.filter { seen.insert($0).inserted }
    }
}

/// The list keys of the small pickers (the `;` picker, the entity card, the @ list and the context tray), pure so a test
/// holds them (tests/picker_key_guards.swift). Each key counts only when `on` (no ⌘⌃⌥⇧ held, or the picker's own
/// condition) for both keycodes of its pair: a `case 125, 126 where x` guarded only ↑, so ⌘↓ or ⌥↓ moved the list and
/// was swallowed (26 November 2026). nil / false: the key is not the picker's, it goes on.
enum PickerKeys {
    /// ↓ +1, ↑ -1.
    static func step(_ code: Int64, on: Bool) -> Int? {
        guard on else { return nil }
        return code == 125 ? 1 : code == 126 ? -1 : nil
    }
    /// → +1, ← -1.
    static func side(_ code: Int64, on: Bool) -> Int? {
        guard on else { return nil }
        return code == 124 ? 1 : code == 123 ? -1 : nil
    }
    /// ↵ or the keypad's enter.
    static func enter(_ code: Int64, on: Bool) -> Bool { on && (code == 36 || code == 76) }
}

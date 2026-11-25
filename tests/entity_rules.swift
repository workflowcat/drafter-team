// swiftc -O -parse-as-library app/EntityRules.swift app/RefRules.swift tests/entity_rules.swift -o app/build/entity-rules-test && app/build/entity-rules-test
// Made-up entities only. Run from the repo root (reads tests/entity_cases.json, the golden text engine/entities.py makes too).
import Foundation

@main struct Checks {
    static func main() throws {
        // --- the golden cases: the same strings as the Python side
        let g = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: "tests/entity_cases.json"))) as! [String: Any]
        let today = g["today"] as! String
        let recs = try JSONDecoder().decode([Entity].self, from: JSONSerialization.data(withJSONObject: g["records"]!))
        let byId = Dictionary(uniqueKeysWithValues: recs.map { ($0.id, $0) })
        for c in g["lines"] as! [[String: Any]] {
            let got = EntityRules.render(byId[c["id"] as! String]!, level: c["level"] as! Int, today: today)
            precondition(got == c["expect"] as! String, "line \(c["id"]!) \(c["level"]!):\n\(got)\n\(c["expect"]!)")
        }
        for c in g["blocks"] as! [[String: Any]] {
            let items = (c["items"] as! [[Any]]).map { EntityRules.Item(entity: byId[$0[0] as! String]!, level: $0[1] as! Int, mentions: $0[2] as! Int) }
            let got = EntityRules.block(items, today: today, limit: c["limit"] as? Int ?? EntityRules.blockMax)
            precondition(got == c["expect"] as! String, "block \(c["name"]!):\n\(got)\n---\n\(c["expect"]!)")
        }
        for c in g["cut"] as! [[String: Any]] { precondition(EntityRules.cut(c["s"] as! String, c["n"] as! Int) == c["expect"] as! String, "cut") }
        for c in g["fold"] as! [[String: Any]] { precondition(EntityRules.fold(c["s"] as! String) == c["expect"] as! String, "fold \(c["s"]!)") }
        print("PASS: packs render the same text as engine/entities.py (\((g["lines"] as! [Any]).count) lines, \((g["blocks"] as! [Any]).count) blocks)")

        // --- a small store with surfaces as the builder writes them
        func ent(_ id: String, _ kind: String, _ name: String, related: [String] = [], heat: Double = 1, cards: Bool = false, targets: [String: String] = [:], handles: [String: [String]] = [:]) -> Entity {
            Entity(id: id, kind: kind, name: name, aliases: [], who: "made-up " + kind, targets: targets, handles: handles, related: related,
                   pack: EntityPack(facts: [], pointers: [EntityPointer(label: "Note", value: "/tmp/\(name).md", path: true)], newest: ""), heat: heat, cards_only: cards)
        }
        var store = EntityStore(records: [
            ent("p:hanna", "person", "Ганна Ткач", related: ["o:lantern"], heat: 6, targets: ["obsidian": "Entities/People/Hanna Tkach"], handles: ["email": ["hanna@example.test"], "tg": ["hanna_x"]]),
            ent("p:hanna2", "person", "Ганна Інша", related: ["o:other"]),
            ent("o:lantern", "org", "Lantern Labs"),
            ent("x:lantern", "project", "Lantern", heat: 3),
            ent("t:gate", "tool", "lantern-gate"),
            ent("o:other", "org", "Other Org"),
            ent("c:card", "person", "Card Only", cards: true, handles: ["email": ["card@example.test"]]),
        ])
        store.surfaces = ["ганна ткач": [EntityHit(index: 0, how: "name")], "ганні": [EntityHit(index: 0, how: "form"), EntityHit(index: 1, how: "form")],
                          "ганна": [EntityHit(index: 0, how: "first"), EntityHit(index: 1, how: "first")], "ткач": [EntityHit(index: 0, how: "part")],
                          "hanna tkach": [EntityHit(index: 0, how: "alias")], "lantern labs": [EntityHit(index: 2, how: "name")],
                          "lantern": [EntityHit(index: 3, how: "name")], "lantern-gate": [EntityHit(index: 4, how: "name")],
                          "card only": [EntityHit(index: 6, how: "name")]]

        // a full name resolves; a case form shared by two does not, unless the context or a pick decides
        var m = EntityRules.mention(before: "напиши Ганна Ткач ", store: store)!
        precondition(m.index == 0 && m.resolved && m.text == "Ганна Ткач" && m.back == 11 && m.length == 10, "\(m)")
        m = EntityRules.mention(before: "дай Ганні", store: store)!
        precondition(m.candidates.count == 2 && !m.resolved, "\(m)")
        // a related name on screen puts her first, but only twice the next score resolves (proposal 2.2): the chooser asks
        let plain = EntityRules.mention(before: "про Lantern Labs і Ганні", store: store)!
        m = EntityRules.mention(before: "про Lantern Labs і Ганні", store: store, context: EntityRules.fold("про Lantern Labs і"))!
        precondition(m.index == 0 && m.score == plain.score + 1 && !m.resolved, "context ranks: \(m)")
        m = EntityRules.mention(before: "дай Ганні", store: store, picks: ["ганні": "p:hanna2"])!
        precondition(m.index == 1 && m.resolved, "a pick decides")
        // the longest name wins over its last word
        m = EntityRules.mention(before: "we pitched Lantern Labs.", store: store)!
        precondition(m.index == 2 && m.text == "Lantern Labs" && m.back == 13, "\(m)")
        // lower case: only a lower-case slug; a person never; a contact-only card never
        precondition(EntityRules.mention(before: "deploy lantern-gate ", store: store)?.index == 4)
        precondition(EntityRules.mention(before: "a lantern ", store: store) == nil)
        precondition(EntityRules.mention(before: "ганна ткач ", store: store) == nil)
        precondition(EntityRules.mention(before: "Card Only ", store: store) == nil)
        precondition(EntityRules.mention(before: "", store: store) == nil)
        let ms = EntityRules.mentions(in: "Ганна Ткач and Lantern Labs, then Lantern.", store: store); precondition(ms == [0, 2, 3], "\(ms)")
        print("PASS: mentions resolve by the longest name, context and picks; lower case and cards stay plain")

        // the `;` card search
        precondition(EntityRules.find(";лан", in: store).isEmpty)
        precondition(EntityRules.find(";lant", in: store) == [3, 2, 4] || EntityRules.find(";lant", in: store).first == 3, "\(EntityRules.find(";lant", in: store))")
        precondition(EntityRules.find(";ганна ткач", in: store) == [0])
        precondition(EntityRules.find("@card", in: store) == [6])
        precondition(EntityRules.find(";h", in: store).isEmpty)
        // the forms for each place
        let h = store.records[0]
        precondition(RefRules.forms(h, dest: "obsidian").first == RefRules.Form(label: "link", text: "[[Entities/People/Hanna Tkach|Ганна Ткач]]"))
        precondition(RefRules.forms(h, dest: "mail").map { $0.label } == ["name", "address", "email", "Telegram", "link"])
        precondition(RefRules.forms(h, dest: "mail")[1].text == "Ганна Ткач <hanna@example.test>")
        precondition(RefRules.forms(h, dest: "ai").first?.label == "context")
        precondition(RefRules.forms(store.records[6], dest: "obsidian").map { $0.label } == ["email"])
        precondition(RefRules.dest(id: "com.googlecode.iterm2", title: "claude ~/Codius", kind: "other") == "agent")
        precondition(RefRules.dest(id: "com.googlecode.iterm2", title: "zsh", kind: "other") == "plain")
        precondition(RefRules.level("agent") == 3 && RefRules.level("ai") == 2 && RefRules.level("chat") == 1)
        print("PASS: the card finds any kind; forms per place; agent apps")

        // --- ambiguous forms (2026-11-14 relations round): the same decisions as entities.decide
        for c in g["decide"] as! [[String: Any]] {
            let cands = (c["cands"] as! [[String: Any]]).map { d in
                EntityRules.Cand(i: d["i"] as! Int, how: d["how"] as! String, score: (d["score"] as! NSNumber).doubleValue,
                                 heat: (d["heat"] as! NSNumber).doubleValue, related: d["related"] as! Bool, named: d["named"] as! Bool, kind: d["kind"] as! Bool,
                                 chat: d["chat"] as? Bool ?? false)
            }
            let got = EntityRules.decide(cands, flags: c["flags"] as! [String], picked: c["picked"] as? Int)
            let want = c["expect"] as! [Any]
            precondition((got.index ?? -1) == want[0] as! Int && got.resolved == want[1] as! Bool, "decide \(c["name"]!): \(got)")
        }
        for c in g["chat_target"] as! [[String: Any]] {
            let got = EntityRules.chatTarget(EntityRules.fold(c["text"] as! String))
            precondition(got == c["expect"] as? String, "chat target \(c["text"]!): \(String(describing: got))")
        }
        // a chat placeholder names the person: an ordinary-word nickname resolves there, and only there
        var cs = EntityStore(records: [ent("p:bear", "person", "Bear"), ent("t:bear", "tool", "bear")],
                             surfaces: ["bear": [EntityHit(index: 0, how: "name"), EntityHit(index: 1, how: "name")]],
                             flags: ["bear": EntitySurfaceFlags(needs_context: true, shared: false, twins: true, ordinary: true, short: false)])
        let ph = "Message Bear on WhatsApp"
        m = EntityRules.mention(before: "Message Bear", store: cs, context: EntityRules.fold(ph), picks: [:], expect: [])!
        precondition(m.index == 0 && m.resolved, "placeholder: \(m)")
        precondition(EntityRules.mention(before: "Bear", store: cs, context: "bear", picks: [:], expect: []) == nil, "no placeholder: plain word")
        precondition(EntityRules.mentions(in: ph, store: cs) == [0], "\(EntityRules.mentions(in: ph, store: cs))")
        cs.surfaceFlags = [:]
        // an older store (no surface_flags, no relations) still loads; a new one carries both
        let old = try JSONDecoder().decode(EntityStore.self, from: Data(#"{"records":[{"id":"a","kind":"tool","name":"Anvil","aliases":[],"related":["b"]}],"surfaces":{"anvil":[[0,"name"]]}}"#.utf8))
        precondition(old.surfaceFlags.isEmpty && old.records[0].relations == nil)
        let new = try JSONDecoder().decode(EntityStore.self, from: Data(#"{"records":[{"id":"a","kind":"tool","name":"Anvil","aliases":[],"related":["b"],"relations":[{"id":"b","why":"repo of","w":0.81,"src":["aleph"]}]}],"surfaces":{"anvil":[[0,"name"]]},"surface_flags":{"anvil":{"needs_context":true,"shared":false,"ordinary":true,"short":false}}}"#.utf8))
        precondition(new.surfaceFlags["anvil"]?.list == ["ordinary"] && new.records[0].relations?.first?.why == "repo of")
        // flagged forms in the matcher: an ordinary-word name needs context, a shared first name needs a related thing
        var fs = store
        fs.records.append(ent("x:anvil", "project", "Anvil", heat: 30))
        fs.surfaces["anvil"] = [EntityHit(index: 7, how: "name")]
        fs.surfaceFlags = ["anvil": EntitySurfaceFlags(needs_context: true, shared: false, ordinary: true, short: false),
                           "ганні": EntitySurfaceFlags(needs_context: true, shared: true, ordinary: false, short: false)]
        precondition(EntityRules.mention(before: "we use Anvil ", store: fs) == nil, "an ordinary word without context")
        m = EntityRules.mention(before: "we use Anvil ", store: fs, context: "", picks: [:], expect: EntityRules.expect(dest: "agent"))!
        precondition(m.index == 7 && m.resolved, "kind expected here and a warm project: \(m)")
        m = EntityRules.mention(before: "дай Ганні", store: fs)!
        precondition(!m.resolved && m.candidates.count == 2, "a shared form with no context waits for the chooser")
        m = EntityRules.mention(before: "про Lantern Labs і Ганні", store: fs, context: EntityRules.fold("про Lantern Labs і Ганні"), picks: [:], expect: [])!
        precondition(m.index == 0 && m.resolved, "a related org named nearby decides: \(m)")
        m = EntityRules.mention(before: "дай Ганні", store: fs, context: "", picks: ["ганні": "p:hanna2"], expect: [])!
        precondition(m.index == 1 && m.resolved, "a pick decides")
        precondition(EntityRules.mentions(in: "Ганні and Anvil.", store: fs).isEmpty)
        precondition(EntityRules.mentions(in: "Ганні from Lantern Labs.", store: fs) == [0, 2], "\(EntityRules.mentions(in: "Ганні from Lantern Labs.", store: fs))")
        // his fixes: pure, a fix replaces its opposite
        var fx = EntityRules.addFix([:], what: "related", a: "b", b: "a", why: "same client")!
        precondition((fx["related"] as! [[String]]) == [["a", "b", "same client"]])
        fx = EntityRules.addFix(fx, what: "not_related", a: "a", b: "b")!
        precondition((fx["related"] as! [[String]]).isEmpty && (fx["not_related"] as! [[String]]) == [["a", "b"]])
        fx = EntityRules.addFix(fx, what: "not_this", a: "Ганна", b: "p:hanna2")!
        precondition((fx["not_this"] as! [[String]]) == [["ганна", "p:hanna2"]])
        precondition(EntityRules.addFix(fx, what: "maybe", a: "a", b: "b") == nil)
        print("PASS: ambiguous forms need context (golden decisions and chat placeholders as in Python); old stores load; fixes")

        // --- cost per word end with 5,000 made-up entities and their surfaces
        var big: [Entity] = [], surf: [String: [EntityHit]] = [:]
        let syll = ["ка", "ло", "ри", "на", "те", "ва", "мо", "ди", "ус", "ен", "ko", "ra", "li", "mo", "sa", "te"]
        func word(_ n: Int, _ k: Int) -> String { var s = ""; var x = n &* 2654435761 &+ k; for _ in 0..<3 { s += syll[abs(x) % syll.count]; x /= syll.count }; return s.prefix(1).uppercased() + s.dropFirst() }
        for i in 0..<5000 {
            let name = word(i, 1) + " " + word(i, 7)
            big.append(ent("e:\(i)", EntityRules.kinds[i % 6], name, related: ["e:\((i + 1) % 5000)"], heat: Double(i % 9)))
            for (k, how) in [(name, "name"), (name.components(separatedBy: " ")[0], "first"), (name.components(separatedBy: " ")[1], "part"),
                             (name.components(separatedBy: " ")[0] + "і", "form"), (name.components(separatedBy: " ")[0] + "у", "form")] {
                surf[EntityRules.fold(k), default: []].append(EntityHit(index: i, how: how))
            }
        }
        var flags: [String: EntitySurfaceFlags] = [:]
        for (k, v) in surf where !k.contains(" ") { flags[k] = EntitySurfaceFlags(needs_context: true, shared: Set(v.map { $0.index }).count > 1, ordinary: false, short: k.count <= 4) }
        let bigStore = EntityStore(records: big, surfaces: surf, flags: flags)
        let lines = (0..<2000).map { i -> String in "Сьогодні говорили з " + big[(i * 37) % 5000].name + (i % 3 == 0 ? " про щось " : " ") }
        let ctx = EntityRules.fold(String(lines.joined().suffix(400)))
        var times: [Double] = []
        var found = 0
        for line in lines {
            let t0 = DispatchTime.now().uptimeNanoseconds
            if EntityRules.mention(before: line, store: bigStore, context: ctx, picks: [:], expect: ["person"]) != nil { found += 1 }
            times.append(Double(DispatchTime.now().uptimeNanoseconds - t0) / 1000)
        }
        times.sort()
        let p50 = times[times.count / 2], p99 = times[Int(Double(times.count) * 0.99)]
        print(String(format: "cost per word end, 5,000 entities, %d surfaces: p50 %.1f µs, p99 %.1f µs, max %.1f µs (%d of %d lines had a name)",
                     surf.count, p50, p99, times.last!, found, lines.count))
        precondition(p99 < 200, "p99 over 0.2 ms")
        print("PASS: under 0.2 ms per word end at p99")
    }
}

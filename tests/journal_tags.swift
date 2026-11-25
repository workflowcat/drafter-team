import Foundation

// swiftc -parse-as-library app/JournalTags.swift app/TapeRules.swift app/ClipRules.swift app/EntityRules.swift tests/journal_tags.swift -o app/build/journal-tags-test && app/build/journal-tags-test
// The tags boundary with a made-up store: a form that points to two records gives no tag, a short dictionary word
// gives no tag, a clear name does, people of a recording come first, a reason from the record's own line.
@main
struct JournalTagChecks {
    static var failures = 0
    static func check(_ ok: Bool, _ what: String) { if !ok { print("FAIL: " + what); failures += 1 } }

    static func main() {
        var mila = Entity(id: "p1", kind: "person", name: "Mila Synthetic"); mila.who = "designer on the station project"
        let recs = [mila, Entity(id: "p2", kind: "person", name: "Mark Sample"), Entity(id: "p3", kind: "person", name: "Mark Other"),
                    Entity(id: "p4", kind: "project", name: "Lantern"), Entity(id: "p5", kind: "person", name: "Will Example")]
        let store = EntityStore(records: recs, surfaces: [
            "mila synthetic": [EntityHit(index: 0, how: "name")], "mila": [EntityHit(index: 0, how: "first")],
            "mark": [EntityHit(index: 1, how: "first"), EntityHit(index: 2, how: "first")],
            "mark sample": [EntityHit(index: 1, how: "name")], "lantern": [EntityHit(index: 3, how: "name")],
            "will": [EntityHit(index: 4, how: "first")]])
        let common: Set<String> = ["will", "mark", "bill", "sun"]
        check(JournalTags.fits(form: "Mila", records: 1, common: common), "a clear first name")
        check(!JournalTags.fits(form: "Mark", records: 2, common: common), "two records: no tag")
        check(!JournalTags.fits(form: "Will", records: 1, common: common), "a short dictionary word: no tag")
        check(JournalTags.fits(form: "Mark Sample", records: 1, common: common), "a full name with a short word in it")
        let f = JournalTags.found(in: "Will you ask Mark and Mila about Lantern?", store: store, common: common)
        check(f.map(\.name) == ["Mila Synthetic", "Lantern"], "only the clear names: \(f.map(\.name))")
        check(JournalTags.found(in: "Mark Sample sent it", store: store, common: common).map(\.name) == ["Mark Sample"], "the full name resolves")
        let t = JournalTags.tags(text: "Ask Mila", clip: "text", app: "Telegram", chat: nil, store: store, common: common)
        check(t.first == TapeTag(name: "Mila Synthetic", kind: "person"), "the boundary gives the person first")
        let call = JournalTags.tags(text: "Design review", clip: "text", app: "Zoom", chat: nil, people: ["Sava Synthetic"], store: store, common: common)
        check(call.map(\.name) == ["Sava Synthetic", "Zoom"], "a recording's people")
        let chat = JournalTags.tags(text: "the build is green", clip: "text", app: "Telegram", chat: "mila synthetic", store: store, common: common)
        check(chat.first == TapeTag(name: "Mila Synthetic", kind: "person"), "a chat named after a person in the store is that person: \(chat)")
        check(JournalTags.reason(TapeTag(name: "Mila Synthetic", kind: "person"), store: store) == "designer on the station project", "a reason from the record")
        check(JournalTags.reason(TapeTag(name: "Lantern", kind: "project"), store: store) == nil, "no line, no reason")
        check(JournalTags.common.isEmpty || !JournalTags.common.contains("Mila"), "the word list holds lower-case words only")

        // a store with surface_flags decides ambiguous forms itself; a twin shows as its main record
        var lantern = Entity(id: "p4", kind: "project", name: "Lantern")
        lantern.relations = [EntityRelation(id: "o1", why: "made by", w: 0.4), EntityRelation(id: "p1", why: "works on it: designer", w: 0.9),
                             EntityRelation(id: "x9", why: "private thing", w: 1), EntityRelation(id: "p6", why: "own repo", w: 0.95)]
        var gate = Entity(id: "p6", kind: "tool", name: "lantern-gate"); gate.twin_of = "p4"
        var secret = Entity(id: "x9", kind: "person", name: "Hidden Person"); secret.private = true
        let recs2 = [mila, Entity(id: "p2", kind: "person", name: "Mark Sample"), Entity(id: "p3", kind: "person", name: "Mark Other"),
                     lantern, Entity(id: "p5", kind: "person", name: "Will Example"), gate, Entity(id: "o1", kind: "org", name: "Example Studio"), secret]
        let flagged = EntityStore(records: recs2, surfaces: [
            "mila synthetic": [EntityHit(index: 0, how: "name")], "mila": [EntityHit(index: 0, how: "first")],
            "mark": [EntityHit(index: 1, how: "first"), EntityHit(index: 2, how: "first")],
            "mark sample": [EntityHit(index: 1, how: "name")], "lantern": [EntityHit(index: 3, how: "name")],
            "will": [EntityHit(index: 4, how: "first")], "lantern-gate": [EntityHit(index: 5, how: "name")]],
            flags: ["mark": EntitySurfaceFlags(needs_context: true, shared: true), "will": EntitySurfaceFlags(needs_context: true, ordinary: true, short: true)])
        let g = JournalTags.found(in: "Will you ask Mark and Mila about lantern-gate?", store: flagged, common: [], app: "Telegram")
        check(g.map(\.name) == ["Mila Synthetic", "Lantern"], "the store's decision: no Will, no Mark; the repo shows as its project: \(g.map(\.name))")
        check(JournalTags.dest(app: "Telegram") == "chat" && JournalTags.dest(app: "Terminal") == "agent" && JournalTags.dest(app: "Figma") == "plain", "the app's kind of place")
        let l = JournalTags.links(TapeTag(name: "Lantern", kind: "project"), store: flagged)
        check(l.map(\.why) == ["works on it: designer", "made by"], "reasons strongest first, no private record, no twin of itself: \(l)")
        let l2 = JournalTags.links(TapeTag(name: "Lantern", kind: "project"), others: [TapeTag(name: "Example Studio", kind: "org")], store: flagged, max: 1)
        check(l2 == [JournalTags.Link(why: "made by", name: "Example Studio", kind: "org")], "the item's other tag comes first: \(l2)")
        check(JournalTags.links(TapeTag(name: "lantern-gate", kind: "tool"), store: flagged).first?.name == "Mila Synthetic", "a twin's tag reads its main record's relations")

        // tags on disk: kept by row, read back, started again for a new store
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("journal-tags-\(UUID().uuidString)")
        let url = dir.appendingPathComponent("journal-tags.json")
        let d1 = TagDisk(url: url, sign: "a")
        d1.put("t:1|5", [TapeTag(name: "Mila Synthetic", kind: "person"), TapeTag(name: "Telegram", kind: "app")]); d1.put("t:2|3", [])
        d1.save()
        let d2 = TagDisk(url: url, sign: "a")
        check(d2.get("t:1|5") == [TapeTag(name: "Mila Synthetic", kind: "person"), TapeTag(name: "Telegram", kind: "app")], "read back")
        check(d2.get("t:2|3") == [] && d2.get("t:3|1") == nil, "an empty list is kept, an unknown row is nil")
        d2.keep(["t:1|5"]); d2.save()
        check(TagDisk(url: url, sign: "a").get("t:2|3") == nil, "a row no longer shown goes")
        check(TagDisk(url: url, sign: "b").get("t:1|5") == nil, "a new store starts again")
        try? FileManager.default.removeItem(at: dir)
        if failures > 0 { print("\(failures) failed"); exit(1) }
        print("journal tags: all passed")
    }
}

// swiftc -parse-as-library app/StreamZoomRules.swift app/TapeRules.swift app/ClipRules.swift app/EntityRules.swift app/TopicClusterRules.swift app/PictureLookRules.swift app/StreamGroupRules.swift tests/stream_group_rules.swift -o app/build/stream-group-rules-test && app/build/stream-group-rules-test
// Topics round (24 November 2026): topics and folded days in the stream. Made-up rows only.
import Foundation

@main struct StreamGroupRulesTest {
    static var failed = 0, ran = 0
    static func check(_ ok: Bool, _ what: String) { ran += 1; if !ok { failed += 1; print("FAIL:", what) } }
    static func main() {
        typealias G = StreamGroupRules
        let t0 = 1_795_514_400.0
        func it(_ id: String, _ dt: Double, _ text: String, kind: String = "typed", app: String = "Notes", tags: [TapeTag] = []) -> TopicInput {
            TopicInput(id: id, kind: kind, text: text, app: app, at: t0 - dt, tags: tags, pinned: false)
        }
        let lantern = TapeTag(name: "Lantern", kind: "project")
        let items = [
            it("a", 0, "Lantern order form needs a new empty state", tags: [lantern]),
            it("b", 3600, "the order form for Lantern goes out Friday", app: "Mail", tags: [lantern]),
            it("c", 7200, "station map review with the made up team", app: "Slack"),
            it("d", 7300, "station map review notes, platform lifts", app: "Figma"),
            it("d2", 7400, "station map review: the made up lift list", app: "Notes"),
            it("e", 9000, "lunch", kind: "copied", app: "Dia"),
        ]
        let r = G.topics(items)
        check(r.topics.count == 2, "two topics: \(r.topics.map(\.title))")
        check(r.topics.first?.title == "Lantern", "tag names the topic: \(r.topics.map(\.title))")
        check(r.loose == ["e"], "loose ends: \(r.loose)")
        let day = G.dayTopics(items)
        check(day.count == 2 && day.contains("Lantern"), "day topics: \(day)")
        check(G.dayTopics(items, max: 1).count == 1, "max")
        check(G.dayTopics([it("x", 0, "one thing")]).isEmpty, "a day with no topic")
        // one title is one topic, even weeks apart
        let far = items + [it("g", 40 * 86400, "station map review, old notes", app: "Slack"), it("h", 40 * 86400 + 60, "station map review again", app: "Figma")]
        let rf = G.topics(far).topics
        check(rf.count == 2, "merged by title: \(rf.map(\.title)) \(rf.map(\.itemIds))")
        if let st = rf.first(where: { $0.itemIds.contains("g") }) {
            check(st.itemIds == ["c", "d", "d2", "g", "h"] && st.subtitle == "5 drafts", "merged rows newest first: \(st.itemIds) \(st.subtitle)")
        }
        // an untagged topic is named by its most typical line
        if let st = r.topics.first(where: { $0.itemIds.contains("c") }) {
            check(st.title.hasPrefix("station map review"), "named by a line: \(st.title)")
        }
        // first real look: a tag on most rows is home, not a topic; pairs of copies are not topics
        let home = TapeTag(name: "Made Up Co", kind: "project")
        let many = (0..<60).map { it("m\($0)", Double($0) * 144_000, "unrelated line number \($0) about thing \($0 * 7)", app: "App\($0)", tags: [home]) }
        check(G.topics(many).topics.isEmpty, "home tag joins nothing: \(G.topics(many).topics.map(\.itemIds.count))")
        check(G.topics([it("k1", 0, "made up link page one", kind: "copied", app: "Dia"), it("k2", 60, "made up link page two", kind: "copied", app: "Dia"),
                        it("k3", 90, "made up link page three", kind: "copied", app: "Dia")]).topics.isEmpty, "copies alone are no topic")
        check(G.topics([it("u1", 0, "made up quarterly plan review"), it("u2", 600, "quarterly plan review again")]).topics.isEmpty, "an untagged pair is no topic")
        let pics = G.topics([it("s1", 0, "Screen · made up dashboard numbers", kind: "copied"), it("s2", 30, "made up dashboard numbers look off"),
                             it("s3", 60, "dashboard numbers fixed, made up", kind: "spoken")]).topics
        check(pics.first.map { !$0.title.hasPrefix("Screen · ") } ?? false, "a picture's line is not a title: \(pics.map(\.title))")
        let paths = G.topics([it("p", 0, "/tmp/made-up-plan.pdf", kind: "file", tags: [lantern]), it("q", 60, "made up plan pdf", kind: "typed", tags: [lantern])]).topics
        check(paths.first.map { !$0.title.hasPrefix("/") } ?? true, "a path is not a title: \(paths.map(\.title))")
        // topic identity (review 25 November 2026): a tag is the id; a burst does not chain a tagged row to the next one;
        // one line joins only within two months; a person and a project of one name stay two
        check(r.topics.first?.id == "tag:project:lantern", "a tagged topic's id is its tag: \(r.topics.map(\.id))")
        let chain = G.topics([it("t1", 0, "made up lantern invoice draft", app: "Slack", tags: [lantern]),
                              it("t2", 120, "lantern invoice numbers again", app: "Slack", tags: [lantern]),
                              it("t3", 300, "unrelated lunch plan with nobody", app: "Slack"),
                              it("t4", 330, "where do we eat, made up", app: "Slack")]).topics
        check(!(chain.first { $0.itemIds.contains("t1") }?.itemIds.contains("t3") ?? false), "a burst does not chain a tagged row: \(chain.map(\.itemIds))")
        let apart = G.topics([it("v1", 0, "made up garden fence plan"), it("v2", 60, "garden fence plan, posts"), it("v3", 90, "garden fence plan done"),
                              it("w1", 100 * 86400, "made up garden fence plan"), it("w2", 100 * 86400 + 60, "garden fence plan, posts"),
                              it("w3", 100 * 86400 + 90, "garden fence plan done")]).topics
        check(apart.count == 2, "one line, 100 days apart: two topics: \(apart.map(\.itemIds))")
        let person = TapeTag(name: "Lantern", kind: "person")
        let two = G.topics([it("x1", 0, "call the lantern people", tags: [person]), it("x2", 60, "lantern people again", tags: [person]),
                            it("y1", 5000, "lantern build notes", tags: [lantern]), it("y2", 5060, "lantern build more notes", tags: [lantern])]).topics
        check(two.count == 2, "a person and a project of one name: \(two.map(\.id))")
        // folding
        func f(_ d: String, fold: Bool = true, ranked: Bool = false, opened: Set<String> = [], chosen: String? = nil) -> Bool {
            G.folded(day: d, today: "2026-11-24", yesterday: "2026-11-23", foldPast: fold, ranked: ranked, opened: opened, chosenDay: chosen)
        }
        check(!f("2026-11-24") && !f("2026-11-23") && f("2026-11-20"), "today and yesterday stay open")
        check(!f("2026-11-20", fold: false) && !f("2026-11-20", ranked: true), "off, or best first")
        check(!f("2026-11-20", opened: ["2026-11-20"]) && !f("2026-11-20", chosen: "2026-11-20"), "opened, or holding the chosen row")
        check(G.dayLine(topics: ["A", "B"], first: "x", count: 5) == "A · B" && G.dayLine(topics: [], first: "first", count: 1) == "first", "day line")
        print("ran \(ran); failed: \(failed == 0 ? "" : String(failed))")
        if failed > 0 { exit(1) }
    }
}

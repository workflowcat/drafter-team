import Foundation
// swiftc -O -parse-as-library app/TapeRules.swift app/ClipRules.swift app/EntityRules.swift app/TopicClusterRules.swift tests/topic_cluster_rules.swift -o app/build/topic-cluster-test && app/build/topic-cluster-test

@main
struct TopicClusterChecks {
    static var failures = 0
    static func check(_ ok: Bool, _ message: String) { if !ok { print("FAIL: " + message); failures += 1 } }
    static func row(_ id: String, _ text: String, _ at: Double = 10_000, kind: String = "typed", app: String = "", tags: [TapeTag] = [], pinned: Bool = false) -> TopicInput {
        TopicInput(id: id, kind: kind, text: text, app: app, at: at, tags: tags, pinned: pinned)
    }
    static func main() {
        grouping(); merging(); clutter(); speed()
        if failures > 0 { print("\(failures) failed"); exit(1) }
        print("topic cluster rules: all passed")
    }
    static func grouping() {
        check(TopicClusterRules.cluster([]).isEmpty, "empty input")
        let tagged = [
            row("a", "Prepare the evidence", 100, tags: [TapeTag(name: "KYC & Compliance", kind: "project")]),
            row("b", "A separate phrase", 900_000, kind: "spoken", tags: [TapeTag(name: "KYC & Compliance", kind: "project")]),
            row("c", "Vendor reference", 800_000, kind: "copied", tags: [TapeTag(name: "KYC & Compliance", kind: "project")]),
            row("d", "Review recording", 700_000, kind: "call", tags: [TapeTag(name: "KYC & Compliance", kind: "project")])]
        let t = TopicClusterRules.cluster(tagged)
        check(t.count == 1 && t[0].title == "KYC & Compliance", "entity tag wins across dates and kinds")
        check(t[0].subtitle == "1 draft · 1 voice note · 1 clip · 1 recording", "readable counts")
        check(t[0].latestAt == 900_000 && t[0].earliestAt == 100 && t[0].primaryTag == tagged[0].tags[0], "cluster facts")
        check(t[0].itemIds == ["b", "c", "d", "a"], "members newest first")
        let en = [row("en1", "Review vendor budgets and contracts", 40_000), row("en2", "Vendor budget contract revision", 35_000, kind: "spoken")]
        let e = TopicClusterRules.cluster(en)
        check(e.count == 1 && e[0].itemIds.count == 2, "English plural stems across apps")
        check(!e[0].title.contains("and") && !e[0].title.isEmpty, "stopwords absent from title")
        let uk = [row("uk1", "Обговорити бюджет проєкту", 40_000), row("uk2", "Перевірка бюджету проєктів", 35_000, kind: "spoken")]
        check(TopicClusterRules.cluster(uk).count == 1, "Ukrainian inflections")
        check(TopicClusterRules.cluster([row("s1", "and the you with", 1), row("s2", "і та це що для", 2)]).count == 2, "stopword-only notes do not merge")
        check(TopicClusterRules.cluster([row("s1", "and the you with")])[0].title == "Standalone", "noise has a clean fallback")
        check(TopicClusterRules.cluster([row("old", en[0].text, 1), row("new", en[1].text, 200_000)]).count == 2, "keyword time boundary")
        check(TopicClusterRules.cluster(en, maxGapHours: 0.1).count == 2, "caller gap respected")
        check(TopicClusterRules.cluster([row("j1", "orchard trees", 1), row("j2", "orchard fruit", 2)]).count == 1, "Jaccard single strong token")
        let burst = [row("b1", "Prepare sketches", 1, app: "Notes"), row("b2", "Discuss railway", 1201, kind: "spoken", app: "Notes")]
        check(TopicClusterRules.cluster(burst).count == 1, "typing and voice at 20-minute boundary")
        check(TopicClusterRules.cluster([burst[0], row("b2", "Discuss railway", 1202, app: "Notes")]).count == 2, "outside burst")
        check(TopicClusterRules.cluster([burst[0], row("b2", "Discuss railway", 2, kind: "copied", app: "Notes")]).count == 2, "clips are not burst glue")
        let appTag = TapeTag(name: "Notes", kind: "app")
        check(TopicClusterRules.cluster([row("a1", "Amber meadow", tags: [appTag]), row("a2", "Violet station", tags: [appTag])]).count == 2, "app tag is not an entity")
        let input = tagged + en + uk + [row("solo", "!!! 1234", 999_999)]
        let original = TopicClusterRules.cluster(input)
        check(original == TopicClusterRules.cluster(Array(input.reversed())), "deterministic regardless of input order")
        check(original.first?.itemIds == ["solo"], "newest standalone stays date ordered")
        check(Set(original.flatMap(\.itemIds)).count == input.count, "every input occurs once")
    }
    static func merging() {
        let result = TopicClusterRules.mergeCleanNote([
            (300, "typed", "Review the station budget tomorrow."),
            (100, "typed", "Review the station budget"),
            (200, "spoken", "Review the station budget"),
            (400, "spoken", "review the station budget tomorrow!"),
            (500, "typed", "Keep the drawings.\n\nCheck the doors."),
            (600, "typed", "  ")], title: "Station review")
        check(result == "# Station review\n\nReview the station budget tomorrow.\n\nKeep the drawings.\n\nCheck the doors.", "partial drafts and repeated takes deduplicate")
        let distinct = TopicClusterRules.mergeCleanNote([(1, "typed", "Approve 10"), (2, "typed", "Approve 100"), (3, "spoken", "Do not approve 100")], title: "Numbers")
        check(distinct.contains("Approve 10\n\nApprove 100\n\nDo not approve 100"), "numbers and negation survive")
        check(TopicClusterRules.mergeCleanNote([], title: "\n").hasPrefix("# Notes\n\n"), "empty merge heading")
        let chronology = TopicClusterRules.mergeCleanNote([(1, "typed", "Plan the route"), (2, "typed", "Check the station"), (3, "typed", "Plan the route tomorrow")], title: "Route")
        check(chronology == "# Route\n\nCheck the station\n\nPlan the route tomorrow", "surviving notes keep chronological order")
    }
    static func clutter() {
        let items = [
            row("partial", "Review the station", 100, app: "Notes"),
            row("final", "Review the station budget", 500, app: "Notes"),
            row("repeat", "REVIEW the station budget!", 600, app: "Notes"),
            row("fragment", "maybe", 700), row("two", "later please", 800),
            row("clip", "okay", 900, kind: "copied"), row("space", "  \n", 901, kind: "copied"),
            row("pinned", "a", 902, pinned: true), row("call", "a", 903, kind: "call"),
            row("url", "https://example.com", 904), row("code", "let x = 1", 905),
            row("command", "git status", 906), row("shortURL", "example.com", 907, kind: "copied"),
            row("path", "/tmp/note", 908), row("three", "one two three", 909),
            row("number", "42", 910), row("negation", "Do not review the station budget", 600, app: "Notes")]
        let got = TopicClusterRules.findTidyCandidates(items), by = Dictionary(uniqueKeysWithValues: got.map { ($0.id, $0) })
        check(by["partial"]?.reason == .duplicate && by["final"]?.reason == .duplicate, "prefix and near-identical duplicate")
        check(by["partial"]?.duplicateOf == "repeat" && by["final"]?.duplicateOf == "repeat", "duplicate chains point to surviving item")
        check(by["fragment"]?.reason == .fragment && by["two"]?.reason == .fragment, "tiny drafts")
        check(by["clip"]?.reason == .shortClip && by["space"]?.reason == .shortClip, "trivial clips")
        for id in ["pinned", "call", "url", "code", "command", "shortURL", "path", "three", "number", "negation", "repeat"] {
            check(by[id] == nil, "protect \(id)")
        }
        check(TopicClusterRules.findTidyCandidates(Array(items.reversed())) == got, "deterministic tidy suggestions")
        let far = [row("old", "Complete railway review", 1), row("new", "Complete railway review", 602)]
        check(TopicClusterRules.findTidyCandidates(far).isEmpty, "duplicate time limit")
        let pin = [row("p", "Complete railway review", 1, pinned: true), row("r", "Complete railway review", 2)]
        check(TopicClusterRules.findTidyCandidates(pin).map(\.id) == ["r"], "older pinned duplicate wins")
        let recording = [row("c1", "Full recording text", 1, kind: "call"), row("c2", "Full recording text", 2, kind: "call")]
        check(TopicClusterRules.findTidyCandidates(recording).isEmpty, "duplicate calls never flagged")
        let short = [row("s1", "okay", 1, kind: "copied"), row("s2", "okay", 2, kind: "copied")]
        let shortGot = TopicClusterRules.findTidyCandidates(short)
        check(shortGot.count == 1 && shortGot.first?.id == "s1", "select all still keeps the duplicate survivor")
    }
    static func speed() {
        let phrases = ["Railway station budget review", "Orchard harvest storage schedule", "Library catalogue indexing progress", "Бюджет проєкту перевірка договорів", "Museum lighting exhibition design", "Garden irrigation watering plants", "Concert rehearsal instrument tuning", "Планування ремонту будівлі станції"]
        let input = (0..<2000).map { i in row("perf-\(i)", phrases[i % phrases.count], Double(1_000_000 - i * 75), kind: i % 3 == 0 ? "spoken" : "typed", app: "Synthetic \(i % 13)") }
        _ = TopicClusterRules.cluster(input)
        var times: [Double] = []
        for _ in 0..<5 {
            let start = DispatchTime.now().uptimeNanoseconds
            let clusters = TopicClusterRules.cluster(input)
            times.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
            check(clusters.flatMap(\.itemIds).count == 2000, "performance input complete")
        }
        let median = times.sorted()[2]
        print(String(format: "topics: 2,000 synthetic items median %.2f ms, max %.2f ms", median, times.max()!))
        check(median < 100, "2,000 items under 100 ms")
    }
}

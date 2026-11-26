import Foundation

// swiftc -O -parse-as-library app/TapeRules.swift app/ClipRules.swift app/EntityRules.swift tests/tape_rules.swift -o app/build/tape-rules-test && app/build/tape-rules-test
// The window's display rules with made-up rows: chat export heads, copied web pages, tags (with a made-up entity
// store), repeats folding, how long a row took, the sidebar's entries and counts, filters, sections; and the time
// to tag and fold 1,000 rows.
@main
struct TapeRuleChecks {
    static var failures = 0
    static func check(_ ok: Bool, _ what: String) { if !ok { print("FAIL: " + what); failures += 1 } }

    static func main() {
        chat(); pages(); tagging(); folding(); timing(); sidebar(); tagRules(); when(); sections(); sessions(); names(); speed()
        if failures > 0 { print("\(failures) failed"); exit(1) }
        print("tape rules: all passed")
    }

    static func chat() {
        let h = TapeRules.chatHeader("[14.11.26, 12:41] Mila Synthetic: Can you send the drawings?")
        check(h?.name == "Mila Synthetic" && h?.rest == "Can you send the drawings?", "a Telegram-style head")
        check(TapeRules.chatHeader("[11/14/26, 9:05:12 AM] Sava: ok")?.name == "Sava", "a WhatsApp-style head with seconds")
        check(TapeRules.chatHeader("[2026-11-14 12:41] Олена Вигадана: Добре, до четверга")?.rest == "Добре, до четверга", "Ukrainian name")
        check(TapeRules.chatHeader("[link](https://example.com) see: here") == nil, "a markdown link is no head")
        check(TapeRules.chatHeader("[12] not a chat: at all here") == nil, "too short a stamp")
        check(TapeRules.chatHeader("Note: [14.11] Mila: x") == nil, "a head must start the text")
        check(TapeRules.chatHeader("[14.11.26, 12:41] this is a long sentence before any colon at all: x") == nil, "a name has at most four words")
        let d = TapeRules.display("[14.11.26, 12:41] Mila Synthetic: First line\n[14.11.26, 12:42] Alex: second", kind: "copied", clip: "text")
        check(d.line == "First line" && d.chat == "Mila Synthetic", "display: the first message, the name as the tag")
        check(TapeRules.display("plain words\nsecond", kind: "typed", clip: "text").line == "plain words second", "plain text flattens")
        check(TapeRules.display("https://example.org/a", kind: "copied", clip: "link").chat == nil, "a link has no chat")
    }

    static func pages() {
        let page = "Skip to content\nMenu\nHome\nProducts\nAbout us\nSign in\nThe station redesign is finished. Drawings follow next week.\nMore text here"
        check(TapeRules.pageLead(page) == "The station redesign is finished.", "navigation lines skipped, first sentence: \(TapeRules.pageLead(page) ?? "nil")")
        let uk = "Головна\nНовини\nКонтакти\nУвійти\nРемонт станції завершено, креслення будуть наступного тижня"
        check(TapeRules.pageLead(uk) == "Ремонт станції завершено, креслення будуть наступного тижня", "Ukrainian navigation")
        let flat = "Home About Blog Contact Sign in The quick report on the station review is ready for you. Read it."
        check(TapeRules.pageLead(flat) == "The quick report on the station review is ready for you.", "one line: \(TapeRules.pageLead(flat) ?? "nil")")
        check(TapeRules.pageLead("Dear Mila,\nThanks for the drawings.\nSee you on Tuesday at the station, as agreed.\nAlex") == nil, "a letter is not a page")
        check(TapeRules.pageLead("Room 4.12, second floor") == nil, "a short note is not a page")
        check(TapeRules.display(page, kind: "copied", clip: "text", title: "Station redesign · Example").line == "Station redesign · Example", "the pasteboard's title wins")
        check(TapeRules.display(page, kind: "copied", clip: "text").line == "The station redesign is finished.", "else the lead")
        check(TapeRules.display(page, kind: "typed", clip: "text").line.hasPrefix("Skip to content"), "only copies are cleaned")
    }

    static func tagging() {
        // a made-up store: a person, a project, a tool, an org (orgs are not tags)
        let recs = [Entity(id: "p1", kind: "person", name: "Mila Synthetic"), Entity(id: "p2", kind: "project", name: "Lantern"),
                    Entity(id: "p3", kind: "tool", name: "Figma"), Entity(id: "p4", kind: "org", name: "Acme")]
        let store = EntityStore(records: recs, surfaces: ["mila synthetic": [EntityHit(index: 0, how: "name")], "mila": [EntityHit(index: 0, how: "first")],
                                                          "lantern": [EntityHit(index: 1, how: "name")], "figma": [EntityHit(index: 2, how: "name")],
                                                          "acme": [EntityHit(index: 3, how: "name")]])
        func found(_ t: String) -> [(name: String, kind: String)] { EntityRules.mentions(in: t, store: store).map { (recs[$0].name, recs[$0].kind) } }
        let t1 = TapeRules.tags(text: "Ask Mila about Lantern in Figma", clip: "text", app: "Telegram", found: found("Ask Mila about Lantern in Figma"))
        check(t1.map(\.name) == ["Mila Synthetic", "Lantern"], "two entities, first seen first: \(t1.map(\.name))")
        check(t1.first?.kind == "person" && t1.first?.glyph == "user", "person glyph")
        let t2 = TapeRules.tags(text: "Acme wants a call", clip: "text", app: "Mail", found: found("Acme wants a call"))
        check(t2 == [TapeTag(name: "Mail", kind: "app")], "an org is not a tag; the app is: \(t2)")
        let t3 = TapeRules.tags(text: "https://www.example.org/station/review", clip: "link", app: "Safari", found: [])
        check(t3.map(\.name) == ["example.org", "Safari"] && t3[0].kind == "site", "a link's site, then the app")
        let t4 = TapeRules.tags(text: NSHomeDirectory() + "/Desktop/drawings.pdf", clip: "file", app: "Finder", found: [])
        check(t4.first == TapeTag(name: "Desktop", kind: "folder"), "a file's folder: \(t4)")
        let t5 = TapeRules.tags(text: "x", clip: "text", app: "Telegram", chat: "Mila Synthetic", found: [("Mila Synthetic", "person"), ("Lantern", "project")])
        check(t5.map(\.name) == ["Mila Synthetic", "Lantern"], "the chat name once, then the next")
        check(t5.first?.kind == "person", "a chat named after a known person is the person tag (one sidebar entry)")
        let t6 = TapeRules.tags(text: "x", clip: "text", app: "Telegram", chat: "Station crew", found: [])
        check(t6.first == TapeTag(name: "Station crew", kind: "chat"), "any other chat stays a chat")
        check(TapeRules.tags(text: "x", clip: "text", app: "", found: []).isEmpty, "nothing found: no tags")
        check(found("mila said") .isEmpty, "a lower-case first name is not a person")
    }

    static func folding() {
        typealias Row = (kind: String, app: String, at: Double, text: String)
        let rows: [Row] = [("typed", "Notes", 1000, "See you at the station at nine"),
                           ("typed", "Notes", 990, "See you at the station"),
                           ("copied", "Safari", 985, "something else"),
                           ("typed", "Notes", 980, "see you  at the station"),
                           ("typed", "Notes", 600, "See you at the station"),
                           ("typed", "Mail", 595, "See you at the station"),
                           ("call", "Zoom", 500, "Sync"), ("call", "Zoom", 499, "Sync")]
        let g = TapeRules.collapse(rows)
        check(g == [[0, 1, 3], [2], [4], [5], [6], [7]], "prefix and duplicate fold, older and other app stay: \(g)")
        let same: [Row] = [("spoken", "Notes", 100, "Remind me on Monday"), ("spoken", "Notes", 50, "Remind me on Monday")]
        check(TapeRules.collapse(same) == [[0, 1]], "a spoken repeat folds")
        let longerOlder: [Row] = [("typed", "Notes", 100, "See you"), ("typed", "Notes", 90, "See you at nine")]
        check(TapeRules.collapse(longerOlder) == [[0], [1]], "an older longer text is not a prefix of a newer short one")
        let window: [Row] = [("typed", "Notes", 1000, "a b c"), ("typed", "Notes", 800, "a b c"), ("typed", "Notes", 650, "a b c")]
        check(TapeRules.collapse(window) == [[0, 1, 2]], "the window runs from the group's oldest row")
        check(TapeRules.collapse(window, within: 100) == [[0], [1], [2]], "a shorter window")
    }

    static func timing() {
        check(TapeRules.took(kind: "spoken", secs: 18) == 18, "a take: its audio")
        check(TapeRules.took(kind: "spoken", secs: 0.4) == nil, "under a second: nothing")
        check(TapeRules.took(kind: "call", secs: 92) == 92, "a call: its length")
        check(TapeRules.took(kind: "call", secs: 92, live: true) == nil, "a call that records: nothing")
        check(TapeRules.took(kind: "typed", secs: 0, from: 100, to: 142) == 42, "typed: first to last stamp")
        check(TapeRules.took(kind: "typed", secs: 0) == nil, "typed without stamps: nothing")
        check(TapeRules.took(kind: "typed", secs: 0, from: 0, to: 4000) == nil, "typed over 30 minutes: nothing")
        check(TapeRules.took(kind: "copied", secs: 5) == nil, "a copy: nothing")
        check(TapeRules.clock(8) == "0:08" && TapeRules.clock(92) == "1:32" && TapeRules.clock(3725) == "1:02:05", "clock")
    }

    static func facets() -> [TapeFacet] {
        let mila = TapeTag(name: "Mila Synthetic", kind: "person"), site = TapeTag(name: "example.org", kind: "site")
        return [TapeFacet(kind: "typed", app: "Telegram", at: 100_000, tags: [mila, TapeTag(name: "Telegram", kind: "app")]),
                TapeFacet(kind: "copied", clip: "link", app: "Safari", at: 99_000, tags: [site], pinned: true),
                TapeFacet(kind: "spoken", app: "Notes", at: 98_000, tags: [mila]),
                TapeFacet(kind: "copied", clip: "image", app: "Preview", at: 10_000),
                TapeFacet(kind: "call", app: "Zoom", at: 9_000, tags: [mila]),
                TapeFacet(kind: "copied", clip: "file", app: "Finder", at: 8_000)]
    }

    static func when() {
        let chunks: [(id: String, title: String, count: Int, tip: String)] = [("c:today", "Today", 20, ""), ("c:yesterday", "Yesterday", 6, ""),
            ("c:week", "Earlier this week", 20, ""), ("c:lastweek", "Last week", 35, ""), ("c:month", "Earlier this month", 5, ""),
            ("c:m:2026-10", "October", 71, ""), ("c:m:2026-09", "September", 83, ""), ("c:y:2025", "2025", 247, "")]
        let shut = TapeRules.when(chunks, olderOpen: false)
        check(shut.map(\.title) == ["Today", "Yesterday", "This week", "Last week", "This month", "Older"], "five recent and Older: \(shut.map(\.title))")
        check(shut.last?.count == 71 + 83 + 247 && shut.last?.unfolds == true && shut.last?.filter == .when(TapeRules.olderId), "Older counts what it holds")
        let open = TapeRules.when(chunks, olderOpen: true)
        check(open.map(\.title).suffix(4) == ["Older", "October", "September", "2025"] && open.suffix(3).allSatisfy { $0.depth == 1 }, "Older unfolds to months and years, one step in")
        check(TapeRules.when(Array(chunks.prefix(2)), olderOpen: false).map(\.title) == ["Today", "Yesterday"], "nothing older: no Older entry")
        check(TapeRules.when([("c:m:2026-10", "October", 3, "")], olderOpen: false).map(\.title) == ["Older"], "only old chunks: Older alone")
        check(TapeRules.when([], olderOpen: false).isEmpty, "no dates: empty bar")
        check(TapeRules.when([("c:today", "Today", 0, "")], olderOpen: false).isEmpty, "empty chunks do not make pills")
        check(open.filter { !$0.unfolds }.map(\.filter) == chunks.map { .when($0.id) }, "pills keep the exact jump IDs")

    }

    static func tagRules() {
        let mila = TapeTag(name: "Mila Synthetic", kind: "person"), lantern = TapeTag(name: "Lantern", kind: "project")
        let site = TapeTag(name: "example.org", kind: "site"), folder = TapeTag(name: "Notes", kind: "folder")
        var p = TagRules.Prefs()
        check(TagRules.auto(mila) && TagRules.auto(lantern) && !TagRules.auto(site) && !TagRules.auto(folder), "guessed kinds")
        check(!TagRules.sure(lantern, count: 2, prefs: p) && TagRules.sure(lantern, count: 3, prefs: p), "a guess needs 3 items")
        check(TagRules.sure(site, count: 1, prefs: p), "a site is a fact")
        p.pin(lantern, true)
        check(TagRules.sure(lantern, count: 1, prefs: p), "a pinned guess shows")
        p.hide(lantern)
        check(!TagRules.sure(lantern, count: 9, prefs: p) && !p.isPinned(lantern), "hide wins and unpins")
        check(TagRules.shown([mila, lantern, site], prefs: p) == [mila, site], "hidden tags dropped from a row")
        p.pin(lantern, true)
        check(!p.isHidden(lantern) && p.isPinned(lantern), "pin brings a hidden tag back")
        check(TagRules.key(TapeTag(name: "Mila Synthetic", kind: "chat")) == TagRules.key(TapeTag(name: "mila synthetic", kind: "person")), "a chat name is the person")
        // the sidebar: pinned first, guesses under 3 left out, at most `top` besides the pinned
        let n: [TapeTag: Int] = [mila: 5, lantern: 1, site: 2, folder: 1, TapeTag(name: "Quill", kind: "tool"): 2]
        let r = TagRules.related(n, prefs: p, top: 2).map(\.0.name)
        check(r == ["Lantern", "Mila Synthetic", "example.org"], "related order: \(r)")
        var q = TagRules.Prefs(); q.hide(mila); q.showAll()
        check(q.hidden.isEmpty, "show all hidden")
        let old = try? JSONDecoder().decode(TagRules.Prefs.self, from: Data(#"{"pinned":["person\tmila synthetic"],"later":1}"#.utf8))
        check(old?.pinned.count == 1 && old?.hidden.isEmpty == true, "a prefs file with other keys loads")
        // marks
        check(TagRules.initials("Mila Synthetic") == "MS" && TagRules.initials("lantern") == "L" && TagRules.initials("  ") == "", "initials")
        check(TagRules.initials("Олена Вигадана") == "ОВ", "initials in Cyrillic")
        check(TagRules.host("example.org") == "example.org" && TagRules.host("Docs.Example.org") == "docs.example.org", "a site")
        check(TagRules.host("localhost") == nil && TagRules.host("printer.local") == nil && TagRules.host("10.0.0.1") == nil
              && TagRules.host("a b.org") == nil && TagRules.host("x.org/../") == nil, "no fetch for local, IP or odd names")
        check(TagRules.faviconURLs("example.org").first?.absoluteString == "https://example.org/favicon.ico", "favicon from the site itself")
        check(TagRules.open(site, link: "https://www.example.org/a?b=1")?.absoluteString == "https://www.example.org/a?b=1", "a site tag opens the item's link")
        check(TagRules.open(site, link: "https://other.net/x")?.absoluteString == "https://example.org", "another site's link: the site")
        check(TagRules.open(site, link: "file:///etc/hosts")?.absoluteString == "https://example.org", "only web links open")
        check(TagRules.open(mila, link: nil) == nil, "a person opens nothing")
    }

    static func sidebar() {
        let f = facets()
        let e = TapeRules.sidebar(f)
        check(e.map(\.title).prefix(9) == ["All", "Pinned", "Clips", "Pictures", "Links", "Files", "Drafts", "Voice notes", "Recordings"], "fixed entries first, named")
        check(e[0].count == 6 && e[1].count == 1 && e[2].count == 3 && e[6].count == 1 && e[7].count == 1 && e[8].count == 1, "counts")
        check(e[3...5].allSatisfy { $0.depth == 1 } && e[6...8].allSatisfy { $0.depth == 0 }, "clip subsets sit under Clips")
        check(!e.contains { $0.group == "When" } && TapeRules.groups == ["Kinds", "Apps", "Related to"], "dates never enter the sidebar")
        let empty = TapeRules.sidebar([])
        check(Array(empty.prefix(9).map(\.filter)) == Array(e.prefix(9).map(\.filter)), "empty kinds keep fixed positions")
        check(e.prefix(9).map { TapeRules.shortcut($0.filter) } == Array(1...9).map(Optional.some), "stable shortcuts in visual order")
        check(TapeRules.shortcut(.app("Example")) == nil && TapeRules.shortcut(.when("c:today")) == nil, "dynamic rows cannot claim sidebar shortcuts")
        let rel = e.filter { $0.group == "Related to" }
        check(rel.map(\.title) == ["Mila Synthetic", "example.org"] && rel[0].count == 3, "tags by count, apps left out: \(rel.map(\.title))")
        check(e.filter { $0.group == "Apps" }.count == 6, "apps")
        check(e.firstIndex { $0.group == "Apps" }! < e.firstIndex { $0.group == "Related to" }!, "Related to under Apps")
        check(e.allSatisfy { !$0.tip.isEmpty }, "every entry has a tooltip")
        check(TapeRules.visible(e, folded: ["Apps", "Related to"]).count == 9, "folded groups are skipped")
        check(f.filter(TapeRules.Filter.kind("picture").matches).count == 1, "pictures")
        check(f.filter(TapeRules.Filter.kind("copied").matches).count == 3, "copied holds every copy")
        check(f.filter(TapeRules.Filter.tag(TapeTag(name: "mila synthetic", kind: "person")).matches).count == 3, "a tag, any case")
        check(f.filter(TapeRules.Filter.app("Zoom").matches).count == 1, "an app")
        check(f.filter(TapeRules.Filter.pinned.matches).count == 1, "pinned")
        check(TapeRules.words(.tag(TapeTag(name: "Lantern", kind: "project"))) == "related to Lantern", "filter in words")
    }

    static func sections() {
        check(TapeRules.Group.allCases == [.time, .topics, .related, .app] && TapeRules.Group.topics.title == "Topics", "Topics in the group picker")
        check(TapeRules.Group(rawValue: "related") == .related, "existing saved group stays valid")
        let f = facets()
        let day: (Double) -> (key: Int, title: String) = { t in (Int(t / 86400), "Day \(Int(t / 86400))") }
        let byTime = TapeRules.sections(f, rows: Array(f.indices), by: .time, day: day)
        check(byTime.map(\.title) == ["Day 1", "Day 0"] && byTime[0].rows == [0, 1, 2], "time: a section per day")
        let byTag = TapeRules.sections(f, rows: Array(f.indices), by: .related, day: day)
        check(byTag.first?.title == "Mila Synthetic" && byTag.first?.rows == [0, 2, 4], "related: the biggest first: \(byTag.map(\.title))")
        check(byTag.contains { $0.title == "Preview" }, "no tag: the app")
        let byApp = TapeRules.sections(f, rows: [0, 2, 4], by: .app, day: day)
        check(byApp.map(\.title) == ["Telegram", "Notes", "Zoom"], "app: equal sizes keep the newest first")
        check(TapeRules.summary(f, rows: Array(f.indices)) == "1 draft · 3 clips · 1 voice note · 1 recording", "summary: \(TapeRules.summary(f, rows: Array(f.indices)))")
    }

    static func sessions() {
        typealias Row = (kind: String, app: String, at: Double, day: Int)
        // newest first: a Telegram stretch with a Safari clip inside, a gap, Notes, a recording, Notes again
        let rows: [Row] = [("typed", "Notes", 10_000, 1),                      // 0
                           ("call", "Zoom", 9_500, 1),                         // 1: its own
                           ("spoken", "Notes", 9_400, 1),                      // 2
                           ("typed", "Notes", 9_000, 1),                       // 3
                           ("typed", "Telegram", 7_000, 1),                    // 4: 2,000 s later than 5? no: 400 s
                           ("copied", "Safari", 6_600, 1),                     // 5: a clip inside the stretch
                           ("typed", "Telegram", 6_200, 1),                    // 6
                           ("typed", "Telegram", 5_000, 1),                    // 7: 1,200 s gap before 6
                           ("copied", "Finder", 4_900, 0),                     // 8: another day
                           ("typed", "Mail", 4_800, 0)]                        // 9
        let g = TapeRules.sessions(rows)
        check(g == [[0], [1], [2, 3], [4, 5, 6], [7], [8, 9]], "sessions: \(g)")
        check(TapeRules.sessions([]).isEmpty, "no rows, no sessions")
        let gap: [Row] = [("typed", "Notes", 1599, 0), ("typed", "Notes", 1000, 0)]
        check(TapeRules.sessions(gap) == [[0, 1]], "599 s apart: one session")
        let gap2: [Row] = [("typed", "Notes", 1600, 0), ("typed", "Notes", 1000, 0)]
        check(TapeRules.sessions(gap2) == [[0], [1]], "600 s apart: two")
        let clipsFirst: [Row] = [("typed", "Mail", 200, 0), ("copied", "Safari", 100, 0)]
        check(TapeRules.sessions(clipsFirst) == [[0, 1]], "a stretch of clips takes the app that joins it")
        let f = [TapeFacet(kind: "typed", app: "Telegram", at: 7000, tags: [TapeTag(name: "Lantern", kind: "project")]),
                 TapeFacet(kind: "copied", clip: "link", app: "Safari", at: 6600, tags: [TapeTag(name: "Lantern", kind: "project")]),
                 TapeFacet(kind: "typed", app: "Telegram", at: 6200)]
        let facts = TapeRules.sessionFacts(f, took: [30, nil, 20], rows: [0, 1, 2])
        check(facts.app == "Telegram" && facts.tag?.name == "Lantern" && facts.items == 3, "session facts: \(facts)")
        check(facts.from == 6180 && facts.to == 7000 && facts.took == 820, "from the first key to the last row")
    }

    /// Nouns for kinds, never a past participle as a label (the user, 14 November).
    static func names() {
        check(TapeRules.one("spoken") == "Voice note" && TapeRules.one("typed") == "Draft" && TapeRules.one("copied") == "Clip", "one of a kind")
        check(TapeRules.one("copied", clip: "link") == "Link" && TapeRules.one("call") == "Recording", "clips by what they are")
        let words = TapeRules.sidebar([]).map(\.title) + TapeRules.sidebar([]).map(\.tip)
        for w in ["Copied", "Typed", "Spoken", "Said", "Calls"] { check(!words.contains { $0.contains(w) }, "no '\(w)' in the sidebar") }
    }

    static func speed() {
        let words = ["plan", "station", "Mila", "budget", "зустріч", "четвер", "report", "Lantern", "invoice", "notes"]
        let recs = [Entity(id: "p1", kind: "person", name: "Mila"), Entity(id: "p2", kind: "project", name: "Lantern")]
        let store = EntityStore(records: recs, surfaces: ["mila": [EntityHit(index: 0, how: "name")], "lantern": [EntityHit(index: 1, how: "name")]])
        var rows: [(kind: String, app: String, at: Double, text: String)] = []
        for i in 0..<1000 { rows.append(("typed", "Notes", Double(100_000 - i * 60), (0..<(6 + i % 30)).map { words[($0 * 7 + i) % words.count] }.joined(separator: " "))) }
        let t0 = Date()
        var n = 0
        for r in rows { n += TapeRules.tags(text: String(r.text.prefix(400)), clip: "text", app: r.app, found: EntityRules.mentions(in: String(r.text.prefix(400)), store: store).map { (recs[$0].name, recs[$0].kind) }).count }
        let tagMs = Date().timeIntervalSince(t0) * 1000
        let t1 = Date(); _ = TapeRules.collapse(rows); let foldMs = Date().timeIntervalSince(t1) * 1000
        print(String(format: "speed: tags for 1,000 rows %.1f ms (%d tags), fold %.1f ms", tagMs, n, foldMs))
        check(tagMs < 2000 && foldMs < 200, "fast enough")
    }
}

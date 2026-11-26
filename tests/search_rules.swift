// swiftc -O -parse-as-library app/SearchRules.swift app/SearchIndex.swift app/JournalEngine.swift app/QuickSearch.swift app/SearchAdapters.swift app/Entry.swift app/PictureLookRules.swift app/ClipRules.swift app/QuickRules.swift app/Recording.swift app/MeetingRules.swift app/Transcript.swift app/CaptureRules.swift tests/search_rules.swift -o app/build/search-rules-test && app/build/search-rules-test
// The journal search core with made-up text in both languages: tokens, stems, the other layout, typos, the query
// language (words, prefix, phrases, exclusions, filters, date offers), name forms, ranking order, ranges, snippets,
// totals, did-you-mean, incremental adds, cancel.
import Foundation

@main
struct SearchChecks {
    static var failures = 0
    static func check(_ ok: Bool, _ what: String) { if !ok { print("FAIL: " + what); failures += 1 } }

    // Saturday 14 November 2026, 12:00 in Kyiv
    static let kyiv = TimeZone(identifier: "Europe/Kyiv")!
    static let clock: SearchClock = {
        var c = Calendar(identifier: .gregorian); c.timeZone = kyiv
        return SearchClock(now: c.date(from: DateComponents(year: 2026, month: 11, day: 14, hour: 12))!.timeIntervalSince1970, timeZone: kyiv)
    }()
    static let now = clock.now
    static let day = 86400.0

    static func main() {
        tokens(); stems(); layout(); typos(); parse(); offers(); intervals()
        matching(); ranking(); filters(); results(); names(); incremental(); cancel()
        alternations(); shortTypos(); phrases(); engine(); quick(); speed()
        if failures > 0 { print("\(failures) failed"); exit(1) }
        print("search rules: all passed")
    }

    // MARK: tokens

    static func tokens() {
        let t = SearchRules.terms
        check(t("Їжак") == t("іжак") && t("ЇЖАК") == ["іжак"], "ї folds to і, case away: \(t("Їжак"))")
        check(t("м'ясо") == ["мясо"] && t("м’ясо") == ["мясо"] && t("мʼясо") == ["мясо"], "three apostrophes are one, dropped inside a word")
        check(t("Café crème") == ["cafe", "creme"], "Latin marks folded: \(t("Café crème"))")
        check(t("Ґанок й") == ["ганок", "и"], "ґ as г, й as и")
        check(t("rev 2026, v5") == ["rev", "2026", "v5"], "digits kept: \(t("rev 2026, v5"))")
        let url = t("https://www.example.com/plans/station-one?x=1")
        check(["example", "com", "plans", "station", "one"].allSatisfy(url.contains), "a link in parts: \(url)")
        var parts: [String] = []
        SearchRules.scan("/Volumes/Work/Desktop/fileName.pdf invoice2026") { if $0.part { parts.append($0.term) } }
        check(parts.contains("file") && parts.contains("name") && parts.contains("invoice") && parts.contains("2026"), "camelCase and digit parts: \(parts)")
        var r: [SearchToken] = []
        SearchRules.scan("Hi, світ!") { r.append($0) }
        check(r.map(\.start) == [0, 4] && r.map(\.length) == [2, 4], "UTF-16 places: \(r)")
        var e: [SearchToken] = []
        SearchRules.scan("😀 кава") { e.append($0) }
        check(e.first?.start == 3, "an emoji counts two UTF-16 units: \(e)")
        check(SearchRules.fold("  Привіт,   СВІТ ") == "привіт світ", "fold as a whole")
    }

    static func stems() {
        let s = SearchRules.stem
        func same(_ a: [String], _ what: String) {
            let st = Set(a.map { s(SearchRules.terms($0)[0]) })
            check(st.count == 1, "\(what): \(a) -> \(st)")
        }
        same(["звіт", "звіту", "звітом", "звіти", "звітів"], "noun forms")
        same(["зустріч", "зустрічі"], "noun i-stem")
        same(["команда", "команди", "командою", "команді", "командами"], "noun a-stem")
        same(["проєкт", "проєкту", "проєкти"], "noun with є")
        same(["новий", "нового", "новому", "нова", "нові", "новими"], "adjective forms")
        same(["зробити", "зробив", "зробила", "зробили"], "verb forms")
        same(["читати", "читав", "читала"], "verb forms 2")
        same(["навчитися", "навчиться", "навчилася"], "reflexive")
        same(["учитель", "учителя", "учителем"], "soft sign")
        same(["plan", "plans", "planning", "planned"], "English plan")
        same(["note", "notes"], "English plural")
        same(["box", "boxes"], "English -es")
        same(["story", "stories"], "English -ies")
        same(["make", "makes", "making"], "English -ing with e")
        check(s("bus") == "bus" && s("status") == "status", "short and -us words stay")
        check(s("кіт") == "кіт" && s("2026") == "2026", "short words and digits stay")
    }

    static func layout() {
        check(SearchRules.otherLayout("ghbdsn") == "привіт", "Latin keys meant Ukrainian: \(String(describing: SearchRules.otherLayout("ghbdsn")))")
        check(SearchRules.otherLayout("руддщ") == "hello", "Cyrillic keys meant English: \(String(describing: SearchRules.otherLayout("руддщ")))")
        check(SearchRules.otherLayout("ghj'rn") == "проєкт", "' is є: \(String(describing: SearchRules.otherLayout("ghj'rn")))")
        check(SearchRules.otherLayout("pdsn") == "звіт", "pdsn: \(String(describing: SearchRules.otherLayout("pdsn")))")
        check(SearchRules.otherLayout("2026") == nil && SearchRules.otherLayout("abcабв") == nil, "digits and mixed scripts stay")
    }

    static func typos() {
        func d(_ a: String, _ b: String, _ m: Int = 2) -> Int { SearchRules.distance(Array(a.unicodeScalars), Array(b.unicodeScalars), max: m) }
        check(d("plan", "plna") == 1, "a swap is one edit")
        check(d("station", "statoin") == 1 && d("кава", "кава") == 0 && d("budget", "budgte") == 1, "small edits")
        check(d("abcdef", "azcdxf") == 2 && d("abcdef", "uvwxyz", 2) == 3, "two edits; over the bound stops at max+1")
        check(SearchRules.typoBudget("plan") == 0 && SearchRules.typoBudget("звіту") == 1 && SearchRules.typoBudget("documentation") == 2, "budget by length")
        check(SearchRules.typoBudget("v20266") == 0, "no typos with digits")
        check(SearchRules.trigrams("кава").count == 4, "trigrams with ends marked")
    }

    // MARK: the query language

    static func parse() {
        let q = SearchQueryRules.parse("report \"station one\" -draft kind:voice app:Chrome in:yesterday before:2026-11-01 has:link is:pinned with:Olena pla", clock: clock)
        check(q.words.map(\.term) == ["report", "pla"], "words: \(q.words)")
        check(q.words.last?.prefix == true && q.words.first?.prefix == false, "the last word is a prefix")
        check(q.phrases == [["station", "one"]], "phrase: \(q.phrases)")
        check(q.excluded.map(\.term) == ["draft"], "excluded")
        check(q.chips.count == 7, "chips: \(q.chips.map(\.label))")
        check(q.filters.contains(.kind([.voice])) && q.filters.contains(.app("chrome")) && q.filters.contains(.with("olena")), "kind, app, with")
        check(q.filters.contains(.has(.link)) && q.filters.contains(.has(.pin)), "has:link, is:pinned")
        check(q.chips.contains { $0.label == "Yesterday" } && q.chips.contains { $0.label.hasPrefix("Before 1 Nov") }, "time chips: \(q.chips.map(\.label))")
        // removing a chip gives the query without it
        let app = q.chips.first { $0.filter == .app("chrome") }!
        check(!q.removing(app).contains("app:") && q.removing(app).contains("kind:voice"), "chip removed: \(q.removing(app))")
        check(SearchQueryRules.parse("plan ", clock: clock).words.first?.prefix == false, "a space after the word: no prefix")
        check(SearchQueryRules.parse("p", clock: clock).words.first?.prefix == false, "one letter: no prefix")
        let w = SearchQueryRules.parse("in:this week звіт", clock: clock)
        check(w.chips.first?.label == "This week" && w.words.map(\.term) == ["звіт"], "in:this week joins two words: \(w.chips.map(\.label)) \(w.words)")
        let u = SearchQueryRules.parse("тип:голос коли:минулого тижня", clock: clock)
        check(u.filters.contains(.kind([.voice])) && u.chips.contains { $0.label == "Last week" }, "Ukrainian keys and values: \(u.chips.map(\.label))")
        check(SearchQueryRules.parse("app:\"Google Chrome\" x", clock: clock).filters == [.app("google chrome")], "quoted filter value")
        check(SearchQueryRules.parse("10:30 re:", clock: clock).words.map(\.term) == ["10", "30", "re"], "unknown keys stay words")
        check(SearchQueryRules.parse("kind:nonsense", clock: clock).chips.isEmpty, "a value it does not know: no chip")
        check(SearchQueryRules.parse("-\"old plan\" x", clock: clock).excludedPhrases == [["old", "plan"]], "excluded phrase")
        check(SearchQueryRules.parse("«кава зранку»", clock: clock).phrases == [["кава", "зранку"]], "«» quotes")
        check(SearchQueryRules.parse("app:", clock: clock).isEmpty, "a half-typed filter is nothing yet")
    }

    static func offers() {
        let a = SearchQueryRules.parse("notes yesterday", clock: clock)
        check(a.chips.isEmpty && a.words.count == 2, "a date word is not applied")
        check(a.offers.first?.token == "in:yesterday" && a.offers.first?.label == "Yesterday", "but offered: \(a.offers)")
        check(a.applying(a.offers[0]) == "notes in:yesterday", "applying: \(a.applying(a.offers[0]))")
        let b = SearchQueryRules.parse("звіт вчора", clock: clock)
        check(b.offers.first?.token == "in:yesterday", "вчора: \(b.offers)")
        let c = SearchQueryRules.parse("last week report", clock: clock)
        check(c.offers.first?.token == "in:last-week" && c.offers.first?.range == NSRange(location: 0, length: 9), "last week: \(c.offers)")
        let d = SearchQueryRules.parse("дзвінок у понеділок", clock: clock)
        check(d.offers.first?.token == "in:2026-11-09" && d.applying(d.offers[0]) == "дзвінок in:2026-11-09", "у понеділок: \(d.offers) \(d.offers.first.map { d.applying($0) } ?? "")")
        let e = SearchQueryRules.parse("план на минулому тижні", clock: clock)
        check(e.offers.first?.token == "in:last-week", "на минулому тижні: \(e.offers)")
        let f = SearchQueryRules.parse("рахунок березня", clock: clock)
        check(f.offers.first?.token == "in:march" && f.offers.first?.label == "March", "березня: \(f.offers)")
        check(SearchQueryRules.parse("you may go", clock: clock).offers.isEmpty, "may alone is a word")
        let g = SearchQueryRules.parse("last friday", clock: clock)
        check(g.offers.first?.token == "in:2026-11-06", "last friday: \(g.offers)")
        check(SearchQueryRules.parse("friday", clock: clock).offers.first?.token == "in:2026-11-13", "friday: the latest one")
    }

    static func intervals() {
        let cal = clock.calendar
        func at(_ y: Int, _ m: Int, _ d: Int) -> Double { cal.date(from: DateComponents(year: y, month: m, day: d))!.timeIntervalSince1970 }
        let t = SearchQueryRules.interval("today", clock)!
        check(t.lo == at(2026, 11, 14) && t.hi == at(2026, 11, 15), "today, midnight to midnight in Kyiv")
        let w = SearchQueryRules.interval("this-week", clock)!
        check(w.lo == at(2026, 11, 9), "the week starts on Monday")
        check(SearchQueryRules.interval("march", clock)!.lo == at(2026, 3, 1), "a past month this year")
        check(SearchQueryRules.interval("december", clock)!.lo == at(2025, 12, 1), "a month ahead means last year")
        check(SearchQueryRules.interval("грудень", clock)!.lo == at(2025, 12, 1), "Ukrainian month")
        check(SearchQueryRules.interval("2025", clock)!.hi == at(2026, 1, 1), "a year")
        check(SearchQueryRules.interval("10.11", clock)!.lo == at(2026, 11, 10), "dd.mm this year")
        check(SearchQueryRules.interval("2026-10-03", clock)!.lo == at(2026, 10, 3), "yyyy-mm-dd")
        check(SearchQueryRules.interval("nonsense", clock) == nil, "unknown")
        let ch = SearchIndex.chunker(clock)
        check(ch(now - 60) == "today" && ch(now - day) == "yesterday" && ch(at(2026, 11, 10)) == "this-week"
              && ch(at(2026, 11, 3)) == "last-week" && ch(at(2026, 11, 1)) == "this-month" && ch(at(2026, 9, 5)) == "2026-09", "chunks")
    }

    // MARK: the index

    /// Wire round bench: 3,000 made-up rows with detector marks (as the build stores them); every key, with has: and
    /// mentions: filters too, answers under 30 ms in the core once the index is built. The core never runs the
    /// detector: its marks are plain fields of the document.
    static func speed() {
        let words = ["station", "plan", "drawings", "lantern", "review", "room", "agenda", "invoice", "studio", "heating", "станція", "кімната", "план", "зустріч"]
        let ix = SearchIndex()
        var docs: [SearchDoc] = []
        for i in 0..<3000 {
            let w = (0..<12).map { words[($0 * 7 + i * 3) % words.count] }.joined(separator: " ")
            var d = doc("s\(i)", i % 3 == 0 ? .clip : .draft, "\(w) number \(i)", ago: Double(i % 400))
            if i % 5 == 0 { d.found = SearchHas.date.bit; d.mentions = [now + Double(i % 9) * day] }
            if i % 7 == 0 { d.found |= SearchHas.money.bit }
            docs.append(d)
        }
        ix.add(docs)
        _ = ix.search("warm", clock: clock)
        var worst = 0.0
        for q in ["s", "st", "sta", "stat", "stati", "station has:date", "has:money", "mentions:friday", "plan mentions:friday", "lantern review", "кімн"] {
            let t0 = Date(); _ = ix.search(q, clock: clock); worst = max(worst, Date().timeIntervalSince(t0) * 1000)
        }
        check(worst < 30, String(format: "3,000 rows: every key under 30 ms in the core (worst %.1f ms)", worst))
        print(String(format: "search speed: 3,000 rows, worst key %.1f ms", worst))
    }

    static func doc(_ id: String, _ kind: SearchKind, _ text: String, ago: Double = 1, app: String = "Notes") -> SearchDoc {
        SearchDoc.text(id: id, kind: kind, time: now - ago * day, app: app, text: text)
    }
    static func ids(_ ix: SearchIndex, _ q: String, _ o: SearchOptions = SearchOptions()) -> [String] {
        ix.search(q, clock: clock, options: o)!.hits.map(\.id)
    }

    static func matching() {
        let ix = SearchIndex()
        ix.add([
            doc("a", .draft, "Зустріч з командою у четвер"),
            doc("b", .clip, "station plan for the budget"),
            doc("c", .clip, "one station, then another"),
            doc("d", .voice, "Звіт за жовтень готовий"),
            doc("e", .draft, "budget draft, old"),
            doc("f", .clip, "notes on the station one design"),
        ])
        check(ids(ix, "зустрічі") == ["a"] && ids(ix, "команди") == ["a"], "case forms find each other")
        check(ids(ix, "stat").contains("b") && ids(ix, "stat ").isEmpty, "prefix only while typing")
        check(Set(ids(ix, "station budget")) == ["b"], "words AND")
        check(Set(ids(ix, "\"station one\"")) == ["f"], "phrase: \(ids(ix, "\"station one\""))")
        check(Set(ids(ix, "budget -draft")) == ["b"], "excluded word")
        let r = ix.search("pdsn", clock: clock)!
        check(r.hits.map(\.id) == ["d"] && r.didYouMean == "звіт" && r.didYouMeanWhy == "layout", "other layout: \(r.hits.map(\.id)) \(String(describing: r.didYouMean))")
        let t = ix.search("budgte", clock: clock)!
        check(Set(t.hits.map(\.id)) == ["b", "e"] && t.didYouMean == "budget" && t.didYouMeanWhy == "typo", "typo: \(t.hits.map(\.id)) \(String(describing: t.didYouMean))")
        ix.add([doc("g", .draft, "Добрий ранок усім")])
        check(ids(ix, "lj,hbq hfyjr") == ["g"], "б typed as , in the other layout: \(ids(ix, "lj,hbq hfyjr"))")
        check(ids(ix, "zzzz").isEmpty && ix.search("zzzz", clock: clock)?.didYouMean == nil, "nothing, nothing offered")
        check(ids(ix, "").count == 7, "empty query: everything")
        let mixed = ix.search("plan бюджет", clock: clock)!
        check(mixed.hits.isEmpty, "a word that is nowhere keeps AND strict")
    }

    static func ranking() {
        let ix = SearchIndex()
        ix.add([
            doc("old-title", .draft, "Квартальний звіт\nцифри по продажах", ago: 300),
            doc("new-body", .draft, "Нотатки на день\nДовгий текст про різне: погода, кава, дорога додому, і десь там звіт, а далі ще багато слів про інше", ago: 0.01),
        ])
        check(ids(ix, "звіт").first == "old-title", "an old title hit stays above a new weak one: \(ids(ix, "звіт"))")
        let ix2 = SearchIndex()
        ix2.add([doc("older", .clip, "coffee beans order", ago: 3), doc("newer", .clip, "coffee beans order", ago: 1)])
        check(ids(ix2, "coffee") == ["newer", "older"], "same text: newer first")
        ix2.setPinned("older", true)
        check(ids(ix2, "coffee") == ["older", "newer"], "a pin lifts it")
        let ix3 = SearchIndex()
        var a = doc("used", .clip, "invoice template", ago: 2); a.uses = 6
        ix3.add([a, doc("fresh", .clip, "invoice template", ago: 1.5)])
        check(ids(ix3, "invoice") == ["used", "fresh"], "puts lift it (QuickRules' learned signal)")
        let ix4 = SearchIndex()
        ix4.add([doc("apart", .clip, "one thing and then station", ago: 1), doc("together", .clip, "the station one is here", ago: 2)])
        check(ids(ix4, "station one") == ["together", "apart"], "words side by side in order win: \(ids(ix4, "station one"))")
        let ix5 = SearchIndex()
        ix5.add([doc("typo", .clip, "budgte line", ago: 1), doc("exact", .clip, "budget line", ago: 5)])
        check(ids(ix5, "budget") == ["exact", "typo"], "exact above typo: \(ids(ix5, "budget"))")
        let ix6 = SearchIndex()
        ix6.add([doc("pre", .clip, "stationery shop", ago: 1), doc("ex", .clip, "station shop", ago: 5)])
        check(ids(ix6, "station ") == ["ex"] && Set(ids(ix6, "statio")) == ["pre", "ex"], "prefix reaches both, a finished word only itself")
        check(ids(ix6, "station shop").first == "ex", "exact above prefix while typing: \(ids(ix6, "station shop"))")
        let ix7 = SearchIndex()
        var tl = SearchDoc(id: "title", kind: .recording, time: now - day); tl.recTitle = "Budget call"
        var tr = SearchDoc(id: "trans", kind: .recording, time: now - day); tr.transcript = "we talked about the budget for a while and then moved on"
        ix7.add([tr, tl])
        check(ids(ix7, "budget") == ["title", "trans"], "a recording title above its transcript")
        check(SearchRules.useSignal(item: [now], app: [], now: now) == 1.5, "use signal as QuickRules counts it")
    }

    static func filters() {
        let ix = SearchIndex()
        var pic = doc("pic", .clip, "Image · 400 × 300", ago: 0.1); pic.picture = true; pic.ocr = "квитанція оплата"
        var lnk = doc("lnk", .clip, "https://example.com/plans", ago: 1, app: "Google Chrome"); lnk.link = "example.com plans Station plans"
        var tag = doc("tag", .recording, "", ago: 8); tag.recTitle = "Weekly"; tag.tags = ["Olena Petrenko"]
        var pin = doc("pin", .draft, "plans for next week", ago: 20); pin.pinned = true
        var chg = doc("chg", .voice, "plans changed", ago: 40); chg.changed = true
        // a shot: the picture as an image entry, then its note, a mark's words and the window (ShotJournalRules.searchText)
        var e = Entry(id: "c9", when: Date(timeIntervalSince1970: now - 0.2 * day), app: "Safari", text: "Image · 1280 × 720", audio: "")
        e.clip = .image; e.ocr = "Departures board"
        var shot = SearchDoc.entry(e, kind: .clip, id: "shot")
        shot.addShot("the lift button is too small\nthis one\nStation plan")
        var bare = SearchDoc.entry(e, kind: .clip, id: "bare"); bare.addShot("")
        let sx = SearchIndex(); sx.add([pic, shot, bare])
        check(ids(sx, "lift button") == ["shot"] && ids(sx, "this one") == ["shot"], "a shot found by its note and a mark's words")
        check(Set(ids(sx, "departures")) == ["shot", "bare"] && bare.title.isEmpty && bare.body.isEmpty, "the read text still searched; no note adds nothing")
        check(shot.title == "the lift button is too small", "the note is the title the search marks: \(shot.title)")
        check(Set(ids(sx, "has:picture")) == ["pic", "shot", "bare"], "shots are pictures")
        ix.add([pic, lnk, tag, pin, chg])
        check(ids(ix, "has:picture") == ["pic"] && ids(ix, "оплата") == ["pic"], "picture and its read text")
        check(ids(ix, "plans has:link") == ["lnk"] && ids(ix, "app:chrome") == ["lnk"], "has:link, app:")
        check(ids(ix, "with:olena") == ["tag"] && ids(ix, "with:petrenko") == ["tag"], "with: in the tags")
        check(ids(ix, "is:pinned") == ["pin"] && ids(ix, "has:change") == ["chg"], "pinned, changed")
        check(Set(ids(ix, "plans kind:draft,voice")) == ["pin", "chg"], "kinds")
        check(ids(ix, "plans in:today") == [] && ids(ix, "in:today") == ["pic"], "in:today")
        check(Set(ids(ix, "plans before:2026-11-01")) == ["pin", "chg"] && ids(ix, "after:2026-11-01 plans") == ["lnk"], "before:, after: \(ids(ix, "after:2026-11-01 plans"))")
        check(ids(ix, "in:this-week") == ["pic", "lnk"], "filter only: newest first")
        let r = ix.search("plans kind:voice", clock: clock)!
        check(r.hits.map(\.id) == ["chg"] && r.kindTotals == [.clip: 1, .draft: 1, .voice: 1], "kind totals ignore the kind filter: \(r.kindTotals)")
        check(r.chunkTotals == ["2026-10": 1], "chunk totals of the filtered set: \(r.chunkTotals)")
        let all = ix.search("plans", clock: clock)!
        check(all.chunkTotals["yesterday"] == 1 && all.chunkTotals["2026-10"] == 2, "chunks: \(all.chunkTotals)")
        found()
    }

    /// Wire round: has:date/money/phone/email/path/code from the detector's marks, mentions:<date words>.
    static func found() {
        let cal = clock.calendar
        // the clock's next Friday (today included) and the day after it
        let today = (cal.component(.weekday, from: clock.date) + 5) % 7 + 1
        let fri = cal.startOfDay(for: cal.date(byAdding: .day, value: (5 - today + 7) % 7, to: clock.date)!).timeIntervalSince1970
        let ix = SearchIndex()
        var a = doc("call", .draft, "call Mila on Friday about the plan", ago: 2); a.found = SearchHas.date.bit; a.mentions = [fri]
        var b = doc("pay", .clip, "the plan costs 1 250 грн", ago: 3); b.found = SearchHas.money.bit
        var c = doc("mail", .clip, "write to mila@example.org", ago: 4); c.found = SearchHas.email.bit | SearchHas.link.bit
        var e = doc("later", .draft, "the plan for the day after", ago: 5); e.found = SearchHas.date.bit; e.mentions = [fri + 86400]
        ix.add([a, b, c, e])
        check(Set(ids(ix, "has:date")) == ["call", "later"], "has:date: \(ids(ix, "has:date"))")
        check(ids(ix, "has:money") == ["pay"] && ids(ix, "має:гроші") == ["pay"], "has:money, має:гроші")
        check(ids(ix, "has:email") == ["mail"] && ids(ix, "has:link") == ["mail"], "has:email; a found link counts for has:link")
        check(Set(ids(ix, "plan has:date")) == ["call", "later"], "words and has:date")
        check(ids(ix, "mentions:friday") == ["call"], "mentions:friday: \(ids(ix, "mentions:friday"))")
        check(ids(ix, "згадує:п'ятницю") == ["call"], "згадує:п'ятницю: \(ids(ix, "згадує:п'ятницю"))")
        check(ids(ix, "has:date mentions:friday") == ["call"], "has:date with mentions:friday")
        check(ids(ix, "has:phone").isEmpty && ids(ix, "has:code").isEmpty && ids(ix, "has:iban").isEmpty, "nothing marked: nothing found")
        check(SearchQueryRules.parse("has:amount", clock: clock).chips.first?.label == "Has money" && SearchQueryRules.parse("has:iban", clock: clock).chips.first?.label == "Has iban", "has:amount is money; has:iban")
        let q = SearchQueryRules.parse("plan has:date mentions:friday", clock: clock)
        check(q.chips.count == 2 && q.chips.contains { $0.label == "Has date" } && q.chips.contains { $0.label.hasPrefix("Mentions Friday") }, "chips: \(q.chips.map(\.label))")
        if case .mentions(let lo, _)? = q.chips.first(where: { $0.label.hasPrefix("Mentions") })?.filter { check(lo == fri && lo >= cal.startOfDay(for: clock.date).timeIntervalSince1970, "a weekday is the next one, today included") }
        else { check(false, "mentions filter") }
        // a month resolves forward; in: still backward
        let m = SearchQueryRules.interval("january", clock, forward: true)!, mb = SearchQueryRules.interval("january", clock)!
        check(m.lo > clock.now && mb.lo < clock.now, "mentions:january is the next January, in:january the last")
        check(SearchQueryRules.parse("mentions:завтра", clock: clock).chips.first?.label == "Mentions Tomorrow", "mentions:завтра")
        check(SearchQueryRules.parse("mentions:soon", clock: clock).chips.isEmpty, "an unknown date: no chip")
        check(SearchHas.allCases.count == Set(SearchHas.allCases.map(\.bit)).count && !SearchHas.allCases.contains { $0.bit == 16 }, "bits apart and clear of the index's own")
    }

    static func results() {
        let ix = SearchIndex()
        let long = String(repeating: "слова без змісту ", count: 30) + "тут важлива зустріч з Оленою" + String(repeating: " і ще трохи тексту", count: 20)
        ix.add([doc("short", .draft, "Кава й зустріч", ago: 3), doc("long", .voice, "Нотатка\n" + long, ago: 1)])
        let r = ix.search("зустрічі", clock: clock)!
        let s = r.hits.first { $0.id == "short" }!
        check(s.ranges[.title] == [NSRange(location: 7, length: 7)], "title range: \(s.ranges)")
        let l = r.hits.first { $0.id == "long" }!
        let sn = l.snippet!
        check(sn.field == .body && sn.text.hasPrefix("…") && sn.text.hasSuffix("…") && (sn.text as NSString).length < 200, "snippet window: \(sn.text)")
        check(sn.ranges.count == 1 && (sn.text as NSString).substring(with: sn.ranges[0]) == "зустріч", "snippet range marks the word")
        check(r.marker.ranges(in: "наша зустріч завтра") == [NSRange(location: 5, length: 7)], "the marker works on any line")
        let p = ix.search("зуст", clock: clock)!
        check(p.marker.ranges(in: "зустрічі").count == 1, "prefix marked")
        let lim = ix.search("зустріч", clock: clock, options: SearchOptions(order: .rank, limit: 1, detail: 0))!
        check(lim.hits.count == 1 && lim.hits[0].ranges.isEmpty && lim.kindTotals.values.reduce(0, +) == 2, "limit and no detail; totals count all")
        let tm = ix.search("зустріч", clock: clock, options: SearchOptions(order: .time))!
        check(tm.hits.map(\.id) == ["long", "short"], "time order: \(tm.hits.map(\.id))")
        let (rs, _) = ix.detail(ix.index(of: "long")!, r.marker)
        check(rs[.body]?.count == 1, "detail on demand")
    }

    static func names() {
        let surfaces: [String: [(record: Int, how: String)]] = [
            "olena petrenko": [(0, "name")], "олена петренко": [(0, "form")], "олени петренко": [(0, "form")],
            "оленою петренко": [(0, "form")], "olena": [(0, "first"), (1, "first")],
            "ivan": [(2, "first"), (3, "first")], "notion": [(4, "name")], "ноушн": [(4, "alias")],
        ]
        let nf = NameFormTable(surfaces)
        check(Set(nf.otherForms(of: "olena")) == ["олена", "олени", "оленою"], "word at the same place: \(nf.otherForms(of: "olena"))")
        check(nf.otherForms(of: "ivan").isEmpty, "a surface of two records needs context: skipped")
        check(nf.otherForms(of: "notion") == ["ноушн"], "one-word names")
        check(NameFormTable(surfaces, needsContext: ["олена петренко"]).otherForms(of: "olena").count == 2, "marked forms skipped")
        let ix = SearchIndex(names: nf)
        ix.add([doc("u", .voice, "дзвінок з Оленою про план"), doc("n", .clip, "нотатки в ноушн")])
        check(ids(ix, "olena") == ["u"], "a Latin spelling finds the Cyrillic form")
        check(ids(ix, "notion") == ["n"], "a tool's other name")
        var t = doc("t", .recording, ""); t.tags = ["Олена Петренко"]
        ix.add([t])
        check(ids(ix, "with:olena") == ["t"], "with: through name forms")
    }

    static func incremental() {
        let ix = SearchIndex()
        ix.add([doc("1", .clip, "first apple")])
        check(ids(ix, "apple") == ["1"], "first add")
        ix.prepare()                                       // packed flat; later adds go to each word's tail
        ix.add([doc("2", .clip, "second apple pie")])
        check(Set(ids(ix, "apple")) == ["1", "2"] && ids(ix, "pie") == ["2"], "added later")
        check(Set(ids(ix, "apples ")) == ["1", "2"], "stems of words added after packing")
        ix.prepare()
        check(Set(ids(ix, "apple")) == ["1", "2"] && ids(ix, "pie") == ["2"], "packed again")
        ix.remove(id: "1")
        check(ids(ix, "apple") == ["2"] && ids(ix, "first").isEmpty, "removed")
        ix.add([doc("2", .clip, "second pear")])
        check(ids(ix, "apple").isEmpty && ids(ix, "pear") == ["2"], "replaced by id")
        check(ids(ix, "pea") == ["2"], "new words reach the prefix list")
        ix.add([doc("3", .clip, "translation")])
        check(ids(ix, "translaton") == ["3"], "typo filter covers words added after the first typo query")
    }

    static func cancel() {
        let ix = SearchIndex()
        ix.add((0..<200).map { doc("c\($0)", .clip, "item number \($0) apple") })
        check(ix.search("apple", clock: clock, cancelled: { true }) == nil, "a cancelled query reports nothing")
        let svc = SearchService()
        svc.callback = DispatchQueue(label: "test.callback")
        let g = DispatchGroup()
        g.enter(); svc.load((0..<50).map { doc("s\($0)", .clip, "service apple \($0)") }) { g.leave() }
        g.wait()
        var got: [String] = []
        let lock = NSLock()
        svc.queue.async { usleep(100_000) }               // the queue is busy: both queries wait
        g.enter(); g.enter()
        svc.search("zzz", clock: { clock }) { _ in lock.lock(); got.append("first"); lock.unlock(); g.leave() }
        svc.search("apple", clock: { clock }) { r in lock.lock(); got.append("second \(r.hits.count)"); lock.unlock(); g.leave() }
        g.leave()                                          // the first never calls back
        _ = g.wait(timeout: .now() + 2)
        check(got == ["second 50"], "the newer query wins, the stale one is dropped: \(got)")
    }

    // MARK: round two: alternations, short typos, phrases, the wired engine, the Quick panel

    static func alternations() {
        let a = Set(SearchRules.alternations(SearchRules.stem("кінь")))
        check(a.contains("кон") && a.contains("кен"), "кін- -> кон-: \(a)")
        check(SearchRules.alternations("сн").contains("сон"), "the dropped о comes back: \(SearchRules.alternations("сн"))")
        check(SearchRules.alternations("сон").contains("сн"), "сон -> сн")
        check(SearchRules.alternations("рук").contains("руц"), "к/ц at the end: \(SearchRules.alternations("рук"))")
        check(SearchRules.alternations("plan").isEmpty, "English words have none")
        let ix = SearchIndex()
        ix.add([
            doc("kin", .draft, "Купили коня на ярмарку"),
            doc("kyiv", .voice, "Зустріч у Києві в понеділок"),
            doc("son", .draft, "Після сну все краще"),
            doc("hand", .clip, "Тримай у руці"),
            doc("night", .draft, "Цієї ночі тихо"),
            doc("autumn", .draft, "Восени листя жовте"),
            doc("window", .voice, "Біля вікон стоїть стіл"),
            doc("plain", .draft, "Кінь стоїть у стайні"),
        ])
        check(Set(ids(ix, "кінь ")) == ["kin", "plain"], "кінь finds коня: \(ids(ix, "кінь "))")
        check(ids(ix, "кінь ").first == "plain", "the plain form ranks above the alternation: \(ids(ix, "кінь "))")
        check(ids(ix, "Київ ") == ["kyiv"], "Київ finds Києві: \(ids(ix, "Київ "))")
        check(ids(ix, "сон ") == ["son"], "сон finds сну: \(ids(ix, "сон "))")
        check(ids(ix, "рука ") == ["hand"], "рука finds руці: \(ids(ix, "рука "))")
        check(ids(ix, "ніч ") == ["night"], "ніч finds ночі: \(ids(ix, "ніч "))")
        check(ids(ix, "вікно ") == ["window"], "вікно finds вікон: \(ids(ix, "вікно "))")
        // what still fails: a whole different stem (осінь / восени: the prothetic в)
        check(ids(ix, "осінь ").isEmpty, "осінь does not reach восени (known limit)")
        let r = ix.search("коня ", clock: clock)!
        check(r.marker.ranges(in: "Кінь стоїть").count == 1, "the marker marks the other shape too")
    }

    static func shortTypos() {
        let ix = SearchIndex()
        ix.add([doc("a", .draft, "Купити хліб і каву"), doc("b", .draft, "Новий план на тиждень"), doc("c", .clip, "the blue door")])
        check(ids(ix, "хлжб ") == ["a"], "a 4-letter word with one edit, when nothing else was found: \(ids(ix, "хлжб "))")
        check(ids(ix, "plna ") == ["b"] || ids(ix, "плна ") == ["b"], "a 4-letter swap")
        check(ids(ix, "bleu ") == ["c"], "bleu -> blue")
        let r = ix.search("bleu ", clock: clock)!
        check(r.didYouMean == "blue" && r.didYouMeanWhy == "typo", "did you mean for a 4-letter typo: \(String(describing: r.didYouMean))")
        // a 4-letter word that exists keeps its own answer, no typo neighbours
        ix.add([doc("d", .clip, "the blur effect"), doc("e", .clip, "blue sky"), doc("f", .clip, "blue sea"), doc("g", .clip, "blue ink")])
        check(!ids(ix, "blue ").contains("d"), "blue (4 hits) does not pull in blur: \(ids(ix, "blue "))")
        check(ids(ix, "blxx ").isEmpty, "two edits in a 4-letter word: nothing")
    }

    static func phrases() {
        let long = (0..<700).map { ["кава", "зранку", "план", "station", "one", "budget"][$0 % 6] }.joined(separator: " ")
        let ix = SearchIndex()
        var call = SearchDoc(id: "call", kind: .recording, time: now - day)
        call.transcript = long + " зелений чай наприкінці"
        ix.add([call,
                doc("t", .draft, "Ранкова кава\nзранку все добре"),      // the phrase runs from the first line into the body
                doc("s", .draft, "кава і чай, зранку"),
                doc("x", .clip, "чай зелений")])
        check(Set(ids(ix, "\"зелений чай\"")) == ["call"], "a phrase in a long recording: \(ids(ix, "\"зелений чай\""))")
        check(Set(ids(ix, "\"чай зелений\"")) == ["x"], "the order counts")
        check(Set(ids(ix, "\"кава зранку\"")) == ["call", "t"], "across the first line and the body: \(ids(ix, "\"кава зранку\""))")
        check(ids(ix, "\"кава чай\"").isEmpty, "words apart are not a phrase")
        check(Set(ids(ix, "\"зранку план\"")) == ["call"], "a phrase inside the long run")
    }

    static func engine() {
        // the journal's engine, as the window drives it, with made-up rows
        let rows: [SearchDoc] = (0..<40).map { i in
            var d = doc("r\(i)", i % 2 == 0 ? .draft : .clip, i == 7 ? "Оплатити рахунок за світло" : "Нотатка номер \(i) про ремонт", ago: Double(i))
            d.pinned = i == 3
            return d
        }
        let e = JournalEngine(inline: true)
        var docs = rows
        e.update(version: 1, count: docs.count, id: { docs[$0].id }, sig: { docs[$0].pinned ? 1 : 0 }, doc: { docs[$0] })
        check(e.ready, "inline engine is ready at once")
        var got: SearchResult?
        e.search("рахунок", now: now) { got = $0 }
        check(got?.hits.map(\.id) == ["r7"], "finds through the engine: \(String(describing: got?.hits.map(\.id)))")
        e.search("ремонт", now: now) { got = $0 }
        check(got?.hits.count == 39, "every hit comes back, not only the top: \(got?.hits.count ?? -1)")
        check(got?.hits.filter { !$0.ranges.isEmpty }.count == SearchWeights.detail, "ranges for the top \(SearchWeights.detail)")
        let deep = got!.hits.last!
        let text = docs.first { $0.id == deep.id }!.body
        check(!got!.marker.ranges(in: text).isEmpty, "the marker marks a row beyond the top 20")
        check(got?.hits.first?.id == "r3", "a pin rises: \(String(describing: got?.hits.first?.id))")
        // a row goes, one changes, one comes: only those are read again
        docs.removeAll { $0.id == "r7" }
        docs[0].body = "Новий текст про дах"; docs[0].title = "Новий текст про дах"
        docs.append(doc("new", .voice, "Рахунок за воду"))
        let sig: (Int) -> Int = { docs[$0].id == "r0" ? 99 : docs[$0].pinned ? 1 : 0 }
        e.update(version: 2, count: docs.count, id: { docs[$0].id }, sig: sig, doc: { docs[$0] })
        e.search("рахунок", now: now) { got = $0 }
        check(got?.hits.map(\.id) == ["new"], "a removed row is gone, a new one found: \(String(describing: got?.hits.map(\.id)))")
        e.search("дах", now: now) { got = $0 }
        check(got?.hits.map(\.id) == ["r0"], "a changed row is read again")
        // a pin only: the flag changes, the words stay
        docs[5].pinned = true
        e.update(version: 3, count: docs.count, id: { docs[$0].id }, sig: sig, doc: { docs[$0] })
        e.search("ремонт", now: now) { got = $0 }
        check(Set(got!.hits.prefix(2).map(\.id)) == ["r3", "r5"], "a new pin rises: \(got!.hits.prefix(3).map(\.id))")
        // the same version costs nothing (no closure is called)
        var called = false
        e.update(version: 3, count: docs.count, id: { called = true; return docs[$0].id }, sig: sig, doc: { docs[$0] })
        check(!called, "the same rows are not read again")
        let at = e.rowIndex(version: 3, count: docs.count, id: { docs[$0].id })
        check(at["new"] == docs.count - 1, "row index by id")

        // on its own queue: answers come back on the callback queue, a newer search drops an older one
        let q = DispatchQueue(label: "test.callback")
        let a = JournalEngine()
        a.callback = q
        let built = DispatchSemaphore(value: 0)
        a.onReady = { built.signal() }
        check(!a.ready, "not ready before the build")
        let many = (0..<3000).map { doc("m\($0)", .draft, "рядок \($0) зі словом поле і ще кілька слів для ваги") }
        a.update(version: 1, count: many.count, id: { many[$0].id }, sig: { _ in 0 }, doc: { many[$0] })
        var answers: [String] = []
        let lock = NSLock()
        let done = DispatchSemaphore(value: 0)
        a.search("поле", now: now) { _ in lock.lock(); answers.append("old"); lock.unlock() }
        a.search("рядок", now: now) { _ in lock.lock(); answers.append("new"); lock.unlock(); done.signal() }
        done.wait(); built.wait()
        q.sync {}
        check(answers == ["new"], "the newer search wins, the older never answers: \(answers)")
        check(a.ready && a.buildMs > 0, "ready after the build")
    }

    static func quick() {
        // the Quick panel's search: pins first, the core's order, then what only the plain match finds
        func item(_ k: QuickKind, _ t: String, ago: Double) -> QuickItem { QuickItem(kind: k, text: t, app: "Notes", at: now - ago * 3600) }
        var items = [
            item(.copied, "https://example.com/station-1250", ago: 1),
            item(.typed, "Зустріч у четвер о десятій", ago: 2),
            item(.voice, "зустрічі переносимо на п'ятницю", ago: 30),
            item(.copied, "order 1 250 confirmed", ago: 3),
        ]
        items[2].pinned = true
        let qs = QuickSearch()
        qs.inline = true
        check(qs.filter(items, query: "зустріч", kind: nil, uses: QuickUses(), now: now) == QuickRules.filter(items, query: "зустріч", kind: nil, uses: QuickUses(), now: now),
              "before the index: the plain filter, unchanged")
        qs.rebuild(items, uses: QuickUses(), now: now)
        check(qs.ready, "built inline")
        let z = qs.filter(items, query: "зустріч", kind: nil, uses: QuickUses(), now: now)
        check(z == [2, 1], "pins first, then the core's order: \(z)")
        check(qs.filter(items, query: "pecnhs", kind: nil, uses: QuickUses(), now: now).contains(1), "the other layout in the Quick panel")
        check(qs.filter(items, query: "1 250", kind: nil, uses: QuickUses(), now: now) == QuickRules.filter(items, query: "1 250", kind: nil, uses: QuickUses(), now: now),
              "numbers as before: \(qs.filter(items, query: "1 250", kind: nil, uses: QuickUses(), now: now))")
        check(qs.filter(items, query: "ation", kind: nil, uses: QuickUses(), now: now) == [0], "a piece inside a word still found (the plain match)")
        check(qs.filter(items, query: "зустріч", kind: .typed, uses: QuickUses(), now: now) == [1], "the kind tab holds")
        check(qs.filter(items, query: "", kind: nil, uses: QuickUses(), now: now) == QuickRules.filter(items, query: "", kind: nil, uses: QuickUses(), now: now), "empty query as before")
        // the learned puts lift an item
        var u = QuickUses()
        for k in 0..<4 { QuickRules.used(&u, items[3], at: now - Double(k) * 600) }
        items.append(item(.copied, "order 2 shipped", ago: 0.5))
        qs.rebuild(items, uses: u, now: now)
        check(qs.filter(items, query: "order", kind: nil, uses: u, now: now).first == 3, "an item he puts in often comes first: \(qs.filter(items, query: "order", kind: nil, uses: u, now: now))")
        // new rows: the old index is dropped at once, the plain filter answers until the new one is in
        let qa = QuickSearch()
        qa.rebuild(items, uses: u, now: now)
        check(!qa.ready, "a background build is handed over on the main thread, not before")
        check(qa.filter(items, query: "order", kind: nil, uses: u, now: now) == QuickRules.filter(items, query: "order", kind: nil, uses: u, now: now),
              "meanwhile the plain filter answers")
    }
}

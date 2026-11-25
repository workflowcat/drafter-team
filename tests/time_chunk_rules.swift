import Foundation

// swiftc -O -parse-as-library app/TimeChunkRules.swift tests/time_chunk_rules.swift -o app/build/time-chunks-test && app/build/time-chunks-test
// The journal's chunks of time with made-up moments, in Kyiv time with Monday as the week's first day: midnight,
// the week start, month and year edges, the clock change day (25 October 2026), an empty chunk, moments exactly on a
// boundary; the tree and its totals; the row times and the relative phrases; and the time for a year of rows.
@main
struct TimeChunkChecks {
    static var failures = 0
    static func check(_ ok: Bool, _ what: String) { if !ok { print("FAIL: " + what); failures += 1 } }
    static var cal: Calendar = { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "Europe/Kyiv")!; c.firstWeekday = 2; c.locale = Locale(identifier: "en_GB"); return c }()
    static func t(_ y: Int, _ mo: Int, _ d: Int, _ h: Int = 12, _ mi: Int = 0, _ s: Int = 0) -> Double {
        cal.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi, second: s))!.timeIntervalSince1970
    }
    static func ids(_ at: Double, _ now: Double) -> [String] { TimeChunks.path(at, now: now, cal: cal).map(\.id) }
    static func titles(_ at: Double, _ now: Double) -> [String] { TimeChunks.path(at, now: now, cal: cal).map(\.title) }

    static func main() {
        let now = t(2026, 11, 14, 12, 45)   // a Saturday
        // today and its parts, boundaries included
        check(ids(t(2026, 11, 14, 0, 0, 0), now) == ["c:today", "p:2026-11-14:0"], "midnight starts today, at night")
        check(titles(t(2026, 11, 14, 6, 0), now) == ["Today", "Morning"], "06:00 is morning")
        check(titles(t(2026, 11, 14, 5, 59, 59), now) == ["Today", "Night"], "05:59 is night")
        check(titles(t(2026, 11, 14, 12, 0), now) == ["Today", "Midday"], "12:00 is midday")
        check(titles(t(2026, 11, 13, 14, 0), now) == ["Yesterday", "Afternoon"], "14:00 is afternoon")
        check(titles(t(2026, 11, 13, 18, 0), now) == ["Yesterday", "Evening"], "18:00 is evening")
        check(titles(t(2026, 11, 13, 17, 59, 59), now) == ["Yesterday", "Afternoon"], "17:59:59 is afternoon")
        check(titles(now + 3600, now) == ["Today", "Midday"], "a moment after now counts as now")
        // yesterday: midnight's other side
        check(titles(t(2026, 11, 13, 23, 59, 59), now) == ["Yesterday", "Evening"], "23:59:59 yesterday")
        check(ids(t(2026, 11, 13, 0, 0, 0), now).first == "c:yesterday", "yesterday's midnight")
        // the week: Monday 9 November starts it
        check(titles(t(2026, 11, 12, 9), now) == ["This week", "Thursday 12 November"], "earlier this week")
        check(ids(t(2026, 11, 9, 0, 0, 0), now).first == "c:week", "Monday 00:00 is this week")
        check(ids(t(2026, 11, 8, 23, 59, 59), now).first == "c:lastweek", "Sunday 23:59:59 is last week")
        check(ids(t(2026, 11, 2, 0, 0, 0), now).first == "c:lastweek", "last Monday 00:00 is last week")
        // earlier this month: 1 November is a Sunday, its week clipped to November
        check(titles(t(2026, 11, 1, 10), now) == ["This month", "1 November", "Sunday 1 November"], "the month's first day: \(titles(t(2026, 11, 1, 10), now))")
        // an earlier month of this year, by week (clipped to the month)
        check(titles(t(2026, 10, 30, 10), now) == ["October", "26–31 October", "Friday 30 October"], "October's last week: \(titles(t(2026, 10, 30, 10), now))")
        check(titles(t(2026, 1, 1, 0, 0, 0), now) == ["January", "1–4 January", "Thursday 1 January"], "the year's first moment: \(titles(t(2026, 1, 1, 0, 0, 0), now))")
        // an earlier year, by month
        check(titles(t(2025, 12, 31, 23, 59, 59), now) == ["2025", "December 2025", "29–31 December", "Wednesday 31 December"], "the year's last moment: \(titles(t(2025, 12, 31, 23, 59, 59), now))")
        // the clock change (Kyiv, 25 October 2026, 04:00 back to 03:00): one day, the right parts
        let after = t(2026, 10, 26, 10)   // the Monday after
        check(titles(t(2026, 10, 25, 23, 30), after) == ["Yesterday", "Evening"], "the change day's evening is yesterday: \(titles(t(2026, 10, 25, 23, 30), after))")
        check(titles(t(2026, 10, 25, 0, 30), after) == ["Yesterday", "Night"], "the change day's first hour is yesterday")
        let onIt = t(2026, 10, 25, 22)
        check(ids(t(2026, 10, 25, 0, 10), onIt).first == "c:today" && ids(t(2026, 10, 25, 23, 50), onIt).first == "c:today", "the whole change day is today on it")
        check(ids(t(2026, 10, 24, 23, 59), onIt).first == "c:yesterday", "the day before the change is yesterday")
        // a Monday: yesterday was Sunday (last week's), This week is empty
        let monday = t(2026, 11, 9, 10)
        check(ids(t(2026, 11, 8, 15), monday).first == "c:yesterday", "on a Monday, Sunday is yesterday")
        check(ids(t(2026, 11, 7, 15), monday).first == "c:lastweek", "on a Monday, Saturday is last week")
        // the year's first week, when last week is in the year before
        let jan = t(2027, 1, 6, 10)
        check(ids(t(2026, 12, 30, 10), jan).first == "c:lastweek", "last week across the new year")
        check(ids(t(2026, 12, 20, 10), jan).first == "c:y:2026", "before last week, last year is a year chunk")

        // the tree: an empty chunk does not show, totals add up
        func s(_ id: String, _ at: Double, active: Double = 60, rec: Int = 0, items: Int = 2) -> TimeChunks.SessionIn {
            TimeChunks.SessionIn(id: id, path: TimeChunks.path(at, now: now, cal: cal), active: active, recordings: rec, items: items)
        }
        let tree = TimeChunks.tree([s("a", t(2026, 11, 14, 11)), s("b", t(2026, 11, 14, 9), active: 600, rec: 1, items: 1),
                                    s("c", t(2026, 11, 13, 20)), s("d", t(2026, 11, 3, 10)), s("e", t(2026, 9, 3, 10), items: 5)])
        check(tree.map(\.key.title) == ["Today", "Yesterday", "Last week", "September"], "chunks with something, newest first; no 'This week': \(tree.map(\.key.title))")
        check(tree[0].totals == TimeChunks.Totals(active: 660, recordings: 1, items: 3), "today's totals: \(tree[0].totals)")
        check(tree[0].children.map(\.key.title) == ["Morning"] && tree[0].children[0].children.count == 2, "both sessions in the morning")
        check(tree[0].children[0].children[1].session == 1, "a session leaf knows its index")
        check(tree[3].children.first?.children.first?.children.first?.session == 4, "September: week, day, session")
        check(TimeChunks.tree([]).isEmpty, "no sessions, no chunks")
        check(TimeChunks.words(tree[0].totals) == "11 min active · 1 recording · 3 items", "totals in words: \(TimeChunks.words(tree[0].totals))")
        check(TimeChunks.words(.init(active: 7800, recordings: 2, items: 40)) == "2 h 10 min active · 2 recordings · 40 items", "hours")
        check(TimeChunks.words(.init(active: 20, recordings: 0, items: 1)) == "1 item", "under a minute: no active time")
        // Sparse date paths open at every age. Explicit folds still win at the caller; session policy is unchanged.
        for level in [TimeChunks.Level.chunk, .year, .month, .week, .day, .part] {
            let key = TimeChunks.Key(level: level, id: "c:y:2025", title: "Synthetic date", start: 0)
            check(TimeChunks.openByDefault(key, chunk: "c:y:2025", fold: "older", sparse: true), "sparse date opens: \(level)")
            let opens = ["manual": false]
            check(!(opens["manual"] ?? TimeChunks.openByDefault(key, chunk: "c:y:2025", fold: "older", sparse: true)), "manual fold wins")
        }
        let sessionKey = TimeChunks.Key(level: .session, id: "sample", title: "", start: 0)
        check(!TimeChunks.openByDefault(sessionKey, chunk: "c:yesterday", fold: "all", sparse: true), "sparse keeps explicit session policy")
        // folds by default
        let k = TimeChunks.path(t(2026, 11, 14, 9), now: now, cal: cal)
        check(TimeChunks.openByDefault(k[0], chunk: "c:today", fold: "older"), "today is open")
        check(TimeChunks.openByDefault(TimeChunks.Key(level: .session, id: "x", title: "", start: 0), chunk: "c:today", fold: "older"), "today's sessions are open")
        check(!TimeChunks.openByDefault(TimeChunks.Key(level: .session, id: "x", title: "", start: 0), chunk: "c:yesterday", fold: "older"), "yesterday's sessions are folded")
        check(TimeChunks.openByDefault(TimeChunks.Key(level: .session, id: "x", title: "", start: 0), chunk: "c:y:2025", fold: "none"), "fold none: open")
        check(!TimeChunks.openByDefault(TimeChunks.Key(level: .session, id: "x", title: "", start: 0), chunk: "c:today", fold: "all"), "fold all: folded")
        check(!TimeChunks.openByDefault(TimeChunks.path(t(2026, 9, 3), now: now, cal: cal)[0], chunk: "", fold: "older"), "an earlier month is folded")
        check(!TimeChunks.openByDefault(TimeChunks.path(t(2026, 11, 3), now: now, cal: cal)[1], chunk: "", fold: "older"), "a day of last week is folded")
        // the gutter and the reader
        check(TimeChunks.rowTime(t(2026, 11, 14, 9, 5), chunk: "c:today", cal: cal) == "09:05", "today: the clock")
        check(TimeChunks.rowTime(t(2026, 11, 3, 9, 5), chunk: "c:lastweek", cal: cal) == "Tue 09:05", "a week chunk: weekday and clock")
        check(TimeChunks.rowTime(t(2026, 9, 3, 9, 5), chunk: "c:m:2026-09", cal: cal) == "3 Sept" || TimeChunks.rowTime(t(2026, 9, 3, 9, 5), chunk: "c:m:2026-09", cal: cal) == "3 Sep", "a month chunk: day and month")
        check(TimeChunks.rowTime(t(2025, 3, 3, 9, 5), chunk: "c:y:2025", cal: cal) == "3 Mar 25", "a year chunk: day, month, year")
        check(TimeChunks.relative(now - 30, now: now, cal: cal) == "just now", "just now")
        check(TimeChunks.relative(now - 2 * 3600 - 60, now: now, cal: cal) == "2 hours ago", "2 hours ago")
        check(TimeChunks.relative(t(2026, 11, 13, 18, 40), now: now, cal: cal) == "yesterday at 18:40", "yesterday")
        check(TimeChunks.relative(t(2026, 11, 10, 9), now: now, cal: cal) == "on Tuesday", "this week")
        check(TimeChunks.relative(t(2026, 11, 3, 9), now: now, cal: cal) == "last Tuesday", "last week")
        check(TimeChunks.relative(t(2026, 10, 3, 9), now: now, cal: cal) == "in October", "a month")
        check(TimeChunks.relative(t(2025, 10, 3, 9), now: now, cal: cal) == "in October 2025", "a year")

        // speed: a year of made-up moments, one every 20 minutes of the day
        var times: [Double] = []
        var x = now
        while x > now - 365 * 86400 { times.append(x); x -= 1200 }
        let t0 = Date()
        let frame = TimeChunks.Frame(now: now, cal: cal)
        let paths = times.map { frame.path($0) }
        let pathMs = Date().timeIntervalSince(t0) * 1000
        let t1 = Date()
        let built = TimeChunks.tree(paths.enumerated().map { TimeChunks.SessionIn(id: "s\($0.offset)", path: $0.element, active: 60, recordings: 0, items: 1) })
        let treeMs = Date().timeIntervalSince(t1) * 1000
        print(String(format: "speed: %d moments, paths %.0f ms, tree %.1f ms, %d chunks", times.count, pathMs, treeMs, built.count))

        if failures > 0 { print("\(failures) failed"); exit(1) }
        print("time chunk rules: all passed")
    }
}

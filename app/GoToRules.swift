// "Go to" (⌘T, soft round, 14 November 2026): one small palette that jumps to a left-pane entry, a person, project or
// tool, an app, or a date said the way he says it, in English or Ukrainian ("last Tuesday", "3 Oct", "October",
// "минулого вівторка", "3 жовтня", "жовтень"). Pure: `now` and the calendar come in; tested in tests/goto_rules.swift.
import Foundation

enum GoTo {
    struct Candidate: Equatable { let kind: String; let title: String; let id: String; var glyph = "list" }
    /// A span of time to jump to: [from, to) in seconds, and its name.
    struct Span: Equatable { let from: Double; let to: Double; let title: String }

    // MARK: words

    static let monthsEn = ["january", "february", "march", "april", "may", "june", "july", "august", "september", "october", "november", "december"]
    static let monthsUk = ["січ", "лют", "берез", "квіт", "трав", "черв", "лип", "серп", "верес", "жовт", "листопад", "груд"]
    static let daysEn = ["sunday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday"]   // Calendar weekday 1...7
    static let daysUk = ["неділ", "понеділ", "вівтор", "серед", "четвер", "пятниц", "субот"]

    static func clean(_ s: String) -> [String] {
        s.lowercased().replacingOccurrences(of: "’", with: "").replacingOccurrences(of: "'", with: "").replacingOccurrences(of: "ʼ", with: "")
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "." }).map(String.init).filter { !$0.isEmpty }
    }
    static func month(_ w: String) -> Int? {
        if let i = monthsUk.firstIndex(where: { w.hasPrefix($0) }) { return i + 1 }
        guard w.count >= 3 else { return nil }
        let e = w == "sept" ? "sep" : w
        return monthsEn.firstIndex { $0.hasPrefix(e) }.map { $0 + 1 }   // "oct", "octob", "october"; never "mark"
    }
    static func weekday(_ w: String) -> Int? {
        if let i = daysUk.firstIndex(where: { w.hasPrefix($0) }) { return i + 1 }
        guard w.count >= 3 else { return nil }
        let e = w == "tues" ? "tue" : w == "thur" || w == "thurs" ? "thu" : w
        return daysEn.firstIndex { $0.hasPrefix(e) }.map { $0 + 1 }
    }

    // MARK: dates

    /// A date in his words, or nil. A month or a day without a year is the latest one not after `now`.
    static func date(_ q: String, now: Double, cal: Calendar) -> Span? {
        let w = clean(q)
        guard !w.isEmpty else { return nil }
        let n = Date(timeIntervalSince1970: now), today = cal.startOfDay(for: n)
        func day(_ d: Date) -> Span {
            let f = DateFormatter(); f.calendar = cal; f.timeZone = cal.timeZone; f.locale = Locale(identifier: "en_GB"); f.dateFormat = "EEEE d MMMM yyyy"
            return Span(from: d.timeIntervalSince1970, to: cal.date(byAdding: .day, value: 1, to: d)!.timeIntervalSince1970, title: f.string(from: d))
        }
        func span(_ c: Calendar.Component, _ d: Date, _ title: String) -> Span {
            let i = cal.dateInterval(of: c, for: d)!
            return Span(from: i.start.timeIntervalSince1970, to: i.end.timeIntervalSince1970, title: title)
        }
        let last = w.contains { $0 == "last" || $0.hasPrefix("минул") || $0 == "попередн" || $0.hasPrefix("попередн") }
        let this = w.contains { $0 == "this" || $0.hasPrefix("цього") || $0.hasPrefix("цей") || $0.hasPrefix("ця") }
        let all = w.joined(separator: " ")
        if all == "today" || w.contains(where: { $0.hasPrefix("сьогодн") }) { return day(today) }
        if all == "yesterday" || w.contains(where: { $0 == "вчора" || $0 == "учора" }) { return day(cal.date(byAdding: .day, value: -1, to: today)!) }
        if w.contains(where: { $0 == "week" || $0.hasPrefix("тижн") || $0 == "тиждень" }) {
            let d = last ? cal.date(byAdding: .weekOfYear, value: -1, to: n)! : n
            return span(.weekOfYear, d, last ? "Last week" : "This week")
        }
        if w.contains(where: { $0 == "month" || $0.hasPrefix("місяц") }), last || this {
            let d = last ? cal.date(byAdding: .month, value: -1, to: n)! : n
            return span(.month, d, last ? "Last month" : "This month")
        }
        // "N days ago" / "N днів тому"
        if w.count >= 2, let k = Int(w[0]), w[1].hasPrefix("day") || w[1].hasPrefix("дн") || w[1].hasPrefix("ден") {
            return day(cal.date(byAdding: .day, value: -k, to: today)!)
        }
        // a weekday: the latest one not after today ("last": the one in last week)
        if let wd = w.lazy.compactMap(weekday).first, w.allSatisfy({ weekday($0) != nil || ["last", "on", "у", "в", "во"].contains($0) || $0.hasPrefix("минул") }) {
            let todayWd = cal.component(.weekday, from: today)
            if last {
                let lastWeek = cal.dateInterval(of: .weekOfYear, for: cal.date(byAdding: .weekOfYear, value: -1, to: today)!)!.start
                var d = lastWeek
                while cal.component(.weekday, from: d) != wd { d = cal.date(byAdding: .day, value: 1, to: d)! }
                return day(d)
            }
            let back = (todayWd - wd + 7) % 7
            return day(cal.date(byAdding: .day, value: -back, to: today)!)
        }
        // numbers: "3.10", "03.10.2025", "2025"
        if w.count == 1, w[0].contains(".") {
            let p = w[0].split(separator: ".").compactMap { Int($0) }
            if p.count >= 2, (1...31).contains(p[0]), (1...12).contains(p[1]) {
                return dayOf(p[0], p[1], year: p.count > 2 ? (p[2] < 100 ? 2000 + p[2] : p[2]) : nil, now: n, cal: cal).map(day)
            }
            return nil
        }
        let nums = w.compactMap { Int($0) }
        let m = w.lazy.compactMap(month).first
        let year = nums.first { $0 >= 1990 && $0 <= 2100 }
        let dnum = nums.first { $0 >= 1 && $0 <= 31 }
        if let m {
            if let dnum { return dayOf(dnum, m, year: year, now: n, cal: cal).map(day) }
            var c = DateComponents(); c.year = year ?? cal.component(.year, from: n); c.month = m; c.day = 1
            var d = cal.date(from: c)!
            if year == nil, d > n { c.year! -= 1; d = cal.date(from: c)! }
            let f = DateFormatter(); f.calendar = cal; f.locale = Locale(identifier: "en_GB"); f.dateFormat = "MMMM yyyy"
            return span(.month, d, f.string(from: d))
        }
        if let y = year, w.count == 1 {
            var c = DateComponents(); c.year = y; c.month = 1; c.day = 1
            return span(.year, cal.date(from: c)!, "\(y)")
        }
        return nil
    }
    private static func dayOf(_ d: Int, _ m: Int, year: Int?, now: Date, cal: Calendar) -> Date? {
        var c = DateComponents(); c.year = year ?? cal.component(.year, from: now); c.month = m; c.day = d
        guard var x = cal.date(from: c), cal.component(.day, from: x) == d else { return nil }
        if year == nil, x > now { c.year! -= 1; x = cal.date(from: c) ?? x }
        return x
    }

    // MARK: the list

    /// The candidates for what he typed, best first: a date (when it reads as one), then names that start with it,
    /// then names with a word that starts with it, then names that hold it. Empty: everything, as given.
    static func rank(_ q: String, _ all: [Candidate], limit: Int = 12) -> [Candidate] {
        let t = q.lowercased().trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return Array(all.prefix(limit)) }
        func score(_ c: Candidate) -> Int? {
            let n = c.title.lowercased()
            if n.hasPrefix(t) { return 0 }
            if n.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).contains(where: { $0.hasPrefix(t) }) { return 1 }
            if n.contains(t) { return 2 }
            return nil
        }
        return all.enumerated().compactMap { i, c in score(c).map { ($0, i, c) } }.sorted { ($0.0, $0.1) < ($1.0, $1.1) }.prefix(limit).map(\.2)
    }
}

import Foundation

// swiftc -O -parse-as-library app/GoToRules.swift tests/goto_rules.swift -o app/build/goto-test && app/build/goto-test
// Go to: dates in English and Ukrainian (Kyiv time, Monday first), and the ranked list. Made-up names only.
@main
struct GoToTest {
    static var failed = 0
    static func check(_ ok: Bool, _ what: String) { if !ok { failed += 1; print("FAIL " + what) } }
    static func main() {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "Europe/Kyiv")!; cal.firstWeekday = 2
        func at(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 0) -> Double { cal.date(from: DateComponents(year: y, month: m, day: d, hour: h))!.timeIntervalSince1970 }
        let now = at(2026, 11, 14, 12)   // Saturday
        func day(_ q: String) -> Double? { GoTo.date(q, now: now, cal: cal)?.from }
        check(day("today") == at(2026, 11, 14) && day("сьогодні") == at(2026, 11, 14), "today")
        check(day("yesterday") == at(2026, 11, 13) && day("вчора") == at(2026, 11, 13) && day("учора") == at(2026, 11, 13), "yesterday")
        check(day("Tuesday") == at(2026, 11, 10) && day("tue") == at(2026, 11, 10) && day("у вівторок") == at(2026, 11, 10), "this Tuesday")
        check(day("last Tuesday") == at(2026, 11, 3) && day("минулого вівторка") == at(2026, 11, 3) && day("минулий вівторок") == at(2026, 11, 3), "last Tuesday")
        check(day("saturday") == at(2026, 11, 14) && day("п'ятниця") == at(2026, 11, 13) && day("пʼятницю") == at(2026, 11, 13), "today's weekday, apostrophes")
        check(day("3 Oct") == at(2026, 10, 3) && day("Oct 3") == at(2026, 10, 3) && day("3 жовтня") == at(2026, 10, 3), "a day of a month")
        check(day("20 December") == at(2025, 12, 20) && day("20 грудня") == at(2025, 12, 20), "a later day: last year")
        check(day("3 Oct 2025") == at(2025, 10, 3) && day("3.10") == at(2026, 10, 3) && day("03.10.2025") == at(2025, 10, 3) && day("3.10.25") == at(2025, 10, 3), "numbers")
        let oct = GoTo.date("October", now: now, cal: cal)
        check(oct?.from == at(2026, 10, 1) && oct?.to == at(2026, 11, 1) && oct?.title == "October 2026", "a month")
        check(day("жовтень") == at(2026, 10, 1) && day("листопада") == at(2026, 11, 1) && day("December") == at(2025, 12, 1), "months in Ukrainian, a later month last year")
        check(day("last week") == at(2026, 11, 2) && day("минулого тижня") == at(2026, 11, 2) && day("this week") == at(2026, 11, 9), "weeks")
        check(day("last month") == at(2026, 10, 1) && day("минулого місяця") == at(2026, 10, 1), "last month")
        check(day("3 days ago") == at(2026, 11, 11) && day("3 дні тому") == at(2026, 11, 11), "days ago")
        check(GoTo.date("2025", now: now, cal: cal)?.to == at(2026, 1, 1), "a year")
        check(day("31 Feb") == nil && day("Lantern") == nil && day("mark") == nil && day("") == nil && day("ma") == nil, "not dates")
        check(day("may") == at(2026, 5, 1), "may is a month")
        // the list
        let all = [GoTo.Candidate(kind: "entry", title: "Pinned", id: "pinned"), GoTo.Candidate(kind: "tag", title: "Mila Synthetic", id: "t1"),
                   GoTo.Candidate(kind: "tag", title: "Lantern", id: "t2"), GoTo.Candidate(kind: "app", title: "Mail", id: "a1"),
                   GoTo.Candidate(kind: "tag", title: "Example Studio", id: "t3")]
        check(GoTo.rank("mi", all).map(\.id) == ["t1"], "prefix")
        check(GoTo.rank("ma", all).map(\.id) == ["a1"], "prefix, no inner match")
        check(GoTo.rank("stu", all).map(\.id) == ["t3"], "word prefix")
        check(GoTo.rank("ter", all).map(\.id) == ["t2"], "contains")
        check(GoTo.rank("", all).count == 5 && GoTo.rank("zz", all).isEmpty, "empty and none")
        print(failed == 0 ? "go to rules: all passed" : "go to rules: \(failed) failed")
        exit(failed == 0 ? 0 : 1)
    }
}

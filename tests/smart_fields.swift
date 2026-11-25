import Foundation

// swiftc -parse-as-library app/SmartFields.swift tests/smart_fields.swift -o app/build/smart-fields-test && app/build/smart-fields-test
// Made-up names and links only.
@main
struct SmartFieldChecks {
    static func check(_ ok: Bool, _ what: String) { if !ok { print("FAIL: " + what); exit(1) } }

    static func main() {
        let raw = "Hi {First Name}, the deck for {company}: {last link to them}. Free: {my free slots}. Next: {date next week}. {name}"
        check(SmartFields.wanted(raw) == ["first name", "company", "last link to them", "my free slots", "date next week", "name"], "wanted: \(SmartFields.wanted(raw))")
        check(SmartFields.wanted("Hi {name=Олег}, {day:Mon|Tue} {cursor} {date}") == [], "his own fields are not smart")
        check(SmartFields.wanted("{name} and {name}") == ["name"], "once each")
        check(SmartFields.needsChat(["company"]) && !SmartFields.needsChat(["date next week"]), "needs chat")
        check(SmartFields.needsCalendar(["my free slots"]) && !SmartFields.needsCalendar(["name"]), "needs calendar")

        let v = ["first name": "Мирося", "company": "Sample {Labs}|x", "last link to them": "", "name": "  "]
        let out = SmartFields.apply("Hi {first name}, {Company} - {last link to them} {name}", values: v)
        check(out == "Hi Мирося, Sample (Labs)/x - {last link to them} {name}", "apply: \(out)")
        check(SmartFields.apply("no fields", values: v) == "no fields", "plain")

        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "Europe/Kyiv")!
        func day(_ y: Int, _ m: Int, _ d: Int) -> Date { cal.date(from: DateComponents(year: y, month: m, day: d, hour: 12))! }
        check(SmartFields.dateNextWeek(now: day(2026, 11, 17), calendar: cal) == "23.11.2026", "Tuesday -> next Monday")
        check(SmartFields.dateNextWeek(now: day(2026, 11, 16), calendar: cal) == "23.11.2026", "Monday -> a week on")
        check(SmartFields.dateNextWeek(now: day(2026, 11, 22), calendar: cal) == "23.11.2026", "Sunday -> tomorrow")
        check(SmartFields.dateNextWeek(now: day(2026, 12, 30), calendar: cal) == "04.01.2027", "year end")

        check(SmartFields.slotsText(["Tue 10:00", "", "Wed 11:00", "Thu 12:00", "Fri 9:00"]) == "Tue 10:00, Wed 11:00, Thu 12:00", "slots")
        let h = SmartFields.head(key: ";deck", wanted: ["first name", "company"], values: ["first name": "Мирося"])
        check(h == ";deck · 1 filled, 1 to fill (company) · Tab", "head: \(h)")
        print("smart fields: all checks pass")
    }
}

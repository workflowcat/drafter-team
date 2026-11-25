import Foundation

// swiftc -parse-as-library app/AvailabilityRules.swift tests/availability_rules.swift -o app/build/availability-test && app/build/availability-test
// Made-up messages and events only.
@main
struct AvailabilityChecks {
    static func check(_ ok: Bool, _ what: String) { if !ok { print("FAIL: " + what); exit(1) } }

    static func main() {
        typealias A = AvailabilityRules
        let kyiv = TimeZone(identifier: "Europe/Kyiv")!
        var cal = Calendar(identifier: .gregorian); cal.timeZone = kyiv; cal.firstWeekday = 2
        func at(_ d: Int, _ h: Int, _ m: Int = 0) -> Date { cal.date(from: DateComponents(year: 2026, month: 11, day: d, hour: h, minute: m))! }
        let now = at(17, 8, 30)   // Tuesday 17 November 2026, 08:30

        // asks
        for s in ["When are you free next week?", "Can we meet on Thursday?", "Коли тобі зручно созвонитись?", "коли зможеш?",
                  "Would Friday at 3pm work for you?", "Чи підійде четвер о 15:00?", "Є час на дзвінок?", "can we jump on a call tomorrow",
                  "Ти вільний завтра?"] {
            check(A.asks(s), "asks: \(s)")
        }
        for s in ["Thanks, got it", "Дякую, все отримав", "I was free yesterday", "The meeting went well", "Free shipping today"] {
            check(!A.asks(s), "not a question of time: \(s)")
        }
        // typed start
        for s in ["I'm free ", "можу в ", "How about ", "вільний у "] { check(A.typedStart(s), "typed start: \(s)") }
        for s in ["I'm free to say no", "можу допомогти", "hello"] { check(!A.typedStart(s), "not a start: \(s)") }

        // their last message
        check(A.lastTheirs("Я: привіт\nВони: коли зручно?\nзавтра чи в четвер") == "коли зручно? завтра чи в четвер", "theirs with a continuation")
        check(A.lastTheirs("Вони: коли зручно?\nЯ: зараз гляну") == nil, "his turn last")
        check(A.lastTheirs("Олег Петренко: can we meet Thursday?") == "can we meet Thursday?", "a named line")
        check(A.lastTheirs("Я: write a plan\nАсистент: Here it is") == nil, "an assistant")
        check(A.lastTheirs("") == nil, "empty")
        // language, zones
        check(A.lang("Коли зручно?") == "uk" && A.lang("When works?") == "en", "lang")
        check(A.zone("let's do 10:00 CET")?.identifier == "Europe/Berlin", "CET")
        check(A.zone("3pm London time works")?.identifier == "Europe/London", "London")
        check(A.zone("о 15 за Києвом") == kyiv, "за Києвом")
        check(A.zone("I'm in UTC+5:30 these days")?.secondsFromGMT() == 19800, "UTC+5:30")
        check(A.zone("this is the best test") == nil, "no zone inside words")
        check(A.zone("no zone here") == nil, "no zone")

        // proposed slots
        check(A.proposed("Would Thursday at 15:00 work?", now: now, calendar: cal) == at(19, 15), "Thursday 15:00")
        check(A.proposed("Чи підійде четвер о 15?", now: now, calendar: cal) == at(19, 15), "четвер о 15")
        check(A.proposed("tomorrow 3pm?", now: now, calendar: cal) == at(18, 15), "tomorrow 3pm")
        check(A.proposed("завтра о 10:30?", now: now, calendar: cal) == at(18, 10, 30), "завтра о 10:30")
        check(A.proposed("Tuesday at 11?", now: now, calendar: cal) == at(24, 11), "the same weekday is next week")
        check(A.proposed("when are you free?", now: now, calendar: cal) == nil, "no slot without a day and time")
        let berlin = TimeZone(identifier: "Europe/Berlin")!
        check(A.proposed("Thursday 10:00 CET?", now: now, calendar: cal, zone: berlin) == at(19, 11), "their zone: 10 CET = 11 Kyiv")

        // free slots
        let busy = [A.Busy(start: at(17, 9), end: at(17, 12)),                                 // a morning meeting
                    A.Busy(start: at(17, 14), end: at(17, 15), away: true),                    // at a place: 30 min each side
                    A.Busy(start: at(18, 0), end: at(19, 0), allDay: true),                    // Wednesday off
                    A.Busy(start: at(19, 9), end: at(19, 10))]
        let s = A.slots(busy: busy, now: now, calendar: cal)
        check(s.count == 3, "three slots: \(s)")
        check(s[0] == at(17, 12), "first: Tue 12:00 right after the meeting (\(s[0]))")
        check(!s.contains { $0 >= at(17, 13, 15) && $0 < at(17, 15, 30) }, "travel buffer kept")
        check(!s.contains { cal.isDate($0, inSameDayAs: at(18, 12)) }, "all-day block skipped")
        check(s.filter { cal.isDate($0, inSameDayAs: at(17, 12)) }.count <= 2, "at most two a day")
        check(s.contains { cal.isDate($0, inSameDayAs: at(19, 10)) }, "Thursday offered")
        check(!A.isFree(at(21, 10), minutes: 30, busy: [], now: now, calendar: cal), "Saturday is not free")
        check(!A.isFree(at(17, 9, 15), minutes: 30, busy: [], now: now, calendar: cal), "within the lead time")
        check(!A.isFree(at(17, 17, 45), minutes: 30, busy: [], now: now, calendar: cal), "past working hours")

        // a proposed slot: works, or the nearest
        check(A.isFree(at(19, 15), minutes: 30, busy: busy, now: now, calendar: cal), "Thu 15:00 is free")
        check(!A.isFree(at(19, 9, 30), minutes: 30, busy: busy, now: now, calendar: cal), "Thu 09:30 is taken")
        check(A.nearest(to: at(19, 9, 30), busy: busy, now: now, calendar: cal) == at(19, 10), "nearest: Thu 10:00")
        check(A.nearest(to: at(18, 11), busy: busy, now: now, calendar: cal).map { !cal.isDate($0, inSameDayAs: at(18, 11)) } == true, "a blocked day: another day")

        // lines: plain words, ranges, the zone only when theirs differs
        let en = A.offerLine([at(17, 12), at(19, 10)], now: now, lang: "en", mine: kyiv, theirs: nil)
        check(en == "I'm free today 12:00-12:30 or Thursday 10:00-10:30.", "en line: \(en)")
        let uk = A.offerLine([at(18, 9), at(19, 14), at(20, 11)], now: now, lang: "uk", mine: kyiv, theirs: nil)
        check(uk == "Можу завтра 9:00-9:30, у четвер 14:00-14:30 або у пʼятницю 11:00-11:30.", "uk line: \(uk)")
        let ru = A.offerLine([at(18, 9)], now: now, lang: "ru", mine: kyiv, theirs: nil)
        check(ru == "Могу завтра 9:00-9:30.", "ru line: \(ru)")
        let far = A.offerLine([at(24, 10)], now: now, lang: "uk", mine: kyiv, theirs: nil, start: false)
        check(far == "вт 24.11 10:00-10:30.", "a week on: short day and date: \(far)")
        let listed = A.offerLine([at(18, 9), at(19, 14)], now: now, lang: "en", mine: kyiv, theirs: nil, list: true)
        check(listed == "I'm free:\n– Tomorrow 9:00-9:30\n– Thursday 14:00-14:30", "list: \(listed)")
        check(!en.contains("Kyiv") && !en.contains("2026"), "no zone or year when the zones match")
        let both = A.offerLine([at(19, 11)], now: now, lang: "en", mine: kyiv, theirs: berlin)
        check(both == "I'm free Thursday 10:00-10:30 (CET; 11:00 my time).", "both zones: \(both)")
        check(A.offerLine([], now: now, lang: "en", mine: kyiv, theirs: nil) == "", "no slots, no line")
        let works = A.checkLine(at(19, 15), free: true, instead: nil, now: now, lang: "uk", mine: kyiv, theirs: nil)
        check(works == "Так, у четвер 15:00-15:30 підходить.", "works: \(works)")
        let other = A.checkLine(at(19, 9, 30), free: false, instead: at(19, 10), now: now, lang: "en", mine: kyiv, theirs: nil)
        check(other == "Thursday 9:30-10:00 doesn't work for me, how about 10:00-10:30?", "instead same day: \(other)")

        // language: letters decide, then the keyboard
        check(A.lang("Коли тобі зручно?") == "uk", "uk letters")
        check(A.lang("Когда тебе удобно, завтра или в четверг?") == "ru", "ru letters")
        check(A.lang("Ну давай", keyboard: "ru") == "ru" && A.lang("Ну давай") == "uk", "no tell-tale letters or words: the keyboard")
        check(A.lang("When works?") == "en" && A.lang("", keyboard: "uk") == "uk", "en, empty")

        // add-to-calendar link
        let link = A.calendarLink(at(18, 9), title: "Дзвінок: Олег")
        check(link == "https://calendar.google.com/calendar/render?action=TEMPLATE&text=%D0%94%D0%B7%D0%B2%D1%96%D0%BD%D0%BE%D0%BA%3A%20%D0%9E%D0%BB%D0%B5%D0%B3&dates=20261118T070000Z/20261118T073000Z", "link: \(link)")
        let withLinks = A.offerLine([at(18, 9)], now: now, lang: "en", mine: kyiv, theirs: nil, links: [link])
        check(withLinks == "I'm free:\n– Tomorrow 9:00-9:30 " + link, "slots with links: \(withLinks)")
        check(A.eventTitle(theirName: "Олег", myName: "", lang: "uk") == "Дзвінок: Олег" && A.eventTitle(theirName: "", myName: "", lang: "en") == "Call", "title")
        check(A.theirName("Олег Петренко: коли?\nЯ: зараз") == "Олег" && A.theirName("Вони: коли?") == "", "their name from the screen")

        // the picker's ranges and parts of the day
        check(A.span(.tomorrow, now: now, calendar: cal) == (at(18, 0), 1), "tomorrow")
        check(A.span(.week, now: now, calendar: cal) == (at(17, 0), 6), "this week: to Sunday")
        check(A.span(.nextWeek, now: now, calendar: cal) == (at(23, 0), 7), "next week: from Monday")
        let (nw, nd) = A.span(.nextWeek, now: now, calendar: cal)
        let mornings = A.slots(busy: [], now: now, days: nd, count: 2, calendar: cal, hours: A.hours(.morning), from: nw)
        check(mornings == [at(23, 9), at(23, 10, 30)], "next week mornings: \(mornings)")
        check(A.slots(busy: [], now: now, days: 1, count: 3, calendar: cal, hours: A.hours(.afternoon), from: at(18, 0)).first == at(18, 13), "afternoon")

        // the picker's refine rows
        check(A.refine(";free 30 tomorrow", days: .nextWeek) == ";free 30 next week", "days: \(A.refine(";free 30 tomorrow", days: .nextWeek))")
        check(A.refine(";free 30 tomorrow", minutes: 60) == ";free 60 tomorrow", "length")
        check(A.refine(";free tomorrow", minutes: 15) == ";free 15 tomorrow", "length added")
        check(A.refine(";free 30 завтра вранці", part: .afternoon) == ";free 30 завтра afternoon", "part")
        check(A.refine(";free 30 tomorrow morning", part: .any) == ";free 30 tomorrow", "any part")

        // at Tab: a slot that filled in between goes
        let later = busy + [A.Busy(start: at(19, 10), end: at(19, 11))]
        check(A.stillFree(s, busy: later, now: now, calendar: cal) == s.filter { $0 != at(19, 10) }, "a filled slot is dropped")
        check(A.stillFree(s, busy: busy, now: now, calendar: cal) == s, "unchanged calendar keeps them all")
        print("availability: all checks pass")
    }
}

// Availability as a reply (17 November 2026; the user: "suggest my availability to somebody and do like a quick check").
// Their last message asks for a time: 2-3 free slots in the user's words and their language, in their time zone when the chat
// names one. They proposed a slot: "works", or the nearest free one instead. The slots are checked again when the user takes
// the line (Tab), since the calendar can change in between. Text only, into the field: never an invite.
// Busy times come from the user's calendars through Actions.busy (EventKit, the calendars Settings leaves on: `calendarsOff`).
// Pure Foundation:
// swiftc -parse-as-library app/AvailabilityRules.swift tests/availability_rules.swift -o app/build/availability-test && app/build/availability-test
import Foundation

enum AvailabilityRules {
    /// A busy stretch from the user's calendar. `allDay`: blocks the whole day (an opaque all-day event: a trip, a day off);
    /// `away`: an event at a place (not a call link), so travel time is kept around it.
    struct Busy: Equatable { var start: Date; var end: Date; var allDay = false; var away = false }

    /// The picker's choices (17 November 2026): which days, how long, which part of the day, how many.
    enum Days: String { case today, tomorrow, week, nextWeek }
    enum Part: String { case any, morning, afternoon }
    /// (first day, days) for a range, from `now`.
    static func span(_ r: Days, now: Date, calendar: Calendar) -> (Date, Int) {
        let today = calendar.startOfDay(for: now)
        var cal = calendar; cal.firstWeekday = 2
        let wd = cal.component(.weekday, from: today), toMonday = (9 - wd) % 7 == 0 ? 7 : (9 - wd) % 7
        switch r {
        case .today: return (today, 1)
        case .tomorrow: return (cal.date(byAdding: .day, value: 1, to: today)!, 1)
        case .week: return (today, max(1, toMonday))
        case .nextWeek: return (cal.date(byAdding: .day, value: toMonday, to: today)!, 7)
        }
    }
    static func hours(_ p: Part) -> Hours {
        var h = Hours()
        switch p { case .any: break; case .morning: h.end = 13 * 60; case .afternoon: h.start = 13 * 60 }
        return h
    }

    struct Hours: Equatable {
        var start = 9 * 60, end = 18 * 60     // minutes of the day, the user's time
        var buffer = 30                        // minutes kept before and after an event at a place
        var lead = 60                          // nothing sooner than this from now
        var gap = 60                           // minutes between two offered slots
    }

    // ---- reading their message --------------------------------------------------------------------------------------

    private static func rx(_ p: String) -> NSRegularExpression { try! NSRegularExpression(pattern: p, options: [.caseInsensitive]) }
    private static func has(_ r: NSRegularExpression, _ s: String) -> Bool { r.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil }

    static let askRX = rx(#"(when (are|would|will) you( be)? (free|available|around)|what time (works|suits|is good)|(does|would) .{1,40}\b(work|suit)( for you)?\?|can we (meet|talk|call|catch up|have a call|jump on)|are you (free|available)|your availability|find (a )?time|когда (удобно|сможешь|свободен)|коли (тобі |вам )?(зручно|зможеш|зможете|маєш час|є час|вільн)|ти (вільний|вільна)|ви (вільні)|можемо (зустрітись|зустрітися|созвонитись|поговорити|зідзвонитись|зідзвонитися)|зідзвонимось|созвонимся|є (час|хвилинка|пару хвилин)|підійде\b.{0,40}\?|зручно\b.{0,40}\?)"#)
    static let typedRX = rx(#"^\s*(i('| a)m (free|available|around)|i can (do|make it|meet)|how about|free (on|at)|можу (в|у|о|об|зустрітись|зустрітися|зідзвонитись)|вільний (в|у|о)|вільна (в|у|о)|давай (в|у|о)|як щодо)\s*$"#)

    /// Their last message on screen (the app marks "Я: " / "Вони: " / "Асистент: ", or "Name: " lines), or nil when the
    /// last turn is the user's, an assistant's, or there is none. A line without a mark continues the turn above it.
    static func lastTheirs(_ context: String) -> String? {
        let lines = context.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let mark = rx(#"^(Я|Вони|Асистент|[A-ZА-ЯІЇЄҐ][\w'’.-]{1,20}(?: [A-ZА-ЯІЇЄҐ][\w'’.-]{1,20})?): "#)
        var who: String?, text: [String] = []
        for l in lines {
            if let m = mark.firstMatch(in: l, range: NSRange(l.startIndex..., in: l)), let r = Range(m.range(at: 1), in: l), let all = Range(m.range, in: l) {
                who = String(l[r]); text = [String(l[all.upperBound...])]
            } else { text.append(l) }
        }
        guard let w = who, w != "Я", w != "Асистент", w != "Me", w != "You" else { return who == nil && !text.isEmpty ? text.last : nil }
        let t = text.joined(separator: " ").trimmingCharacters(in: .whitespaces)
        return t.isEmpty ? nil : t
    }

    /// Their name from the screen's marks ("Олег Петренко: ..."): the first word of the last named line not the user's; "".
    static func theirName(_ context: String) -> String {
        let mark = rx(#"^([A-ZА-ЯІЇЄҐ][\w'’.-]{1,20})(?: [A-ZА-ЯІЇЄҐ][\w'’.-]{1,20})?: "#)
        for l in context.split(separator: "\n").reversed() {
            let t = l.trimmingCharacters(in: .whitespaces)
            if let m = mark.firstMatch(in: t, range: NSRange(t.startIndex..., in: t)), let r = Range(m.range(at: 1), in: t),
               !["Я", "Вони", "Асистент", "Me", "You"].contains(String(t[r])) { return String(t[r]) }
        }
        return ""
    }

    /// Their message asks the user for a time (or offers one with a question).
    static func asks(_ text: String) -> Bool { has(askRX, text) }

    /// The user started an availability line themselves ("I'm free", "можу в"): the slots finish it.
    static func typedStart(_ lineBefore: String) -> Bool { has(typedRX, lineBefore) }

    /// A time zone the chat names ("10:00 CET", "London time", "UTC+2", "за Києвом", "PT"), else nil.
    static func zone(_ text: String) -> TimeZone? {
        let t = " " + text.lowercased() + " "
        let named: [(String, String)] = [
            ("kyiv", "Europe/Kyiv"), ("kiev", "Europe/Kyiv"), ("києв", "Europe/Kyiv"), ("київ", "Europe/Kyiv"), ("eet", "Europe/Kyiv"),
            ("london", "Europe/London"), ("лондон", "Europe/London"), ("uk time", "Europe/London"), ("gmt", "Europe/London"), ("bst", "Europe/London"),
            ("cet", "Europe/Berlin"), ("cest", "Europe/Berlin"), ("berlin", "Europe/Berlin"), ("warsaw", "Europe/Warsaw"), ("варшав", "Europe/Warsaw"),
            ("lisbon", "Europe/Lisbon"), ("лісабон", "Europe/Lisbon"),
            ("new york", "America/New_York"), ("est", "America/New_York"), ("edt", "America/New_York"), ("et", "America/New_York"),
            ("pst", "America/Los_Angeles"), ("pdt", "America/Los_Angeles"), ("pt", "America/Los_Angeles"), ("pacific", "America/Los_Angeles"),
            ("cst", "America/Chicago"), ("dubai", "Asia/Dubai"), ("gst", "Asia/Dubai"), ("singapore", "Asia/Singapore"),
        ]
        for (k, id) in named {
            // a zone word on its own (" est ", "(cet)", "est,"), a city as part of a word ("києвом", "london time")
            let city = k.count > 4 || !k.allSatisfy(\.isASCII)   // Cyrillic stems ("києв") match inside words
            let p = city ? NSRegularExpression.escapedPattern(for: k) : #"(?<![\p{L}])"# + NSRegularExpression.escapedPattern(for: k) + #"(?![\p{L}])"#
            if has(rx(p), t) { return TimeZone(identifier: id) }
        }
        if let m = rx(#"(?:utc|gmt)\s*([+-−])\s*(\d{1,2})(?::?(\d{2}))?"#).firstMatch(in: t, range: NSRange(t.startIndex..., in: t)),
           let s = Range(m.range(at: 1), in: t), let h = Range(m.range(at: 2), in: t), let hours = Int(t[h]) {
            let mins = Range(m.range(at: 3), in: t).flatMap { Int(t[$0]) } ?? 0
            let sign = t[s] == "+" ? 1 : -1
            return TimeZone(secondsFromGMT: sign * (hours * 3600 + mins * 60))
        }
        return nil
    }

    /// A slot they proposed: a day word (today, tomorrow, a weekday; both languages) and a time ("15:00", "3pm",
    /// "о 15", "at 11"), read in `zone` (theirs when named, else the user's). nil when either is missing.
    static func proposed(_ text: String, now: Date, calendar: Calendar, zone: TimeZone? = nil) -> Date? {
        var cal = calendar; if let zone { cal.timeZone = zone }
        let t = text.lowercased()
        // the day
        var day: Date?
        let today = cal.startOfDay(for: now)
        if has(rx(#"\b(tomorrow|завтра)\b"#), t) { day = cal.date(byAdding: .day, value: 1, to: today) }
        else if has(rx(#"\b(today|сьогодні|сегодня)\b"#), t) { day = today }
        else {
            let days: [(String, Int)] = [("monday|понеділ|понедел", 2), ("tuesday|вівтор|вторник", 3), ("wednesday|серед|сред", 4),
                                         ("thursday|четвер|четверг", 5), ("friday|п'ятниц|пятниц|п’ятниц", 6), ("saturday|субот", 7), ("sunday|неділ|воскрес", 1),
                                         (#"\bmon\b"#, 2), (#"\btue\b"#, 3), (#"\bwed\b"#, 4), (#"\bthu\b"#, 5), (#"\bfri\b"#, 6)]
            for (p, wd) in days where has(rx(p), t) {
                let cur = cal.component(.weekday, from: today)
                var ahead = (wd - cur + 7) % 7; if ahead == 0 { ahead = 7 }
                day = cal.date(byAdding: .day, value: ahead, to: today); break
            }
        }
        guard let day else { return nil }
        // the time
        var hour: Int?, minute = 0
        if let m = rx(#"\b([01]?\d|2[0-3])[:.]([0-5]\d)\b"#).firstMatch(in: t, range: NSRange(t.startIndex..., in: t)),
           let h = Range(m.range(at: 1), in: t), let mm = Range(m.range(at: 2), in: t) {
            hour = Int(t[h]); minute = Int(t[mm]) ?? 0
        } else if let m = rx(#"\b(1[0-2]|0?[1-9])\s*(am|pm)\b"#).firstMatch(in: t, range: NSRange(t.startIndex..., in: t)),
                  let h = Range(m.range(at: 1), in: t), let ap = Range(m.range(at: 2), in: t), let v = Int(t[h]) {
            hour = (v % 12) + (t[ap] == "pm" ? 12 : 0)
        } else if let m = rx(#"(?:\bat|\bо|\bоб|\bв|\bна)\s+(1\d|2[0-3]|[7-9])\b(?![:.\d])"#).firstMatch(in: t, range: NSRange(t.startIndex..., in: t)),
                  let h = Range(m.range(at: 1), in: t) {
            hour = Int(t[h])
        }
        guard let hour else { return nil }
        return cal.date(bySettingHour: hour, minute: minute, second: 0, of: day)
    }

    // ---- the user's calendar ---------------------------------------------------------------------------------------------

    /// The stretch a busy item keeps the user away: an all-day block the whole day, an event at a place with travel time.
    static func blocked(_ b: Busy, calendar: Calendar, hours: Hours) -> (Date, Date) {
        if b.allDay {
            let d0 = calendar.startOfDay(for: b.start)
            let d1 = calendar.startOfDay(for: b.end) > d0 ? calendar.startOfDay(for: b.end) : calendar.date(byAdding: .day, value: 1, to: d0)!
            return (d0, max(d1, b.end))
        }
        let pad = b.away ? Double(hours.buffer) * 60 : 0
        return (b.start.addingTimeInterval(-pad), b.end.addingTimeInterval(pad))
    }

    /// The slot [start, start+minutes) is in working hours on a weekday, later than now + lead, and clear of every block.
    static func isFree(_ start: Date, minutes: Int, busy: [Busy], now: Date, calendar: Calendar, hours: Hours = Hours()) -> Bool {
        let end = start.addingTimeInterval(Double(minutes) * 60)
        guard start >= now.addingTimeInterval(Double(hours.lead) * 60), !calendar.isDateInWeekend(start) else { return false }
        let day = calendar.startOfDay(for: start)
        let open = day.addingTimeInterval(Double(hours.start) * 60), close = day.addingTimeInterval(Double(hours.end) * 60)
        guard start >= open, end <= close else { return false }
        return !busy.contains { b in let (a, z) = blocked(b, calendar: calendar, hours: hours); return a < end && z > start }
    }

    /// Up to `count` free slots of `minutes` from now on, on quarter hours, at least `hours.gap` apart and at most two a
    /// day, so the choice spreads over days.
    static func slots(busy: [Busy], now: Date, days: Int = 7, minutes: Int = 30, count: Int = 3, calendar: Calendar, hours: Hours = Hours(), from: Date? = nil) -> [Date] {
        var out: [Date] = []
        var day = calendar.startOfDay(for: max(from ?? now, now))
        for _ in 0..<days {
            var t = day.addingTimeInterval(Double(hours.start) * 60), perDay = 0
            let close = day.addingTimeInterval(Double(hours.end) * 60)
            while t.addingTimeInterval(Double(minutes) * 60) <= close, out.count < count, perDay < 2 {
                if isFree(t, minutes: minutes, busy: busy, now: now, calendar: calendar, hours: hours) {
                    out.append(t); perDay += 1; t = t.addingTimeInterval(Double(minutes + hours.gap) * 60)
                } else { t = t.addingTimeInterval(15 * 60) }
            }
            if out.count >= count { break }
            day = calendar.date(byAdding: .day, value: 1, to: day)!
        }
        return out
    }

    /// The free slot nearest to a taken one: the same day first (later, then earlier), else the next days.
    static func nearest(to t: Date, minutes: Int = 30, busy: [Busy], now: Date, calendar: Calendar, hours: Hours = Hours()) -> Date? {
        for step in 1...32 {
            for sign in [1.0, -1.0] {
                let c = t.addingTimeInterval(sign * Double(step) * 15 * 60)
                if calendar.isDate(c, inSameDayAs: t), isFree(c, minutes: minutes, busy: busy, now: now, calendar: calendar, hours: hours) { return c }
            }
        }
        return slots(busy: busy, now: max(now, calendar.startOfDay(for: t)), days: 7, minutes: minutes, count: 1, calendar: calendar, hours: hours).first
    }

    // ---- the line -------------------------------------------------------------------------------------------------
    // Plain words (the user, 17 November 2026: "simpler terms"): "Tomorrow 9:00-9:30", "У четвер 14:00-14:30",
    // "Пн 24.11 10:00-10:30"; the zone only when theirs differs from the user's.

    private static let dayNames: [String: [String]] = [   // Sunday first, as Calendar's weekday 1...7
        "en": ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"],
        "uk": ["у неділю", "у понеділок", "у вівторок", "у середу", "у четвер", "у пʼятницю", "у суботу"],
        "ru": ["в воскресенье", "в понедельник", "во вторник", "в среду", "в четверг", "в пятницу", "в субботу"]]
    private static let shortDays: [String: [String]] = [
        "en": ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"], "uk": ["нд", "пн", "вт", "ср", "чт", "пт", "сб"], "ru": ["вс", "пн", "вт", "ср", "чт", "пт", "сб"]]
    private static let words: [String: [String: String]] = [
        "en": ["today": "today", "tomorrow": "tomorrow", "free": "I'm free", "or": " or ", "works": "%@ works for me.",
               "busy": "%@ doesn't work for me, how about %@?", "none": "%@ doesn't work for me, I'll suggest another time.", "mine": "my time", "add": "add to calendar"],
        "uk": ["today": "сьогодні", "tomorrow": "завтра", "free": "Можу", "or": " або ", "works": "Так, %@ підходить.",
               "busy": "%@ не вийде, можу %@?", "none": "%@ не вийде, підберу інший час.", "mine": "у мене", "add": "додати в календар"],
        "ru": ["today": "сегодня", "tomorrow": "завтра", "free": "Могу", "or": " или ", "works": "Да, %@ подходит.",
               "busy": "%@ не получится, могу %@?", "none": "%@ не получится, предложу другое время.", "mine": "у меня", "add": "добавить в календарь"]]
    static func w(_ lang: String, _ k: String) -> String { words[lang]?[k] ?? words["en"]![k]! }

    /// "uk", "ru" or "en": Ukrainian letters (і ї є ґ) or Russian ones (ы э ъ ё) decide Cyrillic; none of them: the
    /// keyboard layout when it says, else Ukrainian. More Latin than Cyrillic letters: English.
    static func lang(_ text: String, keyboard: String = "") -> String {
        var c = 0, l = 0, uk = 0, ru = 0
        for u in text.lowercased().unicodeScalars {
            if (0x0400...0x04FF).contains(u.value) {
                c += 1
                if "іїєґ".unicodeScalars.contains(u) { uk += 1 }
                if "ыэъё".unicodeScalars.contains(u) { ru += 1 }
            } else if (0x41...0x5A).contains(u.value) || (0x61...0x7A).contains(u.value) { l += 1 }
        }
        let kb = String(keyboard.lowercased().prefix(2))
        if c == 0 && l == 0 { return ["uk", "ru", "en"].contains(kb) ? kb : "en" }
        if l >= c { return "en" }
        if uk != ru { return uk > ru ? "uk" : "ru" }
        // no tell-tale letters: common words only one of the two languages has
        if has(rx(#"(?<![\p{L}])(когда|или|что|это|сегодня|можно|удобно|свободен|созвон\p{L}*|встрет\p{L}*)(?![\p{L}])"#), text) { return "ru" }
        if has(rx(#"(?<![\p{L}])(коли|або|що|це|зручно|можна|вільн\p{L}*)(?![\p{L}])"#), text) { return "uk" }
        return kb == "ru" ? "ru" : "uk"
    }

    /// The day in plain words from `now`: today, tomorrow, a weekday name within 6 days, else "пн 24.11" / "Mon 24 Nov".
    static func dayWord(_ d: Date, now: Date, lang: String, zone: TimeZone) -> String {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = zone
        let days = cal.dateComponents([.day], from: cal.startOfDay(for: now), to: cal.startOfDay(for: d)).day ?? 99
        if days == 0 { return w(lang, "today") }
        if days == 1 { return w(lang, "tomorrow") }
        let wd = cal.component(.weekday, from: d) - 1
        if days > 1 && days < 7 { return dayNames[lang]?[wd] ?? dayNames["en"]![wd] }
        let f = DateFormatter(); f.timeZone = zone; f.locale = Locale(identifier: "en_GB"); f.dateFormat = lang == "en" ? "d MMM" : "dd.MM"
        return (shortDays[lang]?[wd] ?? shortDays["en"]![wd]) + " " + f.string(from: d)
    }

    static func hm(_ d: Date, _ z: TimeZone) -> String {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = z
        let c = cal.dateComponents([.hour, .minute], from: d)
        return "\(c.hour ?? 0):" + String(format: "%02d", c.minute ?? 0)
    }

    /// "tomorrow 9:00-9:30"; in their zone with the user's in brackets when the zones differ at that moment.
    static func when(_ d: Date, minutes: Int = 30, now: Date, lang: String, mine: TimeZone, theirs: TimeZone?, withDay: Bool = true) -> String {
        let z = theirs ?? mine, e = d.addingTimeInterval(Double(minutes) * 60)
        var s = (withDay ? dayWord(d, now: now, lang: lang, zone: z) + " " : "") + hm(d, z) + "-" + hm(e, z)
        if let theirs, theirs.secondsFromGMT(for: d) != mine.secondsFromGMT(for: d) {
            s += " (" + zoneName(theirs) + "; " + (lang == "en" ? hm(d, mine) + " " + w(lang, "mine") : w(lang, "mine") + " " + hm(d, mine)) + ")"
        }
        return s
    }
    static func zoneName(_ z: TimeZone) -> String {
        let common: [String: String] = ["Europe/Kyiv": "Kyiv", "Europe/London": "London", "Europe/Berlin": "CET", "Europe/Warsaw": "CET",
                                        "Europe/Lisbon": "Lisbon", "America/New_York": "ET", "America/Los_Angeles": "PT", "America/Chicago": "CT",
                                        "Asia/Dubai": "Dubai", "Asia/Singapore": "Singapore"]
        if let n = common[z.identifier] { return n }
        let sec = z.secondsFromGMT(), h = sec / 3600, m = abs(sec / 60 % 60)
        return "UTC" + (sec >= 0 ? "+" : "-") + "\(abs(h))" + (m > 0 ? String(format: ":%02d", m) : "")
    }
    static func capitalized(_ s: String) -> String { s.prefix(1).uppercased() + s.dropFirst() }

    /// The user's line offering the slots. One line: "Можу завтра 9:00-9:30, у четвер 14:00-14:30 або у пʼятницю 11:00-11:30."
    /// A list: one slot per line, "– Tomorrow 9:00-9:30". `links`: each slot followed by its add-to-calendar link.
    static func offerLine(_ slots: [Date], minutes: Int = 30, now: Date, lang: String, mine: TimeZone, theirs: TimeZone?, start: Bool = true,
                          list: Bool = false, links: [String] = []) -> String {
        guard !slots.isEmpty else { return "" }
        var parts = slots.map { when($0, minutes: minutes, now: now, lang: lang, mine: mine, theirs: theirs) }
        if !links.isEmpty { parts = zip(parts, links).map { $0 + " " + $1 } + parts.dropFirst(links.count) }
        if list || !links.isEmpty {
            let rows = parts.map { "– " + capitalized($0) }.joined(separator: "\n")
            return start ? w(lang, "free") + ":\n" + rows : rows
        }
        let or = w(lang, "or")
        let joined = parts.count == 1 ? parts[0] : parts.dropLast().joined(separator: ", ") + or + parts.last!
        return start ? w(lang, "free") + " " + joined + "." : joined + "."
    }

    /// The answer to a slot they proposed: it works, or the nearest free one instead.
    static func checkLine(_ proposed: Date, minutes: Int = 30, free: Bool, instead: Date?, now: Date, lang: String, mine: TimeZone, theirs: TimeZone?) -> String {
        let p = when(proposed, minutes: minutes, now: now, lang: lang, mine: mine, theirs: theirs)
        if free { return capitalized(String(format: w(lang, "works"), p)) }
        guard let instead else { return capitalized(String(format: w(lang, "none"), p)) }
        let sameDay = Calendar.current.isDate(instead, inSameDayAs: proposed)
        let i = when(instead, minutes: minutes, now: now, lang: lang, mine: mine, theirs: theirs, withDay: !sameDay)
        return capitalized(String(format: w(lang, "busy"), p, i))
    }

    /// A Google Calendar template link: the other person clicks it and gets the event filled in their own calendar.
    /// No API call, no invite from the user's account; nothing is sent.
    static func calendarLink(_ start: Date, minutes: Int = 30, title: String, details: String = "") -> String {
        let f = DateFormatter(); f.timeZone = TimeZone(identifier: "UTC"); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        var allowed = CharacterSet.alphanumerics; allowed.insert(charactersIn: "-._~")
        func enc(_ s: String) -> String { s.addingPercentEncoding(withAllowedCharacters: allowed) ?? "" }
        var u = "https://calendar.google.com/calendar/render?action=TEMPLATE&text=" + enc(title)
            + "&dates=" + f.string(from: start) + "/" + f.string(from: start.addingTimeInterval(Double(minutes) * 60))
        if !details.isEmpty { u += "&details=" + enc(details) }
        return u
    }

    /// The event's title from the chat: "Дзвінок: Олег / Марта", "Call: Olena / Marta"; without their name, the user's name alone.
    static func eventTitle(theirName: String, myName: String, lang: String) -> String {
        let call = lang == "uk" ? "Дзвінок" : lang == "ru" ? "Созвон" : "Call"
        let who = [theirName, myName].map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return who.isEmpty ? call : call + ": " + who.joined(separator: " / ")
    }

    /// At Tab: the slots still free, in order. When some went, the line is built again from these (and fresh ones).
    static func stillFree(_ slots: [Date], minutes: Int = 30, busy: [Busy], now: Date, calendar: Calendar, hours: Hours = Hours()) -> [Date] {
        var h = hours; h.lead = 0
        return slots.filter { isFree($0, minutes: minutes, busy: busy, now: now, calendar: calendar, hours: h) }
    }
}

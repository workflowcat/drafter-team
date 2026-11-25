// Smart snippet fields (17 November 2026; Text Blaze, Folk): {name}, {first name}, {company}, {last link to them},
// {date next week}, {my free slots}. They fill from the chat on screen (engine /fields: the names reference and his own
// lines there, engine/whom.py Who.fields) and from his calendar (Actions.freeSlots, the same as ;free). A field with no
// value stays as it was, so Snippets.fill makes it a place to fill (the word selected, typing replaces it). The filled
// snippet shows as a preview card first; Tab puts it in (Snippets.previewSmart). Pure Foundation:
// swiftc -parse-as-library app/SmartFields.swift tests/smart_fields.swift -o app/build/smart-fields-test && app/build/smart-fields-test
import Foundation

enum SmartFields {
    /// From the engine (the chat on screen).
    static let fromChat = ["name", "first name", "company", "last link to them"]
    /// Worked out on this Mac: the calendar, the date.
    static let fromMac = ["date next week", "my free slots"]
    static var all: [String] { fromChat + fromMac }
    private static let rx = try! NSRegularExpression(pattern: #"\{([\p{L}][\p{L} ]{1,24})\}"#)

    /// The smart fields a snippet holds, lower case, in order, once each. `{name=Олег}` or `{name:a|b}` are his own
    /// fields with a default or a choice, never smart.
    static func wanted(_ raw: String) -> [String] {
        var out: [String] = []
        for m in rx.matches(in: raw, range: NSRange(raw.startIndex..., in: raw)) {
            guard let r = Range(m.range(at: 1), in: raw) else { continue }
            let n = norm(String(raw[r]))
            if all.contains(n), !out.contains(n) { out.append(n) }
        }
        return out
    }
    static func norm(_ s: String) -> String { s.lowercased().split(separator: " ").joined(separator: " ") }

    /// Whether a lookup is needed: the engine for the chat's fields, the calendar for free slots.
    static func needsChat(_ w: [String]) -> Bool { w.contains { fromChat.contains($0) } }
    static func needsCalendar(_ w: [String]) -> Bool { w.contains("my free slots") }

    /// Each smart field with a value put in; one without stays `{field}` (Snippets.fill makes it a gap). Values lose
    /// braces and bars, so a value can never open a field of its own.
    static func apply(_ raw: String, values: [String: String]) -> String {
        var t = raw
        for m in rx.matches(in: raw, range: NSRange(raw.startIndex..., in: raw)).reversed() {
            guard let r = Range(m.range(at: 1), in: raw), let whole = Range(m.range, in: t) else { continue }
            let v = (values[norm(String(raw[r]))] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "{", with: "(").replacingOccurrences(of: "}", with: ")").replacingOccurrences(of: "|", with: "/")
            if !v.isEmpty { t.replaceSubrange(whole, with: v) }
        }
        return t
    }

    /// Monday of next week, as {date} writes dates (dd.MM.yyyy).
    static func dateNextWeek(now: Date, calendar: Calendar = .current) -> String {
        var cal = calendar; cal.firstWeekday = 2
        let wd = cal.component(.weekday, from: now)              // 1 Sunday ... 7 Saturday
        let ahead = wd == 1 ? 1 : 9 - wd                          // Sunday -> tomorrow; Monday -> 7 days on
        let d = cal.date(byAdding: .day, value: ahead, to: cal.startOfDay(for: now)) ?? now
        let f = DateFormatter(); f.calendar = cal; f.timeZone = cal.timeZone; f.dateFormat = "dd.MM.yyyy"
        return f.string(from: d)
    }

    /// The calendar's slot chips ("Tue 18 Nov 10:00") as one line.
    static func slotsText(_ chips: [String]) -> String { chips.filter { !$0.isEmpty }.prefix(3).joined(separator: ", ") }

    /// The card's head: what was filled and what is left to fill.
    static func head(key: String, wanted: [String], values: [String: String]) -> String {
        let gaps = wanted.filter { (values[$0] ?? "").trimmingCharacters(in: .whitespaces).isEmpty }
        let filled = wanted.count - gaps.count
        return "\(key) · \(filled) filled" + (gaps.isEmpty ? "" : ", \(gaps.count) to fill (\(gaps.joined(separator: ", ")))") + " · Tab"
    }
}

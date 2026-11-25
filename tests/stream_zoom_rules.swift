// swiftc -parse-as-library app/StreamZoomRules.swift tests/stream_zoom_rules.swift -o app/build/stream-zoom-rules-test && app/build/stream-zoom-rules-test
// Zoom round (24 November 2026): the stream's ladder and its cards of time. Made-up rows only.
import Foundation

@main struct StreamZoomRulesTest {
    static var failed = 0, ran = 0
    static func check(_ ok: Bool, _ what: String) { ran += 1; if !ok { failed += 1; print("FAIL:", what) } }
    static func main() {
        typealias Z = StreamZoomRules
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "UTC")!
        // ladder
        check(Z.step(.normal, by: -1) == .compact && Z.step(.weeks, by: -1) == .weeks && Z.step(.detailed, by: 3) == .detailed, "step holds at ends")
        check(Z.into(.weeks) == .days && Z.into(.days) == .sessions && Z.into(.sessions) == .normal, "into")
        check(Z.Level.days.summary && !Z.Level.compact.summary && Z.Level.detailed.density == 2, "summary and density")
        var p = Z.Pinch()
        check(p.add(0.1) == 0 && p.add(0.15) == 1 && p.add(-0.5) == -2, "pinch")
        // made-up rows: Tue 24 Nov 2026 10:00 UTC and back
        let t0 = 1_795_514_400.0   // 2026-11-24 10:00 UTC
        func it(_ id: String, _ dt: Double, _ kind: String, _ app: String, _ line: String, secs: Double = 0) -> Z.Item {
            Z.Item(id: id, at: t0 - dt, kind: kind, app: app, line: line, secs: secs)
        }
        let items = [
            it("a", 0, "typed", "Notes", "short one"),
            it("b", 10 * 60, "spoken", "Mail", "Please send the made up sample report to the team before noon. Thanks", secs: 30),
            it("c", 20 * 60, "picture", "Claude", "Code · import Foundation"),
            it("d", 3 * 3600, "call", "Zoom", "Weekly sample sync", secs: 1800),       // 07:00, another session
            it("e", 26 * 3600, "copied", "Dia", "https://example.com/page"),          // Monday
            it("f", 9 * 86400, "typed", "Notes", "an older made up line in the previous week"),
        ]
        let days = Z.cards(items, level: .days, cal: cal)
        check(days.count == 3 && days[0].ids == ["a", "b", "c", "d"], "days: \(days.map(\.ids))")
        let sessions = Z.cards(items, level: .sessions, cal: cal)
        check(sessions.count == 4 && sessions[0].ids == ["a", "b", "c"] && sessions[1].ids == ["d"], "sessions: \(sessions.map(\.ids))")
        check(Z.span(sessions[0], cal: cal) == "09:40–10:00", "span \(Z.span(sessions[0], cal: cal))")
        check(Z.span(sessions[1], cal: cal) == "07:00", "one time")
        let weeks = Z.cards(items, level: .weeks, cal: cal)
        check(weeks.count == 2 && weeks[0].ids.count == 5, "weeks: \(weeks.map(\.ids))")
        check(Z.weekTitle(weeks[0], now: t0, cal: cal) == "This week" && Z.weekTitle(weeks[1], now: t0 - 7 * 86400, cal: cal) == "Last week", "week titles")
        check(Z.weekTitle(weeks[1], now: t0 + 21 * 86400, cal: cal) == "9–15 Nov", "dated week: \(Z.weekTitle(weeks[1], now: t0 + 21 * 86400, cal: cal))")
        // Tue 24: a b c d, Mon 23: e  →  Mon 1, Tue 4
        check(weeks[0].perDay == [1, 4, 0, 0, 0, 0, 0] && weeks[1].perDay == [0, 0, 0, 0, 0, 0, 1], "per day: \(weeks.map(\.perDay))")
        check(days[0].perDay.isEmpty, "days: no per-day")
        check(Z.cards(items, level: .normal, cal: cal).isEmpty, "rows: no cards")
        // a card's words
        let d0 = days[0]
        check(d0.lines.first == "Weekly sample sync", "recording first: \(d0.lines)")
        check(d0.lines.contains("Please send the made up sample report to the team before noon."), "first sentence: \(d0.lines)")
        check(Z.countLine(d0) == "1 recording · 1 take · 1 typed · 1 picture", "count line: \(Z.countLine(d0))")
        check(d0.secs == 1830 && Z.duration(d0.secs) == "30 min" && Z.duration(3900) == "1 h 05 min" && Z.duration(20) == "", "duration")
        check(d0.apps.count == 4, "apps")
        check(Z.summary(String(repeating: "word ", count: 40)).count <= 91, "summary cut")
        check(Z.highlights([it("x", 0, "typed", "", "same line here"), it("y", 1, "typed", "", "Same line here")]).count == 1, "no repeats")
        print("ran \(ran); failed: \(failed == 0 ? "" : String(failed))")
        if failed > 0 { exit(1) }
    }
}

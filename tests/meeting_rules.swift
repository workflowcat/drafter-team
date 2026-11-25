// swiftc -parse-as-library app/MeetingRules.swift tests/meeting_rules.swift -o app/build/meeting-rules-test && app/build/meeting-rules-test
// Meeting notes: when the strip offers, which event the menu attaches, the menu and picker labels. Made-up events only.
import Foundation

@main
struct MeetingRulesTest {
    static var failed = 0, checks = 0
    static func check(_ ok: Bool, _ what: String) { checks += 1; if !ok { failed += 1; print("FAIL", what) } }

    static var cal: Calendar = { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "Europe/Kyiv")!; return c }()
    static let t0 = cal.date(from: DateComponents(year: 2026, month: 11, day: 18, hour: 14, minute: 0))!
    static func at(_ min: Double) -> Date { t0.addingTimeInterval(min * 60) }
    static func ev(_ id: String, _ title: String = "Sample sync", from: Double = 0, to: Double = 30, video: Bool = true, others: Bool = true,
                   allDay: Bool = false, declined: Bool = false, canceled: Bool = false) -> MeetEvent {
        MeetEvent(id: id, title: title, start: at(from), end: at(to), allDay: allDay, declined: declined, canceled: canceled, video: video, others: others)
    }

    static func main() {
        offer(); current(); labels(); short(); mode()
        print(failed == 0 ? "meeting rules: \(checks) checks pass" : "\(failed) of \(checks) failed")
        if failed > 0 { exit(1) }
    }

    static func offer() {
        let e = ev("a")
        check(MeetingRules.offer([e], now: at(-2), offered: [], busy: false) == nil, "2 min before: no offer yet")
        check(MeetingRules.offer([e], now: at(-1), offered: [], busy: false) == e, "1 min before: offered")
        check(MeetingRules.offer([e], now: at(0), offered: [], busy: false) == e, "at the start: offered")
        check(MeetingRules.offer([e], now: at(2), offered: [], busy: false) == e, "2 min in: still offered")
        check(MeetingRules.offer([e], now: at(2.5), offered: [], busy: false) == nil, "2.5 min in: too late")
        check(MeetingRules.offer([e], now: at(0), offered: ["a"], busy: false) == nil, "once per event")
        check(MeetingRules.offer([e], now: at(0), offered: [], busy: true) == nil, "no offer while recording or another offer shows")
        check(MeetingRules.offer([ev("b", video: false)], now: at(0), offered: [], busy: false) == nil, "no video link: no offer (in person starts from the menu)")
        check(MeetingRules.offer([ev("c", declined: true)], now: at(0), offered: [], busy: false) == nil, "declined: no offer")
        check(MeetingRules.offer([ev("d", allDay: true)], now: at(0), offered: [], busy: false) == nil, "all-day: no offer")
        check(MeetingRules.offer([ev("e", canceled: true)], now: at(0), offered: [], busy: false) == nil, "canceled: no offer")
        check(MeetingRules.offer([ev("f", others: false)], now: at(0), offered: [], busy: false)?.id == "f", "a video link alone is a meeting")
        let two = [ev("late", from: 1, to: 31), ev("early", from: 0, to: 30)]
        check(MeetingRules.offer(two, now: at(0.5), offered: [], busy: false)?.id == "early", "two at once: the earlier start")
        check(MeetingRules.offer([ev("g", from: 0, to: 1)], now: at(1), offered: [], busy: false) == nil, "already over: no offer")
    }

    static func current() {
        check(MeetingRules.current([ev("a", from: 10, to: 40)], now: at(0))?.id == "a", "starts in 10 min: attached")
        check(MeetingRules.current([ev("a", from: 11, to: 40)], now: at(0)) == nil, "starts in 11 min: not attached")
        check(MeetingRules.current([ev("a", from: -20, to: 10)], now: at(0))?.id == "a", "running: attached")
        check(MeetingRules.current([ev("a", from: -30, to: 0)], now: at(0)) == nil, "just ended: not attached")
        check(MeetingRules.current([ev("run", from: -20, to: 10), ev("next", from: 5, to: 35)], now: at(0))?.id == "run", "running beats coming")
        check(MeetingRules.current([ev("x", from: 8, to: 30), ev("y", from: 3, to: 30)], now: at(0))?.id == "y", "of two coming, the sooner")
        check(MeetingRules.current([ev("focus", video: false, others: false)], now: at(0)) == nil, "a block of focus time is no meeting")
        check(MeetingRules.current([ev("p", video: false, others: true)], now: at(0))?.id == "p", "in person with people: attached")
        check(MeetingRules.current([ev("d", declined: true)], now: at(0)) == nil, "declined: not attached")
        check(MeetingRules.current([ev("d", allDay: true)], now: at(0)) == nil, "all-day: not attached")
    }

    static func labels() {
        check(MeetingRules.menuLabel(recording: false, event: nil, calendar: cal) == "Start meeting notes", "no event: Start meeting notes")
        check(MeetingRules.menuLabel(recording: false, event: ev("a", "Design review"), calendar: cal) == "Notes for Design review (14:00)", "event: its title and start")
        check(MeetingRules.menuLabel(recording: true, minutes: 12, event: nil, calendar: cal) == "■ Stop meeting notes · 12 min", "recording: stop and minutes")
        check(MeetingRules.menuLabel(recording: true, meeting: false, minutes: 3, event: nil, calendar: cal) == "■ Stop the long note · 3 min", "a plain long note keeps its words")
        check(MeetingRules.minutes(since: at(0), now: at(0.2)) == 1, "under a minute shows 1 min")
        check(MeetingRules.minutes(since: at(0), now: at(12.9)) == 12, "whole minutes")
        let r = MeetingRules.pickRow(event: ev("a", "Design review", from: 5), recording: false, calendar: cal)
        check(r.title == "Notes for Design review" && r.detail == "14:05", "picker row: title and start \(r)")
        check(MeetingRules.pickRow(event: nil, recording: false).title == "Start meeting notes", "picker row without an event")
        check(MeetingRules.pickRow(event: nil, recording: true).title == "Stop meeting notes", "picker row while recording")
        let rows = MeetingRules.offerRows(ev("a", "Design review"), now: at(-1), calendar: cal)
        check(rows.count == 3 && rows[0] == "Take notes for «Design review»?" && rows[1] == "starts at 14:00", "offer rows before the start \(rows)")
        check(MeetingRules.offerRows(ev("a"), now: at(1), calendar: cal)[1] == "started at 14:00", "offer rows after the start")
        check(MeetingRules.keys == [";meet", ";notes"], "quick start keys")
    }

    static func short() {
        check(MeetingRules.short("Weekly sync") == "Weekly sync", "short title stays")
        check(MeetingRules.short("  Weekly \n sync ") == "Weekly sync", "spaces folded")
        check(MeetingRules.short("") == "the meeting", "empty title")
        let long = MeetingRules.short("Quarterly planning review with the sample team and every partner", most: 40)
        check(long.count <= 41 && long.hasSuffix("…") && !long.contains("  "), "long title cut at a word: \(long)")
        check(MeetingRules.short(String(repeating: "x", count: 60), most: 40).count == 41, "one long word cut hard")
    }

    static func mode() {
        check(MeetingRules.mode(callAppHoldsMic: true) == .call, "a call app on the mic: the call")
        check(MeetingRules.mode(callAppHoldsMic: false) == .inPerson, "no call app: in person")
    }
}

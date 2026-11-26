// Meeting notes from the app (17 November 2026, the user: "need a better way to start meeting notes from the app"; the
// last call recording before that started on 3 November). Pure: no AppKit, no EventKit. Three ways in, one behaviour
// (app/MeetingNotes.swift): the menu bar's first item, the `;meet` / `;notes` quick start in the one `;` picker, and the
// strip's offer 1 min before, or at the start of, a calendar event with a video link. With a call app holding the
// microphone the call is recorded (both sides); without one it is an in-person note (the user's microphone only).
// Test: tests/meeting_rules.swift.
import Foundation

/// A calendar event as these rules see it (filled from EventKit by app/MeetingNotes.swift).
struct MeetEvent: Equatable {
    let id: String            // the event's id plus its start: one recurring event offers once per day it happens
    let title: String
    let start: Date
    let end: Date
    var allDay = false
    var declined = false      // the user said no to it
    var canceled = false
    var video = false         // a Meet, Zoom, Teams (or other call) link in its url, place or notes
    var others = false        // someone besides the user is invited
}

enum MeetingRules {
    /// The quick start's triggers in the `;` picker.
    static let keys = [";meet", ";notes"]
    /// The menu and the picker attach an event going on now or starting within this many seconds.
    static let soon: TimeInterval = 10 * 60
    /// The strip offers from 1 min before the start until 2 min after it.
    static let lead: TimeInterval = 60, late: TimeInterval = 120
    /// How long the offer stays in the strip, in seconds.
    static let offerSeconds = 60.0

    /// An event worth notes at all: timed, not declined or canceled, and a meeting (a video link or other people), not a
    /// block of focus time (2026-11-01, the user: "pulling too much from my other tools").
    static func meeting(_ e: MeetEvent) -> Bool {
        !e.allDay && !e.declined && !e.canceled && (e.video || e.others) && e.end > e.start
    }

    /// The event the menu item and the quick start attach: one going on now or starting within 10 min. A started one
    /// beats one still to come; among started ones the latest start, among coming ones the soonest.
    static func current(_ evs: [MeetEvent], now: Date) -> MeetEvent? {
        let on = evs.filter { meeting($0) && $0.start <= now.addingTimeInterval(soon) && $0.end > now }
        let started = on.filter { $0.start <= now }
        if let e = started.max(by: { $0.start < $1.start }) { return e }
        return on.min(by: { $0.start < $1.start })
    }

    /// The event to offer notes for now, or nil. `offered`: ids already offered (once per event); `busy`: a recording
    /// runs or another offer is in the strip. Only events with a video link: an in-person meeting starts from the menu.
    static func offer(_ evs: [MeetEvent], now: Date, offered: Set<String>, busy: Bool) -> MeetEvent? {
        guard !busy else { return nil }
        return evs.filter { e in
            meeting(e) && e.video && !offered.contains(e.id) && e.end > now
                && now >= e.start.addingTimeInterval(-lead) && now <= e.start.addingTimeInterval(late)
        }.min(by: { $0.start < $1.start })
    }

    /// A title short enough for a menu row or the strip: at most `most` characters, cut at a word, an ellipsis after.
    static func short(_ title: String, most: Int = 40) -> String {
        let t = title.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard t.count > most else { return t.isEmpty ? "the meeting" : t }
        let cut = String(t.prefix(most))
        let word = cut.lastIndex(of: " ").map { String(cut[..<$0]) } ?? cut
        return (word.count >= most / 2 ? word : cut).trimmingCharacters(in: CharacterSet(charactersIn: " ,.;:-·")) + "…"
    }

    /// "14:00" in the user's own calendar and zone.
    static func clock(_ d: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.hour, .minute], from: d)
        return String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0)
    }

    /// Whole minutes recorded, at least 1 once it runs.
    static func minutes(since start: Date, now: Date) -> Int { max(1, Int(now.timeIntervalSince(start) / 60)) }

    /// The menu bar's first item. Recording: how to stop it and for how long (a plain long note keeps its own words);
    /// else what starting it will attach.
    static func menuLabel(recording: Bool, meeting: Bool = true, minutes: Int = 0, event: MeetEvent?, calendar: Calendar = .current) -> String {
        if recording { return (meeting ? "■ Stop meeting notes" : "■ Stop the long note") + " · \(minutes) min" }
        if let e = event { return "Notes for \(short(e.title)) (\(clock(e.start, calendar: calendar)))" }
        return "Start meeting notes"
    }

    /// The quick start's row in the `;` picker: its title and its grey end.
    static func pickRow(event: MeetEvent?, recording: Bool, calendar: Calendar = .current) -> (title: String, detail: String) {
        if recording { return ("Stop meeting notes", "recording") }
        if let e = event { return ("Notes for \(short(e.title))", clock(e.start, calendar: calendar)) }
        return ("Start meeting notes", "call or in person")
    }

    /// The strip's offer: the question, when, what is recorded.
    static func offerRows(_ e: MeetEvent, now: Date, calendar: Calendar = .current) -> [String] {
        ["Take notes for «\(short(e.title))»?",
         (now < e.start ? "starts at " : "started at ") + clock(e.start, calendar: calendar),
         "Your microphone, and the call's sound once a call app joins"]
    }

    enum Mode: Equatable { case call, inPerson }
    /// A call app holds the microphone (and offers are on there): the call, both sides; else in person, the user's mic only.
    static func mode(callAppHoldsMic: Bool) -> Mode { callAppHoldsMic ? .call : .inPerson }

    /// What an in-person recording is labelled by, in its meta and on its page.
    static let inPersonLabel = "In person"
}

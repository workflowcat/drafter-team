// Meeting notes from the app (17 November 2026; rules and reasons: app/MeetingRules.swift). One start for the menu bar's
// first item, the `;meet` / `;notes` quick start and the strip's calendar offer: a call app holding the microphone records
// the call (both sides, CallWatch); otherwise an in-person note of the user's microphone, labelled "In person". The event comes
// from the user's calendars through EventKit, the same set as free slots and call names (Meeting.calendars, Settings › Calendars).
import AppKit
import EventKit

enum MeetingNotes {
    /// What the next recording's Spool takes: the event the user started notes for, and in person or not. Set just before the
    /// recording begins, taken (and cleared) by Spool.init.
    static var pending: (event: [String: Any]?, inPerson: Bool)?
    /// The recording running now was started as meeting notes or is a call (Spool.init sets it for every recording).
    static var active = false
    /// Events already offered in the strip (MeetEvent.id), so each is offered once.
    static var offered: Set<String> = []
    private static var timer: Timer?
    /// The 20 s offer check works from this copy: read again every 5 min or when a calendar changes (EventKit's
    /// notification), not on every tick (was a 6-hour EventKit query every 20 s, all day).
    private static var cached: (at: Date, list: [(MeetEvent, EKEvent)])?
    private static var changed: NSObjectProtocol?

    // MARK: the calendar

    /// Events around now from the user's calendars: started up to 6 h ago, starting in the next 15 min. Empty without access.
    static func events(_ now: Date = Date()) -> [(MeetEvent, EKEvent)] {
        guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else { return [] }
        let cals = Meeting.calendars()
        if cals?.isEmpty == true { return [] }
        let s = Actions.store
        return s.events(matching: s.predicateForEvents(withStart: now.addingTimeInterval(-6 * 3600), end: now.addingTimeInterval(15 * 60), calendars: cals)).map { e in
            let mine = e.attendees?.first(where: { $0.isCurrentUser })
            let m = MeetEvent(id: (e.calendarItemIdentifier) + "@\(Int(e.startDate.timeIntervalSince1970))", title: e.title ?? "",
                              start: e.startDate, end: e.endDate, allDay: e.isAllDay, declined: mine?.participantStatus == .declined,
                              canceled: e.status == .canceled, video: Meeting.link(e), others: !Meeting.others(e).isEmpty)
            return (m, e)
        }
    }

    /// The event the menu item and the quick start attach (running, or starting within 10 min).
    static func current(_ now: Date = Date()) -> (MeetEvent, EKEvent)? {
        let evs = events(now)
        guard let m = MeetingRules.current(evs.map { $0.0 }, now: now) else { return nil }
        return evs.first { $0.0 == m }
    }

    // MARK: start and stop

    /// The menu bar's first item.
    static var menuLabel: String {
        let t = Talk.shared
        if t.recording { return MeetingRules.menuLabel(recording: true, meeting: active || t.isCall, minutes: MeetingRules.minutes(since: t.recStart, now: Date()), event: nil) }
        return MeetingRules.menuLabel(recording: false, event: current()?.0)
    }

    /// Menu item or quick start: stop what records, else start notes for the event on now.
    static func toggle(from: String) {
        if Talk.shared.recording { Talk.shared.stopRecording(from); return }
        start(current().map { Meeting.info($0.1) }, from: from)
    }

    /// Start meeting notes for `event`. A call app holding the microphone (offers on there): the call, both sides; else
    /// in person, the user's microphone only.
    static func start(_ event: [String: Any]?, from: String) {
        guard Talk.shared.state == .idle else { Pill.shared.flash("Finish the voice take first"); return }
        let title = (event?["title"] as? String).map { " «\(MeetingRules.short($0))»" } ?? ""
        var app: String?
        if CallWatch.micBusy() { app = CallWatch.pick().app }
        switch MeetingRules.mode(callAppHoldsMic: app != nil) {
        case .call:
            CallWatch.offeredFor = app
            CallWatch.event = event ?? Meeting.now()
            log("meeting notes: the call in \(app ?? "?") from \(from)" + (event == nil ? "" : ", with its event"))
            CallWatch.accept()
        case .inPerson:
            pending = (event, true)
            Talk.shared.begin(long: true)
            pending = nil
            guard Talk.shared.recording else { log("meeting notes: did not start (from \(from))"); return }
            log("meeting notes: in person from \(from)" + (event == nil ? "" : ", with its event"))
        }
        if !title.isEmpty, Talk.shared.recording { Pill.shared.flash("Notes for" + title) }
    }

    // MARK: the calendar offer

    /// Every 20 s: 1 min before an event with a video link, or at its start, the strip asks "Take notes for …?".
    static func watch() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { _ in tick() }
        timer?.tolerance = 5
        if changed == nil {
            changed = NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: nil, queue: .main) { _ in cached = nil }
        }
    }

    /// The events around now for the offer check, from the cache when it is under 5 min old.
    static func recent(_ now: Date = Date()) -> [(MeetEvent, EKEvent)] {
        if let c = cached, now.timeIntervalSince(c.at) < 300, now >= c.at { return c.list }
        let list = events(now)
        cached = (now, list)
        return list
    }

    static func tick(_ now: Date = Date()) {
        guard !Drafter.shared.settings.paused else { return }
        let busy = Talk.shared.state != .idle || Offer.active
        if busy { return }
        let evs = recent(now)
        guard let m = MeetingRules.offer(evs.map { $0.0 }, now: now, offered: offered, busy: busy),
              let e = evs.first(where: { $0.0 == m })?.1 else { return }
        offered.insert(m.id)
        if offered.count > 200 { offered = Set(offered.suffix(100)) }
        offer(m, info: Meeting.info(e), now: now)
    }

    /// The strip's offer. test: shown from the `meetoffertest` hook with a made-up event; taking it only logs.
    static func offer(_ m: MeetEvent, info: [String: Any], now: Date = Date(), test: Bool = false) {
        Offer.show(MeetingRules.offerRows(m, now: now), kind: "Meeting", side: "Calendar", accept: "Take notes",
                   seconds: MeetingRules.offerSeconds, key: "↵") {
            if test { log("meeting offer test: taken") } else { start(info, from: "the calendar offer") }
        }
        Offer.noTab = true                 // Tab stays the app's; ↵ or the button start it, Esc dismisses
        Offer.returnUntil = Offer.until
        log("meeting notes: offered for an event at \(MeetingRules.clock(m.start))" + (test ? " (test)" : ""))
    }
}

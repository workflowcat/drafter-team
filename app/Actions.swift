// Chip actions, EventKit calendar/reminder integration, free-slot search, and /pending long-poll jobs.
// Extracted from Keys.swift so EventKit and action dispatch stay cleanly decoupled from the key event tap.
import AppKit
import EventKit

/// Runs what a chip shows. App-side kinds use EventKit; anything else goes back to the engine's action file.
enum Actions {
    static let store = EKEventStore()

    static func run(_ a: [String: Any]) {
        guard let r = a["run"] as? [String: Any], let kind = r["kind"] as? String else { return }
        switch kind {
        case "replaceSelection":
            Talk.shared.replaceSelection(r["old"] as? String ?? "", with: r["new"] as? String ?? "")
        case "replace":
            Focus.replace(r["old"] as? String ?? "", with: r["new"] as? String ?? "") { ok in
                if !ok { Ghost.shared.flash("Text changed; replacement cancelled") }
                log("voice better text " + (ok ? "paste or AX replacement requested" : "not replaced"))
            }
        case "expand":   // a snippet chip (engine/snippets.py)
            Snippets.expand(old: r["old"] as? String ?? "", new: r["new"] as? String ?? "", key: r["key"] as? String ?? "", expected: Keys.shared.spot)
        case "eventkit.event": event(r)
        case "eventkit.reminder": reminder(r)
        case "avail.typed": Availability.runTyped(r)                 // "I'm free " + slots, read again now (app/Availability.swift)
        case "open": Presets.open(r, expected: Keys.shared.spot)   // a quick start (app/Presets.swift)
        case "proofread": Proof.apply()                              // the reader check's Fix chip (app/Proof.swift)
        case "reader.note": Ghost.shared.hide()                      // the reader's "they asked about" chip: Tab puts it away
        case "pauseRewrite": PauseRewrite.apply()                    // Claude's rewrite after a pause (app/PauseRewrite.swift)
        default:
            Engine.shared.post("/act", ["id": a["id"] ?? "", "fields": a["fields"] ?? [:]], timeout: 15) { j in
                Ghost.shared.flash((j?["done"] as? String) ?? (j?["error"] as? String) ?? "Action failed")
            }
        }
    }

    static func date(_ s: Any?) -> Date? {
        guard let s = s as? String else { return nil }
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd'T'HH:mm"
        return f.date(from: String(s.prefix(16)))
    }

    /// Jobs other local tools handed to the engine: run them here and report back.
    /// One request at a time, held by the engine up to 25 s until a job comes (2026-11-14: was one every second);
    /// the 1 s timer only starts the next one. Needs the engine of the same build (server.py reads ?wait).
    private static var polling = false
    static func poll() {
        guard !polling else { return }
        polling = true
        Engine.shared.get("/pending?wait=25", timeout: 30, longPoll: true) { j in
            polling = false
            for job in (j?["jobs"] as? [[String: Any]]) ?? [] {
                guard let id = job["job"] as? String, let r = job["run"] as? [String: Any] else { continue }
                let report: (String, Bool) -> Void = { text, ok in
                    Engine.shared.post("/done", ["job": id, "result": ok ? ["done": text] : ["error": text]])
                }
                switch r["kind"] as? String {
                case "eventkit.event": event(r, report)
                case "eventkit.reminder": reminder(r, report)
                case "eventkit.free":
                    freeSlots(r) { slots, err in
                        let result: [String: Any] = slots.map { ["done": "\($0.count) free slots", "slots": $0.map { ["start": $0.start, "end": $0.end, "chip": $0.chip] }] }
                            ?? ["error": err ?? "calendar not readable"]
                        Engine.shared.post("/done", ["job": id, "result": result])
                    }
                default: report("unknown kind", false)
                }
            }
        }
    }

    /// Free time in the user's own calendars (all of them, busy events only), working hours, weekdays, from 15 min from now,
    /// on quarter hours, spread out: up to `count` (default 3) slots of `minutes`. nil + reason when the calendar
    /// cannot be read; never invented slots.
    static func freeSlots(_ r: [String: Any], _ done: @escaping ([(start: String, end: String, chip: String)]?, String?) -> Void) {
        log("free slots: asked, calendar access \(EKEventStore.authorizationStatus(for: .event).rawValue)")
        store.requestFullAccessToEvents { ok, _ in
            DispatchQueue.main.async {
                guard ok else { log("free slots: no calendar access"); done(nil, "Cannot check the calendar: access needed in System Settings › Privacy › Calendars"); return }
                let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd"
                let cal = Calendar.current
                let d0 = f.date(from: String((r["from"] as? String ?? "").prefix(10))) ?? Date()
                let d1 = f.date(from: String((r["to"] as? String ?? "").prefix(10))) ?? d0
                let minutes = r["minutes"] as? Int ?? 30, want = r["count"] as? Int ?? 3
                func hm(_ s: Any?, _ def: Int) -> Int { let p = (s as? String ?? "").split(separator: ":").compactMap { Int($0) }; return p.count == 2 ? p[0] * 60 + p[1] : def }
                let early = hm(r["earliest"], 9 * 60), late = hm(r["latest"], 19 * 60)
                let end = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: d1))!
                let chosen = Meeting.calendars()
                let busy = chosen?.isEmpty == true ? [] : store.events(matching: store.predicateForEvents(withStart: cal.startOfDay(for: d0), end: end, calendars: chosen))
                    .filter { !$0.isAllDay && $0.availability != .free }
                var slots: [Date] = []
                var day = cal.startOfDay(for: d0)
                let now = Date().addingTimeInterval(15 * 60)
                while day < end, slots.count < want {
                    if !cal.isDateInWeekend(day) {
                        var t = max(day.addingTimeInterval(Double(early) * 60), now)
                        let q = cal.component(.minute, from: t) % 15; if q != 0 { t = t.addingTimeInterval(Double(15 - q) * 60) }
                        t = cal.date(bySetting: .second, value: 0, of: t) ?? t
                        let stop = day.addingTimeInterval(Double(late) * 60)
                        while t.addingTimeInterval(Double(minutes) * 60) <= stop, slots.count < want {
                            let e = t.addingTimeInterval(Double(minutes) * 60)
                            if let clash = busy.first(where: { $0.startDate < e && $0.endDate > t }) { t = clash.endDate; continue }
                            slots.append(t); t = e.addingTimeInterval(Double(max(60, minutes)) * 60)
                        }
                    }
                    day = cal.date(byAdding: .day, value: 1, to: day)!
                }
                let show = DateFormatter(); show.locale = Locale(identifier: "uk_UA"); show.dateFormat = "EEE d.MM, HH:mm"
                let tf = DateFormatter(); tf.dateFormat = "HH:mm"
                let out = DateFormatter(); out.locale = Locale(identifier: "en_US_POSIX"); out.dateFormat = "yyyy-MM-dd'T'HH:mm"
                let title = r["title"] as? String ?? "Meeting"
                done(slots.map { s in
                    let e = s.addingTimeInterval(Double(minutes) * 60)
                    return (out.string(from: s), out.string(from: e), "\(title) · \(show.string(from: s))–\(tf.string(from: e)) (free)")
                }, nil)
            }
        }
    }

    static func event(_ r: [String: Any], _ report: @escaping (String, Bool) -> Void = { _, _ in }) {
        store.requestFullAccessToEvents { ok, err in
            DispatchQueue.main.async {
                guard ok else { Ghost.shared.flash("Calendar access is off (System Settings › Privacy › Calendars)"); report("calendar access off", false); return }
                guard let start = date(r["start"]) else { Ghost.shared.flash("No time in the chip"); report("no time", false); return }
                let e = EKEvent(eventStore: store)
                e.title = r["title"] as? String ?? "Meeting"
                e.startDate = start
                e.endDate = start.addingTimeInterval(Double(r["minutes"] as? Int ?? 60) * 60)
                e.notes = r["notes"] as? String
                e.calendar = store.defaultCalendarForNewEvents
                do { try store.save(e, span: .thisEvent); Ghost.shared.flash("Event created: \(e.title ?? "")"); log("event saved \(start)"); report("Event created: \(e.title ?? "")", true) }
                catch { Ghost.shared.flash("Failed: \(error.localizedDescription)"); report(error.localizedDescription, false) }
            }
        }
    }

    static func reminder(_ r: [String: Any], _ report: @escaping (String, Bool) -> Void = { _, _ in }) {
        store.requestFullAccessToReminders { ok, _ in
            DispatchQueue.main.async {
                guard ok else { Ghost.shared.flash("Reminders access is off (System Settings › Privacy › Reminders)"); report("reminders access off", false); return }
                let x = EKReminder(eventStore: store)
                x.title = r["title"] as? String ?? "Reminder"
                x.calendar = store.defaultCalendarForNewReminders()
                if let d = date(r["due"]) {
                    x.dueDateComponents = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: d)
                    x.addAlarm(EKAlarm(absoluteDate: d))
                }
                do { try store.save(x, commit: true); Ghost.shared.flash("Reminder: \(x.title ?? "")"); report("Reminder: \(x.title ?? "")", true) }
                catch { Ghost.shared.flash("Failed: \(error.localizedDescription)"); report(error.localizedDescription, false) }
            }
        }
    }
}

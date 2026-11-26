// Availability as a reply (17 November 2026): the app side of app/AvailabilityRules.swift. Busy times from the user's calendars
// (EventKit, the calendars Settings leaves on: `calendarsOff`, the same set as call names); the rules pick the
// slots and write the line. Three ways in:
//   - their last message asks for a time: an option on the next-message card ("Можу вт 18.11 о 10:00, …"),
//   - they proposed a slot: "works", or the nearest free one instead,
//   - the user starts the line themselves ("I'm free ", "можу в "): a chip, Tab finishes it.
// Every way checks the calendar again at Tab and drops a slot that filled meanwhile. Text only: never an invite, never Return.
import AppKit
import EventKit

enum Availability {
    static let minutes = 30
    /// The option for the box on screen, put on the card after a due promise and before the replies.
    static var first: (el: AXUIElement, opts: [[String: String]])?

    private static let iso: ISO8601DateFormatter = { let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime]; return f }()

    /// The user's busy stretches from today through `days`. nil: no calendar access (never invented slots).
    static func busy(days: Int = 9, now: Date = Date()) -> [AvailabilityRules.Busy]? {
        guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else { return nil }
        let cals = Meeting.calendars()
        if cals?.isEmpty == true { return [] }
        let cal = Calendar.current, s = Actions.store
        let end = cal.date(byAdding: .day, value: days, to: cal.startOfDay(for: now))!
        return s.events(matching: s.predicateForEvents(withStart: cal.startOfDay(for: now), end: end, calendars: cals)).compactMap { e in
            guard e.status != .canceled, e.availability != .free else { return nil }
            if e.isAllDay, e.availability == .notSupported { return nil }   // birthdays, holidays: they block nothing
            let loc = (e.location ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let away = !e.isAllDay && !loc.isEmpty && !loc.lowercased().contains("http")
                && Meeting.video.firstMatch(in: loc, range: NSRange(loc.startIndex..., in: loc)) == nil
            return AvailabilityRules.Busy(start: e.startDate, end: e.endDate, allDay: e.isAllDay, away: away)
        }
    }

    /// The card option for their last message, or nil: it asks for a time, or proposes one with a question.
    static func option(last: String, now: Date = Date()) -> [String: String]? {
        let theirs = AvailabilityRules.zone(last)
        let p = AvailabilityRules.proposed(last, now: now, calendar: .current, zone: theirs)
        guard AvailabilityRules.asks(last) || (p != nil && last.contains("?")), let busy = busy(now: now) else { return nil }
        let lang = AvailabilityRules.lang(last, keyboard: KeyLayout.language), mine = TimeZone.current, cal = Calendar.current
        var o = ["lang": lang, "zone": theirs?.identifier ?? ""]
        if let p {
            let free = AvailabilityRules.isFree(p, minutes: minutes, busy: busy, now: now, calendar: cal)
            let instead = free ? nil : AvailabilityRules.nearest(to: p, minutes: minutes, busy: busy, now: now, calendar: cal)
            o["text"] = AvailabilityRules.checkLine(p, free: free, instead: instead, now: now, lang: lang, mine: mine, theirs: theirs)
            o["label"] = free ? (lang == "en" ? "free" : lang == "ru" ? "свободно" : "вільно") : (lang == "en" ? "busy · another time" : lang == "ru" ? "занято · другое время" : "зайнято · інший час")
            o["avail"] = "check"; o["proposed"] = iso.string(from: p)
            o["slots"] = (instead.map { [$0] } ?? []).map(iso.string).joined(separator: ",")
        } else {
            let slots = AvailabilityRules.slots(busy: busy, now: now, minutes: minutes, calendar: cal)
            guard !slots.isEmpty else { return nil }
            o["text"] = AvailabilityRules.offerLine(slots, now: now, lang: lang, mine: mine, theirs: theirs)
            o["label"] = lang == "uk" ? "мій вільний час" : lang == "ru" ? "моё свободное время" : "my free times"
            o["avail"] = "offer"; o["slots"] = slots.map(iso.string).joined(separator: ",")
        }
        return o
    }

    /// The same free times as a short list, each with a Google Calendar link the other person clicks to add it to their
    /// own calendar (AvailabilityRules.calendarLink: no API, no invite, nothing sent). Title from the chat.
    static func withLinks(_ o: [String: String], title: String, now: Date = Date()) -> [String: String]? {
        guard o["avail"] == "offer" else { return nil }
        let slots = (o["slots"] ?? "").split(separator: ",").compactMap { iso.date(from: String($0)) }
        guard !slots.isEmpty else { return nil }
        let lang = o["lang"] ?? "en", z = o["zone"] ?? ""
        var l = o
        l["text"] = AvailabilityRules.offerLine(slots, now: now, lang: lang, mine: .current, theirs: z.isEmpty ? nil : TimeZone(identifier: z),
                                                links: slots.map { AvailabilityRules.calendarLink($0, minutes: minutes, title: title) })
        l["label"] = (o["label"] ?? "") + " · " + AvailabilityRules.w(lang, "add")
        l["title"] = title
        return l
    }

    /// At Tab: the line again when the calendar changed since it was shown (a slot filled, the proposed time taken);
    /// nil = keep the text as it is. Not an availability option: nil.
    static func recheck(_ o: [String: String]?, now: Date = Date()) -> String? {
        guard let o, let kind = o["avail"], let busy = busy(now: now) else { return nil }
        let cal = Calendar.current, mine = TimeZone.current, lang = o["lang"] ?? "en"
        let theirs = (o["zone"] ?? "").isEmpty ? nil : TimeZone(identifier: o["zone"]!)
        let slots = (o["slots"] ?? "").split(separator: ",").compactMap { iso.date(from: String($0)) }
        if kind == "check", let p = o["proposed"].flatMap(iso.date) {
            let free = !AvailabilityRules.stillFree([p], minutes: minutes, busy: busy, now: now, calendar: cal).isEmpty
            if free, slots.isEmpty { return nil }                                   // it worked and still does
            if !free, !slots.isEmpty, AvailabilityRules.stillFree(slots, minutes: minutes, busy: busy, now: now, calendar: cal).count == slots.count { return nil }
            let instead = free ? nil : AvailabilityRules.nearest(to: p, minutes: minutes, busy: busy, now: now, calendar: cal)
            log("availability: the proposed time changed at Tab")
            return AvailabilityRules.checkLine(p, free: free, instead: instead, now: now, lang: lang, mine: mine, theirs: theirs)
        }
        let still = AvailabilityRules.stillFree(slots, minutes: minutes, busy: busy, now: now, calendar: cal)
        if still.count == slots.count { return nil }
        var fresh = still
        for t in AvailabilityRules.slots(busy: busy, now: now, minutes: minutes, count: slots.count + 2, calendar: cal) where fresh.count < slots.count && !fresh.contains(t) { fresh.append(t) }
        fresh.sort()
        log("availability: \(slots.count - still.count) slot(s) filled before Tab, line rebuilt")
        Ghost.shared.flash(lang == "en" ? "Calendar changed: times updated" : lang == "ru" ? "Календарь изменился: время обновлено" : "Календар змінився: час оновлено")
        let links = o["title"].map { t in fresh.map { AvailabilityRules.calendarLink($0, minutes: minutes, title: t) } } ?? []
        return AvailabilityRules.offerLine(fresh, now: now, lang: lang, mine: mine, theirs: theirs, links: links)
    }

    /// The user typed the start of an availability line: a chip with the slots; Tab reads the calendar again and finishes it.
    static func typedOffer(_ s: Spot, context: String) -> [String: Any]? {
        let line = s.before.components(separatedBy: "\n").last ?? ""
        guard AvailabilityRules.typedStart(line), let busy = busy() else { return nil }
        let slots = AvailabilityRules.slots(busy: busy, now: Date(), minutes: minutes, calendar: .current)
        guard !slots.isEmpty else { return nil }
        let lang = AvailabilityRules.lang(line, keyboard: KeyLayout.language), theirs = AvailabilityRules.lastTheirs(context).flatMap(AvailabilityRules.zone)
        let text = AvailabilityRules.offerLine(slots, now: Date(), lang: lang, mine: .current, theirs: theirs, start: false)
        return ["id": "availability", "chip": "⇥ " + String(text.prefix(60)),
                "run": ["kind": "avail.typed", "lang": lang, "zone": theirs?.identifier ?? ""]]
    }

    /// The chip's Tab: slots from the calendar as it is now, put in after what the user typed.
    static func runTyped(_ r: [String: Any]) {
        guard let busy = busy() else { Ghost.shared.flash("Calendar access is off (System Settings › Privacy › Calendars)"); return }
        let slots = AvailabilityRules.slots(busy: busy, now: Date(), minutes: minutes, calendar: .current)
        guard !slots.isEmpty else { Ghost.shared.flash("No free times in the next week"); return }
        let z = r["zone"] as? String ?? ""
        let text = AvailabilityRules.offerLine(slots, now: Date(), lang: r["lang"] as? String ?? "en", mine: .current, theirs: z.isEmpty ? nil : TimeZone(identifier: z), start: false)
        Snippets.expand(old: "", new: text, key: "lookup", expected: Keys.shared.spot)
        log("availability: \(slots.count) slots put in after the user's start")
    }
}

extension Keys {
    /// The empty box's screen was read: when their last message asks for a time, the availability option goes on the
    /// card now (the replies join it when the local model answers). Calendar only; nothing leaves the Mac.
    func askAvailability(_ s: Spot, ctx: String) {
        Availability.first = nil
        guard let last = AvailabilityRules.lastTheirs(ctx), let o = Availability.option(last: last) else { return }
        let lang = o["lang"] ?? "en"
        let title = AvailabilityRules.eventTitle(theirName: AvailabilityRules.theirName(ctx), myName: "", lang: lang)
        let all = [o] + (Availability.withLinks(o, title: title).map { [$0] } ?? [])
        Availability.first = (s.el, all)
        guard !Ghost.shared.isDraft, let now = Focus.spot(skip: Drafter.shared.settings.skip).0, CFEqual(now.el, s.el),
              Keys.replyBox(now) || Keys.boxKind(now) == false, let r = now.rect ?? Focus.fieldStart(now.el) else { return }
        spot = now
        Ghost.shared.showDraft(Keys.numbered(all), field: Focus.frame(now.el), caret: r)
        log("availability: \(o["avail"] ?? "") shown")
    }

    /// Options that go before the replies on a card for this field: availability.
    static func leading(for el: AXUIElement) -> [[String: String]] {
        if let a = Availability.first, CFEqual(a.el, el) { return a.opts }
        return []
    }
}

// Which app a call is in, and what to call it (17 November 2026, the user: a Microsoft Teams meeting was labelled Slack).
// Pure Foundation, tested by tests/call_app_rules.swift. Before, the first call app holding the microphone won: Slack
// can hold the microphone with no huddle open while the meeting runs in Teams, and a browser counted for any tab.
// Now each call app is scored on what can be seen of it:
//   holds the microphone          +4   (CoreAudio per process, CallWatch.probe)
//   a call window is open         +3   (its window titles: "Zoom Meeting", "… | Microsoft Teams" with a meeting word,
//                                       a Slack huddle, any FaceTime window, a Meet / Teams / Zoom tab in a browser)
//   the calendar event's link     +3   (the event's video link names the same service)
//   it is the front app           +1
// A browser needs a meeting tab or the event's link to count at all (a tab that records is not a call). The best app
// with offers on wins; with none on, the best app with offers off is named for the log. Scores under 3 never win:
// being in front alone says nothing.
import Foundation

struct CallSeen: Equatable {
    var bundle: String
    var holdsMic = false
    var front = false
    var titles: [String] = []
    var on = true
}

enum CallAppRules {
    /// The app a process belongs to, from its executable's path: the outermost `.app` folder (18 November 2026: in a
    /// Dia call the microphone is held by "Browser Helper (Aperitif)" inside Dia.app, which has no bundle id of its
    /// own, so no call was seen and the recording was a note of the user's mic only). nil: not inside an app.
    static func appPath(executable: String) -> String? {
        guard let r = executable.range(of: ".app/") else { return executable.hasSuffix(".app") ? executable : nil }
        return String(executable[..<r.lowerBound]) + ".app"
    }

    enum Service: String, CaseIterable { case teams, meet, zoom, slack, facetime, webex, whereby, discord, whatsapp, telegram, beeper, notion }

    static let browsers: Set<String> = ["com.google.Chrome", "company.thebrowser.dia", "company.thebrowser.Browser", "com.apple.Safari",
                                        "com.microsoft.edgemac", "org.mozilla.firefox", "com.brave.Browser", "com.vivaldi.Vivaldi"]
    static let native: [String: Service] = [
        "us.zoom.xos": .zoom, "com.apple.FaceTime": .facetime, "com.tinyspeck.slackmacgap": .slack, "com.microsoft.teams2": .teams,
        "com.microsoft.teams": .teams, "com.hnc.Discord": .discord, "net.whatsapp.WhatsApp": .whatsapp, "ru.keepcoder.Telegram": .telegram,
        "com.automattic.beeper.desktop": .beeper, "com.cisco.webexmeetingsapp": .webex, "notion.id": .notion,
    ]
    static func isCallApp(_ b: String) -> Bool { native[b] != nil || browsers.contains(b) }

    static func label(_ s: Service, web: Bool = false) -> String {
        switch s {
        case .teams: return web ? "Microsoft Teams (web)" : "Microsoft Teams"
        case .meet: return "Google Meet"
        case .zoom: return web ? "Zoom (web)" : "Zoom"
        case .slack: return "Slack huddle"
        case .facetime: return "FaceTime"
        case .webex: return "Webex"
        case .whereby: return "Whereby"
        case .discord: return "Discord"
        case .whatsapp: return "WhatsApp"
        case .telegram: return "Telegram"
        case .beeper: return "Beeper"
        case .notion: return "Notion"
        }
    }

    private static func has(_ t: String, _ p: String) -> Bool { t.range(of: p, options: [.regularExpression, .caseInsensitive]) != nil }
    private static let meetingWord = #"\b(meeting|call|calling|webinar|нарада|зустріч|дзвінок|виклик)\b"#

    /// The service a browser tab or a calendar link points at, from its text.
    static func service(text t: String) -> Service? {
        if has(t, #"meet\.google\.com|google meet|^meet\s*[-–—:]"#) { return .meet }
        if has(t, #"teams\.microsoft|teams\.live|microsoft teams"#) { return .teams }
        if has(t, #"zoom\.us|\bzoom\b"#) { return .zoom }
        if has(t, #"slack\.com/huddle|\bhuddle\b"#) { return .slack }
        if has(t, #"webex"#) { return .webex }
        if has(t, #"whereby"#) { return .whereby }
        if has(t, #"facetime"#) { return .facetime }
        return nil
    }

    /// A window that shows a call going on in this app -> its service, or nil.
    static func callWindow(_ bundle: String, _ titles: [String]) -> Service? {
        if browsers.contains(bundle) {
            for t in titles {
                if has(t, #"meet\.google\.com|^meet\s*[-–—:]|google meet"#) { return .meet }
                if has(t, #"microsoft teams"#), has(t, meetingWord) { return .teams }
                if has(t, #"\bzoom\b"#), has(t, meetingWord + #"|webinar"#) { return .zoom }
                if has(t, #"whereby|webex"#) { return service(text: t) }
            }
            return nil
        }
        guard let s = native[bundle] else { return nil }
        switch s {
        case .zoom: return titles.contains { has($0, #"zoom (meeting|webinar)|^meeting$"#) } ? s : nil
        case .teams: return titles.contains { has($0, meetingWord) } ? s : nil
        case .slack: return titles.contains { has($0, #"\bhuddle\b"#) } ? s : nil
        case .facetime: return titles.contains { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ? s : nil
        case .webex: return titles.contains { has($0, meetingWord) } ? s : nil
        default: return nil
        }
    }

    /// Record at once, without the offer: the user's switch for this call app, or for the calendar of the meeting going on.
    /// Offers off in the app wins (no recording there at all).
    static func auto(app: String, on: Bool, calendar: String?, apps: [String], calendars: [String]) -> Bool {
        guard on else { return false }
        return apps.contains(app) || (calendar.map { !$0.isEmpty && calendars.contains($0) } ?? false)
    }

    struct Pick: Equatable {
        var app: String?        // the call app to offer or record (offers on)
        var off: String?        // the best call app with offers off, when none with offers on won (for the log)
        var label = ""          // what the recording is called by: "Microsoft Teams", "Google Meet", "Slack huddle"
    }

    static func score(_ s: CallSeen, eventService: Service?) -> (score: Int, service: Service?) {
        guard isCallApp(s.bundle) else { return (0, nil) }
        let window = callWindow(s.bundle, s.titles)
        let browser = browsers.contains(s.bundle)
        // what this app would be serving: its call window, else its own service, else (a browser) the event's
        let svc = window ?? native[s.bundle] ?? (browser ? eventService.flatMap { [.meet, .teams, .zoom, .whereby, .webex].contains($0) ? $0 : nil } : nil)
        if browser, window == nil, svc == nil { return (0, nil) }   // a tab that merely records
        var n = 0
        if s.holdsMic { n += 4 }
        if window != nil { n += 3 }
        if let e = eventService, e == svc { n += 3 }
        if s.front { n += 1 }
        return (n, svc)
    }

    /// The call app among those seen (every app holding the mic, plus running call apps).
    static func pick(_ seen: [CallSeen], eventService: Service? = nil) -> Pick {
        struct Scored { let i: Int; let s: CallSeen; let score: Int; let service: Service? }
        var all: [Scored] = []
        for (i, s) in seen.enumerated() {
            let r = score(s, eventService: eventService)
            if r.score >= 3 { all.append(Scored(i: i, s: s, score: r.score, service: r.service)) }
        }
        all.sort { a, b in a.score != b.score ? a.score > b.score : a.i < b.i }
        func name(_ x: Scored) -> String { x.service.map { label($0, web: browsers.contains(x.s.bundle)) } ?? "" }
        if let best = all.first(where: { $0.s.on }) { return Pick(app: best.s.bundle, off: nil, label: name(best)) }
        if let off = all.first { return Pick(app: nil, off: off.s.bundle, label: name(off)) }
        return Pick()
    }
}

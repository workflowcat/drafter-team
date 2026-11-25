// swiftc -parse-as-library app/CallAppRules.swift tests/call_app_rules.swift -o app/build/call-app-rules-test && app/build/call-app-rules-test
import Foundation

@main
struct CallAppChecks {
    static var failed = 0
    static func check(_ ok: Bool, _ what: String) { if !ok { print("FAIL: " + what); failed += 1 } }

    static func main() {
        let slack = "com.tinyspeck.slackmacgap", teams = "com.microsoft.teams2", zoom = "us.zoom.xos", chrome = "com.google.Chrome",
            ft = "com.apple.FaceTime", safari = "com.apple.Safari", notion = "notion.id", word = "com.microsoft.Word"
        typealias Case = (String, [CallSeen], CallAppRules.Service?, String?, String?, String)   // name, seen, event, app, off, label
        let cases: [Case] = [
            // 17 November: Slack held the mic with no huddle; the meeting ran in Teams
            ("Teams meeting beside an idle Slack",
             [CallSeen(bundle: slack, holdsMic: true, titles: ["general (Channel) - Acme - Slack"]),
              CallSeen(bundle: teams, holdsMic: true, titles: ["Weekly sync | Meeting | Microsoft Teams"])], nil, teams, nil, "Microsoft Teams"),
            ("Teams without the mic list still wins by its meeting window",
             [CallSeen(bundle: slack, titles: ["general - Slack"]), CallSeen(bundle: teams, titles: ["Call with Mila | Microsoft Teams"])], nil, teams, nil, "Microsoft Teams"),
            ("Teams chat window alone is no call",
             [CallSeen(bundle: teams, titles: ["Chat | Microsoft Teams"])], nil, nil, nil, ""),
            ("Slack huddle",
             [CallSeen(bundle: slack, holdsMic: true, titles: ["Huddle: #design - Slack"])], nil, slack, nil, "Slack huddle"),
            ("Meet in Chrome, named Google Meet",
             [CallSeen(bundle: chrome, holdsMic: true, titles: ["Meet - abc-defg-hij"])], nil, chrome, nil, "Google Meet"),
            ("Meet tab beats Slack holding the mic",
             [CallSeen(bundle: slack, holdsMic: true, titles: ["general - Slack"]), CallSeen(bundle: chrome, holdsMic: true, titles: ["Inbox", "Meet – Design review"])], nil, chrome, nil, "Google Meet"),
            ("a browser tab that merely records is no call",
             [CallSeen(bundle: chrome, holdsMic: true, titles: ["Voice recorder online"])], nil, nil, nil, ""),
            ("a browser with the event's Meet link counts",
             [CallSeen(bundle: chrome, holdsMic: true, titles: ["Untitled"])], .meet, chrome, nil, "Google Meet"),
            ("Teams on the web in Safari",
             [CallSeen(bundle: safari, holdsMic: true, titles: ["Meeting with Sava | Microsoft Teams"])], nil, safari, nil, "Microsoft Teams (web)"),
            ("Zoom meeting window",
             [CallSeen(bundle: zoom, holdsMic: true, titles: ["Zoom Meeting"]), CallSeen(bundle: slack, holdsMic: true)], nil, zoom, nil, "Zoom"),
            ("the event's Zoom link breaks a tie for Zoom",
             [CallSeen(bundle: slack, holdsMic: true), CallSeen(bundle: zoom, holdsMic: true)], .zoom, zoom, nil, "Zoom"),
            ("the event's Teams link names Teams over Slack, both holding the mic",
             [CallSeen(bundle: slack, holdsMic: true), CallSeen(bundle: teams, holdsMic: true)], .teams, teams, nil, "Microsoft Teams"),
            ("FaceTime with a window",
             [CallSeen(bundle: ft, holdsMic: true, titles: ["Mila Synthetic"])], nil, ft, nil, "FaceTime"),
            ("in front alone says nothing",
             [CallSeen(bundle: slack, front: true)], nil, nil, nil, ""),
            ("not a call app", [CallSeen(bundle: word, holdsMic: true, front: true, titles: ["Meeting notes"])], nil, nil, nil, ""),
            ("offers off in Notion: the real call beside it wins",
             [CallSeen(bundle: notion, holdsMic: true, on: false), CallSeen(bundle: zoom, holdsMic: true, titles: ["Zoom Meeting"])], nil, zoom, nil, "Zoom"),
            ("only an app with offers off: named for the log",
             [CallSeen(bundle: notion, holdsMic: true, on: false)], nil, nil, notion, "Notion"),
            ("first holder wins a full tie",
             [CallSeen(bundle: slack, holdsMic: true), CallSeen(bundle: zoom, holdsMic: true)], nil, slack, nil, "Slack huddle"),
        ]
        for (name, seen, ev, app, off, label) in cases {
            let p = CallAppRules.pick(seen, eventService: ev)
            check(p.app == app && p.off == off && p.label == label, "\(name): got app \(p.app ?? "nil") off \(p.off ?? "nil") label «\(p.label)»")
        }
        check(CallAppRules.service(text: "https://teams.microsoft.com/l/meetup-join/x") == .teams, "a Teams link")
        check(CallAppRules.service(text: "Join: https://meet.google.com/abc-defg-hij") == .meet, "a Meet link")
        check(CallAppRules.service(text: "https://acme.zoom.us/j/1") == .zoom, "a Zoom link")
        check(CallAppRules.service(text: "Room 4, second floor") == nil, "a place is no service")
        // auto-record: off unless he switched it on for the app or the meeting's calendar
        check(!CallAppRules.auto(app: zoom, on: true, calendar: "cal-work", apps: [], calendars: []), "auto-record is off by default")
        check(CallAppRules.auto(app: zoom, on: true, calendar: nil, apps: [zoom], calendars: []), "on for the app")
        check(CallAppRules.auto(app: teams, on: true, calendar: "cal-work", apps: [], calendars: ["cal-work"]), "on for the calendar")
        check(!CallAppRules.auto(app: teams, on: true, calendar: "", apps: [], calendars: [""]), "no calendar is no match")
        check(!CallAppRules.auto(app: zoom, on: false, calendar: nil, apps: [zoom], calendars: []), "offers off in the app wins")
        // a browser's helper process holds the mic: the call is the browser's
        check(CallAppRules.appPath(executable: "/Applications/Dia.app/Contents/Frameworks/ArcCore.framework/Versions/A/Helpers/Browser Helper (Aperitif).app/Contents/MacOS/Browser Helper (Aperitif)") == "/Applications/Dia.app", "Dia's helper is Dia")
        check(CallAppRules.appPath(executable: "/Applications/zoom.us.app/Contents/MacOS/zoom.us") == "/Applications/zoom.us.app", "an app itself")
        check(CallAppRules.appPath(executable: "/usr/libexec/coreaudiod") == nil, "not in an app")
        if failed > 0 { print("\(failed) failed"); exit(1) }
        print("call app rules: \(cases.count) cases passed")
    }
}

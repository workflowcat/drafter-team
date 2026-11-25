import Foundation

// swiftc -parse-as-library app/CaptureRules.swift tests/capture_rules.swift -o app/build/capture-rules-test && app/build/capture-rules-test
// Calls and screen capture without audio hardware: back-off, the strip's warning, which app a call is, unread recordings.
@main
struct CaptureRuleChecks {
    static var failures = 0
    static func check(_ ok: Bool, _ what: String) { if !ok { print("FAIL: " + what); failures += 1 } }

    static func main() {
        backoff(); health(); pick(); unread()
        if failures > 0 { print("\(failures) failed"); exit(1) }
        print("capture rules: all passed")
    }

    static func backoff() {
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        var b = Backoff(first: 30, most: 600)
        check(b.allowed(t0), "a fresh capture may run")
        let f1 = b.failed(t0)
        check(f1.report && f1.wait == 30, "first failure waits 30 s and is logged")
        check(!b.allowed(t0.addingTimeInterval(29)), "no capture during the wait")
        // reads that started before the wait fail too: no log, no longer wait (9 November: 80 lines in a few minutes)
        let late = b.failed(t0.addingTimeInterval(1))
        check(!late.report && b.failures == 1, "failures inside a wait are not counted again")
        check(b.allowed(t0.addingTimeInterval(30)), "allowed again after the wait")
        let f2 = b.failed(t0.addingTimeInterval(31))
        check(f2.report && f2.wait == 60, "second failure doubles the wait")
        var t = t0.addingTimeInterval(31 + 60)
        var last = 0.0
        for _ in 0..<10 { let f = b.failed(t); last = f.wait; t = t.addingTimeInterval(f.wait) }
        check(last == 600, "the wait stops at 10 min")
        // a hundred context reads in 10 minutes of failing: at most a handful of log lines
        var c = Backoff(first: 30, most: 600), logged = 0
        for i in 0..<100 { let now = t0.addingTimeInterval(Double(i) * 6); if c.allowed(now) { if c.failed(now).report { logged += 1 } } }
        check(logged <= 5, "100 reads over 10 min log at most 5 lines (got \(logged))")
        check(c.succeeded() && c.allowed(t0) && c.failures == 0, "a success ends the run and resets the wait")
        check(!c.succeeded(), "a second success says nothing new")
    }

    static func health() {
        var s = SideStats(seconds: 2, meSamples: 32000, mePeak: 0.2, call: true, sysState: .starting, themSamples: 0, themPeak: 0)
        check(CallHealth.warning(s) == nil, "nothing said in the first seconds")
        s.seconds = 30; s.sysState = .running; s.themSamples = 16000 * 25; s.themPeak = 0.3
        check(CallHealth.warning(s) == nil, "both sides heard: no warning")
        var f = s; f.sysState = .failed; f.themSamples = 0; f.themPeak = 0; f.seconds = 4
        check(CallHealth.warning(f)?.contains("Other side not recorded") == true, "call audio did not start: said within seconds")
        var n = s; n.themSamples = 0; n.themPeak = 0; n.seconds = 9
        check(CallHealth.warning(n)?.contains("no sound arriving") == true, "stream runs but delivers nothing")
        var q = s; q.themPeak = 0.001; q.seconds = 25
        check(CallHealth.warning(q) == "Not hearing the other side yet", "other side silent for 20 s")
        q.seconds = 15
        check(CallHealth.warning(q) == nil, "a quiet other side gets 20 s before a warning")
        // 10 November: the microphone gave exact zeros (peak 0.000) from before the call
        var z = s; z.mePeak = 0; z.seconds = 7
        check(CallHealth.warning(z)?.contains("only silence") == true, "microphone of exact zeros")
        var none = s; none.meSamples = 0; none.mePeak = 0; none.seconds = 7
        check(CallHealth.warning(none) == "Microphone gives no sound at all", "microphone delivers nothing")
        var quiet = s; quiet.mePeak = 0.001; quiet.seconds = 12
        check(CallHealth.warning(quiet) == "Your microphone is very quiet", "very quiet microphone")
        // a long note (no call): nothing about the other side
        var note = SideStats(seconds: 60, meSamples: 16000 * 60, mePeak: 0.3, call: false, sysState: .none, themSamples: 0, themPeak: 0)
        check(CallHealth.warning(note) == nil, "a note never warns about the other side")
        note.mePeak = 0
        check(CallHealth.warning(note) != nil, "a note with a dead microphone warns")
    }

    static func pick() {
        let apps: Set<String> = ["notion.id", "com.automattic.beeper.desktop", "us.zoom.xos", "com.google.Chrome"]
        let off: Set<String> = ["notion.id"]
        func choose(_ h: [String], _ r: String? = nil) -> (String?, String?) {
            let c = CallPick.choose(holders: h, running: r, isCallApp: { apps.contains($0) }, isOn: { !off.contains($0) })
            return (c.app, c.off)
        }
        // 10 November: Notion's meeting notes and the call both hold the mic; Notion has offers off
        check(choose(["notion.id", "com.automattic.beeper.desktop"]) == ("com.automattic.beeper.desktop", nil), "the call wins over Notion")
        check(choose(["com.automattic.beeper.desktop", "notion.id"]) == ("com.automattic.beeper.desktop", nil), "order does not matter")
        check(choose(["notion.id"]) == (nil, "notion.id"), "Notion alone: no offer, logged as off")
        check(choose(["notion.id"], "com.google.Chrome") == (nil, "notion.id"), "a front browser never stands in for Notion")
        check(choose(["com.example.voicememo"]) == (nil, nil), "a holder that is no call app: no offer, as before")
        check(choose([], "us.zoom.xos") == ("us.zoom.xos", nil), "no holder known: the running call app")
        check(choose([], "notion.id") == (nil, "notion.id"), "no holder known, running app off: nothing")
        check(choose([], nil) == (nil, nil), "nothing at all")
    }

    static func unread() {
        check(Unread.shouldRecover(hasMarker: true, attempts: 0, hasAudio: true, hasTranscript: false, thisRun: false), "closed, never read: read again")
        check(!Unread.shouldRecover(hasMarker: true, attempts: 0, hasAudio: true, hasTranscript: true, thisRun: false), "read already")
        check(!Unread.shouldRecover(hasMarker: true, attempts: 0, hasAudio: true, hasTranscript: false, thisRun: true), "closed in this run: its reading is under way")
        check(!Unread.shouldRecover(hasMarker: true, attempts: Unread.maxAttempts, hasAudio: true, hasTranscript: false, thisRun: false), "gives up after two tries")
        check(!Unread.shouldRecover(hasMarker: false, attempts: 0, hasAudio: true, hasTranscript: false, thisRun: false), "older recordings without the marker are left alone")
        check(!Unread.shouldRecover(hasMarker: true, attempts: 0, hasAudio: false, hasTranscript: false, thisRun: false), "no audio: nothing to read")
    }
}

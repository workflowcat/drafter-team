// Rules for screen and call capture that need no hardware (2026-11-13), so tests/capture_rules.swift can run them:
// how long a failing capture waits before the next try, what the recording strip says when a side of a call is not
// heard, which app a call belongs to when more than one holds the microphone, and when a recording left unread is
// read again after a restart. Pure Foundation.
import Foundation

/// A capture that fails waits before it is tried again: `first` seconds, doubling up to `most`; a success resets it.
/// Failures that arrive while a wait is already running (calls that started before it) neither log nor lengthen it.
/// (2026-11-13: "screen capture: Failed to start stream" was logged 1,231 times since 24 October, 80 on 9 November,
/// once per context read, because every read tried again at once.)
struct Backoff {
    let first: Double, most: Double
    private(set) var failures = 0
    private(set) var until = Date.distantPast

    init(first: Double = 30, most: Double = 600) { self.first = first; self.most = most }

    func allowed(_ now: Date = Date()) -> Bool { now >= until }

    /// A failure. -> the wait now in force and whether to log it (only a failure that starts a new wait).
    mutating func failed(_ now: Date = Date()) -> (wait: Double, report: Bool) {
        if now < until { return (until.timeIntervalSince(now), false) }
        failures += 1
        let wait = min(most, first * pow(2, Double(failures - 1)))
        until = now.addingTimeInterval(wait)
        return (wait, true)
    }

    /// A success. -> true when it ends a run of failures (worth one log line).
    @discardableResult
    mutating func succeeded() -> Bool {
        let was = failures > 0
        failures = 0; until = .distantPast
        return was
    }
}

/// What a recording knows about its two sides so far.
struct SideStats: Equatable {
    var seconds: Double = 0         // since the recording began
    var meSamples = 0               // microphone samples written
    var mePeak: Float = 0           // loudest microphone sample so far
    var call = false
    var sysState = SysState.none    // the Mac's own sound (the other side), calls only
    var themSamples = 0             // samples the Mac's own sound delivered
    var themPeak: Float = 0         // loudest of them so far
    enum SysState: Equatable { case none, starting, running, failed }
}

enum CallHealth {
    /// The line the recording strip shows in place of its second row when a side is not being heard, or nil.
    /// Shown while the call runs, not after it ended (2026-11-10: a call ended with "other side not recorded" and
    /// nothing on his side either, and nothing said so during it).
    static func warning(_ s: SideStats) -> String? {
        if s.seconds >= 6, s.meSamples == 0 { return "Microphone gives no sound at all" }
        if s.call {
            if s.sysState == .failed, s.seconds >= 3 { return "Other side not recorded: call audio did not start" }
            if s.seconds >= 8, s.sysState == .running, s.themSamples == 0 { return "Other side: no sound arriving from the Mac" }
        }
        // exact zeros: the microphone is muted or taken (2026-11-10: peak 0.000 from 30 s before the call)
        if s.seconds >= 6, s.mePeak == 0 { return "Your microphone gives only silence (muted or taken by another app?)" }
        if s.call, s.seconds >= 20, s.themSamples > 0, s.themPeak < 0.003 { return "Not hearing the other side yet" }
        if s.seconds >= 10, s.mePeak < 0.002 { return "Your microphone is very quiet" }
        return nil
    }
}

enum CallPick {
    /// The call app for an offer or ⇧ right ⌥, from the apps holding the microphone (all of them, in the order CoreAudio
    /// gave them) and the running call app (used only when no holder is known). A call app with offers on wins over one
    /// with offers off: Notion's meeting notes can hold the microphone beside the real call ("call: notion.id holds the
    /// mic, offers are off there", 10 November), and only the first holder was looked at, so a call beside it was never
    /// offered. A holder that is not a call app (a voice app, a browser helper) still gets no offer, as before.
    /// -> (the app to offer, or nil; a call app with offers off that holds the mic, for the log).
    static func choose(holders: [String], running: String?, isCallApp: (String) -> Bool, isOn: (String) -> Bool) -> (app: String?, off: String?) {
        let calls = holders.filter(isCallApp)
        if let a = calls.first(where: isOn) { return (a, nil) }
        if let off = calls.first { return (nil, off) }
        if !holders.isEmpty { return (nil, nil) }
        guard let r = running else { return (nil, nil) }
        return isOn(r) ? (r, nil) : (nil, r)
    }
}

enum Unread {
    /// The marker a recording folder carries from the moment its audio is closed until its transcript is written.
    static let marker = ".unread"
    /// Times a recording is read again after a restart before it is left for Read again by hand.
    static let maxAttempts = 2

    /// Read a recording again on start? It was closed but never read (the app froze, quit or crashed while reading:
    /// 3 November 2026, a 53-minute call), it is not the one recording or closed in this run, and it has not failed
    /// too often already.
    static func shouldRecover(hasMarker: Bool, attempts: Int, hasAudio: Bool, hasTranscript: Bool, thisRun: Bool) -> Bool {
        hasMarker && hasAudio && !hasTranscript && !thisRun && attempts < maxAttempts
    }
}

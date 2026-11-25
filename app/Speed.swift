// Speed marks (17 November 2026, docs/plans/2026-11-17-speed-load.md "Structural changes" item 5): one os_signpost
// interval per felt step, seen in Instruments (subsystem com.kit.drafter, category speed), and one app.log line
// "speed: <step> N ms" when the step is on screen. A ghost has its own "shown N ms" line already (Keys.swift); it
// gets a signpost event only.
import AppKit
import os

enum Speed {
    enum Step: String { case captureOpen = "capture open", deckOpen = "deck open", deckClose = "deck close",
                             recordStart = "recording start", recordStop = "recording stop" }

    static let poster = OSSignposter(subsystem: "com.kit.drafter", category: "speed")

    /// One running step. `t0`: when the felt wait began (the deck counts from the mouse release).
    struct Mark {
        let step: Step, t0: Date, state: OSSignpostIntervalState

        /// End the step once AppKit has drawn and Core Animation has sent this turn's frame to the screen.
        func drawn(_ note: String = "") { Speed.afterCommit { self.end(note) } }

        func end(_ note: String = "") {
            Speed.close(step, state)
            log("speed: \(step.rawValue) \(Int(Date().timeIntervalSince(t0) * 1000)) ms" + (note.isEmpty ? "" : ", " + note))
        }
    }

    static func begin(_ s: Step, from t0: Date = Date()) -> Mark {
        let id = poster.makeSignpostID()
        let st: OSSignpostIntervalState
        switch s {   // a signpost name must be a static string
        case .captureOpen: st = poster.beginInterval("capture open", id: id)
        case .deckOpen: st = poster.beginInterval("deck open", id: id)
        case .deckClose: st = poster.beginInterval("deck close", id: id)
        case .recordStart: st = poster.beginInterval("recording start", id: id)
        case .recordStop: st = poster.beginInterval("recording stop", id: id)
        }
        return Mark(step: s, t0: t0, state: st)
    }

    private static func close(_ s: Step, _ st: OSSignpostIntervalState) {
        switch s {
        case .captureOpen: poster.endInterval("capture open", st)
        case .deckOpen: poster.endInterval("deck open", st)
        case .deckClose: poster.endInterval("deck close", st)
        case .recordStart: poster.endInterval("recording start", st)
        case .recordStop: poster.endInterval("recording stop", st)
        }
    }

    /// A ghost on screen: `ms` from the request.
    static func ghost(ms: Int) { poster.emitEvent("ghost shown", "\(ms) ms") }

    /// `f` once, at the end of this main run-loop turn, after Core Animation's commit (order 2,000,000). A plain
    /// main-queue block can run before the commit when the queue already holds work, and would read too early.
    /// The observer is added from a run-loop block, so a call from inside another observer still ends this turn.
    static func afterCommit(_ f: @escaping () -> Void) {
        CFRunLoopPerformBlock(CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue) { observe(f) }
        CFRunLoopWakeUp(CFRunLoopGetMain())
    }

    private static func observe(_ f: @escaping () -> Void) {
        var obs: CFRunLoopObserver?
        obs = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.beforeWaiting.rawValue | CFRunLoopActivity.exit.rawValue,
                                                 false, 2_000_001) { _, _ in
            if let o = obs { CFRunLoopRemoveObserver(CFRunLoopGetMain(), o, .commonModes) }
            obs = nil
            f()
        }
        if let o = obs { CFRunLoopAddObserver(CFRunLoopGetMain(), o, .commonModes) }
    }
}

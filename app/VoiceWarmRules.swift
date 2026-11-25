// Background touch of Parakeet (voice warm round, 17 November 2026): the wired limit does not keep its weights paged
// in (presses still paid 312-717 ms on the touch, docs/rounds/2026-11-17-voice-speed-two.md), so while he is active
// the app sends a quiet touch every 4 min (engine frame 251). Pure rule; the timer is VoiceEngine.backgroundTouch.
import Foundation

enum VoiceWarmRules {
    static let every = 240.0        // seconds between touches (and since the last press, which touches by itself)
    static let activeWithin = 1800.0  // any key or mouse in the last 30 min
    static let minFreePct = 20      // kern.memorystatus_level: the system's free memory share, %

    /// Send a background touch now.
    static func due(sinceTouch: Double, sincePress: Double, inputIdle: Double, freePct: Int?, loaded: Bool, talking: Bool) -> Bool {
        guard loaded, !talking, let free = freePct, free >= minFreePct else { return false }
        return inputIdle < activeWithin && sinceTouch >= every && sincePress >= every
    }

    /// The log line for a background touch: ms, CPU, page-ins and the resident share before it.
    static func line(ms: Int, cpu: Int?, pageins: Int?, resident: Int?, footprint: Int?) -> String {
        var s = "voice: background touch \(ms) ms"
        if let c = cpu { s += ", cpu \(c) ms" }
        if let p = pageins { s += ", \(p) page-ins" }
        if let r = resident, let f = footprint { s += ", resident \(r) of \(f) MB before" }
        return s
    }
}

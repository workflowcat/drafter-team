// Audio ducking rules (17 November 2026, pure): when a voice take lowers the Mac's other sounds, to what, and whether
// the volume goes back after it. The CoreAudio side is app/Duck.swift; test tests/duck_rules.swift.
import Foundation

enum DuckRules {
    /// The ducked volume is this share of the volume before the take.
    static let level: Float = 0.3
    /// A volume read back within this of what Drafter set is still Drafter's (the device rounds to its own steps).
    static let tolerance: Float = 0.02
    /// At or below this the output counts as silent: nothing to lower.
    static let silent: Float = 0.001

    /// What the take and the Mac look like when the microphone opens.
    struct Moment: Equatable {
        var on: Bool            // Settings > Voice "Lower other sounds while I speak"
        var long: Bool          // a long note (⇧ Right Option) or a call recording
        var call: Bool          // the take records a call
        var callGoing: Bool     // another app holds the microphone or a call offer is up (CallWatch)
        var muted: Bool         // the output device is muted
        var volume: Float?      // the output volume 0...1; nil = the device has no volume to set
    }

    /// Why not to duck, or nil to duck. The reason goes to the log as is.
    static func skip(_ m: Moment) -> String? {
        if !m.on { return "off" }
        if m.long || m.call { return "long take" }
        if m.callGoing { return "call going on" }
        if m.muted { return "muted" }
        guard let v = m.volume else { return "no volume" }
        if v <= silent { return "silent" }
        return nil
    }

    static func shouldDuck(_ m: Moment) -> Bool { skip(m) == nil }

    /// The volume to set while the user speaks.
    static func target(_ volume: Float) -> Float { max(0, min(1, volume * level)) }

    /// Put the old volume back only when the volume is still what Drafter set: if the user changed it meanwhile, their value
    /// stays. nil `current` (cannot read it) restores: losing the user's music is worse than a missed change.
    static func shouldRestore(current: Float?, set: Float?) -> Bool {
        guard let c = current, let s = set else { return true }
        return abs(c - s) <= tolerance
    }

    /// The log line for a duck, numbers only.
    static func duckLine(from: Float, to: Float) -> String { "duck " + num(from) + " -> " + num(to) }
    static func restoreLine(_ v: Float) -> String { "duck restored " + num(v) }
    static func num(_ v: Float) -> String { String(format: "%.2f", v) }
}

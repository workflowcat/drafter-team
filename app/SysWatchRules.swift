import Foundation

// When to start the Mac's sound again during a call (17 November 2026). In a client demo call the ScreenCaptureKit
// stream kept running and replayd kept counting its audio frames, yet from 22:30 them.wav got holes of 10-20 ms and
// from 24:10 only exact zeros, 3 s after coreaudiod logged an audio IO overload; no error ever reached Drafter, so
// the other side was silently lost for 32 minutes. Meet's own output is never exact zeros for long (its quiet is
// noise), so a long run of exact zeros while the user's mic hears speech means the capture broke. Pure: tests/sys_watch.swift.
struct SysWatch: Equatable {
    /// No samples at all for this long while the stream runs: start it again.
    static let quiet: Double = 20
    /// Only exact zeros for this long...
    static let flat: Double = 60
    /// ...while the mic heard at least this much speech: start it again.
    static let speech: Double = 10
    /// At most one restart in this many seconds.
    static let pause: Double = 120

    enum Act: Equatable { case none, restart(String) }

    var lastSamples: Double
    var lastSound: Double
    var micSpeech: Double = 0          // seconds of mic speech since the Mac last gave a sound
    var lastRestart: Double = -.infinity
    var restarts = 0

    init(at t: Double) { lastSamples = t; lastSound = t }

    /// Samples came from the stream; `sound`: at least one is not exactly zero.
    mutating func samples(at t: Double, sound: Bool) {
        lastSamples = t
        if sound { lastSound = t; micSpeech = 0 }
    }

    /// A stretch of the mic: `secs` long, `loud` when it holds speech.
    mutating func mic(secs: Double, loud: Bool) { if loud { micSpeech += secs } }

    /// Called as the mic's chunks come; `.restart(why)` at most once per `pause`.
    mutating func check(at t: Double) -> Act {
        guard t - lastRestart >= SysWatch.pause else { return .none }
        var why: String?
        let none = t - lastSamples, flat = t - lastSound
        if none >= SysWatch.quiet {
            why = "no sound from the Mac for \(Int(none)) s"
        } else if flat >= SysWatch.flat, micSpeech >= SysWatch.speech {
            why = "only exact zeros from the Mac for \(Int(flat)) s while the mic heard \(Int(micSpeech)) s of speech"
        }
        guard let why else { return .none }
        lastRestart = t; restarts += 1
        lastSamples = t; lastSound = t; micSpeech = 0
        return .restart(why + (restarts > 1 ? " (restart \(restarts))" : ""))
    }
}

enum SysAudioRules {
    /// Float samples of one or more channels -> mono (their mean per frame). `interleaved`: one buffer, channels
    /// side by side; else one buffer per channel.
    static func mono(_ buffers: [[Float]], channels: Int, interleaved: Bool) -> [Float] {
        if interleaved {
            guard let b = buffers.first, channels > 1 else { return buffers.first ?? [] }
            let n = b.count / channels
            var out = [Float](repeating: 0, count: n)
            for i in 0..<n { var s: Float = 0; for c in 0..<channels { s += b[i * channels + c] }; out[i] = s / Float(channels) }
            return out
        }
        guard buffers.count > 1 else { return buffers.first ?? [] }
        let n = buffers.map(\.count).min() ?? 0
        var out = [Float](repeating: 0, count: n)
        for b in buffers { for i in 0..<n { out[i] += b[i] } }
        let k = Float(buffers.count)
        for i in 0..<n { out[i] /= k }
        return out
    }
}

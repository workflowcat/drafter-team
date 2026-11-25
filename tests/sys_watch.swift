// swiftc -parse-as-library app/SysWatchRules.swift tests/sys_watch.swift -o app/build/sys-watch-test && app/build/sys-watch-test
// When the Mac's sound is started again during a call, and mixing its channels to mono.
import Foundation

@main
struct SysWatchTest {
    static var failed = 0
    static func check(_ ok: Bool, _ what: String) { if !ok { failed += 1; print("FAIL: \(what)") } }

    static func main() {
        // samples keep coming with sound: nothing to do
        var w = SysWatch(at: 0)
        for t in stride(from: 1.0, through: 300, by: 1) { w.samples(at: t, sound: true); w.mic(secs: 1, loud: true); check(w.check(at: t) == .none, "alive at \(t)") }

        // no samples for 20 s: restart once, then not again for 120 s
        w = SysWatch(at: 0)
        var acts: [Double] = []
        for t in stride(from: 1.0, through: 200, by: 1) { if case .restart = w.check(at: t) { acts.append(t) } }
        check(acts == [20, 140], "no samples: restart at 20 s, the next 120 s later: \(acts)")

        // exact zeros for 60 s while the mic hears speech (the 17 November call): restart, with the reason
        w = SysWatch(at: 0)
        var why = ""
        for t in stride(from: 1.0, through: 90, by: 1) {
            w.samples(at: t, sound: false); w.mic(secs: 1, loud: true)
            if case .restart(let s) = w.check(at: t) { why = s; check(t == 60, "zeros: restart at 60 s, got \(t)"); break }
        }
        check(why.contains("exact zeros") && why.contains("60 s"), "zeros: says why: \(why)")

        // exact zeros while he is quiet too (nobody talks): no restart
        w = SysWatch(at: 0)
        for t in stride(from: 1.0, through: 300, by: 1) { w.samples(at: t, sound: false); w.mic(secs: 1, loud: false); check(w.check(at: t) == .none, "quiet call at \(t)") }

        // zeros with only 5 s of his speech: no restart; the Mac making a sound clears the count
        w = SysWatch(at: 0)
        for t in stride(from: 1.0, through: 100, by: 1) { w.samples(at: t, sound: t == 50); w.mic(secs: t <= 5 ? 1 : 0, loud: true); check(w.check(at: t) == .none, "little speech at \(t)") }

        // a second restart says which one it is
        w = SysWatch(at: 0)
        var reasons: [String] = []
        for t in stride(from: 1.0, through: 300, by: 1) { if case .restart(let s) = w.check(at: t) { reasons.append(s) } }
        check(reasons.count == 3 && reasons[1].hasSuffix("(restart 2)") && w.restarts == 3, "restarts counted: \(reasons)")

        // mono: interleaved stereo, planar stereo, mono as is
        check(SysAudioRules.mono([[1, 3, 2, 4]], channels: 2, interleaved: true) == [2, 3], "interleaved stereo -> mean")
        check(SysAudioRules.mono([[1, 2], [3, 4]], channels: 2, interleaved: false) == [2, 3], "planar stereo -> mean")
        check(SysAudioRules.mono([[0.5, -0.5]], channels: 1, interleaved: true) == [0.5, -0.5], "mono stays")
        check(SysAudioRules.mono([], channels: 2, interleaved: false) == [], "nothing stays nothing")

        print(failed == 0 ? "sys watch: all passed" : "sys watch: \(failed) failed")
        exit(failed == 0 ? 0 : 1)
    }
}

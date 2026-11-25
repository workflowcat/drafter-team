// swiftc -parse-as-library app/VoiceWarmRules.swift tests/voice_warm_rules.swift -o app/build/voice-warm-test && app/build/voice-warm-test
import Foundation

@main struct VoiceWarmTest {
    static func main() {
        var failed = 0
        func check(_ ok: Bool, _ what: String) { if !ok { failed += 1; print("FAIL:", what) } }
        typealias R = VoiceWarmRules
        func due(touch: Double = 300, press: Double = 300, idle: Double = 10, free: Int? = 50, loaded: Bool = true, talking: Bool = false) -> Bool {
            R.due(sinceTouch: touch, sincePress: press, inputIdle: idle, freePct: free, loaded: loaded, talking: talking)
        }
        check(due(), "active, loaded, 4 min since both, memory free: touch")
        check(!due(touch: 200), "touched under 4 min ago: wait")
        check(!due(press: 100), "a press under 4 min ago touched already: wait")
        check(!due(idle: 1800), "no key or mouse for 30 min: no touch")
        check(due(idle: 1799), "29 min idle still counts as active")
        check(!due(free: 19), "free memory under 20%: no touch")
        check(due(free: 20), "20% free: touch")
        check(!due(free: nil), "free memory unknown: no touch")
        check(!due(loaded: false), "Parakeet not loaded: never load it for a touch")
        check(!due(talking: true), "a take running: no touch")
        check(R.line(ms: 62, cpu: 40, pageins: 0, resident: 1300, footprint: 1310) == "voice: background touch 62 ms, cpu 40 ms, 0 page-ins, resident 1300 of 1310 MB before", R.line(ms: 62, cpu: 40, pageins: 0, resident: 1300, footprint: 1310))
        check(R.line(ms: 5, cpu: nil, pageins: nil, resident: nil, footprint: nil) == "voice: background touch 5 ms", "bare line")
        if failed == 0 { print("voice warm rules: all checks passed") } else { print("\(failed) failed"); exit(1) }
    }
}

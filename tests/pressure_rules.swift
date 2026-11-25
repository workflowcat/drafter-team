// swiftc -parse-as-library app/PressureRules.swift tests/pressure_rules.swift -o app/build/pressure-test && app/build/pressure-test
import Foundation

@main struct PressureTest {
    static func main() {
        var failed = 0
        func check(_ ok: Bool, _ what: String) { if !ok { failed += 1; print("FAIL:", what) } }
        typealias R = PressureRules
        check(!R.yieldText(.normal, typingQuiet: 9999, asleep: false), "normal: never")
        check(!R.yieldText(.warning, typingQuiet: 119, asleep: false), "warning while he typed in the last 2 min: keep it")
        check(R.yieldText(.warning, typingQuiet: 120, asleep: false), "warning, quiet 2 min: sleep")
        check(!R.yieldText(.critical, typingQuiet: 14, asleep: false), "critical while typing: keep it")
        check(R.yieldText(.critical, typingQuiet: 15, asleep: false), "critical, quiet 15 s: sleep")
        check(!R.yieldText(.critical, typingQuiet: 999, asleep: true), "already asleep: nothing")
        if failed == 0 { print("pressure rules: all checks passed") } else { print("\(failed) failed"); exit(1) }
    }
}

import Foundation

// swiftc -O -parse-as-library app/DuckRules.swift tests/duck_rules.swift -o app/build/duck-rules-test && app/build/duck-rules-test
// Audio ducking rules (17 November 2026): when to lower the Mac's sound, to what, when to put it back. Made-up values.
@main struct DuckRulesTest {
    static var failures = 0
    static func check(_ ok: Bool, _ what: String) { if !ok { failures += 1; print("FAIL \(what)") } }

    static func main() {
        typealias M = DuckRules.Moment
        let base = M(on: true, long: false, call: false, callGoing: false, muted: false, volume: 0.6)
        func with(_ f: (inout M) -> Void) -> M { var m = base; f(&m); return m }
        let cases: [(M, String?, String)] = [
            (base, nil, "push to talk with music on ducks"),
            (with { $0.on = false }, "off", "setting off"),
            (with { $0.long = true }, "long take", "long note"),
            (with { $0.long = true; $0.call = true }, "long take", "call recording"),
            (with { $0.call = true }, "long take", "call flag alone"),
            (with { $0.callGoing = true }, "call going on", "another app holds a call"),
            (with { $0.muted = true }, "muted", "output muted"),
            (with { $0.volume = 0 }, "silent", "volume at 0"),
            (with { $0.volume = 0.0005 }, "silent", "volume almost 0"),
            (with { $0.volume = nil }, "no volume", "device without volume"),
            (with { $0.volume = 1 }, nil, "full volume ducks"),
            (with { $0.on = false; $0.muted = true }, "off", "off wins over muted"),
        ]
        for (m, want, what) in cases {
            check(DuckRules.skip(m) == want, "\(what): \(DuckRules.skip(m) ?? "duck")")
            check(DuckRules.shouldDuck(m) == (want == nil), "\(what): shouldDuck")
        }

        let targets: [(Float, Float)] = [(1, 0.3), (0.6, 0.18), (0.5, 0.15), (0.1, 0.03), (0, 0), (1.4, 0.42)]
        for (v, want) in targets {
            check(abs(DuckRules.target(v) - min(1, want)) < 0.0001, "target \(v) -> \(DuckRules.target(v))")
        }
        check(DuckRules.level == 0.3, "level is 30%")

        let restores: [(Float?, Float?, Bool, String)] = [
            (0.18, 0.18, true, "unchanged"),
            (0.1875, 0.18, true, "device step rounding"),
            (0.17, 0.18, true, "just inside the tolerance"),
            (0.25, 0.18, false, "he turned it up"),
            (0.05, 0.18, false, "he turned it down"),
            (0, 0.18, false, "he turned it off"),
            (nil, 0.18, true, "cannot read: restore"),
            (0.18, nil, true, "no set value (old crash save): restore"),
        ]
        for (cur, set, want, what) in restores {
            check(DuckRules.shouldRestore(current: cur, set: set) == want, "restore: \(what)")
        }

        check(DuckRules.duckLine(from: 0.62, to: DuckRules.target(0.62)) == "duck 0.62 -> 0.19", DuckRules.duckLine(from: 0.62, to: DuckRules.target(0.62)))
        check(DuckRules.restoreLine(0.62) == "duck restored 0.62", "restore line")

        print(failures == 0 ? "duck rules: all passed" : "duck rules: \(failures) failed")
        exit(failures == 0 ? 0 : 1)
    }
}

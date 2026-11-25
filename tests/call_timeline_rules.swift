import Foundation

// swiftc -parse-as-library app/CallTimelineRules.swift tests/call_timeline_rules.swift -o app/build/call-timeline-rules-test && app/build/call-timeline-rules-test
// Synthetic test cases only.
@main
struct CallTimelineRulesTest {
    static var failed = 0, ran = 0
    static func check(_ ok: Bool, _ what: String) {
        ran += 1
        if !ok { failed += 1; print("FAIL", what) }
    }

    static func main() {
        typealias R = CallTimelineRules

        // nearestTurnID: empty / untimed
        check(R.nearestTurnID(at: 10, turns: []) == nil, "empty turns -> nil")
        check(R.nearestTurnID(at: 10, turns: [(0, nil), (1, nil)]) == nil, "all untimed -> nil")
        check(R.nearestTurnID(at: .nan, turns: [(0, 5.0)]) == nil, "NaN second -> nil")
        check(R.nearestTurnID(at: .infinity, turns: [(0, 5.0)]) == nil, "infinity second -> nil")

        // nearestTurnID: normal ordered turns
        let turns: [(id: Int, start: Double?)] = [(10, 12.0), (11, 25.5), (12, 48.0), (13, 90.0)]
        check(R.nearestTurnID(at: 0.0, turns: turns) == 10, "before first turn picks earliest")
        check(R.nearestTurnID(at: 11.9, turns: turns) == 10, "just before first turn picks earliest")
        check(R.nearestTurnID(at: 12.0, turns: turns) == 10, "exact match on first turn")
        check(R.nearestTurnID(at: 20.0, turns: turns) == 10, "between first and second picks last <= second")
        check(R.nearestTurnID(at: 25.5, turns: turns) == 11, "exact match on middle turn")
        check(R.nearestTurnID(at: 47.9, turns: turns) == 11, "just before third picks second")
        check(R.nearestTurnID(at: 120.0, turns: turns) == 13, "past last turn picks last")

        // nearestTurnID: mixed nil starts, unsorted order, duplicate starts
        let mixed: [(id: Int, start: Double?)] = [(0, nil), (1, 30.0), (2, nil), (3, 10.0), (4, 10.0), (5, .nan)]
        check(R.nearestTurnID(at: 5.0, turns: mixed) == 3, "before earliest in unsorted/mixed picks earliest")
        check(R.nearestTurnID(at: 10.0, turns: mixed) == 4, "duplicate start picks last matching turn")
        check(R.nearestTurnID(at: 29.0, turns: mixed) == 4, "between 10 and 30 picks 4")
        check(R.nearestTurnID(at: 35.0, turns: mixed) == 1, "after 30 picks 1")

        // formatOffset
        check(R.formatOffset(0) == "00:00", "0s -> 00:00")
        check(R.formatOffset(-5) == "00:00", "negative -> 00:00")
        check(R.formatOffset(.nan) == "00:00", "NaN -> 00:00")
        check(R.formatOffset(.infinity) == "00:00", "infinity -> 00:00")
        check(R.formatOffset(-.infinity) == "00:00", "-infinity -> 00:00")
        check(R.formatOffset(7) == "00:07", "7s -> 00:07")
        check(R.formatOffset(65) == "01:05", "65s -> 01:05")
        check(R.formatOffset(599.6) == "10:00", "rounding to 10:00")
        check(R.formatOffset(3599) == "59:59", "3599s -> 59:59")
        check(R.formatOffset(3600) == "1:00:00", "3600s -> 1:00:00")
        check(R.formatOffset(3661) == "1:01:01", "3661s -> 1:01:01")
        check(R.formatOffset(36000) == "10:00:00", "10h -> 10:00:00")

        // progress
        check(R.progress(at: 0, total: 100) == 0.0, "start -> 0")
        check(R.progress(at: 50, total: 100) == 0.5, "half -> 0.5")
        check(R.progress(at: 100, total: 100) == 1.0, "end -> 1")
        check(R.progress(at: -10, total: 100) == 0.0, "negative clamped to 0")
        check(R.progress(at: 150, total: 100) == 1.0, "over total clamped to 1")
        check(R.progress(at: 10, total: 0) == 0.0, "zero total -> 0")
        check(R.progress(at: 10, total: -5) == 0.0, "negative total -> 0")
        check(R.progress(at: .nan, total: 100) == 0.0, "NaN second -> 0")
        check(R.progress(at: 10, total: .nan) == 0.0, "NaN total -> 0")
        check(R.progress(at: 10, total: .infinity) == 0.0, "infinite total -> 0")

        print(failed == 0 ? "call timeline rules: \(ran) ok" : "call timeline rules: \(failed) of \(ran) failed")
        exit(failed == 0 ? 0 : 1)
    }
}

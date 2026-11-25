// Pure timeline math for call recordings: matching screenshot offsets to transcript turns,
// formatting offsets, and computing clamped timeline progress.
// Pure Foundation: compiles standalone for tests/call_timeline_rules.swift.
import Foundation

enum CallTimelineRules {
    /// Finds the nearest transcript turn to `second`:
    /// prefers the last timed turn starting at or before `second`;
    /// if `second` is before all timed turns, returns the earliest timed turn;
    /// returns `nil` if there are no timed turns or `second` is not finite.
    static func nearestTurnID(at second: Double, turns: [(id: Int, start: Double?)]) -> Int? {
        guard second.isFinite else { return nil }
        var beforeID: Int?
        var beforeStart = -Double.infinity
        var earliestID: Int?
        var earliestStart = Double.infinity

        for turn in turns {
            guard let start = turn.start, start.isFinite else { continue }
            if start <= second, start >= beforeStart {
                beforeStart = start
                beforeID = turn.id
            }
            if start < earliestStart {
                earliestStart = start
                earliestID = turn.id
            }
        }
        return beforeID ?? earliestID
    }

    /// Formats a second offset as `MM:SS` (under 1 hour) or `H:MM:SS` (1 hour or more).
    /// Negative, NaN, and infinite values clamp cleanly to `"00:00"`.
    static func formatOffset(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return "00:00" }
        let clamped = min(seconds, Double(Int.max / 2))
        let total = Int(clamped.rounded())
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, s)
        }
        return String(format: "%02d:%02d", m, s)
    }

    /// Normalized timeline position in `0...1`. Non-finite or non-positive totals return `0`.
    static func progress(at second: Double, total: Double) -> Double {
        guard second.isFinite, total.isFinite, total > 0 else { return 0 }
        return min(1.0, max(0.0, second / total))
    }
}

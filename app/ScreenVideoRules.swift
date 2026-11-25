// Local screen video: privacy, even H.264 sizes, sparse frames and bounded storage.
import Foundation

enum ScreenVideoRules {
    static let maxBytes = 250_000_000
    static let maxDurationSeconds = 4.0 * 60 * 60

    static func shouldSkipFrame(frontApp: String, bundleID: String, skipList: [String],
                                screenLocked: Bool, displayAsleep: Bool, secureInput: Bool) -> Bool {
        screenLocked || displayAsleep || secureInput || skipList.contains {
            !$0.isEmpty && ($0.caseInsensitiveCompare(frontApp) == .orderedSame || $0.caseInsensitiveCompare(bundleID) == .orderedSame)
        }
    }

    /// Round down to even pixels. Invalid sizes return zero; rounding costs at most two pixels per axis.
    static func clampedDimensions(width: Int, height: Int, maxWidth: Int = 1280) -> (width: Int, height: Int) {
        guard width > 0, height > 0, maxWidth >= 2 else { return (0, 0) }
        let scale = min(1, Double(maxWidth - maxWidth % 2) / Double(width))
        func even(_ value: Double) -> Int {
            if value >= Double(Int.max - 1) { return Int.max - 1 }
            return max(2, Int(value / 2) * 2)
        }
        return (even(Double(width) * scale), even(Double(height) * scale))
    }

    static func shouldAppendFrame(elapsed: Double, lastFrameAt: Double?, diff: Double,
                                  minInterval: Double = 1, maxGap: Double = 5, diffThreshold: Double = 0.015) -> Bool {
        guard elapsed.isFinite, elapsed >= 0, minInterval.isFinite, minInterval > 0,
              maxGap.isFinite, maxGap >= minInterval, diffThreshold.isFinite, diffThreshold >= 0 else { return false }
        guard let lastFrameAt else { return true }
        guard lastFrameAt.isFinite, lastFrameAt >= 0 else { return false }
        let gap = elapsed - lastFrameAt
        return gap >= minInterval && (gap >= maxGap || (diff.isFinite && diff >= diffThreshold))
    }

    static func clampedVideoTime(target: Double, videoDuration: Double) -> Double {
        guard videoDuration.isFinite, videoDuration > 0, !target.isNaN else { return 0 }
        return min(videoDuration, max(0, target))
    }

    static func canAppend(writtenBytes: Int, elapsed: Double) -> Bool {
        writtenBytes >= 0 && writtenBytes < maxBytes && elapsed.isFinite && elapsed >= 0 && elapsed < maxDurationSeconds
    }
}

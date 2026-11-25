// Pure timeline math and local video discovery for the meeting studio.
import Foundation

struct SpeakerBar: Equatable, Identifiable {
    let id: Int
    let isMe: Bool
    let startFrac: Double
    let endFrac: Double
    let turnID: Int
    let startSec: Double
}

enum CallStudioRules {
    /// Original index of the latest finite timestamp. Equal timestamps prefer the last frame.
    static func activeShotIndex(at second: Double, shotTimes: [Double]) -> Int? {
        CallTimelineRules.nearestTurnID(at: second, turns: shotTimes.enumerated().map { ($0.offset, $0.element) })
    }

    /// An absent selection starts at the first frame. Even extreme deltas cannot overflow.
    static func stepShot(current: Int?, delta: Int, count: Int) -> Int? {
        guard count > 0 else { return nil }
        let base = min(count - 1, max(0, current ?? 0))
        if delta > 0 { return base + min(delta, count - 1 - base) }
        return base + max(delta, -base)
    }

    static func isMe(_ who: String) -> Bool { who == "\u{042F}" || who == "me" }

    /// Untimed/invalid turns do not invent activity. Sort stably, clip to the recording, and
    /// leave long silences empty rather than painting a speaker across the whole gap.
    static func speakerSegments(turns: [(id: Int, who: String, start: Double?)], totalSecs: Double) -> [SpeakerBar] {
        guard totalSecs.isFinite, totalSecs > 0 else { return [] }
        let timed = turns.enumerated().compactMap { index, turn -> (index: Int, id: Int, who: String, start: Double)? in
            guard let start = turn.start, start.isFinite, start < totalSecs else { return nil }
            return (index, turn.id, turn.who, max(0, start))
        }.sorted { $0.start == $1.start ? $0.index < $1.index : $0.start < $1.start }
        return timed.enumerated().compactMap { i, turn in
            let next = i + 1 < timed.count ? timed[i + 1].start : totalSecs
            let end = min(totalSecs, next, turn.start + 25)
            guard end > turn.start else { return nil }
            return SpeakerBar(id: turn.index, isMe: isMe(turn.who), startFrac: turn.start / totalSecs,
                              endFrac: end / totalSecs, turnID: turn.id, startSec: turn.start)
        }
    }

    static func seekTime(fraction: Double, totalSecs: Double) -> Double {
        guard totalSecs.isFinite, totalSecs > 0, !fraction.isNaN else { return 0 }
        return min(1, max(0, fraction)) * totalSecs
    }

    static func videoEnded(at second: Double, duration: Double) -> Bool {
        second.isFinite && duration.isFinite && duration > 0 && second >= duration
    }

    /// The audio clock remains authoritative after the last video sample, and during a drag no observer may seek.
    static func videoNeedsSync(audioTime: Double, videoTime: Double, videoDuration: Double, scrubbing: Bool, seeking: Bool) -> Bool {
        guard !scrubbing, !seeking, audioTime.isFinite, videoTime.isFinite, videoDuration.isFinite, videoDuration > 0 else { return false }
        return abs(ScreenVideoRules.clampedVideoTime(target: audioTime, videoDuration: videoDuration) - videoTime) > 0.35
    }

    static let playbackRates: [Float] = [1.0, 1.25, 1.5, 2.0]
    static func formatRate(_ r: Float) -> String {
        guard r.isFinite, r > 0 else { return "1×" }
        return String(format: "%g×", locale: Locale(identifier: "en_US_POSIX"), Double(r))
    }

    static func detectVideoFile(in dir: URL) -> URL? {
        for name in ["screen.mp4", "screen.mov", "video.mp4", "recording.mp4", "recording.mov"] {
            let url = dir.appendingPathComponent(name)
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue { return url }
        }
        return nil
    }
}

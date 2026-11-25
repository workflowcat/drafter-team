// swiftc -parse-as-library app/CallTimelineRules.swift app/CallStudioRules.swift app/ScreenVideoRules.swift tests/call_studio_rules.swift -o app/build/call-studio-rules-test && app/build/call-studio-rules-test
import Foundation

@main
struct CallStudioRulesTest {
    static var ran = 0
    static func check(_ ok: Bool, _ message: String) {
        ran += 1
        if !ok { print("FAIL: \(message)"); exit(1) }
    }
    static func near(_ a: Double, _ b: Double) -> Bool { abs(a - b) < 0.000001 }

    static func main() throws {
        typealias R = CallStudioRules
        check(R.activeShotIndex(at: 0, shotTimes: []) == nil, "no shots")
        let shots = [12.0, 40, 60]
        for (t, i) in [(-10.0, 0), (0, 0), (12, 0), (39.9, 0), (40, 1), (59.9, 1), (60, 2), (900, 2)] {
            check(R.activeShotIndex(at: t, shotTimes: shots) == i, "active at \(t)")
        }
        for t in [Double.nan, .infinity, -.infinity] {
            check(R.activeShotIndex(at: t, shotTimes: shots) == nil, "invalid playhead")
        }
        check(R.activeShotIndex(at: 30, shotTimes: [.nan, .infinity]) == nil, "invalid frames")
        check(R.activeShotIndex(at: 30, shotTimes: [40, .nan, 12, 12]) == 3, "unsorted duplicate frames")
        check(R.activeShotIndex(at: 0, shotTimes: [.nan, 12]) == 1, "first valid frame")
        check(R.stepShot(current: nil, delta: 1, count: 0) == nil, "empty stepping")
        check(R.stepShot(current: 0, delta: 1, count: -1) == nil, "negative count")
        check(R.stepShot(current: nil, delta: 0, count: 3) == 0, "initial frame")
        check(R.stepShot(current: nil, delta: 1, count: 3) == 1, "next from initial")
        check(R.stepShot(current: nil, delta: -1, count: 3) == 0, "previous from initial")
        check(R.stepShot(current: 1, delta: 1, count: 3) == 2, "next")
        check(R.stepShot(current: 1, delta: -1, count: 3) == 0, "previous")
        check(R.stepShot(current: 2, delta: 1, count: 3) == 2, "last frame clamps")
        check(R.stepShot(current: -20, delta: -1, count: 3) == 0, "invalid low index")
        check(R.stepShot(current: 20, delta: 1, count: 3) == 2, "invalid high index")
        check(R.stepShot(current: Int.max, delta: Int.max, count: Int.max) == Int.max - 1, "positive overflow")
        check(R.stepShot(current: Int.min, delta: Int.min, count: Int.max) == 0, "negative overflow")
        check(R.stepShot(current: 0, delta: Int.max, count: 1) == 0, "single frame")

        let turns: [(id: Int, who: String, start: Double?)] = [(10, "me", 0), (11, "guest", 10), (12, "\u{042F}", 60)]
        let bars = R.speakerSegments(turns: turns, totalSecs: 80)
        check(bars.count == 3, "three speaker bars")
        check(bars.map(\.isMe) == [true, false, true], "both own speaker labels")
        check(bars.map(\.turnID) == [10, 11, 12], "turn identity preserved")
        check(bars.map(\.startSec) == [0, 10, 60], "start seconds preserved")
        check(bars[0] == SpeakerBar(id: 0, isMe: true, startFrac: 0, endFrac: 0.125, turnID: 10, startSec: 0), "first interval")
        check(near(bars[1].endFrac, 35.0 / 80), "long gap capped at 25s")
        check(bars[2].endFrac == 1, "last interval ends at duration")
        for total in [0.0, -1, .nan, .infinity] {
            check(R.speakerSegments(turns: turns, totalSecs: total).isEmpty, "invalid duration")
        }
        check(R.speakerSegments(turns: [], totalSecs: 50).isEmpty, "empty transcript")
        let mixed: [(id: Int, who: String, start: Double?)] = [
            (1, "guest", nil), (2, "guest", .nan), (3, "guest", .infinity), (4, "me", 100),
            (5, "me", 80), (6, "guest", 20), (7, "me", -3), (8, "guest", 20)]
        let clean = R.speakerSegments(turns: mixed, totalSecs: 80)
        check(clean.map(\.turnID) == [7, 8], "invalid/end starts removed; duplicate keeps last")
        check(clean[0].startSec == 0 && clean[0].endFrac == 0.25, "negative start clipped")
        check(Set(clean.map(\.id)).count == clean.count, "stable unique bar identity")
        check(R.speakerSegments(turns: [(0, "", 0)], totalSecs: 4).first?.endFrac == 1, "short recording")
        // Deterministic synthetic sweep: all intervals finite, positive, normalized, and bounded.
        for n in 1...40 {
            let input: [(id: Int, who: String, start: Double?)] = (0..<n).map { i in
                (id: i, who: i % 2 == 0 ? "me" : "guest", start: Double(i * 7 - 10))
            }
            let result = R.speakerSegments(turns: Array(input.reversed()), totalSecs: 120)
            check(result.allSatisfy { $0.startFrac.isFinite && $0.endFrac.isFinite && $0.startFrac >= 0 && $0.endFrac <= 1 && $0.endFrac > $0.startFrac && ($0.endFrac - $0.startFrac) * 120 <= 25.000001 }, "normalized sweep \(n)")
        }

        for (fraction, expected) in [(-1.0, 0.0), (0, 0), (0.25, 20), (1, 80), (9, 80), (.infinity, 80), (-.infinity, 0)] {
            check(R.seekTime(fraction: fraction, totalSecs: 80) == expected, "seek \(fraction)")
        }
        check(R.seekTime(fraction: .nan, totalSecs: 80) == 0, "NaN fraction")
        for total in [0.0, -3, .nan, .infinity] { check(R.seekTime(fraction: 0.5, totalSecs: total) == 0, "invalid seek total") }
        check(R.playbackRates == [1, 1.25, 1.5, 2], "rates")
        check(R.playbackRates.map(R.formatRate) == ["1×", "1.25×", "1.5×", "2×"], "rate labels")
        check(R.formatRate(.nan) == "1×", "invalid rate")

        check(ScreenVideoRules.clampedVideoTime(target: 90, videoDuration: 30) == 30, "audio beyond short video clamps independently")
        check(ScreenVideoRules.clampedVideoTime(target: 12, videoDuration: 30) == 12, "in-range seek unchanged")
        check(!R.videoEnded(at: 29.9, duration: 30), "video still playing")
        check(R.videoEnded(at: 30, duration: 30) && R.videoEnded(at: 90, duration: 30), "video end indicator")
        check(!R.videoEnded(at: 90, duration: 0), "unloaded video is not ended")
        check(!R.videoEnded(at: .nan, duration: 30) && !R.videoEnded(at: 90, duration: .infinity), "invalid end state")
        check(R.videoNeedsSync(audioTime: 90, videoTime: 20, videoDuration: 30, scrubbing: false, seeking: false), "short video seeks its end")
        check(!R.videoNeedsSync(audioTime: 90, videoTime: 30, videoDuration: 30, scrubbing: false, seeking: false), "ended video does not repeatedly seek")
        check(!R.videoNeedsSync(audioTime: 12, videoTime: 1, videoDuration: 30, scrubbing: true, seeking: false), "drag suppresses clock correction")
        check(!R.videoNeedsSync(audioTime: 12, videoTime: 1, videoDuration: 30, scrubbing: false, seeking: true), "in-flight seek suppresses clock correction")
        check(!R.videoNeedsSync(audioTime: 12, videoTime: 12.2, videoDuration: 30, scrubbing: false, seeking: false), "small drift allowed")
        check(R.videoNeedsSync(audioTime: 12, videoTime: 13, videoDuration: 30, scrubbing: false, seeking: false), "large drift corrected")
        check(!R.videoNeedsSync(audioTime: .nan, videoTime: 1, videoDuration: 30, scrubbing: false, seeking: false), "invalid audio clock")
        check(!R.videoNeedsSync(audioTime: 12, videoTime: 1, videoDuration: 0, scrubbing: false, seeking: false), "unknown duration waits")

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("studio-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        check(R.detectVideoFile(in: dir) == nil, "empty folder")
        try Data().write(to: dir.appendingPathComponent("other.mp4"))
        check(R.detectVideoFile(in: dir) == nil, "unrecognized file ignored")
        for name in ["recording.mov", "recording.mp4", "video.mp4", "screen.mov", "screen.mp4"] {
            try Data().write(to: dir.appendingPathComponent(name))
            check(R.detectVideoFile(in: dir)?.lastPathComponent == name, "file precedence \(name)")
        }
        let nested = dir.appendingPathComponent("nested")
        try FileManager.default.createDirectory(at: nested.appendingPathComponent("screen.mp4"), withIntermediateDirectories: true)
        check(R.detectVideoFile(in: nested) == nil, "directory is not a video")
        check(R.detectVideoFile(in: dir.appendingPathComponent("absent")) == nil, "missing folder")
        print("call studio rules: \(ran) ok")
    }
}

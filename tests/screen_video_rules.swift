// swiftc -swift-version 5 -parse-as-library app/ScreenVideoRules.swift app/ScreenVideoWriter.swift tests/screen_video_rules.swift -o app/build/screen-video-rules-test && app/build/screen-video-rules-test
import Foundation
import AVFoundation
import CoreGraphics

@main
struct ScreenVideoChecks {
    static var ran = 0
    static func check(_ ok: Bool, _ message: String) {
        ran += 1
        if !ok { print("FAIL: \(message)"); exit(1) }
    }

    static func rules() {
        typealias R = ScreenVideoRules
        func skip(_ app: String = "Writer", _ bundle: String = "com.example.writer", _ list: [String] = [],
                  locked: Bool = false, asleep: Bool = false, secure: Bool = false) -> Bool {
            R.shouldSkipFrame(frontApp: app, bundleID: bundle, skipList: list, screenLocked: locked, displayAsleep: asleep, secureInput: secure)
        }
        check(!skip(), "ordinary app allowed")
        check(skip("Writer", "com.example.writer", ["WRITER"]), "case-insensitive app name")
        check(skip("Writer", "com.example.writer", ["COM.EXAMPLE.WRITER"]), "case-insensitive bundle")
        check(!skip("Writer", "com.example.writer", ["write", "com.example"]), "exact match, not substring")
        check(!skip("", "", [""]), "empty exclusion ignored")
        check(skip(locked: true) && skip(asleep: true) && skip(secure: true), "all privacy guards independently block")
        check(R.clampedDimensions(width: 1920, height: 1080) == (1280, 720), "1080p downscaled")
        check(R.clampedDimensions(width: 1601, height: 901) == (1280, 720), "odd source becomes even")
        check(R.clampedDimensions(width: 801, height: 601) == (800, 600), "small odd frame")
        check(R.clampedDimensions(width: 800, height: 1200) == (800, 1200), "portrait aspect kept")
        check(R.clampedDimensions(width: 1920, height: 1080, maxWidth: 641) == (640, 360), "odd cap")
        check(R.clampedDimensions(width: 0, height: 40) == (0, 0), "empty frame rejected")
        check(R.clampedDimensions(width: 40, height: -1) == (0, 0), "negative frame rejected")
        check(R.clampedDimensions(width: 40, height: 40, maxWidth: 1) == (0, 0), "invalid width cap")
        check(R.clampedDimensions(width: 1, height: 1) == (2, 2), "minimum encoder dimensions")
        check(R.clampedDimensions(width: Int.max, height: Int.max) == (1280, 1280), "extreme dimensions cannot overflow")
        for width in stride(from: 300, through: 2500, by: 71) {
            let height = width * 9 / 16, size = R.clampedDimensions(width: width, height: height)
            check(size.width <= 1280 && size.width % 2 == 0 && size.height % 2 == 0, "even bounded sweep")
            check(abs(Double(size.width) / Double(size.height) - Double(width) / Double(height)) < 0.03, "aspect ratio within pixel rounding")
        }
        check(R.shouldAppendFrame(elapsed: 0, lastFrameAt: nil, diff: 0), "first frame")
        check(!R.shouldAppendFrame(elapsed: 0.99, lastFrameAt: 0, diff: 1), "at most one fps")
        check(R.shouldAppendFrame(elapsed: 1, lastFrameAt: 0, diff: 0.015), "threshold includes boundary")
        check(!R.shouldAppendFrame(elapsed: 1, lastFrameAt: 0, diff: 0.014), "small change ignored")
        check(!R.shouldAppendFrame(elapsed: 4.99, lastFrameAt: 0, diff: 0), "still screen waits")
        check(R.shouldAppendFrame(elapsed: 5, lastFrameAt: 0, diff: 0), "keep-alive at five seconds")
        check(!R.shouldAppendFrame(elapsed: 5, lastFrameAt: 5, diff: 1), "paused audio clock does not append")
        check(!R.shouldAppendFrame(elapsed: 4, lastFrameAt: 5, diff: 1), "backward clock rejected")
        for bad in [Double.nan, .infinity, -.infinity, -1] {
            check(!R.shouldAppendFrame(elapsed: bad, lastFrameAt: nil, diff: 1), "invalid timestamp")
            check(!R.canAppend(writtenBytes: 0, elapsed: bad), "invalid cap timestamp")
        }
        check(!R.shouldAppendFrame(elapsed: 1, lastFrameAt: 0, diff: .nan), "NaN difference ignored")
        check(R.shouldAppendFrame(elapsed: 5, lastFrameAt: 0, diff: .nan), "keep-alive independent of difference")
        check(R.shouldAppendFrame(elapsed: 2, lastFrameAt: 0, diff: 0, minInterval: 2, maxGap: 2), "custom cadence")
        check(!R.shouldAppendFrame(elapsed: 2, lastFrameAt: 0, diff: 1, minInterval: 0), "invalid cadence")
        check(R.clampedVideoTime(target: -1, videoDuration: 10) == 0, "negative seek")
        check(R.clampedVideoTime(target: 3, videoDuration: 10) == 3, "normal seek")
        check(R.clampedVideoTime(target: 20, videoDuration: 10) == 10, "short video")
        check(R.clampedVideoTime(target: .infinity, videoDuration: 10) == 10, "infinite forward seek")
        check(R.clampedVideoTime(target: .nan, videoDuration: 10) == 0, "NaN seek")
        for bad in [Double.nan, .infinity, -1, 0] {
            check(R.clampedVideoTime(target: 20, videoDuration: bad) == 0, "invalid duration")
        }
        check(R.maxBytes == 250_000_000 && R.maxDurationSeconds == 14400, "default safety limits")
        check(R.canAppend(writtenBytes: R.maxBytes - 1, elapsed: R.maxDurationSeconds - 0.01), "just below limits")
        check(!R.canAppend(writtenBytes: R.maxBytes, elapsed: 1), "byte boundary stops")
        check(!R.canAppend(writtenBytes: 1, elapsed: R.maxDurationSeconds), "duration boundary stops")
        check(!R.canAppend(writtenBytes: -1, elapsed: 0), "invalid byte count")
    }

    static func frame(_ white: Bool, width: Int = 1601, height: Int = 901) -> CGImage {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(CGColor(gray: white ? 1 : 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()!
    }

    static func append(_ writer: ScreenVideoWriter, _ image: CGImage, _ t: Double, allowed: @escaping () -> Bool = { true }) async -> ScreenVideoWriter.AppendResult {
        await withCheckedContinuation { continuation in
            writer.append(image, at: t, allowed: allowed) { continuation.resume(returning: $0) }
        }
    }
    static func stop(_ writer: ScreenVideoWriter, _ t: Double) async -> Bool {
        await withCheckedContinuation { continuation in writer.stop(at: t) { continuation.resume(returning: $0) } }
    }

    @MainActor static func roundTrip() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("screen-video-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let black = frame(false), white = frame(true), writer = ScreenVideoWriter(recording: dir)
        let first = await append(writer, black, 0)
        check(first == .appended, "real writer accepts first frame")
        check(!FileManager.default.fileExists(atPath: writer.url.path), "Call Studio cannot open an unfinished movie")
        check(await append(writer, white, 0.5) == .skipped, "real writer enforces fps")
        check(await append(writer, white, 1) == .appended, "real writer keeps changed screen")
        check(await append(writer, white, 2) == .skipped, "real writer drops unchanged screen")
        check(await append(writer, black, 3, allowed: { false }) == .skipped, "private frame never appended")
        check(await append(writer, white, 6) == .appended, "real writer keeps still-frame heartbeat")
        check(await stop(writer, 7), "finishWriting succeeds")
        check(await stop(writer, 7), "stop is idempotent")
        check(await append(writer, black, 8) == .stopped, "late callbacks cannot write after stop")
        let asset = AVURLAsset(url: writer.url)
        let duration = try await asset.load(.duration).seconds
        check(abs(duration - 7) < 0.05, "video duration follows audio stop, got \(duration)")
        let tracks = try await asset.loadTracks(withMediaType: .video)
        check(tracks.count == 1, "one real H.264 track")
        let size = try await tracks[0].load(.naturalSize)
        check(size == CGSize(width: 1280, height: 720), "encoded dimensions are even")
        let descriptions = try await tracks[0].load(.formatDescriptions)
        check(descriptions.first.map { CMFormatDescriptionGetMediaSubType($0) } == kCMVideoCodecType_H264, "encoded codec is H.264")
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: tracks[0], outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        reader.add(output); check(reader.startReading(), "decoder starts")
        var times: [Double] = [], levels: [UInt8] = []
        while let sample = output.copyNextSampleBuffer() {
            times.append(CMSampleBufferGetPresentationTimeStamp(sample).seconds)
            if let pixels = CMSampleBufferGetImageBuffer(sample) {
                CVPixelBufferLockBaseAddress(pixels, .readOnly)
                let offset = (CVPixelBufferGetHeight(pixels) / 2) * CVPixelBufferGetBytesPerRow(pixels) + (CVPixelBufferGetWidth(pixels) / 2) * 4
                levels.append(CVPixelBufferGetBaseAddress(pixels)!.advanced(by: offset).load(as: UInt8.self))
                CVPixelBufferUnlockBaseAddress(pixels, .readOnly)
            }
        }
        check(reader.status == .completed, "all encoded frames decode")
        check(times.count == 3 && zip(times, [0.0, 1, 6]).allSatisfy { abs($0 - $1) < 0.01 }, "sparse timestamps survive round trip: \(times)")
        check(levels.count == 3 && levels[0] < 20 && levels[1] > 235 && levels[2] > 235, "private black frame absent from decoded video: \(levels)")
        let player = AVPlayer(playerItem: AVPlayerItem(asset: asset))
        player.isMuted = true
        for _ in 0..<100 where player.currentItem?.status == .unknown { try await Task.sleep(nanoseconds: 20_000_000) }
        check(player.currentItem?.status == .readyToPlay, "AVPlayer loads completed screen.mp4")
        for target in [1.0, 90, 2] {
            let at = ScreenVideoRules.clampedVideoTime(target: target, videoDuration: duration)
            let sought = await player.seek(to: CMTime(seconds: at, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
            check(sought && abs(player.currentTime().seconds - at) < 0.05, "AVPlayer clamped seek \(target)")
        }
        player.pause(); player.replaceCurrentItem(with: nil)

        let delayedDir = dir.appendingPathComponent("delayed")
        try FileManager.default.createDirectory(at: delayedDir, withIntermediateDirectories: true)
        let delayed = ScreenVideoWriter(recording: delayedDir)
        check(await append(delayed, black, 4) == .appended, "first safe frame may arrive after audio started")
        check(await append(delayed, white, 4) == .skipped, "pause leaves audio timestamp unchanged")
        check(await append(delayed, frame(true, width: 900, height: 1600), 5) == .appended, "display changes keep original encoder dimensions")
        async let closed = stop(delayed, 6)
        async let closedAgain = stop(delayed, 6)
        let results = await (closed, closedAgain)
        check(results.0 && results.1, "concurrent stop callers both complete")
        let delayedAsset = AVURLAsset(url: delayed.url)
        check(abs(try await delayedAsset.load(.duration).seconds - 6) < 0.05, "late first frame preserves the audio origin")
        let delayedTrack = try await delayedAsset.loadTracks(withMediaType: .video)[0]
        // Encoded media samples start at zero; the MP4 edit list places them on the audio timeline.
        let segments = try await delayedTrack.load(.segments)
        let firstContent = segments.first { !$0.isEmpty }?.timeMapping.target.start.seconds
        check(firstContent.map { abs($0 - 4) < 0.05 } == true,
              "first visible segment starts at audio second four: \(segments.map { ($0.isEmpty, $0.timeMapping.target.start.seconds, $0.timeMapping.target.duration.seconds) })")

        let emptyDir = dir.appendingPathComponent("empty")
        try FileManager.default.createDirectory(at: emptyDir, withIntermediateDirectories: true)
        let empty = ScreenVideoWriter(recording: emptyDir)
        check(await append(empty, black, 0, allowed: { false }) == .skipped, "denied before capture processing")
        check(!(await stop(empty, 1)) && !FileManager.default.fileExists(atPath: empty.url.path), "zero-frame recording leaves no mp4")
        let raced = ScreenVideoWriter(recording: emptyDir)
        var gates = 0
        check(await append(raced, black, 0, allowed: { gates += 1; return gates == 1 }) == .skipped, "privacy rechecked immediately before append")
        check(!(await stop(raced, 1)) && !FileManager.default.fileExists(atPath: raced.url.path), "empty initialized writer cleaned up")
        check(try FileManager.default.contentsOfDirectory(atPath: emptyDir.path).isEmpty, "failed movie leaves no partial file")
        let capped = ScreenVideoWriter(recording: emptyDir)
        check(await append(capped, black, ScreenVideoRules.maxDurationSeconds) == .stopped, "duration cap enforced in real writer")
        check(!(await stop(capped, ScreenVideoRules.maxDurationSeconds)), "capped empty writer finalizes")
        let existing = Data("synthetic existing file".utf8)
        try existing.write(to: emptyDir.appendingPathComponent("screen.mp4"))
        let collision = ScreenVideoWriter(recording: emptyDir)
        check(await append(collision, black, 0) == .failed, "existing video never overwritten")
        check(!(await stop(collision, 1)), "failed initialization finishes")
        check(try Data(contentsOf: collision.url) == existing, "cleanup never deletes another recording")
    }

    static func main() async throws {
        rules()
        try await roundTrip()
        print("screen video: \(ran) checks passed, including real H.264 encode/decode/AVPlayer round trip")
    }
}

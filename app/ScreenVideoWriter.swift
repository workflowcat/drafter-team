// All image work and AVAssetWriter calls are serialized here. No screen or app access; synthetic frames can test it.
import Foundation
import AVFoundation
import CoreGraphics

final class ScreenVideoWriter {
    enum AppendResult { case appended, skipped, stopped, failed }
    let url: URL
    private let pendingURL: URL
    private let queue = DispatchQueue(label: "drafter.screen-video.writer", qos: .utility)
    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var size = (width: 0, height: 0)
    private var lastFrameAt: Double?
    private var lastGray: [UInt8]?
    private var closing = false, ownsFile = false
    private var result: Bool?
    private var completions: [(Bool) -> Void] = []
    // Fragmented output flushes every five seconds. Reserve room for buffered frames and the final index.
    private let finishReserve = 32_000_000

    init(recording: URL) {
        url = recording.appendingPathComponent("screen.mp4")
        pendingURL = recording.appendingPathComponent(".screen-\(UUID().uuidString).mp4")
    }

    /// `allowed` runs on the writer queue, immediately before any pixel work and again before append.
    /// The live adapter rechecks privacy on main; tests supply a synthetic permission state.
    func append(_ image: CGImage, at t: Double, allowed: @escaping () -> Bool, completion: @escaping (AppendResult) -> Void) {
        queue.async {
            let answer = self.appendNow(image, at: t, allowed: allowed)
            DispatchQueue.main.async { completion(answer) }
        }
    }

    private func appendNow(_ image: CGImage, at t: Double, allowed: () -> Bool) -> AppendResult {
        guard !closing else { return .stopped }
        guard allowed() else { return .skipped }
        let bytes = ((try? FileManager.default.attributesOfItem(atPath: pendingURL.path)[.size]) as? NSNumber)?.intValue ?? 0
        guard ScreenVideoRules.canAppend(writtenBytes: bytes + finishReserve, elapsed: t) else { return .stopped }
        guard let gray = Self.gray(image) else { return .failed }
        var diff = 1.0
        if let old = lastGray {
            var changed = 0
            for i in gray.indices where abs(Int(old[i]) - Int(gray[i])) > 32 { changed += 1 }
            diff = Double(changed) / Double(gray.count)
        }
        guard ScreenVideoRules.shouldAppendFrame(elapsed: t, lastFrameAt: lastFrameAt, diff: diff) else { return .skipped }
        do { if writer == nil { try open(image) } } catch { return .failed }
        guard let writer, writer.status == .writing, let input, let adaptor else { return .failed }
        guard input.isReadyForMoreMediaData else { return .skipped } // bounded: never queue frames waiting for the encoder
        guard let pool = adaptor.pixelBufferPool else { return .failed }
        var buffer: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer) == kCVReturnSuccess, let buffer else { return .failed }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let context = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: size.width, height: size.height,
                                      bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.noneSkipFirst.rawValue) else { return .failed }
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: size.width, height: size.height))
        // A display change keeps the first frame's encoded size, fitting subsequent images without distortion.
        let scale = min(Double(size.width) / Double(image.width), Double(size.height) / Double(image.height))
        let w = Double(image.width) * scale, h = Double(image.height) * scale
        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: (Double(size.width) - w) / 2, y: (Double(size.height) - h) / 2, width: w, height: h))
        guard allowed() else { return .skipped }
        guard adaptor.append(buffer, withPresentationTime: CMTime(seconds: t, preferredTimescale: 600)) else { return .failed }
        lastFrameAt = t; lastGray = gray
        return .appended
    }

    private func open(_ image: CGImage) throws {
        size = ScreenVideoRules.clampedDimensions(width: image.width, height: image.height)
        guard size.width > 0, size.height > 0, size.height <= 8192 else { throw CocoaError(.fileWriteUnknown) }
        // Do not replace an earlier recording. This object only removes a file it created itself.
        guard !FileManager.default.fileExists(atPath: url.path) else { throw CocoaError(.fileWriteFileExists) }
        let writer = try AVAssetWriter(outputURL: pendingURL, fileType: .mp4)
        self.writer = writer; ownsFile = true
        writer.movieTimeScale = 600
        writer.movieFragmentInterval = CMTime(seconds: 5, preferredTimescale: 600)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: size.width, AVVideoHeightKey: size.height,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 500_000, AVVideoExpectedSourceFrameRateKey: 1,
                AVVideoMaxKeyFrameIntervalKey: 5, AVVideoMaxKeyFrameIntervalDurationKey: 5,
                AVVideoAllowFrameReorderingKey: false]
        ])
        input.expectsMediaDataInRealTime = true
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: size.width, kCVPixelBufferHeightKey as String: size.height,
            kCVPixelBufferCGImageCompatibilityKey as String: true, kCVPixelBufferCGBitmapContextCompatibilityKey as String: true
        ])
        guard writer.canAdd(input) else { throw CocoaError(.fileWriteUnknown) }
        writer.add(input)
        self.input = input; self.adaptor = adaptor
        guard writer.startWriting() else { throw CocoaError(.fileWriteUnknown) }
        // Zero is the audio origin, even if privacy delayed the first screen frame.
        writer.startSession(atSourceTime: .zero)
    }

    /// Asynchronous and idempotent. Finalization is ordered after every accepted append.
    func stop(at t: Double, completion: @escaping (Bool) -> Void) {
        queue.async {
            if let result = self.result { DispatchQueue.main.async { completion(result) }; return }
            self.completions.append(completion)
            guard !self.closing else { return }
            self.closing = true
            guard let writer = self.writer, writer.status == .writing, let last = self.lastFrameAt else {
                self.writer?.cancelWriting(); self.complete(false); return
            }
            let end = min(ScreenVideoRules.maxDurationSeconds, max(last + 1.0 / 600, t.isFinite ? t : last))
            writer.endSession(atSourceTime: CMTime(seconds: end, preferredTimescale: 600))
            self.input?.markAsFinished()
            writer.finishWriting {
                self.queue.async { self.complete(writer.status == .completed) }
            }
        }
    }

    private func complete(_ written: Bool) {
        var ok = written
        // Call Studio only discovers finalized movies. Rename in the same directory after the encoder closes.
        if ok {
            do { try FileManager.default.moveItem(at: pendingURL, to: url) } catch { ok = false }
        }
        if !ok, ownsFile { try? FileManager.default.removeItem(at: pendingURL) }
        result = ok; writer = nil; input = nil; adaptor = nil; lastGray = nil
        let callbacks = completions; completions = []
        let saved = ok
        DispatchQueue.main.async { callbacks.forEach { $0(saved) } }
    }

    private static func gray(_ image: CGImage) -> [UInt8]? {
        var bytes = [UInt8](repeating: 0, count: 128 * 80)
        let ok = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: 128, height: 80, bitsPerComponent: 8,
                                          bytesPerRow: 128, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: 0) else { return false }
            context.interpolationQuality = .low
            context.draw(image, in: CGRect(x: 0, y: 0, width: 128, height: 80)); return true
        }
        return ok ? bytes : nil
    }
}

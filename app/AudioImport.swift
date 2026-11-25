import Foundation
import AVFoundation

/// "Transcribe file": any audio or video file Drafter is given becomes a recording-shaped WAV
/// (16 kHz mono 16-bit little-endian PCM, 44-byte header, like History.writeWav), streamed so a
/// 2-hour file never sits in memory. Foundation + AVFoundation only; callable from a background thread.
enum AudioImport {
    static let kinds: Set<String> = ["m4a", "mp3", "wav", "mp4", "mov", "aac", "aiff", "aif", "caf", "m4v"]

    static func supported(_ url: URL) -> Bool { kinds.contains(url.pathExtension.lowercased()) }

    enum Failure: Error, LocalizedError, Equatable {
        case noAudioTrack, unreadable(String), cancelled
        var errorDescription: String? {
            switch self {
            case .noAudioTrack: return "The file has no sound."
            case .unreadable(let why): return "The file can't be read: \(why)"
            case .cancelled: return "Stopped."
            }
        }
    }

    static let rate = 16000

    /// Converts the first audio track to recording WAV. `progress` gets 0...1 at most every ~0.25 s
    /// on the calling thread; `cancelled` is checked between buffers. Returns seconds written.
    /// On any throw the partial `wav` is removed.
    @discardableResult
    static func convert(_ src: URL, to wav: URL, progress: (Double) -> Void = { _ in }, cancelled: () -> Bool = { false }) throws -> Double {
        let asset = AVURLAsset(url: src)
        let track: AVAssetTrack
        let total: Double
        do {
            guard let t = try loadSync({ try await asset.loadTracks(withMediaType: .audio) }).first else { throw Failure.noAudioTrack }
            track = t
            let d = try loadSync({ try await asset.load(.duration) })
            total = d.seconds.isFinite ? d.seconds : 0
        } catch let f as Failure { throw f } catch { throw Failure.unreadable(error.localizedDescription) }

        let reader: AVAssetReader
        do { reader = try AVAssetReader(asset: asset) } catch { throw Failure.unreadable(error.localizedDescription) }
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: rate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        let out = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        out.alwaysCopiesSampleData = false
        guard reader.canAdd(out) else { throw Failure.unreadable("no PCM output") }
        reader.add(out)
        guard reader.startReading() else { throw Failure.unreadable(reader.error?.localizedDescription ?? "reader did not start") }

        FileManager.default.createFile(atPath: wav.path, contents: nil)
        guard let fh = try? FileHandle(forWritingTo: wav) else { reader.cancelReading(); throw Failure.unreadable("can't write \(wav.lastPathComponent)") }
        var ok = false
        defer {
            try? fh.close()
            if !ok { try? FileManager.default.removeItem(at: wav) }
        }
        do {
            try fh.write(contentsOf: header(bytes: 0))
            var bytes = 0
            var lastTick = Date.distantPast
            progress(0)
            while true {
                if cancelled() { reader.cancelReading(); throw Failure.cancelled }
                guard let buf = out.copyNextSampleBuffer() else { break }
                if let block = CMSampleBufferGetDataBuffer(buf) {
                    let n = CMBlockBufferGetDataLength(block)
                    if n > 0 {
                        var chunk = Data(count: n)
                        let st = chunk.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: n, destination: $0.baseAddress!) }
                        if st == kCMBlockBufferNoErr { try fh.write(contentsOf: chunk); bytes += n }
                    }
                }
                let now = Date()
                if total > 0, now.timeIntervalSince(lastTick) >= 0.25 {
                    lastTick = now
                    let pts = CMSampleBufferGetPresentationTimeStamp(buf).seconds
                    if pts.isFinite { progress(min(1, max(0, pts / total))) }
                }
            }
            if reader.status == .failed { throw Failure.unreadable(reader.error?.localizedDescription ?? "read failed") }
            if cancelled() { throw Failure.cancelled }
            try fh.seek(toOffset: 0)
            try fh.write(contentsOf: header(bytes: bytes))
            ok = true
            progress(1)
            return Double(bytes / 2) / Double(rate)
        } catch let f as Failure { throw f } catch { throw Failure.unreadable(error.localizedDescription) }
    }

    /// Duration in seconds, nil when there is no audio track.
    static func duration(_ src: URL) -> Double? {
        let asset = AVURLAsset(url: src)
        guard let tracks = try? loadSync({ try await asset.loadTracks(withMediaType: .audio) }), !tracks.isEmpty,
              let d = try? loadSync({ try await asset.load(.duration) }), d.seconds.isFinite else { return nil }
        return d.seconds
    }

    /// The 44-byte header History.writeWav writes, for `bytes` of PCM.
    static func header(bytes: Int) -> Data {
        var d = Data()
        func u32(_ v: UInt32) { var x = v.littleEndian; d.append(Data(bytes: &x, count: 4)) }
        func u16(_ v: UInt16) { var x = v.littleEndian; d.append(Data(bytes: &x, count: 2)) }
        d.append(contentsOf: Array("RIFF".utf8)); u32(UInt32(36 + bytes)); d.append(contentsOf: Array("WAVEfmt ".utf8))
        u32(16); u16(1); u16(1); u32(UInt32(rate)); u32(UInt32(rate * 2)); u16(2); u16(16)
        d.append(contentsOf: Array("data".utf8)); u32(UInt32(bytes))
        return d
    }

    /// Runs an async load and waits for it. Never call on the main thread of a run loop that the load needs.
    private static func loadSync<T>(_ work: @escaping @Sendable () async throws -> T) throws -> T {
        let box = LoadBox<T>(), sem = DispatchSemaphore(value: 0)
        Task.detached {
            do { box.r = .success(try await work()) } catch { box.r = .failure(error) }
            sem.signal()
        }
        sem.wait()
        return try box.r!.get()
    }
}

/// Holds one async load's result for AudioImport.loadSync.
private final class LoadBox<T>: @unchecked Sendable { var r: Result<T, Error>? }

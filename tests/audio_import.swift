// swiftc -parse-as-library app/AudioImport.swift tests/audio_import.swift -o app/build/audio-import-test && app/build/audio-import-test
// Generated 440 Hz tones only, in a temp folder that is removed at the end.
import Foundation
import AVFoundation

@main
struct AudioImportChecks {
    static var failed = 0, passed = 0
    static func check(_ ok: Bool, _ what: String) { if ok { passed += 1 } else { print("FAIL: " + what); failed += 1 } }

    static let secs = 3.0, hz = 440.0

    /// A 440 Hz tone, 44.1 kHz stereo, written with AVAudioFile in the format `settings` asks for.
    static func tone(_ url: URL, _ settings: [String: Any]) throws {
        let fmt = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2)!
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let n = AVAudioFrameCount(44100 * secs)
        let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: n)!
        buf.frameLength = n
        for c in 0..<2 {
            let p = buf.floatChannelData![c]
            for i in 0..<Int(n) { p[i] = Float(0.5 * sin(2 * .pi * hz * Double(i) / 44100)) }
        }
        try file.write(from: buf)
    }

    /// Copies the audio of `src` into a .mov or .mp4 container (passthrough) with AVAssetWriter.
    static func rewrap(_ src: URL, to dst: URL, type: AVFileType) throws {
        let asset = AVURLAsset(url: src)
        let track = asset.tracks(withMediaType: .audio)[0]
        let reader = try AVAssetReader(asset: asset)
        let out = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        reader.add(out)
        let writer = try AVAssetWriter(outputURL: dst, fileType: type)
        let hint = track.formatDescriptions.first.map { $0 as! CMFormatDescription }
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: nil, sourceFormatHint: hint)
        input.expectsMediaDataInRealTime = false
        writer.add(input)
        reader.startReading(); writer.startWriting(); writer.startSession(atSourceTime: .zero)
        while let b = out.copyNextSampleBuffer() {
            while !input.isReadyForMoreMediaData { usleep(1000) }
            input.append(b)
        }
        input.markAsFinished()
        let sem = DispatchSemaphore(value: 0)
        writer.finishWriting { sem.signal() }
        sem.wait()
        if writer.status != .completed { throw writer.error ?? NSError(domain: "rewrap", code: 1) }
    }

    struct Wav { var rate: UInt32; var channels: UInt16; var bits: UInt16; var riff: UInt32; var dataBytes: UInt32; var samples: [Int16]; var size: Int }
    static func readWav(_ url: URL) -> Wav? {
        guard let d = try? Data(contentsOf: url), d.count >= 44, String(data: d[0..<4], encoding: .ascii) == "RIFF",
              String(data: d[8..<16], encoding: .ascii) == "WAVEfmt ", String(data: d[36..<40], encoding: .ascii) == "data" else { return nil }
        func u32(_ o: Int) -> UInt32 { d[o..<o + 4].withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).littleEndian } }
        func u16(_ o: Int) -> UInt16 { d[o..<o + 2].withUnsafeBytes { $0.loadUnaligned(as: UInt16.self).littleEndian } }
        let pcm = d[44...].withUnsafeBytes { Array($0.bindMemory(to: Int16.self)).map { Int16(littleEndian: $0) } }
        return Wav(rate: u32(24), channels: u16(22), bits: u16(34), riff: u32(4), dataBytes: u32(40), samples: pcm, size: d.count)
    }

    static func main() {
        // supported table
        for (name, want) in [("a.m4a", true), ("B.MP3", true), ("c.Wav", true), ("d.mp4", true), ("e.MOV", true), ("f.aac", true),
                             ("g.aiff", true), ("h.aif", true), ("i.caf", true), ("j.m4v", true), ("k.txt", false), ("l.pdf", false),
                             ("noext", false), ("m.flac", false), ("m4a", false), ("dir.m4a/x.ogg", false)] {
            check(AudioImport.supported(URL(fileURLWithPath: "/tmp/" + name)) == want, "supported \(name) should be \(want)")
        }

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("drafter-audio-import-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        var sources: [URL] = []
        do {
            let wav = dir.appendingPathComponent("tone.wav")
            try tone(wav, [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 44100, AVNumberOfChannelsKey: 2,
                           AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false])
            let m4a = dir.appendingPathComponent("tone.m4a")
            try tone(m4a, [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 44100, AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: 128000])
            let caf = dir.appendingPathComponent("tone.caf")
            try tone(caf, [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 44100, AVNumberOfChannelsKey: 2,
                           AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsBigEndianKey: false])
            sources = [wav, m4a, caf]
            let mov = dir.appendingPathComponent("tone.mov"), mp4 = dir.appendingPathComponent("tone.mp4")
            try rewrap(m4a, to: mov, type: .mov); sources.append(mov)
            try rewrap(m4a, to: mp4, type: .mp4); sources.append(mp4)
        } catch { check(false, "make tones: \(error)") }
        check(sources.count == 5, "5 sources made (wav, m4a, caf, mov, mp4)")

        for src in sources {
            let name = src.lastPathComponent
            let out = dir.appendingPathComponent(name + ".16k.wav")
            let srcDur = AudioImport.duration(src)
            check(srcDur.map { abs($0 - secs) < 0.1 } ?? false, "\(name): duration \(String(describing: srcDur))")
            var ticks: [Double] = []
            var thread = true
            let written: Double
            do {
                written = try AudioImport.convert(src, to: out, progress: { ticks.append($0); if !Thread.isMainThread { thread = false } })
            } catch { check(false, "\(name): convert threw \(error)"); continue }
            check(thread, "\(name): progress on the calling thread")
            guard let w = readWav(out) else { check(false, "\(name): bad WAV header"); continue }
            check(w.rate == 16000 && w.channels == 1 && w.bits == 16, "\(name): 16 kHz mono 16-bit (\(w.rate) \(w.channels) \(w.bits))")
            check(Int(w.dataBytes) == w.size - 44 && Int(w.riff) == w.size - 8, "\(name): RIFF and data sizes patched")
            let len = Double(w.samples.count) / 16000
            check(abs(len - (srcDur ?? secs)) <= 0.05, "\(name): length \(len) vs source \(srcDur ?? -1)")
            check(abs(written - len) < 0.001, "\(name): returned seconds \(written) match the file")
            // skip the AAC priming edges, then level and pitch
            let mid = Array(w.samples[1600..<(w.samples.count - 1600)])
            let peak = mid.map { abs(Int($0)) }.max() ?? 0
            check(peak > 8000, "\(name): not silent (peak \(peak))")
            var crossings = 0
            for i in 1..<mid.count where (mid[i - 1] < 0) != (mid[i] < 0) { crossings += 1 }
            let f = Double(crossings) / 2 / (Double(mid.count) / 16000)
            check(abs(f - hz) < 5, "\(name): pitch \(f) Hz")
            check(!ticks.isEmpty && ticks.last == 1 && ticks.first == 0, "\(name): progress 0 ... 1 (\(ticks))")
            check(zip(ticks, ticks.dropFirst()).allSatisfy { $0 <= $1 }, "\(name): progress rises")
        }

        // cancel: throws `cancelled`, leaves no file
        if let src = sources.first(where: { $0.pathExtension == "m4a" }) {
            let out = dir.appendingPathComponent("cancel.wav")
            var calls = 0
            do {
                _ = try AudioImport.convert(src, to: out, cancelled: { calls += 1; return calls > 2 })
                check(false, "cancel should throw")
            } catch AudioImport.Failure.cancelled {
                check(true, "cancel throws cancelled")
            } catch { check(false, "cancel threw \(error)") }
            check(!FileManager.default.fileExists(atPath: out.path), "cancel removes the partial WAV")
        }

        // a text file: no audio
        let txt = dir.appendingPathComponent("notes.m4a")
        try! "Agree on the plan.".write(to: txt, atomically: true, encoding: .utf8)
        do {
            _ = try AudioImport.convert(txt, to: dir.appendingPathComponent("txt.wav"))
            check(false, "text file should throw")
        } catch let f as AudioImport.Failure {
            check(f == .noAudioTrack || { if case .unreadable = f { return true }; return false }(), "text file throws \(f)")
            check(f.errorDescription?.isEmpty == false, "failure has a message")
        } catch { check(false, "text file threw a non-Failure \(error)") }
        check(AudioImport.duration(txt) == nil, "text file has no duration")
        check(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("txt.wav").path), "failed convert leaves no WAV")

        // header helper matches History.writeWav's layout
        let h = AudioImport.header(bytes: 32000)
        check(h.count == 44, "header is 44 bytes")

        // from a background thread
        if let src = sources.first {
            var secsOut = 0.0
            let sem = DispatchSemaphore(value: 0)
            Thread.detachNewThread {
                secsOut = (try? AudioImport.convert(src, to: dir.appendingPathComponent("bg.wav"))) ?? -1
                sem.signal()
            }
            sem.wait()
            check(abs(secsOut - secs) < 0.05, "converts on a background thread (\(secsOut))")
        }

        print(failed == 0 ? "audio import: \(passed) checks pass" : "audio import: \(failed) failed, \(passed) pass")
        exit(failed == 0 ? 0 : 1)
    }
}

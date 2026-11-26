// The microphone (from Voice Notes, 2026-10-18). Sound comes through a capture session, which names its device itself. (An audio
// engine follows the system's default devices, and with Bluetooth headphones as the default input
// it started fine and then delivered nothing: every take on 2026-10-10 after 17:24 was silent.)
import AVFoundation
import CoreAudio

final class MicCapture: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate {
    private let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "mic")
    private var onSamples: (([Float], Float) -> Void)?
    private(set) var name = ""
    private(set) var plain = false
    private(set) var deviceID = ""
    // pre-roll (2026-10-21): while the mic is kept ready, the last ~0.6 s wait here and become the start of the next take
    private var ring: [Float] = []
    private static let ringMax = 16000 * 6 / 10

    /// The microphone kept configured between takes (2026-10-21: building it on each press held the app ~85 ms), and,
    /// with "Keep the microphone ready" on, kept running so the take starts with the sound from before the press.
    static var shared: MicCapture?
    static var keepReady = false

    /// The ready microphone for a take: `sink` gets its samples from now on (with the pre-roll first, when kept ready).
    /// `call`: a call recording takes the default input as it is. Its call app already opened a Bluetooth headset's
    /// microphone (call quality, no switch to wait for), and the Mac's own microphone hears the user only faintly
    /// (18 November 2026, the user: with Bluetooth on the recording "is not actually recording what people are saying").
    static func take(_ sink: @escaping ([Float], Float) -> Void, call: Bool = false) -> MicCapture? {
        // a new default microphone (headphones in or out), or a call after a take or the other way round: a fresh capture
        if shared == nil || shared?.plain != call || shared?.deviceID != device(plain: call)?.uniqueID {
            shared?.stopNow(); shared = MicCapture(plain: call, onSamples: nil)
        }
        guard let m = shared else { return nil }
        m.attach(sink)
        return m
    }

    /// Builds (and, kept ready, starts) the microphone ahead of the first press.
    static func prepare() {
        if shared == nil { shared = MicCapture(plain: false, onSamples: nil) }
        guard let m = shared else { return }
        if keepReady { m.queue.async { if !m.session.isRunning { m.session.startRunning() } } }
        else { m.queue.async { if m.onSamples == nil, m.session.isRunning { m.session.stopRunning() } } }
    }

    private func attach(_ sink: @escaping ([Float], Float) -> Void) {
        queue.async { [self] in
            let pre = ring; ring = []
            onSamples = sink
            if !pre.isEmpty { sink(pre, pre.reduce(0) { max($0, abs($1)) }) }
            if !session.isRunning { session.startRunning() }
        }
    }

    /// Bluetooth headphones drop to call quality (and take a second to switch) the moment their
    /// microphone opens. With one as the default input, listen on the Mac's own microphone instead;
    /// `plain` asks for the default input as it is (the second try, when the first one was silent).
    static func device(plain: Bool) -> AVCaptureDevice? {
        let def = AVCaptureDevice.default(for: .audio)
        guard !plain, let d = def else { return def }
        let bluetooth: Set<Int32> = [0x626c7565, 0x626c6561]   // 'blue', 'blea'
        guard bluetooth.contains(d.transportType) else { return d }
        let all = AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone], mediaType: .audio, position: .unspecified).devices
        return all.first { $0.transportType == 0x626c746e } ?? d   // 'bltn'
    }

    /// `onSamples` gets 16 kHz mono floats and their peak, on a background queue.
    init?(plain: Bool, onSamples: (([Float], Float) -> Void)?) {
        self.onSamples = onSamples; self.plain = plain
        super.init()
        guard let dev = Self.device(plain: plain), let input = try? AVCaptureDeviceInput(device: dev), session.canAddInput(input) else { return nil }
        name = dev.localizedName; deviceID = dev.uniqueID
        session.addInput(input)
        let out = AVCaptureAudioDataOutput()
        out.audioSettings = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16000.0, AVNumberOfChannelsKey: 1,
                             AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsBigEndianKey: false,
                             AVLinearPCMIsNonInterleaved: false]
        guard session.canAddOutput(out) else { return nil }
        session.addOutput(out)
        out.setSampleBufferDelegate(self, queue: queue)
        // Starting takes a moment; it must not hold up the key press. A prepared mic (no sink yet) waits for a take.
        if onSamples != nil { queue.async { [session] in session.startRunning() } }
    }

    func stopNow() { queue.async { [self] in onSamples = nil; session.stopRunning() } }

    /// The take is over: kept ready, the mic goes on filling the pre-roll; else it stops (the orange dot goes).
    /// Returns once the samples already delivered went through the sink (it writes long notes and calls to disk on this
    /// queue), so the recording can be closed right after with nothing of it left on the way; waits at most 1 s.
    func stop() {
        let done = DispatchSemaphore(value: 0)
        queue.async { [self] in
            onSamples = nil; ring = []
            done.signal()
            // a call's mic (a headset's, plain) never stays open after it: the headset would keep call quality
            if plain || !(MicCapture.keepReady && MicCapture.shared === self) { session.stopRunning() }
        }
        if done.wait(timeout: .now() + 1) == .timedOut { log("mic: stop waited 1 s for the capture queue") }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput buf: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let block = CMSampleBufferGetDataBuffer(buf) else { return }
        var len = 0
        var ptr: UnsafeMutablePointer<Int8>?
        guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &len, dataPointerOut: &ptr) == noErr,
              let ptr, len >= 4 else { return }
        let s = ptr.withMemoryRebound(to: Float.self, capacity: len / 4) { Array(UnsafeBufferPointer(start: $0, count: len / 4)) }
        if let f = onSamples { f(s, s.reduce(0) { max($0, abs($1)) }); return }
        ring.append(contentsOf: s)
        if ring.count > MicCapture.ringMax { ring.removeFirst(ring.count - MicCapture.ringMax) }
    }
}

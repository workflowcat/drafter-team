// Calls (Granola-style, 2026-10-19): when another app opens the microphone and a call app is running, Drafter offers
// "record this call?" in the strip and waits for Tab (it never starts by itself: other people are on the call).
// Recording keeps both sides apart: his microphone, and the Mac's own sound (the other side) through ScreenCaptureKit.
// A mix of the two feeds the live transcript and outline; at the end Whisper reads each side on its own and the
// transcript says who spoke.
import AppKit
import CoreAudio
import EventKit
import ScreenCaptureKit

/// The Mac's own sound (what the other side says), 16 kHz mono, never Drafter's own.
/// Its samples wait in `live` until the microphone's queue takes them beside the microphone's own (`Tape.write`), so
/// both sides go to disk on the same timeline without the main thread. Nothing of the whole call is kept in memory
/// (2026-11-03: the whole other side sat in `all`, and the end of a frozen take threw it away). A stream that fails to
/// start or stops is started again after 5 s, then longer (`Backoff`); meanwhile the other side's file gets silence.
final class SysAudio: NSObject, SCStreamOutput, SCStreamDelegate {
    private var stream: SCStream?
    private let q = DispatchQueue(label: "drafter.sysaudio")
    private let lock = NSLock()
    private var live: [Float] = []       // not yet written beside the microphone
    private var stopped = false
    private var retry = Backoff(first: 5, most: 60)
    private var report: ((Bool) -> Void)?
    private(set) var state = SideStats.SysState.none
    private(set) var received = 0        // samples delivered so far
    private(set) var peak: Float = 0     // loudest of them

    /// `done` is called after the first try (true: the stream runs).
    func start(_ done: @escaping (Bool) -> Void) {
        lock.lock(); report = done; state = .starting; lock.unlock()
        open()
    }

    private func open() {
        lock.lock(); let gone = stopped; lock.unlock()
        if gone { return }
        SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: true) { c, e in
            guard let d = c?.displays.first else { self.failed("no display (\(Self.describe(e)))"); return }
            let cfg = SCStreamConfiguration()
            cfg.capturesAudio = true; cfg.sampleRate = 16000; cfg.channelCount = 1; cfg.excludesCurrentProcessAudio = true
            cfg.width = 2; cfg.height = 2; cfg.minimumFrameInterval = CMTime(value: 1, timescale: 1); cfg.queueDepth = 3
            let s = SCStream(filter: SCContentFilter(display: d, excludingWindows: []), configuration: cfg, delegate: self)
            do {
                try s.addStreamOutput(self, type: .audio, sampleHandlerQueue: self.q)
                try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: self.q)   // required alongside audio; frames ignored
            } catch { self.failed(Self.describe(error)); return }
            s.startCapture { err in
                if let err { self.failed(Self.describe(err)); return }
                self.lock.lock()
                let late = self.stopped
                if !late { self.stream = s; self.state = .running }
                let back = self.retry.succeeded(), r = self.report; self.report = nil
                self.lock.unlock()
                if late { s.stopCapture { _ in }; return }
                if back { log("call audio: running again") }
                r?(true)
            }
        }
    }

    private func failed(_ why: String) {
        lock.lock()
        let gone = stopped
        let (wait, tell) = retry.failed()
        state = .failed; stream = nil
        let r = report; report = nil
        lock.unlock()
        if gone { return }
        if tell { log("call audio: \(why); trying again in \(Int(wait)) s") }
        r?(false)
        DispatchQueue.global().asyncAfter(deadline: .now() + wait) { [weak self] in self?.open() }
    }

    static func describe(_ e: Error?) -> String {
        guard let e else { return "?" }
        let n = e as NSError
        return "\(n.localizedDescription) [\(n.domain) \(n.code)]"
    }

    func stream(_ s: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, sb.isValid else { return }
        // any channel layout: a one-buffer list was too small for two channels and such frames were dropped unseen
        // (17 November 2026); now they are read and mixed to mono, and a frame that still cannot be read is counted
        var size = 0
        CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(sb, bufferListSizeNeededOut: &size, bufferListOut: nil, bufferListSize: 0,
            blockBufferAllocator: nil, blockBufferMemoryAllocator: nil, flags: 0, blockBufferOut: nil)
        let raw = UnsafeMutableRawPointer.allocate(byteCount: max(size, MemoryLayout<AudioBufferList>.size), alignment: 16)
        defer { raw.deallocate() }
        let list = raw.bindMemory(to: AudioBufferList.self, capacity: 1)
        var block: CMBlockBuffer?
        let asbd = CMSampleBufferGetFormatDescription(sb).flatMap { CMAudioFormatDescriptionGetStreamBasicDescription($0)?.pointee }
        guard CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(sb, bufferListSizeNeededOut: nil, bufferListOut: list,
              bufferListSize: max(size, MemoryLayout<AudioBufferList>.size), blockBufferAllocator: nil, blockBufferMemoryAllocator: nil,
              flags: 0, blockBufferOut: &block) == noErr,
              asbd.map({ $0.mFormatFlags & kAudioFormatFlagIsFloat != 0 && $0.mBitsPerChannel == 32 }) ?? true else { unreadable(); return }
        let abl = UnsafeMutableAudioBufferListPointer(list)
        let buffers: [[Float]] = abl.compactMap { b in
            guard let d = b.mData else { return nil }
            return Array(UnsafeBufferPointer(start: d.assumingMemoryBound(to: Float.self), count: Int(b.mDataByteSize) / 4))
        }
        let channels = Int(asbd?.mChannelsPerFrame ?? 1)
        let interleaved = (asbd?.mFormatFlags ?? 0) & kAudioFormatFlagIsNonInterleaved == 0
        receive(SysAudioRules.mono(buffers, channels: channels, interleaved: interleaved))
    }

    private var bad = 0, badLogged = Date.distantPast
    private func unreadable() {
        lock.lock(); bad += 1; let n = bad; let tell = Date().timeIntervalSince(badLogged) > 60; if tell { badLogged = Date() }; lock.unlock()
        if tell { log("call audio: \(n) frames from the Mac could not be read so far") }
    }

    /// Samples from the stream (its queue; tests call it directly).
    func receive(_ f: [Float]) {
        let pk = f.reduce(0) { max($0, abs($1)) }
        lock.lock(); defer { lock.unlock() }
        if stopped { return }      // after stop() took the rest nothing more is kept (Argon 7)
        watch.samples(at: Date().timeIntervalSince1970, sound: pk > 0)
        live.append(contentsOf: f); received += f.count; peak = max(peak, pk)
        // the microphone is gone and never came back: memory stays bounded, the newest 9-10 minutes wait for it
        // (Argon 6); trimmed a minute at a time so the copy is rare
        if live.count > SysAudio.most { live.removeFirst(live.count - (SysAudio.most - 16000 * 60)) }
    }
    static let most = 16000 * 600

    /// The capture can break without an error (SysWatch): the mic's chunks drive the check, a restart runs off its queue.
    private var watch = SysWatch(at: Date().timeIntervalSince1970)
    func micHeard(secs: Double, loud: Bool) {
        lock.lock()
        guard !stopped, state == .running else { lock.unlock(); return }
        watch.mic(secs: secs, loud: loud)
        let act = watch.check(at: Date().timeIntervalSince1970)
        lock.unlock()
        if case .restart(let why) = act { DispatchQueue.global().async { self.restart(why) } }
    }

    /// Stops the stream and opens a new one (the other side's file gets silence meanwhile).
    private func restart(_ why: String) {
        lock.lock()
        let gone = stopped, old = stream
        stream = nil; state = .starting
        let (r, b) = (received, bad)
        lock.unlock()
        if gone { return }
        log("call audio: \(why); starting it again (\(r / 16000) s received so far, \(b) frames unreadable)")
        old?.stopCapture { _ in self.open() }
        if old == nil { open() }
    }

    /// state, samples delivered and their loudest, read together under the lock (Argon 8: Tape.now read them bare).
    func snapshot() -> (SideStats.SysState, Int, Float) { lock.lock(); defer { lock.unlock() }; return (state, received, peak) }

    func stream(_ s: SCStream, didStopWithError error: Error) {
        log("call audio stopped: \(Self.describe(error))")
        lock.lock(); let mine = stream === s; lock.unlock()
        if mine { failed("stopped") }
    }

    /// The Mac's sound for the next `n` microphone samples (zeros when it has none yet). Called on the microphone's queue.
    /// More than 5 s waiting means the microphone stalled (a route change, a reopen): then all of it comes back at once,
    /// longer than `n`, and the tape puts silence on his side for the gap (Argon 6: it was thrown away).
    func take(_ n: Int) -> [Float] {
        lock.lock(); defer { lock.unlock() }
        if live.count > n + 16000 * 5 { let out = live; live.removeAll(keepingCapacity: true); return out }
        let k = min(n, live.count)
        var out = Array(live.prefix(k)); live.removeFirst(k)
        if k < n { out += [Float](repeating: 0, count: n - k) }
        return out
    }

    /// Stops it for good. -> what came after the microphone's last samples (written after them, never thrown away).
    func stop() -> [Float] {
        q.sync {}                  // buffers already handed to the queue land in `live` first (Argon 7)
        lock.lock()
        stopped = true; report = nil
        let s = stream; stream = nil
        let rest = live; live = []
        let (n, b, w) = (received, bad, watch.restarts)
        lock.unlock()
        s?.stopCapture { _ in }
        if b > 0 || w > 0 { log("call audio: ended with \(n / 16000) s from the Mac, \(w) restarts, \(b) frames unreadable") }
        return rest
    }
}

/// Where a long note's or call's sound goes, called on the microphone's own queue: straight to disk, the other side
/// beside it, so a busy or frozen main thread loses nothing (3 November 2026: while main hung, mic chunks piled up as
/// main-queue blocks, the files stopped growing, and the take's end dropped what was queued). Main only gets the
/// samples back for the live transcript and the levels.
final class Tape {
    private let lock = NSLock()
    private var spool: Spool?
    private var sys: SysAudio?
    private var stats = SideStats()
    private var began = Date()
    private var themLoud = Date()
    private var pausedAt: Date?, pausedFor: Double = 0
    /// Paused from the recording window (17 November 2026): the microphone and the Mac's sound keep running, and both
    /// are dropped here together, so the two files keep one timeline and simply skip the pause.
    var paused: Bool {
        get { lock.lock(); defer { lock.unlock() }; return pausedAt != nil }
        set {
            lock.lock(); defer { lock.unlock() }
            if newValue, pausedAt == nil { pausedAt = Date() }
            else if !newValue, let p = pausedAt { pausedFor += Date().timeIntervalSince(p); pausedAt = nil; themLoud = Date() }
        }
    }
    /// Seconds since the other side last made a sound worth hearing (a call that goes on while the live words stall).
    var themLoudAgo: Double { lock.lock(); defer { lock.unlock() }; return Date().timeIntervalSince(themLoud) }

    func attach(_ sp: Spool, call: Bool) {
        lock.lock(); spool = sp; stats = SideStats(); stats.call = call; began = Date(); themLoud = Date(); pausedAt = nil; pausedFor = 0; lock.unlock()
    }
    func attach(sys s: SysAudio) { lock.lock(); sys = s; stats.call = true; lock.unlock() }

    /// The microphone's samples (microphone queue). -> the other side's samples for the same stretch, when a call.
    func write(_ s: [Float], peak: Float) -> [Float]? {
        lock.lock()
        let sp = spool, sy = sys, call = stats.call
        if pausedAt != nil {   // paused: the other side's stretch is taken too and both are dropped
            lock.unlock()
            _ = sy?.take(s.count)
            return nil
        }
        if sp != nil { stats.meSamples += s.count; stats.mePeak = max(stats.mePeak, peak) }
        lock.unlock()
        guard let sp else { return nil }
        // a call keeps its other side on the same timeline even while the Mac's sound is not coming (silence there)
        let other = sy?.take(s.count) ?? (call ? [Float](repeating: 0, count: s.count) : nil)
        sy?.micHeard(secs: Double(s.count) / 16000, loud: peak > 0.03)
        // the other side waited through a microphone stall: his side gets silence for the gap, before this chunk
        let gap = max(0, (other?.count ?? 0) - s.count)
        sp.add(me: gap > 0 ? [Float](repeating: 0, count: gap) + s : s, them: other)
        if sy != nil, let other, other.contains(where: { abs($0) > 0.02 }) { lock.lock(); themLoud = Date(); lock.unlock() }
        return sy == nil ? nil : other.map { gap > 0 ? Array($0.suffix(s.count)) : $0 }
    }

    /// The numbers so far, for the strip's warning (main).
    func now() -> SideStats {
        lock.lock(); defer { lock.unlock() }
        var s = stats
        s.seconds = Date().timeIntervalSince(began) - pausedFor - (pausedAt.map { Date().timeIntervalSince($0) } ?? 0)
        if let sy = sys { (s.sysState, s.themSamples, s.themPeak) = sy.snapshot() }
        else if s.call { s.sysState = .failed }
        return s
    }

    /// The take is over and the microphone stopped: the other side's last samples go after the rest, then nothing more
    /// is written here. -> the spool, to close.
    func detach() -> Spool? {
        lock.lock()
        let sp = spool, sy = sys
        spool = nil; sys = nil; pausedAt = nil; pausedFor = 0
        lock.unlock()
        if let rest = sy?.stop(), !rest.isEmpty { sp?.add(me: [], them: rest) }
        return sp
    }
}

/// A long note or call written to disk while it runs (2026-10-20: two meetings were lost when a take held only in
/// memory was dropped). data/calls/<time>/me.pcm and them.pcm (16 kHz mono Int16, same timeline), meta.json; at the
/// end they become me.wav / them.wav. A folder left with .pcm files (Drafter quit or crashed) is finished on next start.
final class Spool {
    static let root = Home.data.appendingPathComponent("calls")
    static var active: URL?                 // the folder being recorded now
    let dir: URL
    private(set) var event = ""             // the calendar event's title, for the strip
    private var me: FileHandle?, them: FileHandle?
    private let io = NSLock()               // add() runs on the microphone's queue, close() on main
    private var written = 0
    var frames: Int { io.lock(); defer { io.unlock() }; return written }

    init?(call: Bool, app: String) {
        dir = Spool.root.appendingPathComponent(ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-"))
        do { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) } catch { return nil }
        // meeting notes (app/MeetingNotes.swift): the event he started them for, and "In person" without a call app
        let meet = MeetingNotes.pending; MeetingNotes.pending = nil
        MeetingNotes.active = call || meet != nil
        let inPerson = !call && meet?.inPerson == true
        var meta: [String: Any] = ["call": call, "app": inPerson ? MeetingRules.inPersonLabel : app, "started": Date().timeIntervalSince1970]
        if inPerson { meta["inPerson"] = true }
        // a call takes the meeting on now; a long note only one with other people in it (not a block of focus time)
        if let ev = (call ? CallWatch.event : nil) ?? meet?.event ?? Meeting.now(needPeople: !call) { meta["event"] = ev; event = ev["title"] as? String ?? "" }
        try? JSONSerialization.data(withJSONObject: meta).write(to: dir.appendingPathComponent("meta.json"))
        if call { CallWatch.event = nil }
        for n in ["me.pcm"] + (call ? ["them.pcm"] : []) { FileManager.default.createFile(atPath: dir.appendingPathComponent(n).path, contents: nil) }
        me = try? FileHandle(forWritingTo: dir.appendingPathComponent("me.pcm"))
        if call { them = try? FileHandle(forWritingTo: dir.appendingPathComponent("them.pcm")) }
        Spool.active = dir
    }

    private static func pcm(_ s: [Float]) -> Data {
        var a = s.map { Int16(max(-1, min(1, $0)) * 32767).littleEndian }
        return Data(bytes: &a, count: a.count * 2)
    }

    /// The live text as it comes (every draft, written at most every 3 s): live.txt is there even if the sound or the
    /// final reading is lost. A draft that starts over (the voice engine restarted) is added after what was kept.
    private var base = "", last = "", wrote = Date.distantPast
    func text(_ d: String, force: Bool = false) {
        if last.count > 200, d.count < last.count / 2 { base += last + "\n"; }
        last = d
        guard force || Date().timeIntervalSince(wrote) >= 3 else { return }
        wrote = Date()
        try? (base + last).write(to: dir.appendingPathComponent("live.txt"), atomically: true, encoding: .utf8)
    }
    var liveText: String { base + last }

    func add(me m: [Float], them t: [Float]?) {
        io.lock(); defer { io.unlock() }
        guard let me else { return }        // closed: a late chunk is never written to a closed file
        written += m.count
        if !m.isEmpty { try? me.write(contentsOf: Spool.pcm(m)) }
        if let t, !t.isEmpty { try? them?.write(contentsOf: Spool.pcm(t)) }
    }

    /// Closes the files and turns each .pcm into a .wav. Returns (me.wav, them.wav or nil when silent / not a call).
    @discardableResult
    func close() -> (URL, URL?) {
        text(last, force: true)
        if Spool.active == dir { Spool.active = nil }
        io.lock(); try? me?.synchronize(); try? me?.close(); try? them?.close(); me = nil; them = nil; io.unlock()
        Spool.closedThisRun.insert(dir.standardizedFileURL.path)
        return Spool.wavs(dir)
    }

    static func wavs(_ dir: URL) -> (URL, URL?) {
        var out: [URL?] = []
        // from here until its transcript is written the folder says it is unread, so a freeze, quit or crash while it is
        // read never leaves it behind unread (3 November 2026: a 53-minute call was closed and never read)
        if FileManager.default.fileExists(atPath: dir.appendingPathComponent("me.pcm").path) { markUnread(dir) }
        for n in ["me", "them"] {
            let p = dir.appendingPathComponent(n + ".pcm"), w = dir.appendingPathComponent(n + ".wav")
            guard let d = try? Data(contentsOf: p) else { out.append(FileManager.default.fileExists(atPath: w.path) ? w : nil); continue }
            let loud = d.withUnsafeBytes { $0.bindMemory(to: Int16.self).contains { abs(Int32($0)) > 300 } }
            if n == "me" || loud {
                var h = Data()
                func u32(_ v: UInt32) { var x = v.littleEndian; h.append(Data(bytes: &x, count: 4)) }
                func u16(_ v: UInt16) { var x = v.littleEndian; h.append(Data(bytes: &x, count: 2)) }
                h.append("RIFF".data(using: .ascii)!); u32(36 + UInt32(d.count)); h.append("WAVEfmt ".data(using: .ascii)!)
                u32(16); u16(1); u16(1); u32(16000); u32(32000); u16(2); u16(16)
                h.append("data".data(using: .ascii)!); u32(UInt32(d.count))
                try? (h + d).write(to: w)
                out.append(w)
            } else { out.append(nil) }
            try? FileManager.default.removeItem(at: p)
        }
        return (out[0]!, out[1])
    }

    /// Recordings closed in this run (their reading is under way or done): never taken for leftovers.
    static var closedThisRun = Set<String>()

    static func markUnread(_ dir: URL) {
        let f = dir.appendingPathComponent(Unread.marker)
        if !FileManager.default.fileExists(atPath: f.path) { try? "0".write(to: f, atomically: true, encoding: .utf8) }
    }
    /// The transcript is written: the folder is read.
    static func markRead(_ dir: URL) { try? FileManager.default.removeItem(at: dir.appendingPathComponent(Unread.marker)) }

    /// Folders a crash or quit left unfinished: finished and turned into notes now.
    static func recover() {
        let dirs = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        // closed but never read (the app froze or quit while reading): read again, at most twice per folder
        for d in dirs {
            let mark = d.appendingPathComponent(Unread.marker)
            let has = FileManager.default.fileExists(atPath: mark.path)
            guard has else { continue }
            let attempts = Int((try? String(contentsOf: mark, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "") ?? 0
            let me = d.appendingPathComponent("me.wav"), them = d.appendingPathComponent("them.wav")
            let thisRun = closedThisRun.contains(d.standardizedFileURL.path) || Spool.active?.standardizedFileURL == d.standardizedFileURL
            guard Unread.shouldRecover(hasMarker: has, attempts: attempts, hasAudio: FileManager.default.fileExists(atPath: me.path),
                                       hasTranscript: FileManager.default.fileExists(atPath: d.appendingPathComponent("transcript.txt").path),
                                       thisRun: thisRun) else { continue }
            try? String(attempts + 1).write(to: mark, atomically: true, encoding: .utf8)
            closedThisRun.insert(d.standardizedFileURL.path)
            let meta = (try? JSONSerialization.jsonObject(with: Data(contentsOf: d.appendingPathComponent("meta.json")))) as? [String: Any] ?? [:]
            let live = (try? String(contentsOf: d.appendingPathComponent("live.txt"), encoding: .utf8)) ?? ""
            log("recording recovered: \(d.lastPathComponent) was closed but never read (try \(attempts + 1))")
            Talk.shared.transcribe(dir: d, me: me, them: FileManager.default.fileExists(atPath: them.path) ? them : nil,
                                   call: meta["call"] as? Bool ?? false, live: live)
        }
        for d in dirs where FileManager.default.fileExists(atPath: d.appendingPathComponent("me.pcm").path) {
            // never the recording running now, nor one written to in the last minute (2026-10-21: a call started 10 s
            // before this ran was taken for a leftover, closed and read twice; the voice engine went over its cap)
            if let live = Spool.active, live.standardizedFileURL == d.standardizedFileURL { continue }
            let touched = (try? FileManager.default.attributesOfItem(atPath: d.appendingPathComponent("me.pcm").path)[.modificationDate] as? Date) ?? .distantPast
            if Date().timeIntervalSince(touched) < 60 || closedThisRun.contains(d.standardizedFileURL.path) { continue }
            let meta = (try? JSONSerialization.jsonObject(with: Data(contentsOf: d.appendingPathComponent("meta.json")))) as? [String: Any] ?? [:]
            let size = (try? FileManager.default.attributesOfItem(atPath: d.appendingPathComponent("me.pcm").path)[.size] as? Int) ?? 0
            log("recording recovered: \(d.lastPathComponent), \(size / 32000 / 60) min")
            closedThisRun.insert(d.standardizedFileURL.path)
            let (me, them) = wavs(d)
            if size < 32000 * 5 && !FileManager.default.fileExists(atPath: d.appendingPathComponent("live.txt").path) { markRead(d); continue }
            let live = (try? String(contentsOf: d.appendingPathComponent("live.txt"), encoding: .utf8)) ?? ""
            Talk.shared.transcribe(dir: d, me: me, them: them, call: meta["call"] as? Bool ?? false, live: live)
        }
    }

    private static var rereadAt: [String: Date] = [:]

    /// A finished recording read again with today's reader, then a new note (Recordings › Read again). The old
    /// transcript stays as transcript-before-<time>.txt; a recording saved before calendar matching gets the event
    /// that ran when it started.
    static func reread(_ d: URL) {
        let (me, them) = wavs(d)
        guard FileManager.default.fileExists(atPath: me.path) else { Pill.shared.flash("No audio in this recording"); return }
        if let live = active, live.standardizedFileURL == d.standardizedFileURL { Pill.shared.flash("Still recording"); return }
        if let t = rereadAt[d.path], Date().timeIntervalSince(t) < 300 { Pill.shared.flash("Already reading this recording"); return }
        rereadAt[d.path] = Date()
        let metaURL = d.appendingPathComponent("meta.json")
        var meta = (try? JSONSerialization.jsonObject(with: Data(contentsOf: metaURL))) as? [String: Any] ?? [:]
        let call = meta["call"] as? Bool ?? false
        if meta["event"] == nil, let t = meta["started"] as? Double,
           let ev = Meeting.now(Date(timeIntervalSince1970: t), needPeople: !call) {
            meta["event"] = ev
            if let data = try? JSONSerialization.data(withJSONObject: meta) { try? data.write(to: metaURL) }
        }
        let old = d.appendingPathComponent("transcript.txt")
        if FileManager.default.fileExists(atPath: old.path) {
            let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
            try? FileManager.default.copyItem(at: old, to: d.appendingPathComponent("transcript-before-\(stamp).txt"))
        }
        let live = (try? String(contentsOf: d.appendingPathComponent("live.txt"), encoding: .utf8)) ?? ""
        log("recording read again: \(d.lastPathComponent), event: \((meta["event"] as? [String: Any])?["title"] as? String ?? "none")")
        Talk.shared.transcribe(dir: d, me: me, them: them, call: call, live: live)
    }
}

/// Something waiting in the strip for a few seconds: a copy's written form (Tab takes it), or a call to record (its
/// Record button or ⇧ Right Option; never Tab since keys round three, KeyRules.offerKey).
enum Offer {
    static var until = Date.distantPast
    static var action: (() -> Void)?
    static var app: String?          // a call offer's app: ⇧Esc turns offers off there
    /// The copy chip's written forms (keys round three): how many, and what ⇧Tab does (shows the next one).
    static var forms = 0
    static var step: (() -> Void)?
    /// Tab never takes this offer (the meeting-notes offer: ↵ or its button start a recording, Tab stays the app's).
    static var noTab = false
    /// ↵ takes the offer as Tab does, for the one offer that asked (a voice edit's preview, 17 November 2026: its own
    /// deadline, so a later offer never inherits it); that Return never reaches the app.
    static var returnUntil = Date.distantPast
    static var returnAccepts: Bool { active && returnUntil == until }
    static var active: Bool { Date() < until && action != nil }
    /// ⇧Tab on the copy chip: its next written form shows; Tab then takes that one.
    static func next() {
        guard active, let s = step else { return }
        s()
    }
    static func clear() { action = nil; until = .distantPast; app = nil; forms = 0; step = nil; noTab = false }

    /// Esc (or he types on): the offer goes, nothing starts (2026-11-01, Andrii: "I'm not sure how to dismiss it").
    static func dismiss(_ why: String) {
        guard active else { return }
        clear()
        Pill.shared.hide()
        log("offer dismissed (\(why))")
    }

    /// rows: the question, who or why, what happens. The keys are buttons too: `accept` (Tab; for a call ⇧ Right
    /// Option when voice is on, else the button only), Dismiss (Esc) and, for a call app, Turn off offers there (⇧Esc).
    static func show(_ rows: [String], kind: String, side: String = "", accept label: String, seconds: Double, app: String? = nil,
                     key own: String? = nil, _ act: @escaping () -> Void) {
        clear(); until = Date().addingTimeInterval(seconds); action = act; self.app = app
        let key = own ?? (app == nil ? "tab" : KeyRules.callOfferKey(voice: Drafter.shared.settings.voice))
        var keys = [StripButton(label, key: key, style: .primary) { Offer.accept() }, StripButton("Dismiss", key: "esc") { Offer.dismiss("click") }]
        if let app { keys.append(StripButton("Turn off offers in \(CallWatch.name(app))", key: "⇧esc", style: .quiet) { CallWatch.turnOff(app) }) }
        Pill.shared.offer(rows, kind: kind, side: side, controls: keys, seconds: seconds)
    }

    static func accept() {
        guard active else { return }       // it ran out: nothing starts late
        let a = action; clear()
        a?()
    }
}

/// Is a call going on: another app has the microphone and a call app is running.
enum CallWatch {
    static let apps = ["us.zoom.xos", "com.apple.FaceTime", "com.tinyspeck.slackmacgap", "com.microsoft.teams2", "com.microsoft.teams",
                       "com.hnc.Discord", "net.whatsapp.WhatsApp", "ru.keepcoder.Telegram", "com.google.Chrome", "company.thebrowser.dia",
                       "company.thebrowser.Browser", "com.apple.Safari", "com.automattic.beeper.desktop", "com.cisco.webexmeetingsapp",
                       "notion.id"]
    /// Offers on in this app (Settings › Calls, or ⇧Esc on an offer). Off: no offer, and ⇧ right ⌥ there records a
    /// plain long note, never the call.
    static func on(_ app: String) -> Bool { !Drafter.shared.settings.callOff.contains(app) }
    static func name(_ app: String) -> String {
        NSRunningApplication.runningApplications(withBundleIdentifier: app).first?.localizedName
            ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: app).map { FileManager.default.displayName(atPath: $0.path).replacingOccurrences(of: ".app", with: "") } ?? app
    }
    static func turnOff(_ app: String) {
        Offer.dismiss("off in \(app)")
        if !Drafter.shared.settings.callOff.contains(app) { Drafter.shared.change { $0.callOff.append(app) } }
        // undo right there for 5 s; Settings › Calls keeps the switch after that
        Pill.shared.flash("Offers off in \(name(app))", button: StripButton("Undo", key: "", style: .primary) { turnOn(app) })
        log("call: offers off in \(app)")
    }
    static func turnOn(_ app: String) {
        Drafter.shared.change { $0.callOff.removeAll { $0 == app } }
        Pill.shared.flash("Offers back on in \(name(app))")
        log("call: offers on again in \(app)")
    }
    static var offeredFor: String?          // the call app offered while the mic stays busy (one offer per busy period)
    static var callApp: String?             // the app of the call being recorded
    static var ownUntil = Date.distantPast  // Drafter's own take holds the mic, and for a few seconds after it
    static var busyTicks = 0
    static var releasedSince: Date?         // the recorded call's app let go of the microphone at
    static var event: [String: Any]?        // the calendar event of the call offered or recorded

    /// Is another app using a microphone? Per process (macOS 14.4+), so Drafter's own mic, kept ready or in a take,
    /// never counts as a call; else the device-wide "running somewhere".
    static var micPid: pid_t?                // the app holding the mic, when the per-process check found one
    static var micPids: [pid_t] = []         // every app holding it (Notion's meeting notes beside a call, 10 November)

    static func micBusy() -> Bool {
        let r = probe()
        micPids = r.pids; micPid = r.pids.first
        return r.busy
    }

    /// The app a process holding the mic belongs to: itself when it is an app, else the app around its executable
    /// (a browser's helper, CallAppRules.appPath). Safe off the main thread.
    static func owner(_ pid: pid_t) -> pid_t {
        if let a = NSRunningApplication(processIdentifier: pid), a.bundleIdentifier != nil, a.activationPolicy == .regular { return pid }
        var buf = [CChar](repeating: 0, count: 4096)
        guard proc_pidpath(pid, &buf, UInt32(buf.count)) > 0, let path = CallAppRules.appPath(executable: String(cString: buf)),
              let b = Bundle(path: path)?.bundleIdentifier,
              let app = NSRunningApplication.runningApplications(withBundleIdentifier: b).first else { return pid }
        return app.processIdentifier
    }

    /// The CoreAudio walk itself (~3 ms, XPC to coreaudiod), with no shared state: safe off the main thread.
    static func probe() -> (busy: Bool, pids: [pid_t]) {
        var pids: [pid_t] = []
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        if AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr, size > 0 {
            var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
            if AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids) == noErr {
                let me = getpid()
                for id in ids {
                    var pid: pid_t = 0, running: UInt32 = 0
                    var ps = UInt32(MemoryLayout<pid_t>.size), rs = UInt32(MemoryLayout<UInt32>.size)
                    var a1 = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyPID, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
                    var a2 = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyIsRunningInput, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
                    guard AudioObjectGetPropertyData(id, &a1, 0, nil, &ps, &pid) == noErr,
                          AudioObjectGetPropertyData(id, &a2, 0, nil, &rs, &running) == noErr else { continue }
                    if running != 0, pid != me { let o = owner(pid); if o != me, !pids.contains(o) { pids.append(o) } }
                }
                return (!pids.isEmpty, pids)
            }
        }
        return (deviceBusy(), [])
    }

    static func deviceBusy() -> Bool {
        var dev = AudioDeviceID(0), size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &dev) == noErr else { return false }
        var running = UInt32(0); size = UInt32(MemoryLayout<UInt32>.size)
        addr.mSelector = kAudioDevicePropertyDeviceIsRunningSomewhere
        guard AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, &running) == noErr else { return false }
        return running != 0
    }

    /// The call app to offer or record (CallAppRules, 17 November 2026: a Teams meeting was named Slack). Every app
    /// holding the mic and every running call app, scored on the mic, its call windows (titles read here on main;
    /// Drafter's own pid is never asked, Focus), the front app and the calendar event's link.
    /// -> (app, call app with offers off); `callLabel` gets what the recording is called by.
    static func pick() -> (app: String?, off: String?) {
        let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
        var pids = micPids
        for a in NSWorkspace.shared.runningApplications where CallAppRules.isCallApp(a.bundleIdentifier ?? "") && !pids.contains(a.processIdentifier) {
            pids.append(a.processIdentifier)
        }
        let seen: [CallSeen] = pids.compactMap { pid in
            guard pid != getpid(), let b = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier, CallAppRules.isCallApp(b) else { return nil }
            return CallSeen(bundle: b, holdsMic: micPids.contains(pid), front: pid == front, titles: windowTitles(pid), on: on(b))
        }
        let ev = Meeting.now()
        pickedEvent = ev
        let p = CallAppRules.pick(seen, eventService: (ev?["service"] as? String).flatMap(CallAppRules.Service.init(rawValue:)))
        pickedLabel = p.label
        log("call: picked \(p.app ?? p.off ?? "none")\(p.label.isEmpty ? "" : " (\(p.label))") from \(seen.count) call apps, \(micPids.count) holding the mic")
        return (p.app, p.off)
    }
    static var pickedEvent: [String: Any]?  // the calendar event seen with the last pick
    static var pickedLabel = ""             // the label of the app last picked
    static var callLabel = ""               // the label of the call being recorded ("Microsoft Teams", "Google Meet")
    private static var loggedOff: String?

    /// Every 3 s: offer to record a call that just started; end a recorded call when its app is gone. The CoreAudio
    /// walk runs on a utility queue (2026-11-14: ~3 ms on the main thread every 3 s); what to do with it runs on main.
    private static let probeQueue = DispatchQueue(label: "drafter.callwatch", qos: .utility)
    private static var probing = false
    static func tick() {
        guard Drafter.shared.settings.voice else { return }
        if Talk.shared.state != .idle { ownUntil = Date().addingTimeInterval(9); busyTicks = 0 }
        let needed = Talk.shared.state == .idle || (Talk.shared.state == .listening && Talk.shared.isCall)
        if !needed { decide(nil); return }
        guard !probing else { return }
        probing = true
        probeQueue.async {
            let r = probe()
            DispatchQueue.main.async {
                probing = false
                guard Drafter.shared.settings.voice else { return }
                micPids = r.pids; micPid = r.pids.first
                decide(r.busy)
            }
        }
    }

    /// The rest of a tick, on main, with the microphone state just read (nil: not read, as it was not needed).
    private static func decide(_ busyNow: Bool?) {
        if Talk.shared.state == .listening {
            guard Talk.shared.isCall else { return }
            if let app = callApp, NSRunningApplication.runningApplications(withBundleIdentifier: app).isEmpty {
                log("call: \(app) closed, recording ends"); Talk.shared.end(); return
            }
            // a browser call never quits: the call is over when its app lets go of the microphone (Granola's rule too)
            // and nobody spoke for a while; muted in a call that goes on, the other side's words keep it running
            guard let busyNow else { return }
            if busyNow { releasedSince = nil; return }
            if releasedSince == nil { releasedSince = Date(); log("call: the microphone was let go") }
            if Date().timeIntervalSince(releasedSince!) > 45, Talk.shared.quietFor > 30 {
                log("call: microphone free for 45 s and no words for 30 s, recording ends"); Talk.shared.end()
            }
            return
        }
        releasedSince = nil
        guard Talk.shared.state == .idle, let busy = busyNow else { return }
        if !busy { offeredFor = nil; busyTicks = 0; event = nil; loggedOff = nil; return }
        // a call holds the mic for a while; Drafter's own takes (and the moment after them) do not count
        // (2026-10-20: ten offers in Slack after his own voice takes)
        guard Date() > ownUntil else { return }
        busyTicks += 1
        // the app that really holds the mic names the offer (2026-10-21: Zoom held it, the offer said Slack); a call app
        // only, never a voice app or a browser tab that merely records
        guard busyTicks >= 2, offeredFor == nil else { return }
        let (pickApp, off) = pick()
        guard let app = pickApp else {
            // looked at again on the next tick: a call app may start holding the mic beside it
            if let off, loggedOff != off { loggedOff = off; log("call: \(off) holds the mic, offers are off there") }
            return
        }
        offeredFor = app; loggedOff = nil
        let st = Drafter.shared.settings
        if CallAppRules.auto(app: app, on: on(app), calendar: pickedEvent?["calendarId"] as? String, apps: st.autoRecordApps, calendars: st.autoRecordCalendars) {
            event = pickedEvent
            log("call: records by itself in \(app) (auto-record \(st.autoRecordApps.contains(app) ? "for the app" : "for the calendar"))")
            accept()
            return
        }
        offer(app)
    }

    /// The record offer for a call in `app`. test: the same strip from `<bundle id>.offertest`, and Tab only logs.
    static func offer(_ app: String, test: Bool = false) {
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: app).first
        let name = running?.localizedName ?? "call"
        event = Meeting.now()
        let people = Array(((event?["people"] as? [String]) ?? []).filter { !CallDoc.me.contains($0.lowercased()) }.prefix(3))
        Offer.show(ask(name: name, title: (event?["title"] as? String).flatMap { $0.isEmpty ? nil : $0 }, people: people),
                   kind: "Call", side: name, accept: "Record", seconds: 30, app: app) { if test { log("offer test: taken") } else { CallWatch.accept() } }
        log("call: offered for \(app)" + (test ? " (test)" : ""))
        // call prep: notes from the vault cache that match the call windows' titles
        if let pid = running?.processIdentifier {
            let titles = windowTitles(pid) + [NSWorkspace.shared.frontmostApplication.map { Focus.windowTitle($0) } ?? ""]
            Engine.shared.post("/prep", ["text": titles.joined(separator: " · ")]) { j in
                let lines = (j?["lines"] as? [String]) ?? []
                // who it is likely with takes the second row in place: same size, same time left
                guard let first = lines.first, Offer.active, Offer.app == app else { return }
                Pill.shared.offerRow(1, first)
            }
        }
    }

    /// The record offer's rows, the same live and in the strip preview (2026-11-01, Codex notch review: a question, as
    /// the offer comes from the microphone, not from knowing it is a call).
    static func ask(name: String, title: String?, people: [String]) -> [String] {
        [title.map { "Record «\($0)»?" } ?? "Record audio from \(name)?",
         people.isEmpty ? "\(name) is using the microphone" : "with " + people.joined(separator: ", "),
         "Both sides, on this Mac"]
    }

    static func windowTitles(_ pid: pid_t) -> [String] {
        if Focus.offLimits(pid: pid) { return [] }
        let a = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(a, AXOff.timeout)
        var w: CFTypeRef?
        guard AXUIElementCopyAttributeValue(a, kAXWindowsAttribute as CFString, &w) == .success, let wins = w as? [AXUIElement] else { return [] }
        return wins.prefix(6).compactMap { Focus.attr($0, kAXTitleAttribute) as String? }.filter { !$0.isEmpty }
    }

    /// Record on the offer (its button or ⇧ Right Option).
    static func accept() {
        Offer.clear()
        callApp = offeredFor
        callLabel = pickedLabel.isEmpty ? (offeredFor.map(name) ?? "") : pickedLabel
        Talk.shared.beginCall()
    }

    /// ⇧ right ⌥ while another app holds the microphone for a call: record the call (both sides), not a note of his
    /// microphone only. -> true when it started one.
    static func startIfCall() -> Bool {
        guard Talk.shared.state == .idle else { return false }
        if offeredFor == nil || !on(offeredFor!) {
            guard micBusy() else { return false }
            guard let app = pick().app else { return false }   // offers off in every call app holding it: a long note
            offeredFor = app
        }
        guard let app = offeredFor, on(app) else { return false }   // offers off there: a long note of his mic instead
        if event == nil { event = Meeting.now() }
        log("call: started with ⇧ right ⌥ in \(offeredFor ?? "?")")
        accept()
        return true
    }
}

/// The calendar event a call belongs to (EventKit, Drafter's own calendar access): one going on now or starting in the
/// next 10 minutes, a video link or other people first. -> {title, people, start, end}
enum Meeting {
    /// The calendars he lets Drafter read (Settings › Calendars); nil = all of them.
    static func calendars() -> [EKCalendar]? {
        let off = Drafter.shared.settings.calendarsOff
        guard !off.isEmpty else { return nil }
        let on = Actions.store.calendars(for: .event).filter { !off.contains($0.calendarIdentifier) }
        return on.isEmpty ? [] : on
    }
    static let video = try! NSRegularExpression(pattern: #"(?i)meet\.google\.com|zoom\.us|teams\.microsoft|teams\.live|whereby\.com|webex\.com|slack\.com/huddle|facetime"#)

    static func now(_ at: Date = Date(), needPeople: Bool = false) -> [String: Any]? {
        guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else { return nil }
        let s = Actions.store, cals = calendars()
        if cals?.isEmpty == true { return nil }   // every calendar switched off
        // only his chosen calendars, and only a meeting (other people or a video link): a block of time from another
        // tool's calendar named the Slack offer before (2026-11-01, Andrii: "pulling too much from my other tools")
        let evs = s.events(matching: s.predicateForEvents(withStart: at.addingTimeInterval(-6 * 3600), end: at.addingTimeInterval(10 * 60), calendars: cals))
            .filter { !$0.isAllDay && $0.startDate <= at.addingTimeInterval(10 * 60) && $0.endDate > at && $0.status != .canceled }
            .filter { !others($0).isEmpty || (!needPeople && link($0)) }
        // a meeting with a link or people beats a block of time; then the one that started closest to now
        guard let e = evs.max(by: { a, b in
            let ka = (link(a) ? 2 : 0) + (others(a).isEmpty ? 0 : 1), kb = (link(b) ? 2 : 0) + (others(b).isEmpty ? 0 : 1)
            return ka != kb ? ka < kb : abs(a.startDate.timeIntervalSince(at)) > abs(b.startDate.timeIntervalSince(at))
        }) else { return nil }
        return info(e)
    }

    /// A video link in the event's url, place or notes.
    static func link(_ e: EKEvent) -> Bool {
        let t = [e.url?.absoluteString, e.location, e.notes].compactMap { $0 }.joined(separator: " ")
        return video.firstMatch(in: t, range: NSRange(t.startIndex..., in: t)) != nil
    }
    static func others(_ e: EKEvent) -> [EKParticipant] { (e.attendees ?? []).filter { !$0.isCurrentUser } }

    /// What a recording keeps of its event (meta "event"): {title, people, start, end, calendar, service, place}.
    static func info(_ e: EKEvent) -> [String: Any] {
        let people = others(e).prefix(12).compactMap { p -> String? in
            if let n = p.name, !n.isEmpty, !n.contains("@") { return n }
            return p.url.absoluteString.replacingOccurrences(of: "mailto:", with: "").split(separator: "@").first.map(String.init)
        }
        var out: [String: Any] = ["title": e.title ?? "", "people": people, "start": e.startDate.timeIntervalSince1970, "end": e.endDate.timeIntervalSince1970,
                                  "calendar": e.calendar?.title ?? "", "calendarId": e.calendar?.calendarIdentifier ?? ""]
        let text = [e.url?.absoluteString, e.location, e.notes].compactMap { $0 }.joined(separator: " ")
        if let svc = CallAppRules.service(text: text) { out["service"] = svc.rawValue }
        if let place = e.location, !place.isEmpty, CallAppRules.service(text: place) == nil { out["place"] = String(place.prefix(120)) }
        return out
    }
}

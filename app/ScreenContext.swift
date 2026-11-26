// Screen context as a first-class source (14 November 2026). Before: a picture only when Accessibility gave under 120
// characters, taken per read, by window filter, 1.5 s blocking wait, one global back-off. Now:
//   - when: on focus of a field, after a scroll, when the window moves or a new message changes the picture (a 96 px
//     look every 4 s while the user types), never per key, at most one capture per 1.5 s, none after a minute without keys;
//   - what: the window part above the field (its top, not the caret: the field's own lines are not read twice), read
//     as messages with who wrote them (app/ScreenContextRules.swift), the tail under a budget;
//   - which: Accessibility where its text is clean, the picture where it is empty or a page of labels;
//   - kept: the last good text per window and field, in memory, used at once by the next request (stale by seconds).
// Privacy: everything stays on this Mac. No capture in a password field, a skipped app, under secure input, with the
// screen locked or asleep. The picture is never stored; its text lives in memory only, is never logged (lengths and
// times only) and never reaches data/ (journal(): /typed gets the Accessibility text instead).
import AppKit
import Carbon
import ScreenCaptureKit
import Vision

final class ScreenContext {
    static let shared = ScreenContext()
    typealias R = ScreenContextRules

    /// Where the user types: the app, the window, the field and its frame, as the last request saw them.
    struct Target {
        let pid: pid_t, bundle: String, title: String, kind: String
        let caret: CGRect?, field: CGRect?, typing: String
        var key: String { ScreenContext.key(bundle: bundle, title: title, field: field) }
    }
    struct Entry { let text: String; let at: Date; let blocks: Int; let marked: Int }

    private let q = DispatchQueue(label: "drafter.screen", qos: .utility)
    private let lock = NSLock()
    // under `lock`
    private var cache: [String: Entry] = [:], order: [String] = []
    private var memory: [String: R.AppMemory] = [:]
    private var target: Target?
    private var lastKey = 0.0, lastCapture = 0.0, lastScroll = 0.0
    private var inFlight = false, flightGen = 0
    /// One look waits for the user's typing pause (R.when): further asks while it waits add nothing.
    private var pauseQueued = false
    /// The last 96 px gray look per field; nil = a full read just ran, the next look only sets the baseline.
    private var looks: [String: (thumb: [UInt8]?, frame: CGRect)] = [:]
    private var made: [Int: String] = [:], madeOrder: [Int] = []   // hash of a screen text -> the Accessibility text then
    private var timer: DispatchSourceTimer?
    private var scrollMonitor: Any?
    private var stats = Stats()
    /// One ghost shown: its time from the request and, when known, from the key press (the summary's ghost p50/p90).
    func ghostShown(_ shown: TimeInterval, key: TimeInterval?) { stats.ghost(shown: shown, key: key) }

    static func key(bundle: String, title: String, field: CGRect?) -> String {
        bundle + " · " + title + " · " + (field.map { "\(Int($0.minX / 8)),\(Int($0.minY / 8))" } ?? "-")
    }

    // MARK: what Keys asks

    /// The screen context for a field (called off the main thread, from Keys.readContext). Accessibility first; where
    /// that is not clean, the kept picture text at once (and a fresh capture if it is older than 2 s), or on a field
    /// seen for the first time a capture waited for up to `wait` s.
    func read(_ el: AXUIElement, pid: pid_t, caret: CGRect?, wait: Double = 0.9) -> String {
        let ax = Focus.screenContext(el)
        guard Drafter.shared.settings.screenContext, let app = NSRunningApplication(processIdentifier: pid) else { return ax }
        let t = target(el, app: app, caret: caret)
        let now = Date().timeIntervalSince1970
        lock.lock(); let mem = memory[t.bundle] ?? R.AppMemory(); target = t; lock.unlock()
        stats.lock.lock(); stats.asked += 1; stats.lock.unlock()
        guard R.source(ax: ax, memory: mem, now: now) == .screen, ScreenContext.mayCapture(el, bundle: t.bundle, pid: pid) else {
            stats.count(ax.isEmpty ? nil : "ax", chars: ax.count, age: 0); return ax
        }
        if let e = entry(t.key) {
            if Date().timeIntervalSince(e.at) > R.fresh { trigger(.request) }   // a look first; read only if it changed
            return use(e, ax: ax)
        }
        let done = DispatchSemaphore(value: 0)
        q.async { self.capture(t, look: false) { _ in done.signal() } }
        _ = done.wait(timeout: .now() + wait)
        if let e = entry(t.key) { return use(e, ax: ax) }
        stats.count(ax.isEmpty ? nil : "ax", chars: ax.count, age: 0)
        return ax
    }

    /// A key in this field (per key, on main: only times and the target, no capture here).
    func touch(_ s: Spot) {
        guard Drafter.shared.settings.screenContext else { return }
        let now = Date().timeIntervalSince1970
        lock.lock(); lastKey = now; let running = timer != nil; lock.unlock()
        stats.typed(now)
        if !running { startWatch() }
        trigger(.poll)   // a look once the user pauses (R.when), at most every 10 s
    }

    /// The newest kept text for this field, or nil (Keys.contextFor uses it over an older read).
    func kept(_ s: Spot) -> String? {
        guard Drafter.shared.settings.screenContext else { return nil }
        lock.lock(); defer { lock.unlock() }
        guard let t = target, t.pid == s.app.processIdentifier, t.title == s.title, let e = cache[t.key],
              Date().timeIntervalSince(e.at) < R.stale else { return nil }
        return e.text
    }

    /// What may go to data/typed.jsonl for a context: never picture text, the Accessibility text read with it instead.
    func journal(_ text: String) -> String {
        lock.lock(); defer { lock.unlock() }
        return made[text.hashValue] ?? text
    }

    /// Read-only in-memory snapshot for the Inspector page: never logs, writes, or triggers a capture.
    func inspectorInfo() -> (bundle: String, title: String, kind: String, hasOCR: Bool, ocrChars: Int, ocrAgeSec: Double?, ocrText: String, cached: [CachedScreenInfo]) {
        lock.lock(); defer { lock.unlock() }
        let now = Date()
        let bundle = target?.bundle ?? ""
        let title = target?.title ?? ""
        let kind = target?.kind ?? ""
        let active: Entry? = target.flatMap { t in
            guard let e = cache[t.key], now.timeIntervalSince(e.at) < R.stale else { return nil }
            return e
        }
        let cached: [CachedScreenInfo] = order.reversed().compactMap { k in
            guard let e = cache[k] else { return nil }
            let age = max(0, now.timeIntervalSince(e.at))
            guard age < R.stale else { return nil }
            let parts = k.components(separatedBy: " · ")
            let b = parts.first ?? ""
            let t = parts.count >= 2 ? parts[1] : ""
            let label = t.isEmpty ? (b.isEmpty ? k : b) : (b.isEmpty ? t : "\(b) · \(t)")
            return CachedScreenInfo(id: k, title: label, chars: e.text.count, ageSec: age, source: "ocr")
        }
        return (bundle, title, kind, active != nil, active?.text.count ?? 0, active.map { max(0, now.timeIntervalSince($0.at)) }, active?.text ?? "", cached)
    }

    private func use(_ e: Entry, ax: String) -> String {
        // the picture read almost nothing: Accessibility's text if it has more
        if e.text.count < 40, ax.count > e.text.count { stats.count("ax", chars: ax.count, age: 0); return ax }
        stats.count("screen", chars: e.text.count, age: Date().timeIntervalSince(e.at))
        lock.lock()
        if made[e.text.hashValue] == nil { madeOrder.append(e.text.hashValue); if madeOrder.count > 64 { made[madeOrder.removeFirst()] = nil } }
        made[e.text.hashValue] = ax
        lock.unlock()
        return e.text
    }

    private func entry(_ key: String) -> Entry? {
        lock.lock(); defer { lock.unlock() }
        guard let e = cache[key], Date().timeIntervalSince(e.at) < R.stale else { return nil }
        return e
    }

    private func target(_ el: AXUIElement, app: NSRunningApplication, caret: CGRect?) -> Target {
        let id = app.bundleIdentifier ?? "", title = Focus.windowTitle(app)
        let kind = AppKind.of(id, title: title, ai: Keys.aiApps, chats: Keys.chatApps, browsers: Keys.browsers, aiTitle: Keys.aiTitle)
        let caret = caret.flatMap { $0.origin == .zero || $0.height < 2 ? nil : $0 }   // Chromium answers a zero rect
        return Target(pid: app.processIdentifier, bundle: id, title: title, kind: kind, caret: caret,
                      field: Focus.frame(el), typing: Focus.before(el) ?? "")
    }

    /// No picture of a password field, a skipped app, Drafter itself, under secure input, or a locked or sleeping screen.
    static func mayCapture(_ el: AXUIElement, bundle: String, pid: pid_t) -> Bool {
        if pid == getpid() || Drafter.shared.settings.skip.contains(bundle) || IsSecureEventInputEnabled() { return false }
        if Screen.locked || CGDisplayIsAsleep(CGMainDisplayID()) != 0 { return false }
        if !Screen.allowed, !CGPreflightScreenCaptureAccess() { return false }   // granted later: tried again, no restart
        let role: String = Focus.attr(el, kAXRoleAttribute) ?? ""
        let sub: String = Focus.attr(el, kAXSubroleAttribute) ?? ""
        return role != "AXSecureTextField" && sub != "AXSecureTextField"
    }

    // MARK: when

    private func trigger(_ why: R.Why) {
        q.async {
            let now = Date().timeIntervalSince1970
            self.lock.lock(); let t = self.target, lc = self.lastCapture, lk = self.lastKey; self.lock.unlock()
            guard let t else { return }
            // a pause look: only for a screen read by picture, in the app still in front
            if why == .poll, !Drafter.shared.settings.screenContext || NSWorkspace.shared.frontmostApplication?.processIdentifier != t.pid
                || self.entry(t.key) == nil { return }
            switch R.when(why, now: now, lastCapture: lc, lastKey: lk) {
            case .now: self.capture(t, look: R.looks(why)) { _ in }
            case .later(let s) where R.looks(why):
                if self.pauseQueued { return }
                self.pauseQueued = true
                self.q.asyncAfter(deadline: .now() + s) { self.pauseQueued = false; self.trigger(.poll) }
            case .later(let s): self.q.asyncAfter(deadline: .now() + s) { self.trigger(why) }
            case .no: break
            }
        }
    }

    /// While the user types: a scroll reads again once it stops; the looks come in their typing pauses (touch). Stops by itself
    /// a minute after the last key (was a look every 2-4 s while the user typed: 17.4 captures a typing minute).
    private func startWatch() {
        let tm = DispatchSource.makeTimerSource(queue: q)
        tm.schedule(deadline: .now() + 10, repeating: 10, leeway: .seconds(2))
        tm.setEventHandler { [weak self] in
            guard let self else { return }
            self.lock.lock(); let idle = Date().timeIntervalSince1970 - self.lastKey; self.lock.unlock()
            if idle > 60 { self.stopWatch() }
        }
        lock.lock(); timer = tm; lock.unlock()
        tm.resume()
        DispatchQueue.main.async {
            guard self.scrollMonitor == nil else { return }
            self.scrollMonitor = NSEvent.addGlobalMonitorForEvents(matching: .scrollWheel) { [weak self] _ in
                guard let self else { return }
                let now = Date().timeIntervalSince1970
                self.lock.lock(); let was = self.lastScroll; self.lastScroll = now; self.lock.unlock()
                if now - was < 0.3 { return }   // one wait per scroll gesture
                self.q.asyncAfter(deadline: .now() + 0.7) {
                    self.lock.lock(); let quiet = Date().timeIntervalSince1970 - self.lastScroll; self.lock.unlock()
                    if quiet >= 0.6 { self.trigger(.scroll) } else { self.q.asyncAfter(deadline: .now() + 0.7) { self.trigger(.scroll) } }
                }
            }
        }
    }

    private func stopWatch() {
        lock.lock(); let tm = timer; timer = nil; lock.unlock()
        tm?.cancel()
        DispatchQueue.main.async {
            if let m = self.scrollMonitor { NSEvent.removeMonitor(m); self.scrollMonitor = nil }
        }
        stats.flush()
    }

    // MARK: capture and reading (on q)

    /// One capture at a time (two at once failed with -3811 in pairs, 2026-10-28 to 11-13); `look` = a 96 px picture
    /// first, read only when it changed (or the window moved).
    private func capture(_ t: Target, look: Bool, done: @escaping (Entry?) -> Void) {
        let now = Date().timeIntervalSince1970
        lock.lock()
        let mem = memory[t.bundle] ?? R.AppMemory()
        if inFlight || !mem.allowed(now) { lock.unlock(); done(nil); return }
        inFlight = true; flightGen += 1; let gen = flightGen; lastCapture = now
        lock.unlock()
        // a capture whose answer never comes frees the slot after 3 s
        q.asyncAfter(deadline: .now() + 3) { self.lock.lock(); if self.flightGen == gen { self.inFlight = false }; self.lock.unlock() }
        let t0 = Date()
        let finish: (Entry?, String?) -> Void = { e, failure in
            self.lock.lock()
            if self.flightGen == gen { self.inFlight = false }
            if let e { self.cache[t.key] = e; self.order.removeAll { $0 == t.key }; self.order.append(t.key)
                       if self.order.count > 40 { self.cache[self.order.removeFirst()] = nil } }
            if !look {   // a picture that failed or read under 40 characters counts against this app
                var m = self.memory[t.bundle] ?? R.AppMemory()
                m.note(ok: failure == nil && (e?.text.count ?? 0) >= 40, now: Date().timeIntervalSince1970)
                self.memory[t.bundle] = m
            }
            self.lock.unlock()
            if let failure { self.stats.failed(failure) }
            done(e)
        }
        SCShareableContent.getExcludingDesktopWindows(true, onScreenWindowsOnly: true) { content, error in
            self.q.async {
                if let error {
                    let code = (error as NSError).code
                    if code == -3801 { Screen.refused() }
                    finish(nil, "content \(code)"); return
                }
                guard let content, let w = ScreenContext.window(content.windows, t) else { finish(nil, "no window"); return }
                let wf = w.frame
                let fieldTop = t.field.map { Double($0.minY - wf.minY) }, caretTop = t.caret.map { Double($0.minY - wf.minY) }
                guard let (y, h) = R.region(window: (Double(wf.width), Double(wf.height)), fieldTop: fieldTop, caretTop: caretTop) else {
                    finish(nil, "no region"); return
                }
                let local = CGRect(x: 0, y: y, width: Double(wf.width), height: h)
                let global = local.offsetBy(dx: wf.minX, dy: wf.minY)
                let display = content.displays.first { $0.frame.contains(CGPoint(x: global.midX, y: global.midY)) } ?? content.displays.first
                let scale = Double(NSScreen.screens.first { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == display?.displayID }?.backingScaleFactor ?? 2)
                if look {
                    self.lock.lock(); let was = self.looks[t.key]; self.lock.unlock()
                    let lw = 96.0, lh = max(8, (96 * h / max(1, Double(wf.width))).rounded())
                    ScreenContext.shoot(w, display, local: local, global: global, px: (Int(lw), Int(lh))) { img, _ in
                        self.q.async {
                            guard let img else { finish(nil, nil); return }   // a failed look is not counted against the app
                            let th = ScreenContext.thumb(img)
                            self.lock.lock(); self.looks[t.key] = (th, wf); self.lock.unlock()
                            self.stats.looked()
                            // the same as the last look (or the first look after a full read, which only sets the baseline:
                            // a full read's picture and a 96 px look never compared equal, so every look read again)
                            if let was, was.frame == wf, was.thumb.map({ !R.lookChanged($0, th) }) ?? true {
                                // unchanged: the kept text is still what the screen shows, as of now
                                self.lock.lock()
                                if let e = self.cache[t.key] { self.cache[t.key] = Entry(text: e.text, at: Date(), blocks: e.blocks, marked: e.marked) }
                                self.lock.unlock()
                                finish(nil, nil); return
                            }
                            // changed: read it now
                            self.lock.lock(); if self.flightGen == gen { self.inFlight = false }; self.lock.unlock()
                            self.capture(t, look: false, done: done)
                        }
                    }
                    return
                }
                let (pw, ph) = R.pixels(w: Double(wf.width), h: h, scale: scale)
                ScreenContext.shoot(w, display, local: local, global: global, px: (pw, ph)) { img, err in
                    self.q.async {
                        let shot = Date().timeIntervalSince(t0)
                        guard let img else { finish(nil, "capture \((err as NSError?)?.code ?? 0)"); return }
                        let t1 = Date()
                        let lines = ScreenContext.lines(img)
                        let column: (Double, Double)? = t.field.map { f in
                            (Double((f.minX - wf.minX) / wf.width), Double((f.maxX - wf.minX) / wf.width))
                        }.flatMap { $0.1 - $0.0 > 0.2 ? $0 : nil }
                        let c = R.conversation(lines, kind: t.kind, column: column, typing: t.typing)
                        self.stats.timed(shot: shot, read: Date().timeIntervalSince(t1))
                        self.lock.lock(); self.looks[t.key] = (nil, wf); self.lock.unlock()
                        Screen.succeeded()
                        finish(Entry(text: c.text, at: Date(), blocks: c.blocks, marked: c.marked), nil)
                    }
                }
            }
        }
    }

    /// The app's window that holds the field: the one containing the caret or the field, else the one titled as the
    /// focused window, else its frontmost normal window (Chromium apps answer a zero caret; several windows per pid).
    static func window(_ all: [SCWindow], _ t: Target) -> SCWindow? {
        let mine = all.filter { $0.owningApplication?.processID == t.pid && $0.windowLayer == 0 && $0.frame.width > 100 && $0.frame.height > 100 }
        for r in [t.caret, t.field].compactMap({ $0 }) {
            if let w = mine.first(where: { $0.frame.contains(CGPoint(x: r.midX, y: r.midY)) }) { return w }
        }
        if !t.title.isEmpty, let w = mine.first(where: { $0.title == t.title }) { return w }
        return mine.first
    }

    /// One picture: the display with only this window in it (robust where the window-only filter failed with -3811);
    /// on failure once more with the window-only filter.
    static func shoot(_ w: SCWindow, _ d: SCDisplay?, local: CGRect, global: CGRect, px: (Int, Int),
                      _ done: @escaping (CGImage?, Error?) -> Void) {
        let cfg = SCStreamConfiguration()
        cfg.width = px.0; cfg.height = px.1; cfg.showsCursor = false
        let byWindow = {
            let c2 = SCStreamConfiguration()
            c2.width = px.0; c2.height = px.1; c2.showsCursor = false; c2.sourceRect = local
            SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: w), configuration: c2, completionHandler: done)
        }
        guard let d else { byWindow(); return }
        cfg.sourceRect = global.offsetBy(dx: -d.frame.minX, dy: -d.frame.minY)
        SCScreenshotManager.captureImage(contentFilter: SCContentFilter(display: d, including: [w]), configuration: cfg) { img, err in
            if let img { done(img, nil) } else { _ = err; byWindow() }
        }
    }

    /// Vision's lines with their boxes (0...1, top left), Ukrainian and English, small text included.
    static func lines(_ image: CGImage) -> [R.Line] {
        let req = VNRecognizeTextRequest()
        req.recognitionLevel = .accurate
        req.recognitionLanguages = ["uk-UA", "en-US"]
        req.usesLanguageCorrection = true
        req.minimumTextHeight = Float(min(0.03, 14.0 / Double(max(1, image.height))))   // default 1/32 skips chat text
        try? VNImageRequestHandler(cgImage: image).perform([req])
        return (req.results ?? []).compactMap { o in
            guard let s = o.topCandidates(1).first?.string else { return nil }
            let b = o.boundingBox
            return R.Line(text: s, x: b.minX, y: 1 - b.maxY, w: b.width, h: b.height)
        }
    }

    /// A coarse fingerprint of a picture (4 bits per channel, so the same screen gives the same number).
    /// A look as gray bytes, `width` wide, compared with a tolerance (ScreenContextRules.lookChanged), never byte for byte.
    static func thumb(_ img: CGImage, width: Int = 96) -> [UInt8] {
        let w = width, h = max(1, img.height * width / max(1, img.width))
        var px = [UInt8](repeating: 0, count: w * h)
        px.withUnsafeMutableBytes { buf in
            guard let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return }
            ctx.interpolationQuality = .low
            ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        return px
    }

    // MARK: cost and use, numbers only

    final class Stats {
        let lock = NSLock()
        var shots: [Double] = [], reads: [Double] = [], looks = 0, minutes = Set<Int>(), asked = 0
        var used: [String: Int] = [:], chars: [Int] = [], ages: [Double] = [], failures: [String: Int] = [:]
        var since = Date()
        /// Ghost text latency, s: request to grey text (`ghosts`) and key press to grey text (`keys`); Keys.swift "shown".
        var ghosts: [Double] = [], keys: [Double] = []
        func ghost(shown: Double, key: Double?) { lock.lock(); ghosts.append(shown); if let k = key { keys.append(k) }; lock.unlock(); maybeFlush() }
        func typed(_ now: Double) { lock.lock(); minutes.insert(Int(now / 60)); lock.unlock() }
        func looked() { lock.lock(); looks += 1; lock.unlock() }
        func timed(shot: Double, read: Double) { lock.lock(); shots.append(shot); reads.append(read); lock.unlock(); maybeFlush() }
        func failed(_ why: String) { lock.lock(); failures[why, default: 0] += 1; lock.unlock() }
        func count(_ src: String?, chars n: Int, age: Double) {
            lock.lock(); used[src ?? "none", default: 0] += 1
            if src != nil { chars.append(n) }; if src == "screen" { ages.append(age) }
            lock.unlock()
        }
        func maybeFlush() { if Date().timeIntervalSince(since) > 600 { flush() } }
        /// One line every 10 minutes of use: captures per typing minute, times, sources, lengths, ages, failures.
        func flush() {
            lock.lock()
            defer { shots = []; reads = []; ghosts = []; keys = []; looks = 0; minutes = []; asked = 0; used = [:]; chars = []; ages = []; failures = [:]; since = Date(); lock.unlock() }
            guard !shots.isEmpty || !failures.isEmpty || used["screen"] != nil || !ghosts.isEmpty else { return }
            let ms = { (a: [Double], p: Double) -> Int in a.isEmpty ? 0 : Int(a.sorted()[min(a.count - 1, Int(p * Double(a.count)))] * 1000) }
            let pc = { (a: [Int], p: Double) -> Int in a.isEmpty ? 0 : a.sorted()[min(a.count - 1, Int(p * Double(a.count)))] }
            let mins = max(1, minutes.count)
            let fails = failures.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", ")
            let rate = String(format: "%.1f", Double(shots.count) / Double(mins))
            let s1: String = "screen context: \(shots.count) reads + \(looks) looks in \(mins) typing min (\(rate)/min)"
            let s2: String = " · capture p50 \(ms(shots, 0.5)) p90 \(ms(shots, 0.9)) ms · text p50 \(ms(reads, 0.5)) p90 \(ms(reads, 0.9)) ms"
            let s3: String = " · asked \(asked): screen \(used["screen"] ?? 0) ax \(used["ax"] ?? 0) none \(used["none"] ?? 0)"
            let s4: String = " · chars p50 \(pc(chars, 0.5)) p90 \(pc(chars, 0.9)) · age p50 \(ms(ages, 0.5)) p90 \(ms(ages, 0.9)) ms"
            let s5: String = fails.isEmpty ? "" : " · failures \(fails)"
            let s6: String = ghosts.isEmpty ? "" : " · ghost \(ghosts.count) p50 \(ms(ghosts, 0.5)) p90 \(ms(ghosts, 0.9)) ms"
                + (keys.isEmpty ? "" : ", from key p50 \(ms(keys, 0.5)) p90 \(ms(keys, 0.9)) ms")
            log(s1 + s2 + s3 + s4 + s5 + s6)
        }
    }
}

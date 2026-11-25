// Screenshots while a long note or call records (2026-10-29, Andrii: "talking, showing my screen, then pass it over to
// the AI"). Granola's Snapshots keep only what other people share; this keeps his own screen too. A shot is kept when
// the screen changed and then stood still (or kept moving for 6 s), at most one per 5 s and 300 per recording, from the
// display under the mouse, without Drafter's own strip. Files sit next to the audio: <recording>/shots/*.jpg and
// shots.json (time on the audio timeline, app, window title). Local only; the brief (brief.md) points at them.
import AppKit
import ScreenCaptureKit
import UniformTypeIdentifiers

final class Shots {
    static let maxShots = 300
    static let thumbW = 128, thumbH = 80
    let dir: URL                         // <recording>/shots
    private let clock: () -> Double      // seconds on the recording's audio timeline
    private var timer: Timer?
    private var content: SCShareableContent?, contentAt = Date.distantPast
    private var kept: [UInt8]?, prev: [UInt8]?
    private var lastKept = Date.distantPast, changedSince: Date?, lastApp = ""
    private var busy = false
    private var backoff = Backoff(first: 15, most: 300)   // a failing capture waits instead of failing every 1.5 s
    private(set) var list: [Shot] = []
    private let io = DispatchQueue(label: "drafter.shots")

    init(recording: URL, clock: @escaping () -> Double) {
        dir = recording.appendingPathComponent("shots"); self.clock = clock
    }

    func start() {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in self?.tick() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.tick() }
        log("shots: on")
    }

    @discardableResult
    func stop() -> [Shot] {
        timer?.invalidate(); timer = nil
        save()
        if list.isEmpty { try? FileManager.default.removeItem(at: dir) }
        log("shots: \(list.count) kept")
        return list
    }

    private func save() {
        guard let d = try? JSONEncoder().encode(list) else { return }
        try? d.write(to: dir.deletingLastPathComponent().appendingPathComponent("shots.json"))
    }

    // MARK: watching the screen

    private func tick() {
        guard !busy, list.count < Shots.maxShots, Screen.allowed, backoff.allowed(),
              ScreenVideoRecorder.mayCaptureFrontApp() else { return }
        busy = true
        let front = NSWorkspace.shared.frontmostApplication
        // the window title off the main thread, on the front app's AX queue (AXOff; Drafter in front: here, on main)
        let app = front?.localizedName ?? ""
        AXOff.read({ front.map { Focus.windowTitle($0) } ?? "" }) { title in self.shoot(app: app, title: title) }
    }

    private func shoot(app: String, title: String) {
        withContent { c in
            guard let c, let (d, filter) = Shots.target(c) else { self.busy = false; return }
            let cfg = SCStreamConfiguration()
            cfg.width = Shots.thumbW; cfg.height = Shots.thumbH; cfg.showsCursor = false
            SCScreenshotManager.captureImage(contentFilter: filter, configuration: cfg) { img, err in
                DispatchQueue.main.async {
                    guard let img, let g = Shots.gray(img) else {
                        if err != nil { self.failed("thumbnail", err) }
                        self.busy = false; return
                    }
                    if self.backoff.succeeded() { log("shots: working again") }
                    if self.decide(g, app: app) { self.keep(d, filter, app: app, title: title, thumb: g) } else { self.busy = false }
                }
            }
        }
    }

    /// Keep this moment? A change against the last kept shot (or another app in front) that then stands still;
    /// a screen that keeps moving (video, a webcam tile) is taken after 6 s of change.
    private func decide(_ g: [UInt8], app: String) -> Bool {
        defer { prev = g }
        guard let k = kept else { return true }                       // the first shot: where it starts
        let changed = Shots.diff(k, g) > 0.06 || (app != lastApp && Shots.diff(k, g) > 0.02)
        if !changed { changedSince = nil; return false }
        if changedSince == nil { changedSince = Date() }
        let still = prev.map { Shots.diff($0, g) < 0.03 } ?? false
        let waited = Date().timeIntervalSince(changedSince!) >= 6
        return (still || waited) && Date().timeIntervalSince(lastKept) >= 5
    }

    private func keep(_ d: SCDisplay, _ filter: SCContentFilter, app: String, title: String, thumb: [UInt8]) {
        let t = clock()
        kept = thumb; lastKept = Date(); lastApp = app; changedSince = nil
        let cfg = SCStreamConfiguration()
        let scale = max(1, CGFloat(NSScreen.screens.first(where: { $0.number == d.displayID })?.backingScaleFactor ?? 2))
        let w = CGFloat(d.width) * scale, h = CGFloat(d.height) * scale, k = min(1, 1920 / w)
        cfg.width = Int(w * k); cfg.height = Int(h * k); cfg.showsCursor = true
        SCScreenshotManager.captureImage(contentFilter: filter, configuration: cfg) { img, err in
            guard let img else {
                DispatchQueue.main.async { self.failed("capture", err); self.busy = false }
                return
            }
            let n = self.list.count + 1
            let name = String(format: "%03d-%02dm%02ds.jpg", n, Int(t) / 60, Int(t) % 60)
            let url = self.dir.appendingPathComponent(name)
            self.io.async {
                let ok = Shots.jpeg(img, to: url)
                DispatchQueue.main.async {
                    self.busy = false
                    guard ok else { log("shots: could not write \(name)"); return }
                    self.list.append(Shot(t: (t * 10).rounded() / 10, file: "shots/" + name, app: app, title: title))
                    self.save()
                }
            }
        }
    }

    private func failed(_ what: String, _ err: Error?) {
        let (wait, tell) = backoff.failed()
        if tell { log("shots: \(what) failed: \(SysAudio.describe(err)); next try in \(Int(wait)) s") }
    }

    private func withContent(_ done: @escaping (SCShareableContent?) -> Void) {
        if let c = content, Date().timeIntervalSince(contentAt) < 20 { done(c); return }
        SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: true) { c, e in
            DispatchQueue.main.async {
                if c == nil { log("shots: no screen content (\(e?.localizedDescription ?? "?"))") }
                self.content = c; self.contentAt = Date()
                done(c)
            }
        }
    }

    /// The display under the mouse, without the strip and the capture's chrome (OwnChrome); Drafter's window shows.
    /// Main thread.
    static func target(_ c: SCShareableContent) -> (SCDisplay, SCContentFilter)? {
        let mouse = NSEvent.mouseLocation
        let id = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) })?.number
        guard let d = c.displays.first(where: { $0.displayID == id }) ?? c.displays.first else { return nil }
        return (d, OwnChrome.filter(d, c, hide: OwnChrome.ids()))
    }

    // MARK: pictures

    static func gray(_ img: CGImage) -> [UInt8]? {
        var px = [UInt8](repeating: 0, count: thumbW * thumbH)
        let ok = px.withUnsafeMutableBytes { buf -> Bool in
            guard let ctx = CGContext(data: buf.baseAddress, width: thumbW, height: thumbH, bitsPerComponent: 8, bytesPerRow: thumbW,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            ctx.interpolationQuality = .low
            ctx.draw(img, in: CGRect(x: 0, y: 0, width: thumbW, height: thumbH))
            return true
        }
        return ok ? px : nil
    }

    /// Share of thumbnail pixels that changed by more than 32 of 255 (slides, pages, windows; not a webcam's noise).
    static func diff(_ a: [UInt8], _ b: [UInt8]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return 1 }
        var n = 0
        for i in 0..<a.count where abs(Int(a[i]) - Int(b[i])) > 32 { n += 1 }
        return Double(n) / Double(a.count)
    }

    static func jpeg(_ img: CGImage, to url: URL) -> Bool {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else { return false }
        CGImageDestinationAddImage(dest, img, [kCGImageDestinationLossyCompressionQuality: 0.6] as CFDictionary)
        return CGImageDestinationFinalize(dest)
    }
}

extension NSScreen {
    var number: CGDirectDisplayID? { (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value }
}

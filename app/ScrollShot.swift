// Scrolling capture (17 November 2026; like CleanShot X and Shottr). In the capture overlay S (or its button) and a
// dragged region: the overlay goes, a dashed frame marks the region and a small pill sits under it. He scrolls the app
// below as usual (the mouse and every key but ↵ and esc go to it); every 0.12 s the region is taken again and the
// rows that scrolled in are added at the foot (StitchRules: a fixed header and footer stay once). ↵ or a click on the
// pill ends it: the tall picture lands like any shot (one deck card, Capture.landTaken). esc drops it. Frames are
// taken with Drafter's own windows left out (OwnChrome), and the frame and pill are never in a picture.
import AppKit
import ScreenCaptureKit

final class ScrollShot {
    static let shared = ScrollShot()
    private(set) var isOn = false

    private var rect = NSRect.zero
    private var mode = ShotRules.Mode.paste
    private var origin: NSRunningApplication?
    private var title = ""
    private var t0 = Date()
    private var filter: SCContentFilter?
    private var cfg: SCStreamConfiguration?
    private var timer: Timer?
    private var busy = false
    let work = DispatchQueue(label: "drafter.scrollshot")
    // on `work`: the first frame, the strips added since, the last kept frame and its row signatures
    private var first: CGImage?
    private var strips: [CGImage] = []
    private var last: CGImage?
    private var kept: [UInt64] = []
    private var footer = 0
    private var rows = 0
    private var skipped = 0
    private var panels: [NSPanel] = []
    private var hint: ScrollHintView?

    // MARK: start, end

    func start(_ r: NSRect, hide: Set<CGWindowID>, mode: ShotRules.Mode, origin: NSRunningApplication?, title: String) {
        guard !isOn else { return }
        isOn = true; rect = r; self.mode = mode; self.origin = origin; self.title = title; t0 = Date()
        work.sync { first = nil; strips = []; last = nil; kept = []; footer = 0; rows = 0; skipped = 0 }
        busy = false
        showChrome()
        let scr = NSScreen.screens.first { $0.frame.contains(NSPoint(x: r.midX, y: r.midY)) } ?? NSScreen.main
        guard let scr else { cancel("no screen"); return }
        let did = scr.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
        let scale = scr.backingScaleFactor, frame = scr.frame
        SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: true) { content, _ in
            DispatchQueue.main.async {
                guard self.isOn else { return }
                guard let content, let d = content.displays.first(where: { $0.displayID == did }) ?? content.displays.first else {
                    _ = Screen.failed(); self.cancel("no screen access"); return
                }
                // its own frame and pill too (they sit outside the region, and are never shared anyway)
                let own = hide.union(self.panels.filter { $0.windowNumber > 0 }.map { CGWindowID($0.windowNumber) })
                self.filter = OwnChrome.filter(d, content, hide: own)
                let c = SCStreamConfiguration(); c.showsCursor = false
                let src = ShotRules.sourceRect(r, display: frame)
                c.sourceRect = src; c.width = max(1, Int(src.width * scale)); c.height = max(1, Int(src.height * scale))
                self.cfg = c
                self.timer = Timer.scheduledTimer(withTimeInterval: 0.12, repeats: true) { _ in self.tick() }
                self.tick()
            }
        }
        log("capture: scrolling capture on, region \(Int(r.width))×\(Int(r.height))")
    }

    /// ↵ or the pill: the tall picture, as one shot.
    func finish() {
        guard isOn else { return }
        stopTimer()
        let shot = Date()
        // the frame in flight (if any) lands first: `work` is serial
        work.async {
            let img = self.compose()
            let n = self.strips.count, skipped = self.skipped
            DispatchQueue.main.async {
                self.end()
                guard let img, let png = NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:]) else {
                    Pill.shared.flash("Nothing was taken"); log("capture: scrolling capture empty"); return
                }
                log("capture: scrolling capture \(img.width)×\(img.height) px from \(n + 1) frames (\(skipped) skipped) in \(Int(shot.timeIntervalSince(self.t0) * 1000)) ms")
                Capture.shared.landTaken(png, width: img.width, height: img.height, rect: self.rect, window: false, full: false, mode: self.mode,
                                         origin: self.origin, app: self.origin?.localizedName ?? "", title: self.title,
                                         t0: self.t0, shot: shot, inPlace: false)
            }
        }
    }

    /// esc: nothing is kept.
    func cancel(_ why: String = "esc") {
        guard isOn else { return }
        stopTimer(); end()
        work.async { self.first = nil; self.strips = []; self.last = nil }
        log("capture: scrolling capture dropped (\(why))")
        if CaptureNote.shared.collecting { CaptureNote.shared.resume() }   // the deck's next shot: the deck as it was
    }

    /// A key while it runs (the event tap): ↵ ends, esc drops; every other key goes on to the app (arrows, space, page down).
    func key(_ code: Int) -> Bool {
        switch code {
        case 36, 76: DispatchQueue.main.async { self.finish() }; return true
        case 53: DispatchQueue.main.async { self.cancel() }; return true
        default: return false
        }
    }

    private func stopTimer() { timer?.invalidate(); timer = nil }
    private func end() {
        isOn = false
        for p in panels { p.orderOut(nil) }
        panels = []; hint = nil
    }

    // MARK: frames

    private func tick() {
        guard isOn, !busy, let filter, let cfg else { return }
        busy = true
        SCScreenshotManager.captureImage(contentFilter: filter, configuration: cfg) { img, _ in
            guard let img else { DispatchQueue.main.async { self.busy = false }; return }
            self.work.async {
                self.add(img)
                let h = self.rows, full = h >= StitchRules.maxHeight
                DispatchQueue.main.async {
                    self.busy = false
                    self.hint?.rows = h; self.hint?.needsDisplay = true
                    if full { self.finish() }
                }
            }
        }
    }

    /// On `work`: a frame against the last kept one; the rows that scrolled in become a strip.
    func add(_ img: CGImage) {
        let sig = Self.signatures(img)
        guard let prev = last else { first = Self.copy(img); last = img; kept = sig; rows = img.height; return }
        guard img.width == prev.width, img.height == prev.height else { return }
        guard let m = StitchRules.match(kept, sig) else { if sig != kept { skipped += 1 }; return }
        guard m.shift > 0 else { return }
        let r = StitchRules.newRows(m, height: img.height)
        guard !r.isEmpty, rows + r.count <= StitchRules.maxHeight,
              let cut = img.cropping(to: CGRect(x: 0, y: r.lowerBound, width: img.width, height: r.count)) else { return }
        if let s = Self.copy(cut) { strips.append(s) }
        last = img; kept = sig; footer = m.bottom; rows += r.count
    }

    /// On `work`: the first frame without its footer, the strips, then the last frame's footer.
    func compose() -> CGImage? {
        guard let f = first else { return nil }
        if strips.isEmpty { return f }
        let w = f.width, h = StitchRules.height(first: f.height, strips: strips.map(\.height), footer: footer)
        guard let cs = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue) else { return nil }
        var y = 0   // from the top
        func put(_ img: CGImage, rows: Range<Int>) {
            guard !rows.isEmpty, y < h, let c = img.cropping(to: CGRect(x: 0, y: rows.lowerBound, width: img.width, height: rows.count)) else { return }
            ctx.draw(c, in: CGRect(x: 0, y: h - y - rows.count, width: w, height: rows.count))
            y += rows.count
        }
        put(f, rows: 0..<(f.height - footer))
        for s in strips { put(s, rows: 0..<s.height) }
        if footer > 0, let l = last { put(l, rows: (l.height - footer)..<l.height) }
        return ctx.makeImage()
    }

    /// One signature per pixel row: the frame drawn 96 pixels wide in grey, rows kept as they are.
    static func signatures(_ img: CGImage) -> [UInt64] {
        let w = 96, h = img.height
        var grey = [UInt8](repeating: 0, count: w * h)
        let ok = grey.withUnsafeMutableBytes { buf -> Bool in
            guard let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            ctx.interpolationQuality = .low
            ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        return ok ? StitchRules.signatures(grey, width: w, rows: h) : []
    }

    /// A picture of its own (a crop keeps its whole source frame alive otherwise).
    static func copy(_ img: CGImage) -> CGImage? {
        guard let cs = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: img.width, height: img.height, bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue) else { return nil }
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: img.width, height: img.height))
        return ctx.makeImage()
    }

    // MARK: the frame and the pill

    private func showChrome() {
        let edge = ScrollShot.panel(rect.insetBy(dx: -3, dy: -3), mouse: false)
        edge.contentView = ScrollEdgeView(frame: NSRect(origin: .zero, size: edge.frame.size))
        let size = NSSize(width: 300, height: 34)
        let scr = NSScreen.screens.first { $0.frame.intersects(rect) }?.visibleFrame ?? rect
        var at = NSPoint(x: rect.midX - size.width / 2, y: rect.minY - 10 - size.height)
        if at.y < scr.minY + 8 { at.y = rect.maxY + 10 }                          // no room under it: above
        if at.y + size.height > scr.maxY - 8 { at.y = rect.minY + 10 }            // nor above: inside, at its foot
        at.x = min(max(at.x, scr.minX + 8), scr.maxX - 8 - size.width)
        let pill = ScrollShot.panel(NSRect(origin: at, size: size), mouse: true)
        let v = ScrollHintView(frame: NSRect(origin: .zero, size: size)); v.done = { [weak self] in self?.finish() }
        pill.contentView = v; hint = v
        panels = [edge, pill]
        for p in panels { p.orderFrontRegardless() }
    }

    static func panel(_ r: NSRect, mouse: Bool) -> NSPanel {
        let p = NSPanel(contentRect: r, styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: false)
        p.isOpaque = false; p.backgroundColor = .clear; p.hasShadow = false; p.level = .screenSaver
        p.sharingType = .none; p.ignoresMouseEvents = !mouse; p.hidesOnDeactivate = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        p.identifier = OwnChrome.strip
        return p
    }
}

/// The dashed frame round the region.
final class ScrollEdgeView: NSView {
    override func draw(_ dirty: NSRect) {
        let p = NSBezierPath(rect: bounds.insetBy(dx: 1.5, dy: 1.5)); p.lineWidth = 2
        p.setLineDash([6, 4], count: 2, phase: 0)
        Native.blue.setStroke(); p.stroke()
    }
}

/// The pill under the region: what to do, how tall it is so far; a click ends it.
final class ScrollHintView: NSView {
    var rows = 0
    var done: (() -> Void)?
    override func mouseDown(with e: NSEvent) { done?() }
    override func draw(_ dirty: NSRect) {
        let r = bounds.insetBy(dx: 0.5, dy: 0.5)
        let bg = NSBezierPath(roundedRect: r, xRadius: r.height / 2, yRadius: r.height / 2)
        NSColor.black.withAlphaComponent(0.78).setFill(); bg.fill()
        let px = rows > 0 ? "  ·  \(rows) px" : ""
        let s = NSMutableAttributedString(string: "Scroll now\(px)   ", attributes: [.font: NSFont.systemFont(ofSize: 13, weight: .medium), .foregroundColor: NSColor.white])
        s.append(NSAttributedString(string: "↵ Done   esc Cancel", attributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.white.withAlphaComponent(0.7)]))
        let sz = s.size()
        s.draw(at: NSPoint(x: (bounds.width - sz.width) / 2, y: (bounds.height - sz.height) / 2))
    }
}

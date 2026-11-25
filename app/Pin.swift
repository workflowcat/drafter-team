// A pinned shot (17 November 2026; like CleanShot X and Shottr): a deck card floats on the screen as a small picture
// above other windows, to keep it in sight while he works. ⌘P or the card's pin button. Drag moves it, scroll (or a
// pinch) resizes it with its shape kept (DeckRules.pinZoom), esc or the ✕ on hover closes it, a double-click too.
// It never takes the app's focus (a non-activating panel); a click makes it the key window so esc reaches it.
// Several can be up at once; they stay until closed (not kept across restarts).
import AppKit

final class PinPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

enum Pins {
    private(set) static var open: [PinPanel] = []

    /// Pin a picture: at its own size (at most 45% of the screen), over `region` when it is still on the screen as
    /// taken, else near the mouse.
    static func pin(_ png: Data, region: NSRect? = nil) {
        guard let img = NSImage(data: png), let rep = NSBitmapImageRep(data: png) else { return }
        let m = NSEvent.mouseLocation
        let scr = NSScreen.screens.first { $0.frame.contains(m) } ?? NSScreen.main
        let vis = scr?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let size = DeckRules.pinSize(pixels: CGSize(width: rep.pixelsWide, height: rep.pixelsHigh), scale: scr?.backingScaleFactor ?? 2,
                                     screen: vis.size)
        var at: NSPoint
        if let r = region, r.width > 0, abs(r.width - size.width) < 2 { at = r.origin }
        else { at = NSPoint(x: m.x + 24, y: m.y - size.height - 24) }
        at.x = min(max(at.x, vis.minX + 8), vis.maxX - 8 - size.width)
        at.y = min(max(at.y, vis.minY + 8), vis.maxY - 8 - size.height)
        let p = PinPanel(contentRect: NSRect(origin: at, size: size), styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: false)
        p.isOpaque = false; p.backgroundColor = .clear; p.hasShadow = true; p.level = .floating
        p.isMovableByWindowBackground = true; p.hidesOnDeactivate = false; p.isReleasedWhenClosed = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let v = PinView(frame: NSRect(origin: .zero, size: size)); v.image = img; v.panel = p
        p.contentView = v
        p.orderFrontRegardless()
        open.append(p)
        log("shot: pinned \(Int(size.width))×\(Int(size.height)) pt, \(open.count) up")
    }

    static func close(_ p: PinPanel) {
        p.orderOut(nil)
        open.removeAll { $0 === p }
        log("shot: pin closed, \(open.count) up")
    }
}

final class PinView: NSView {
    var image: NSImage?
    weak var panel: PinPanel?
    private var hovering = false
    var previewHover = false   // the render's hover (no mouse there)
    private var area: NSTrackingArea?

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for e: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { true }

    override func updateTrackingAreas() {
        if let a = area { removeTrackingArea(a) }
        let a = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(a); area = a
        super.updateTrackingAreas()
    }
    override func mouseEntered(with e: NSEvent) { hovering = true; needsDisplay = true }
    override func mouseExited(with e: NSEvent) { hovering = false; needsDisplay = true }

    /// The ✕ at the top right (shown on hover).
    private var closeRect: NSRect { NSRect(x: bounds.maxX - 6 - 22, y: bounds.maxY - 6 - 22, width: 22, height: 22) }

    override func mouseDown(with e: NSEvent) {
        let p = convert(e.locationInWindow, from: nil)
        if hovering, closeRect.contains(p) || e.clickCount == 2 { if let w = panel { Pins.close(w) }; return }
        window?.makeKey(); window?.makeFirstResponder(self)
        super.mouseDown(with: e)   // the window moves with the drag (movable by its background)
    }
    override func keyDown(with e: NSEvent) {
        if e.keyCode == 53, let w = panel { Pins.close(w); return }
        super.keyDown(with: e)
    }
    override func scrollWheel(with e: NSEvent) { zoom(e.scrollingDeltaY * (e.hasPreciseScrollingDeltas ? 0.25 : 1)) }
    override func magnify(with e: NSEvent) { zoom(e.magnification * 50) }

    private func zoom(_ dy: CGFloat) {
        guard let w = window, dy != 0 else { return }
        let vis = w.screen?.visibleFrame.size ?? CGSize(width: 1440, height: 900)
        let s = DeckRules.pinZoom(w.frame.size, dy: dy, screen: vis)
        guard s != w.frame.size else { return }
        let c = NSPoint(x: w.frame.midX, y: w.frame.midY)
        w.setFrame(NSRect(x: (c.x - s.width / 2).rounded(), y: (c.y - s.height / 2).rounded(), width: s.width, height: s.height), display: true)
    }

    override func draw(_ dirty: NSRect) {
        let r = bounds.insetBy(dx: 0.5, dy: 0.5)
        let clip = NSBezierPath(roundedRect: r, xRadius: 8, yRadius: 8)
        NSGraphicsContext.saveGraphicsState(); clip.addClip()
        image?.draw(in: bounds, from: .zero, operation: .sourceOver, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        Native.line.setStroke(); clip.lineWidth = 0.5; clip.stroke()
        guard hovering || previewHover else { return }
        let c = closeRect
        NSColor.black.withAlphaComponent(0.6).setFill(); NSBezierPath(ovalIn: c).fill()
        let x = NSBezierPath(); x.lineWidth = 1.5; x.lineCapStyle = .round
        x.move(to: NSPoint(x: c.minX + 7, y: c.minY + 7)); x.line(to: NSPoint(x: c.maxX - 7, y: c.maxY - 7))
        x.move(to: NSPoint(x: c.minX + 7, y: c.maxY - 7)); x.line(to: NSPoint(x: c.maxX - 7, y: c.minY + 7))
        NSColor.white.setStroke(); x.stroke()
    }
}

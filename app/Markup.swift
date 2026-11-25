// Markup on a captured picture (round three, Part C, 14 November 2026): arrow, box, highlight, text label, blur,
// crop, numbered pin (7: a click puts the next number, typing adds its text; screenshot tool, 15 November 2026), a
// freehand pen (P, 17 November 2026, app/PenRules.swift: one ⌘Z takes back one stroke); 1-7 and P pick the tool,
// ⌘Z and ⌘⇧Z undo and redo, ↵ accepts, esc goes back. Our own small layer (no dependency; the options weighed in
// docs/rounds/2026-11-14-quick.md). The model is MarkupRules.swift; this file draws marks onto a picture (full size
// on accept, view size while editing) and holds the editor.
// Look round (15 November 2026; Andrii: "a nicer drawing experience and a better toolbar"): after a region capture the
// marks go on in place - the picture stays where it was on the screen, the rest dimmed, the markup pill attached under
// it (ShotRules.attach; key and strip round: no room under it = the screen's bottom edge, never above the picture).
// Window and screen captures, and ⌘E from the journal, use the editor panel, the same pill at its foot. Five colours
// (R Y G B V), three sizes ([ ]), a filled tapered arrow, a marker highlight (multiply), a real blur (blocks first,
// then a Gaussian over them: smooth, and the text under it cannot be read back). A click on a mark selects it, a drag
// moves it, ⌫ deletes it; undo covers all of it. ⌘N (or +) ends the markup and dims the screen for another picture of
// the same hand-off.
// Like the capture, the panel is non-activating and never key: his app keeps the caret, keys come through the event
// tap, the mouse comes here.
import AppKit
import CoreImage

enum MarkupDraw {
    static func color(_ i: Int) -> NSColor {
        let v = Markup.colors[min(max(i, 0), Markup.colors.count - 1)].rgb
        return NSColor(srgbRed: CGFloat((v >> 16) & 255) / 255, green: CGFloat((v >> 8) & 255) / 255, blue: CGFloat(v & 255) / 255, alpha: 1)
    }
    /// Text on a mark's colour: dark on yellow, white on the rest.
    static func onColor(_ i: Int) -> NSColor { i == 1 ? NSColor(white: 0.08, alpha: 1) : .white }
    static let ci = CIContext(options: [.cacheIntermediates: false])

    /// The picture with its marks, cropped. `scale`: picture pixels to output pixels (1 on accept; the view's scale
    /// while editing, drawn over an already scaled base). `live`: a mark being dragged, drawn as well. `moving`: a mark
    /// drawn shifted while it is dragged.
    static func render(_ base: CGImage, _ m: Markup, scale s: CGFloat = 1, live: PicMark? = nil, cropped: Bool = true,
                       moving: (index: Int, dx: CGFloat, dy: CGFloat)? = nil) -> CGImage? {
        let W = base.width, H = base.height
        guard let ctx = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.draw(base, in: CGRect(x: 0, y: 0, width: W, height: H))
        ctx.translateBy(x: 0, y: CGFloat(H)); ctx.scaleBy(x: 1, y: -1)   // top-left from here on, as the marks are
        let ns = NSGraphicsContext(cgContext: ctx, flipped: true)
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = ns
        var marks = m.marks
        if let mv = moving, marks.indices.contains(mv.index) { marks[mv.index] = marks[mv.index].moved(mv.dx, mv.dy) }
        // blurs first: a mark drawn over a blurred part stays sharp
        let all = marks + (live.map { [$0] } ?? [])
        for mark in all.filter({ $0.tool == .pixelate }) + all.filter({ $0.tool != .pixelate }) where mark.tool != .crop {
            let r = CGRect(x: mark.rect.minX * s, y: mark.rect.minY * s, width: mark.rect.width * s, height: mark.rect.height * s)
            let a = CGPoint(x: mark.from.x * s, y: mark.from.y * s), b = CGPoint(x: mark.to.x * s, y: mark.to.y * s)
            let lw = Markup.stroke(m.size, level: mark.size) * s, c = color(mark.color)
            switch mark.tool {
            case .arrow: arrow(a, b, width: lw, color: c)
            case .pen: pen(mark.points.map { CGPoint(x: $0.x * s, y: $0.y * s) }, width: lw, color: c)
            case .box: box(r, width: lw, color: c)
            case .highlight: highlight(ctx, r, height: lw, color: c, look: Markup.highlightLook(background: luminance(base, under: Markup.highlightSample(r))))
            case .label: label(mark.text, at: a, size: Markup.labelSize(m.size) * s, color: mark.color)
            case .pin: pin(mark.n, mark.text, at: a, radius: Markup.pinRadius(m.size) * s, size: Markup.labelSize(m.size) * s, color: mark.color)
            case .pixelate: blur(ctx, r, block: max(2, Int(CGFloat(Markup.block(mark.rect)) * s)), radius: Markup.blurRadius(mark.rect) * s)
            case .crop: break
            }
        }
        if !cropped, let c = m.marks.last(where: { $0.tool == .crop }) ?? (live?.tool == .crop ? live : nil) {
            // while editing: outside the crop goes dark, the picture stays whole
            let r = CGRect(x: c.rect.minX * s, y: c.rect.minY * s, width: c.rect.width * s, height: c.rect.height * s)
            let p = NSBezierPath(rect: CGRect(x: 0, y: 0, width: W, height: H)); p.append(NSBezierPath(rect: r)); p.windingRule = .evenOdd
            NSColor.black.withAlphaComponent(0.5).setFill(); p.fill()
            NSColor.white.setStroke(); let e = NSBezierPath(rect: r); e.lineWidth = 1; e.stroke()
        }
        NSGraphicsContext.restoreGraphicsState()
        guard let out = ctx.makeImage() else { return nil }
        guard cropped else { return out }
        let c = m.crop
        return c.size == m.size ? out : out.cropping(to: CGRect(x: c.minX * s, y: c.minY * s, width: c.width * s, height: c.height * s).integral)
    }

    /// A soft shadow under a mark: it reads on light and dark screens alike.
    private static func shadowed(_ lw: CGFloat, _ f: () -> Void) {
        NSGraphicsContext.saveGraphicsState()
        let sh = NSShadow(); sh.shadowColor = NSColor.black.withAlphaComponent(0.28); sh.shadowBlurRadius = max(1.5, lw * 0.9); sh.shadowOffset = NSSize(width: 0, height: -max(0.5, lw * 0.25)); sh.set()
        f()
        NSGraphicsContext.restoreGraphicsState()
    }

    /// One filled shape: a thin round tail that widens to the neck, then a filled head with a slightly hollow back.
    static func arrow(_ a: CGPoint, _ b: CGPoint, width lw: CGFloat, color c: NSColor) {
        let dx = b.x - a.x, dy = b.y - a.y, len = hypot(dx, dy)
        guard len > 1 else { return }
        let ux = dx / len, uy = dy / len, nx = -uy, ny = ux
        let head = min(len * 0.5, lw * 5.2), half = head * 0.5
        func pt(_ along: CGFloat, _ side: CGFloat) -> CGPoint { CGPoint(x: a.x + ux * along + nx * side, y: a.y + uy * along + ny * side) }
        let tail = lw * 0.3, neck = lw * 0.8, base = len - head, back = len - head * 0.8
        let p = NSBezierPath()
        p.move(to: pt(0, tail))
        p.line(to: pt(back, neck))
        p.line(to: pt(base, half))
        p.line(to: b)
        p.line(to: pt(base, -half))
        p.line(to: pt(back, -neck))
        p.line(to: pt(0, -tail))
        p.appendArc(withCenter: a, radius: tail, startAngle: atan2(-ny, -nx) * 180 / .pi, endAngle: atan2(ny, nx) * 180 / .pi, clockwise: true)
        p.close(); p.lineJoinStyle = .round
        shadowed(lw) { c.setFill(); p.fill() }
        // round the tip and wings a little
        c.setStroke(); p.lineWidth = max(1, lw * 0.18); p.stroke()
    }

    /// A freehand stroke: a smooth curve through his points (PenRules.smooth), round ends and joins, the arrow's shadow.
    static func pen(_ pts: [CGPoint], width lw: CGFloat, color c: NSColor) {
        let line = PenRules.smooth(pts)
        guard let f = line.first else { return }
        let p = NSBezierPath(); p.move(to: f)
        if line.count == 1 { p.line(to: f) }
        for q in line.dropFirst() { p.line(to: q) }
        p.lineWidth = lw; p.lineCapStyle = .round; p.lineJoinStyle = .round
        // one transparency layer: the stroke and its shadow composite once, so no seams where the curve's pieces meet
        shadowed(lw) {
            let cg = NSGraphicsContext.current?.cgContext
            cg?.beginTransparencyLayer(auxiliaryInfo: nil); c.setStroke(); p.stroke(); cg?.endTransparencyLayer()
        }
    }

    private static func box(_ r: CGRect, width lw: CGFloat, color c: NSColor) {
        let p = NSBezierPath(roundedRect: r, xRadius: lw * 1.2, yRadius: lw * 1.2); p.lineWidth = lw
        shadowed(lw) { c.setStroke(); p.stroke() }
    }

    /// A highlight, by how bright the picture is under it (Markup.highlightLook): on light, a marker (the colour
    /// multiplied in, text under it stays black); on dark, a thin light fill (the colour mixed with white) and an outline.
    private static func highlight(_ ctx: CGContext, _ r: CGRect, height lw: CGFloat, color c: NSColor, look: Markup.HighlightLook) {
        let shape = NSBezierPath(roundedRect: r, xRadius: min(r.height / 2, lw), yRadius: min(r.height / 2, lw))
        ctx.saveGState(); ctx.setBlendMode(look.lighten ? .normal : .multiply)
        (c.blended(withFraction: look.lighten ? 0.45 : 0.12, of: .white) ?? c).withAlphaComponent(look.fill).setFill()
        shape.fill()
        ctx.restoreGState()
        if look.outline { c.setStroke(); shape.lineWidth = max(1.5, lw * 0.35); shape.stroke() }
    }

    /// The mean luminance of the picture under `r` (top-left coordinates, the picture's own pixels), from an 8×8 sample.
    static func luminance(_ img: CGImage, under r: CGRect) -> Double {
        let r = r.integral.intersection(CGRect(x: 0, y: 0, width: img.width, height: img.height))
        guard r.width >= 1, r.height >= 1, let part = img.cropping(to: r) else { return 1 }
        var px = [UInt8](repeating: 0, count: 8 * 8 * 4)
        let ok = px.withUnsafeMutableBytes { buf -> Bool in
            guard let c = CGContext(data: buf.baseAddress, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 32,
                                    space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            c.interpolationQuality = .medium; c.draw(part, in: CGRect(x: 0, y: 0, width: 8, height: 8)); return true
        }
        return ok ? Markup.meanLuminance(px) : 1
    }

    static func labelRect(_ text: String, at p: CGPoint, size: CGFloat) -> CGRect {
        let a: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: size, weight: .semibold)]
        let sz = (text as NSString).size(withAttributes: a), pad = size * 0.35
        return CGRect(x: p.x, y: p.y - sz.height / 2 - pad / 2, width: sz.width + 2 * pad, height: sz.height + pad)
    }
    static func labelWidth(_ text: String, size: CGFloat) -> CGFloat {
        (text as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: size, weight: .semibold)]).width
    }
    private static func label(_ text: String, at p: CGPoint, size: CGFloat, color i: Int) {
        let a: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: size, weight: .semibold), .foregroundColor: onColor(i)]
        let r = labelRect(text, at: p, size: size), pad = size * 0.35
        shadowed(size * 0.12) { color(i).setFill(); NSBezierPath(roundedRect: r, xRadius: pad, yRadius: pad).fill() }
        (text as NSString).draw(at: CGPoint(x: r.minX + pad, y: r.minY + pad / 2), withAttributes: a)
    }

    /// A numbered pin: a filled circle with its number, its text (when typed) as a label to the right.
    static func pin(_ n: Int, _ text: String, at p: CGPoint, radius r: CGFloat, size: CGFloat, color i: Int = 0) {
        let c = CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r)
        shadowed(r * 0.2) { color(i).setFill(); NSBezierPath(ovalIn: c).fill() }
        NSColor.white.setStroke(); let e = NSBezierPath(ovalIn: c.insetBy(dx: r * 0.06, dy: r * 0.06)); e.lineWidth = max(1, r * 0.12); e.stroke()
        let a: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: r * (n > 9 ? 0.95 : 1.15), weight: .bold), .foregroundColor: onColor(i)]
        let num = "\(n)" as NSString, sz = num.size(withAttributes: a)
        num.draw(at: CGPoint(x: p.x - sz.width / 2, y: p.y - sz.height / 2), withAttributes: a)
        if !text.isEmpty { label(text, at: CGPoint(x: p.x + r * 1.35, y: p.y), size: size, color: i) }
    }

    /// The part under `r` blurred: first shrunk to blocks (what was there is gone), then grown back smooth and a
    /// Gaussian laid over it, so it reads as a blur and not as a mosaic.
    private static func blur(_ ctx: CGContext, _ r: CGRect, block: Int, radius: CGFloat) {
        let r = r.integral
        guard r.width >= 2, r.height >= 2, let now = ctx.makeImage(), let part = now.cropping(to: r) else { return }
        let w = max(1, Int(r.width) / block), h = max(1, Int(r.height) / block)
        guard let small = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                    space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        small.interpolationQuality = .medium
        small.draw(part, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let tiny = small.makeImage() else { return }
        let grown = CIImage(cgImage: tiny).samplingLinear()
            .transformed(by: CGAffineTransform(scaleX: r.width / CGFloat(w), y: r.height / CGFloat(h)))
        let soft = grown.clampedToExtent().applyingGaussianBlur(sigma: Double(max(1, radius)))
            .cropped(to: CGRect(x: 0, y: 0, width: r.width, height: r.height))
        guard let out = ci.createCGImage(soft, from: CGRect(x: 0, y: 0, width: r.width, height: r.height)) else { return }
        ctx.saveGState()
        ctx.translateBy(x: 0, y: r.maxY); ctx.scaleBy(x: 1, y: -1)   // CGImages draw bottom-up
        ctx.draw(out, in: CGRect(x: r.minX, y: 0, width: r.width, height: r.height))
        ctx.restoreGState()
    }

    /// A mark's outline in picture pixels (the selection ring goes round it).
    static func bounds(_ m: PicMark, _ size: CGSize) -> CGRect {
        let lw = Markup.stroke(size, level: m.size), fs = Markup.labelSize(size)
        switch m.tool {
        case .arrow: return m.rect.insetBy(dx: -lw * 2.6, dy: -lw * 2.6)
        case .box, .pen: return m.rect.insetBy(dx: -lw, dy: -lw)
        case .label: return labelRect(m.text, at: m.from, size: fs)
        case .pin:
            let r = Markup.pinRadius(size), c = CGRect(x: m.from.x - r, y: m.from.y - r, width: 2 * r, height: 2 * r)
            return m.text.isEmpty ? c : c.union(labelRect(m.text, at: CGPoint(x: m.from.x + r * 1.35, y: m.from.y), size: fs))
        default: return m.rect
        }
    }

    static func png(_ img: CGImage) -> Data? { NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:]) }
}

/// The editor: in place over the dimmed screen (a region capture), or a panel with the picture fitted into most of the
/// screen; the markup pill under the picture either way.
final class MarkupEditor {
    static let shared = MarkupEditor()
    private(set) var isOpen = false
    var model = Markup(size: .zero)
    var live: PicMark?
    var typing: PicMark?                         // a text label (or a pin's text) being typed
    var moving: (index: Int, start: CGPoint, dx: CGFloat, dy: CGFloat)?
    var hover: Int?                              // the pill button under the mouse
    private(set) var inPlace = false
    private(set) var base: CGImage?           // the full picture
    private(set) var shown: CGImage?          // the picture at view size
    private(set) var fitted = CGRect.zero, scale: CGFloat = 1
    private(set) var pill = ShotRules.Pill(bar: .zero, items: [], dividers: [])
    /// ⌘N or + pressed: the strip adds another picture once the markup is done.
    var addAfter = false
    private var done: ((Data?) -> Void)?
    private var panel: NSPanel?
    let view = MarkupView()
    static let pillGap: CGFloat = 12

    /// `marks`: the marks kept from an earlier pass on the same picture (⌘E again), editable and undoable.
    /// `region`: where the picture was on the screen (AppKit points): marks go on in place there. `screenFrame` stands in
    /// for the screen in previews.
    func open(_ png: Data, near: NSScreen?, marks: [PicMark] = [], region: NSRect? = nil, screenFrame: NSRect? = nil, done: @escaping (Data?) -> Void) {
        guard let src = CGImageSourceCreateWithData(png as CFData, nil), let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { done(nil); return }
        base = img; model = Markup(size: CGSize(width: img.width, height: img.height)); live = nil; typing = nil; moving = nil; hover = nil; addAfter = false
        for m in marks { model.add(m) }
        self.done = done
        let scr = near ?? NSScreen.main ?? NSScreen.screens[0]
        let backing = scr.backingScaleFactor
        let frame: NSRect, level: NSWindow.Level
        if let region, let sf = screenFrame ?? NSScreen.screens.first(where: { $0.frame.intersects(region) })?.frame, sf.intersects(region) {
            // in place: the panel covers the screen, the picture sits where it was taken
            inPlace = true
            frame = sf; level = .screenSaver
            fitted = CGRect(x: region.minX - sf.minX, y: sf.maxY - region.maxY, width: region.width, height: region.height).integral
            scale = fitted.width / max(1, model.size.width)
            let size = ShotRules.markPillSize
            // under the picture, else on the bottom edge of the visible screen (above the Dock), never above the picture
            let vis = (screenFrame == nil ? NSScreen.screens.first(where: { $0.frame == sf })?.visibleFrame : nil) ?? sf
            let visLocal = CGRect(x: vis.minX - sf.minX, y: sf.maxY - vis.maxY, width: vis.width, height: vis.height)
            let at = ShotRules.attach(size, to: fitted, in: visLocal, gap: Self.pillGap)
            pill = ShotRules.markPill(at: at.origin)
        } else {
            inPlace = false
            let vis = scr.visibleFrame
            let ps = ShotRules.markPillSize
            let pts = CGSize(width: CGFloat(img.width) / backing, height: CGFloat(img.height) / backing)
            let box = CGRect(x: 0, y: 0, width: min(vis.width * 0.8, max(420, pts.width)), height: min(vis.height * 0.8 - ps.height - Self.pillGap, max(240, pts.height)))
            let fit = Markup.fit(model.size, in: box)
            let size = NSSize(width: max(ps.width, fit.rect.width) + 32, height: fit.rect.height + 32 + Self.pillGap + ps.height)
            fitted = CGRect(x: ((size.width - fit.rect.width) / 2).rounded(), y: 16, width: fit.rect.width, height: fit.rect.height)
            scale = fit.scale
            pill = ShotRules.markPill(at: CGPoint(x: ((size.width - ps.width) / 2).rounded(), y: fitted.maxY + Self.pillGap))
            frame = NSRect(x: (vis.midX - size.width / 2).rounded(), y: (vis.midY - size.height / 2).rounded(), width: size.width, height: size.height)
            level = .popUpMenu
        }
        shown = Self.scaled(img, to: CGSize(width: fitted.width * backing, height: fitted.height * backing))
        let p = panel ?? {
            let p = CapturePanel(contentRect: .zero, styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: false)
            p.isOpaque = false; p.backgroundColor = .clear; p.hidesOnDeactivate = false
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
            p.acceptsMouseMovedEvents = true
            p.contentView = view; view.model = self
            return p
        }()
        panel = p
        p.level = level; p.hasShadow = !inPlace
        p.sharingType = inPlace ? .none : .readOnly
        p.setFrame(frame, display: false)
        view.frame = NSRect(origin: .zero, size: frame.size)
        view.needsDisplay = true
        if screenFrame == nil { p.orderFrontRegardless() }
        isOpen = true
        log("markup: open \(img.width)x\(img.height)\(inPlace ? " in place" : "")")
    }

    private static func scaled(_ img: CGImage, to s: CGSize) -> CGImage? {
        let w = max(1, Int(s.width)), h = max(1, Int(s.height))
        guard let c = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        c.interpolationQuality = .high
        c.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        return c.makeImage()
    }

    /// The shown picture's pixels per picture pixel.
    var shownScale: CGFloat { CGFloat(shown?.width ?? 1) / max(1, model.size.width) }

    func close(_ png: Data?) {
        guard isOpen else { return }
        isOpen = false
        panel?.orderOut(nil)
        log("markup: \(png == nil ? "back" : "accepted, \(model.marks.count) marks")")
        let d = done; done = nil
        d?(png)
    }

    func accept() {
        if typing != nil { commitLabel() }
        guard let b = base, !model.marks.isEmpty, let out = MarkupDraw.render(b, model), let png = MarkupDraw.png(out) else { close(nil); return }
        close(png)
    }

    private func commitLabel() { if let t = typing { model.add(t) }; typing = nil }

    // MARK: keys (from the event tap) and the pill

    func key(_ code: Int, _ ch: String, cmd: Bool, shift: Bool) {
        if var t = typing {   // a label: letters go into it, ↵ ends it, esc drops it
            switch code {
            case 36, 76: commitLabel()
            case 53: typing = nil
            case 51: if !t.text.isEmpty { t.text.removeLast() }; typing = t
            default:
                if !cmd, let c = ch.unicodeScalars.first, !CharacterSet.controlCharacters.contains(c), t.text.count < 120 { t.text += ch; typing = t }
            }
            view.needsDisplay = true; return
        }
        switch Markup.key(code, cmd: cmd, shift: shift) {
        case .tool(let t): model.tool = t; model.selected = nil
        case .color(let c): model.pick(color: c)
        case .sizeStep(let d): model.pick(size: (model.selected.map { model.marks[$0].size } ?? model.stroke) + d)
        case .undo: model.undo()
        case .redo: model.redo()
        case .delete: if let i = model.selected { model.delete(i) }
        case .done: accept(); return
        case .back: if model.selected != nil { model.selected = nil } else { close(nil); return }
        case .addAnother: addAfter = true; accept(); return
        case .none: break
        }
        view.needsDisplay = true
    }

    /// The pill's buttons, as their keys do.
    func press(_ item: ShotRules.MarkItem) {
        switch item {
        case .tool(let t): model.tool = t; model.selected = nil
        case .color(let c): model.pick(color: c)
        case .size(let s): model.pick(size: s)
        case .undo: model.undo()
        case .add: addAfter = true; accept(); return
        case .back: close(nil); return
        case .done: accept(); return
        }
        view.needsDisplay = true
    }

    /// The pill's faces now: the chosen tool, and the colour and size of the selected mark (else of the next one).
    var faces: [PillFace] {
        let sel = model.selected.flatMap { model.marks.indices.contains($0) ? model.marks[$0] : nil }
        let color = sel?.color ?? model.color, size = sel?.size ?? model.stroke
        return ShotRules.markGroups.flatMap { $0 }.map { it in
            var f = PillFace(glyph: it.glyph, key: it.key, word: it.word)
            switch it {
            case .tool(let t): f.on = model.tool == t && sel == nil
            case .color(let c): f.swatch = MarkupDraw.color(c); f.on = color == c; f.key = ""; f.word += " · " + Markup.colors[c].key
            case .size(let s): f.dot = [6, 10, 15][s]; f.on = size == s
            case .done: f.primary = true
            default: break
            }
            return f
        }
    }

    // MARK: the mouse, in view points (flipped)

    private func textWidth(_ m: PicMark) -> CGFloat { MarkupDraw.labelWidth(m.text, size: Markup.labelSize(model.size)) }

    func down(_ p: CGPoint) {
        if pill.bar.contains(p) {
            if let it = ShotRules.markHit(p, pill) { press(it) }
            return
        }
        if typing != nil { commitLabel() }
        guard fitted.insetBy(dx: -8, dy: -8).contains(p) else { model.selected = nil; view.needsDisplay = true; return }
        let q = Markup.toPicture(p, fitted: fitted, scale: scale)
        if model.tool != .crop, let i = model.hit(q, slop: 6 / max(scale, 0.01), textWidth: textWidth) {
            model.selected = i; moving = (i, q, 0, 0); view.needsDisplay = true; return
        }
        model.selected = nil
        let fresh = PicMark(tool: model.tool, from: q, to: q, color: model.color, size: model.stroke)
        if model.tool == .label { typing = fresh; view.needsDisplay = true; return }
        if model.tool == .pin { var t = fresh; t.n = model.nextPin; typing = t; view.needsDisplay = true; return }
        live = fresh
        if model.tool == .pen { live?.points = [q] }
        view.needsDisplay = true
    }
    func dragged(_ p: CGPoint) {
        let q = Markup.toPicture(p, fitted: fitted, scale: scale)
        if let mv = moving, model.marks.indices.contains(mv.index) {
            let d = Markup.keepInside(model.marks[mv.index], q.x - mv.start.x, q.y - mv.start.y, model.size)
            moving = (mv.index, mv.start, d.dx, d.dy); view.needsDisplay = true; return
        }
        guard let l = live else { return }
        if l.tool == .pen {
            // a new point once the mouse moved 1.5 view points: dense enough for the curve, light enough to draw live
            let last = l.points.last ?? l.from
            guard hypot(q.x - last.x, q.y - last.y) * scale >= 1.5 else { return }
            live?.points.append(q)
        }
        live?.to = q; view.needsDisplay = true
    }
    func up(_ p: CGPoint) {
        if let mv = moving {
            if mv.dx != 0 || mv.dy != 0 { model.move(mv.index, by: mv.dx, mv.dy); model.selected = mv.index }
            moving = nil; view.needsDisplay = true; return
        }
        if var l = live {
            if l.tool == .pen { let q = Markup.toPicture(p, fitted: fitted, scale: scale); if l.points.last != q { l.points.append(q) } }
            model.add(l)
        }
        live = nil; view.needsDisplay = true
    }
    func moved(_ p: CGPoint) {
        let h = pill.bar.contains(p) ? ShotRules.hitItem(p, pill.items) : nil
        if h != hover { hover = h; view.needsDisplay = true }
        (fitted.contains(p) && !pill.bar.contains(p) ? NSCursor.crosshair : NSCursor.arrow).set()
    }
}

final class MarkupView: NSView {
    weak var model: MarkupEditor?
    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeAlways, .inVisibleRect], owner: self))
    }
    override func mouseDown(with e: NSEvent) { model?.down(convert(e.locationInWindow, from: nil)) }
    override func mouseDragged(with e: NSEvent) { model?.dragged(convert(e.locationInWindow, from: nil)) }
    override func mouseUp(with e: NSEvent) { model?.up(convert(e.locationInWindow, from: nil)) }
    override func mouseMoved(with e: NSEvent) { model?.moved(convert(e.locationInWindow, from: nil)) }
    override func resetCursorRects() { if let m = model { addCursorRect(m.fitted, cursor: .crosshair) } }
    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityLabel() -> String? {
        "Mark up: " + ShotRules.markGroups.flatMap { $0 }.map(\.word).joined(separator: ", ")
    }

    override func draw(_ dirty: NSRect) {
        guard let m = model else { return }
        if m.inPlace {
            // the rest of the screen dimmed, the picture where it was
            let p = NSBezierPath(rect: bounds); p.append(NSBezierPath(rect: m.fitted)); p.windingRule = .evenOdd
            NSColor.black.withAlphaComponent(0.38).setFill(); p.fill()
        } else {
            NSGraphicsContext.saveGraphicsState()
            Native.floatShadow().set(); Native.card.setFill(); NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: Native.corner(3), yRadius: Native.corner(3)).fill()
            NSGraphicsContext.restoreGraphicsState()
            TapeDraw.surface(bounds)
        }
        if let shown = m.shown {
            var mk = m.model
            if let t = m.typing, !t.text.isEmpty || t.tool == .pin { mk.add(t) }
            let mv = m.moving.map { (index: $0.index, dx: $0.dx, dy: $0.dy) }
            if let img = MarkupDraw.render(shown, mk, scale: m.shownScale, live: m.live, cropped: false, moving: mv) {
                NSImage(cgImage: img, size: m.fitted.size).draw(in: m.fitted, from: .zero, operation: .copy, fraction: 1, respectFlipped: true, hints: nil)
            }
            (m.inPlace ? NSColor.white.withAlphaComponent(0.9) : Native.line).setStroke()
            let e = NSBezierPath(rect: m.fitted.insetBy(dx: -0.5, dy: -0.5)); e.lineWidth = 1; e.stroke()
            if let t = m.typing {   // the caret after the label being typed
                let size = Markup.labelSize(m.model.size) * m.scale
                let w = MarkupDraw.labelWidth(t.text, size: size)
                let off = t.tool == .pin ? Markup.pinRadius(m.model.size) * m.scale * 1.35 + (t.text.isEmpty ? 0 : size * 0.35) : 0
                Native.blue.setFill()
                NSRect(x: m.fitted.minX + t.from.x * m.scale + off + w + size * 0.35 + 2, y: m.fitted.minY + t.from.y * m.scale - size * 0.6, width: 2, height: size * 1.2).fill()
            }
            // the selected mark: a dashed ring in the focus colour round it
            if let i = m.model.selected, m.model.marks.indices.contains(i) {
                var mark = m.model.marks[i]
                if let mv = m.moving, mv.index == i { mark = mark.moved(mv.dx, mv.dy) }
                let b = MarkupDraw.bounds(mark, m.model.size)
                let r = NSRect(x: m.fitted.minX + b.minX * m.scale, y: m.fitted.minY + b.minY * m.scale, width: b.width * m.scale, height: b.height * m.scale).insetBy(dx: -5, dy: -5)
                let ring = NSBezierPath(roundedRect: r, xRadius: 6, yRadius: 6)
                NSColor.white.withAlphaComponent(0.9).setStroke(); ring.lineWidth = 3; ring.stroke()
                Native.blue.setStroke(); ring.lineWidth = 1.5; ring.setLineDash([5, 3], count: 2, phase: 0); ring.stroke()
            }
        }
        ShotPill.draw(m.pill, faces: m.faces, hover: m.hover, bounds: bounds)
    }
}

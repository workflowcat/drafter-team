// The capture deck, round 5 "Stack" (23 November 2026; Andrii: the deck "must not wander", one column instead of a
// long strip, larger images, the actions on each shot). Rounds 4-4c ("Hand": a fan of cards above the caret, one bar
// under it) are in docs/rounds/2026-11-17-deck.md. Now: one panel in the floating-panel style (app/Panel.swift): a head
// with the count (drag it to move the deck) and a close x; one column of shots, newest at the bottom, each 272 pt wide in
// its own shape, left edges aligned, 10 pt apart, the selected one with a 2 pt accent ring; on the hovered or selected
// shot its own buttons: Insert, Copy, Delete at its foot, Voice, Mark up, Pin, Take again as round symbols at its top
// right; its caption under it. The foot: Next shot, Copy all, Insert all (filled, with ↵ while ↵ still inserts). The
// column scrolls up and down only past 70% of the screen (DeckRules.placeStack); a new shot scrolls it to the bottom.
// A click on a shot selects it; nothing is inserted by a click on a picture. A drag up or down reorders.
// The deck never takes his keys: its panel never becomes key, so his caret stays in his app. Rules: app/DeckRules.swift.
import AppKit

final class HandView: NSView {
    weak var model: CaptureNote?
    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }

    // MARK: geometry (flipped view points)

    static let pad = DeckRules.stackPad, corner: CGFloat = Panel.corner, tool: CGFloat = 26
    /// The most the panel may be high before the list scrolls (CaptureNote sets it from the screen when it places it).
    var maxH: CGFloat = .greatestFiniteMagnitude
    private var count: Int { model?.pics.count ?? 0 }
    private var selected: Int? { model?.selectedIndex }
    private var width: CGFloat { DeckRules.stackW + 2 * Self.pad }
    var headRect: NSRect { NSRect(x: Self.pad, y: Self.pad, width: DeckRules.stackW, height: DeckRules.stackHeadH) }
    var closeRect: NSRect { NSRect(x: headRect.maxX - 24, y: headRect.midY - 12, width: 24, height: 24) }
    var listTop: CGFloat { headRect.maxY + 8 }
    /// One shot's box and its caption lines, in list coordinates (0 at the list's top).
    private func caption(_ i: Int) -> [(String, Bool)] {
        guard let m = model, m.pics.indices.contains(i) else { return [] }
        let p = m.pics[i]
        var out = DeckRules.label(p.caption, width: 44, lines: 2).map { ($0, false) }
        if m.listeningFor == p.id, talking {
            let live = m.heardLive.trimmingCharacters(in: .whitespaces)
            if !live.isEmpty { out += DeckRules.labelTail(live, width: 44).map { ($0.line, true) } }
        }
        return Array(out.suffix(3))
    }
    private func boxSize(_ i: Int) -> CGSize {
        guard let m = model, m.pics.indices.contains(i) else { return CGSize(width: DeckRules.stackW, height: DeckRules.stackMinH) }
        return DeckRules.stackBox(pixels: CGSize(width: m.pics[i].shot.width, height: m.pics[i].shot.height))
    }
    private static let capLH: CGFloat = 17
    private func cardHeight(_ i: Int) -> CGFloat {
        let n = caption(i).count
        return boxSize(i).height + (n > 0 ? 6 + CGFloat(n) * Self.capLH : 0)
    }
    /// Where each shot sits in the list (deck order: oldest at the top, newest at the bottom).
    private func offsets() -> [CGFloat] {
        var y: CGFloat = 0, out: [CGFloat] = []
        for i in 0..<count { out.append(y); y += cardHeight(i) + DeckRules.stackGap }
        return out
    }
    var contentH: CGFloat { count == 0 ? 0 : offsets().last! + cardHeight(count - 1) }
    var listH: CGFloat { max(0, min(contentH, maxH - DeckRules.stackChrome)) }
    var listRect: NSRect { NSRect(x: 0, y: listTop, width: width, height: listH) }
    var footY: CGFloat { listRect.maxY + 10 }
    var scrollY: CGFloat = 0
    private var scrolls: Bool { contentH > listH + 0.5 }
    /// Shot `i`'s box in the view (it can be scrolled out of the list).
    func box(_ i: Int) -> NSRect {
        let o = offsets(), s = boxSize(i)
        return NSRect(x: Self.pad, y: listTop + (o.indices.contains(i) ? o[i] : 0) - scrollY, width: s.width, height: s.height)
    }

    @discardableResult
    func fit(room: CGFloat = 0) -> NSSize {
        scrollY = DeckRules.clampScroll(scrollY, content: contentH, room: listH)
        let s = NSSize(width: width, height: (footY + DeckRules.stackFootH + Self.pad).rounded(.up))
        frame = NSRect(origin: .zero, size: s)
        return s
    }

    // MARK: buttons

    private var listening: Bool { talking && model?.listeningFor != nil }
    private var talking: Bool { previewTalking || (Talk.shared.state == .listening && Talk.shared.toNote) }
    private func listens(_ i: Int) -> Bool {
        guard let m = model, m.pics.indices.contains(i) else { return false }
        return talking && m.listeningFor == m.pics[i].id
    }
    /// ↵ still inserts all (until he types in his app): Insert all shows a ↵ key cap. `previewReturn`: the renders.
    var previewReturn = false
    var returnHint: Bool { previewReturn || model?.returnHint == true }
    private var captureKey: String { Capture.keys.first ?? "" }
    private func footButton(_ f: DeckRules.FootAct) -> Panel.Button {
        let key = f.key(captureKey: captureKey, returnKey: returnHint)
        return Panel.Button(glyph: f.glyph, word: f == .next ? "" : f.word(count: count), key: f == .next ? "" : key, prominent: f == .insertAll)
    }
    /// The foot: the next shot as a round-cornered symbol button at the left, Copy all and Insert all at the right.
    func footButtons() -> [(DeckRules.FootAct, NSRect)] {
        let y = footY, h = DeckRules.stackFootH, right = Self.pad + DeckRules.stackW
        let ia = Panel.buttonWidth(footButton(.insertAll)), ca = Panel.buttonWidth(footButton(.copyAll))
        return [(.next, NSRect(x: Self.pad, y: y, width: h + 6, height: h)),
                (.copyAll, NSRect(x: right - ia - 8 - ca, y: y, width: ca, height: h)),
                (.insertAll, NSRect(x: right - ia, y: y, width: ia, height: h))]
    }
    /// Shot `i`'s own buttons: Insert, Copy, Delete in its box's foot, the symbols at its top right.
    func shotButtons(_ i: Int) -> [(DeckRules.ShotAct, NSRect)] {
        let b = box(i), h: CGFloat = 26
        var out: [(DeckRules.ShotAct, NSRect)] = []
        var x = b.minX + 8
        for a in DeckRules.ShotAct.words {
            let w = Panel.buttonWidth(Panel.Button(glyph: a.glyph, word: a.word()), font: Panel.hint)
            out.append((a, NSRect(x: x, y: b.maxY - 8 - h, width: w, height: h))); x += w + 6
        }
        var tx = b.maxX - 8 - Self.tool
        for a in DeckRules.ShotAct.tools.reversed() {
            out.append((a, NSRect(x: tx, y: b.minY + 8, width: Self.tool, height: Self.tool))); tx -= Self.tool + 6
        }
        return out
    }
    private func enabled(_ a: DeckRules.ShotAct) -> Bool {
        guard let m = model else { return false }
        switch a { case .insert: return DeckRules.mayInsert(busy: m.inserting, count: m.pics.count); case .retake: return !m.collecting; default: return true }
    }
    private func enabled(_ f: DeckRules.FootAct) -> Bool {
        guard let m = model else { return false }
        switch f { case .insertAll: return DeckRules.mayInsert(busy: m.inserting, count: m.pics.count); case .next: return !m.collecting; case .copyAll: return !m.pics.isEmpty }
    }
    /// The shot whose own buttons show: the one under the mouse, else the selected one.
    private var active: Int? { hovered ?? selected }

    // MARK: state

    var hovered: Int?
    var hoverAct: (Int, DeckRules.ShotAct)?
    var hoverFoot: DeckRules.FootAct?
    var hoverClose = false
    /// The renders: draw the listening shot's take as live.
    var previewTalking = false
    /// A shot held by the mouse: its index, where it was pressed, how far it went up or down, whether it reorders.
    var held: (i: Int, from: NSPoint, dy: CGFloat, moved: Bool)?
    private var pressed: (key: String, at: Date)?
    private var dragDeck: NSPoint?

    func reset() {
        hovered = nil; hoverAct = nil; hoverFoot = nil; hoverClose = false; held = nil; pressed = nil; dragDeck = nil; scrollY = 0
    }
    func stopMotion() {}
    /// The deck's shots changed (added, taken out, moved, selected): the panel fits again.
    func cardsChanged() {
        held = nil
        if let h = hovered, h >= count { hovered = nil }
        model?.refit()
        fit(); needsDisplay = true
    }
    /// A new shot: the list scrolls to the bottom, where it is.
    func flyIn(_ id: UUID) { scrollY = .greatestFiniteMagnitude; fit(); needsDisplay = true }

    // MARK: the mouse

    func shot(at p: NSPoint) -> Int? {
        guard listRect.contains(p) else { return nil }
        return (0..<count).first { box($0).contains(p) }
    }
    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }
    override func mouseMoved(with e: NSEvent) { hover(convert(e.locationInWindow, from: nil)) }
    override func mouseExited(with e: NSEvent) { hover(nil) }
    private func actAt(_ p: NSPoint) -> (Int, DeckRules.ShotAct)? {
        guard let a = active, listRect.contains(p) else { return nil }
        return shotButtons(a).first { $0.1.contains(p) }.map { (a, $0.0) }
    }
    private func hover(_ p: NSPoint?) {
        guard held == nil, dragDeck == nil else { return }
        hoverClose = p.map { closeRect.contains($0) } ?? false
        hoverFoot = p.flatMap { q in footButtons().first { $0.1.contains(q) }?.0 }
        let s = p.flatMap { shot(at: $0) }
        if s != hovered { hovered = s }
        hoverAct = p.flatMap { actAt($0) }
        if let q = p, headRect.contains(q), !hoverClose { NSCursor.openHand.set() } else { NSCursor.arrow.set() }
        needsDisplay = true
    }
    override func scrollWheel(with e: NSEvent) {
        guard scrolls else { return }
        scrollY = DeckRules.clampScroll(scrollY - e.scrollingDeltaY * (e.hasPreciseScrollingDeltas ? 1 : 8), content: contentH, room: listH)
        hover(convert(e.locationInWindow, from: nil))
    }

    override func mouseDown(with e: NSEvent) {
        guard let m = model else { return }
        let p = convert(e.locationInWindow, from: nil)
        if closeRect.contains(p) { m.dismiss(); return }
        if let f = footButtons().first(where: { $0.1.contains(p) })?.0 {
            if enabled(f) { pressed = ("foot\(f.rawValue)", Date()); needsDisplay = true }
            return
        }
        if let (i, a) = actAt(p) {
            if enabled(a) { pressed = ("shot\(i).\(a.rawValue)", Date()); needsDisplay = true }
            return
        }
        if headRect.contains(p) { dragDeck = NSEvent.mouseLocation; NSCursor.closedHand.set(); return }
        if let i = shot(at: p) { held = (i, p, 0, false) }
    }
    override func mouseDragged(with e: NSEvent) {
        let p = convert(e.locationInWindow, from: nil)
        if pressed != nil { needsDisplay = true; return }
        if let d = dragDeck {
            let now = NSEvent.mouseLocation
            model?.drag(by: now.x - d.x, now.y - d.y); dragDeck = now
            return
        }
        guard var h = held, count > 1 else { return }
        let dx = p.x - h.from.x, dy = p.y - h.from.y
        if !h.moved, DeckRules.reordersInColumn(dx: dx, dy: dy) { h.moved = true }
        h.dy = dy; held = h
        if h.moved { needsDisplay = true }
    }
    /// Where a held shot lands: the shot whose middle is nearest its middle now.
    private func dropAt(_ h: (i: Int, from: NSPoint, dy: CGFloat, moved: Bool)) -> Int {
        let mid = box(h.i).midY + h.dy
        return (0..<count).min { abs(box($0).midY - mid) < abs(box($1).midY - mid) } ?? h.i
    }
    override func mouseUp(with e: NSEvent) {
        let p = convert(e.locationInWindow, from: nil)
        if let pr = pressed {
            // a button acts on mouse up inside it, after showing pressed for at least 80 ms
            let foot = footButtons().first { "foot\($0.0.rawValue)" == pr.key }
            let shotHit = actAt(p).flatMap { "shot\($0.0).\($0.1.rawValue)" == pr.key ? $0 : nil }
            let inside = foot?.1.contains(p) == true || shotHit != nil
            let wait = max(0, DeckRules.pressSeconds - Date().timeIntervalSince(pr.at))
            DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in
                guard let self else { return }
                self.pressed = nil; self.needsDisplay = true
                guard inside else { return }
                if let f = foot?.0 { self.press(f) } else if let (i, a) = shotHit { self.press(a, on: i) }
            }
            return
        }
        if dragDeck != nil { dragDeck = nil; NSCursor.openHand.set(); model?.dragEnded(); return }
        guard let h = held, let m = model else { held = nil; return }
        held = nil
        if !h.moved { m.select(h.i); return }
        let to = dropAt(h)
        if to != h.i { m.move(h.i, to: to) } else { needsDisplay = true }
    }
    func press(_ f: DeckRules.FootAct) {
        guard let m = model, enabled(f) else { return }
        switch f { case .next: m.addAnother(); case .copyAll: m.copyAll(); case .insertAll: m.putAll() }
        needsDisplay = true
    }
    func press(_ a: DeckRules.ShotAct, on i: Int) {
        guard let m = model, m.pics.indices.contains(i), enabled(a) else { return }
        switch a {
        case .insert: m.putOne(i)
        case .copy: m.copyOne(i)
        case .delete: m.dropOne(i)
        case .voice:
            let on = m.listeningFor.flatMap { id in m.pics.firstIndex { $0.id == id } }
            m.micTap(on ?? i)
        case .markup: m.markup(i)
        case .pin: m.pin(i)
        case .retake: m.retake(i)
        }
        needsDisplay = true
    }

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityLabel() -> String? {
        "Screenshot deck, \(count) pictures, picture \((selected ?? 0) + 1) selected. Buttons on each picture: " +
            DeckRules.ShotAct.allCases.map { $0.word(listening: listening) }.joined(separator: ", ") +
            ". At the foot: " + DeckRules.FootAct.allCases.map { $0.word(count: count) }.joined(separator: ", ")
    }

    // MARK: drawing

    override func draw(_ dirty: NSRect) {
        guard let m = model else { return }
        Panel.ground(bounds, radius: Self.corner)
        drawHead()
        NSGraphicsContext.saveGraphicsState()
        NSRect(x: 0, y: listRect.minY - 3, width: width, height: listRect.height + 6).clip()
        for i in 0..<count where held?.i != i || held?.moved != true { drawShot(i, at: box(i)) }
        if let h = held, h.moved, m.pics.indices.contains(h.i) {
            let to = box(dropAt(h))
            Native.blue.setFill(); NSRect(x: Self.pad, y: (h.dy < 0 ? to.minY - 6 : to.maxY + 4).rounded(), width: DeckRules.stackW, height: 2).fill()
            drawShot(h.i, at: box(h.i).offsetBy(dx: 0, dy: h.dy), lifted: true)
        }
        NSGraphicsContext.restoreGraphicsState()
        if scrolls { drawScroller() }
        drawFoot()
        drawTip()
    }

    private func drawHead() {
        let h = headRect, f = Panel.strong, a = TapeDraw.at(f, Native.ink)
        let title = count == 1 ? "1 shot" : "\(count) shots"
        TapeDraw.glyph("image", NSRect(x: h.minX + 2, y: h.midY - 8, width: 16, height: 16), color: Native.muted)
        (title as NSString).draw(at: NSPoint(x: h.minX + 26, y: TapeDraw.lineTop(f, mid: h.midY)), withAttributes: a)
        if model?.collecting == true {
            let ha = TapeDraw.at(Panel.hint, Native.blue), tx = h.minX + 26 + TapeDraw.width(title, a) + 10
            ("taking the next one…" as NSString).draw(at: NSPoint(x: tx, y: TapeDraw.lineTop(Panel.hint, mid: h.midY)), withAttributes: ha)
        }
        let c = closeRect
        if hoverClose { Native.hover.setFill(); NSBezierPath(ovalIn: c).fill() }
        TapeDraw.glyph("close", c.insetBy(dx: 7, dy: 7), color: hoverClose ? Native.ink : Native.muted)
        Panel.divider(x0: 0, x1: width, y: h.maxY + 4)
    }

    /// One shot: its box on the card ground, the picture in its own shape at the left, a 2 pt accent ring when it is
    /// the selected one of two or more; its buttons on hover or selection; a take listening for it; its caption under it.
    private func drawShot(_ i: Int, at b: NSRect, lifted: Bool = false) {
        guard let m = model, m.pics.indices.contains(i) else { return }
        let pc = m.pics[i], on = listens(i), sel = i == selected && count > 1
        let shape = NSBezierPath(roundedRect: b, xRadius: Panel.control, yRadius: Panel.control)
        NSGraphicsContext.saveGraphicsState()
        if lifted { Panel.softShadow().set() }
        Native.soft.setFill(); shape.fill()
        NSGraphicsContext.restoreGraphicsState()
        let im = DeckRules.stackImage(pixels: CGSize(width: pc.shot.width, height: pc.shot.height))
        let ir = NSRect(x: b.minX, y: (b.midY - im.height / 2).rounded(), width: min(im.width, b.width), height: im.height)
        if let th = pc.thumb {
            NSGraphicsContext.saveGraphicsState()
            shape.addClip()
            th.draw(in: ir, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high])
            NSGraphicsContext.restoreGraphicsState()
        }
        let edge = NSBezierPath(roundedRect: b.insetBy(dx: 0.25, dy: 0.25), xRadius: Panel.control, yRadius: Panel.control)
        Native.line.setStroke(); edge.lineWidth = 0.5; edge.stroke()
        if sel || on {
            let rr = NSBezierPath(roundedRect: b.insetBy(dx: -2, dy: -2), xRadius: Panel.control + 2, yRadius: Panel.control + 2)
            rr.lineWidth = 2; (on ? Native.coral : Native.blue).setStroke(); rr.stroke()
        }
        if on { drawListening(b) }
        if !lifted, held == nil, i == active { drawButtons(i) }
        for (k, (l, faint)) in caption(i).enumerated() {
            TapeDraw.line(l, NSRect(x: b.minX + 2, y: b.maxY + 6 + CGFloat(k) * Self.capLH, width: b.width - 4, height: Self.capLH + 2),
                          TapeDraw.at(Panel.hint, faint ? Native.faint : Native.muted))
        }
    }
    /// A take listening for the shot: its live level and "listening" at its bottom right.
    private func drawListening(_ b: NSRect) {
        guard let m = model else { return }
        let lr = NSRect(x: b.maxX - 8 - 112, y: b.maxY - 8 - 26, width: 112, height: 26)
        Panel.ground(lr, radius: 13)
        TapeDraw.glyph("microphone", NSRect(x: lr.minX + 8, y: lr.midY - 7, width: 14, height: 14), color: Native.coral)
        for (k, v) in DeckRules.bars(m.levels, n: 4).enumerated() {
            let h = max(3, v * 14)
            (v > 0.05 ? Native.coral : Native.faint).setFill()
            NSBezierPath(roundedRect: NSRect(x: lr.minX + 27 + CGFloat(k) * 5, y: lr.midY - h / 2, width: 3, height: h), xRadius: 1.5, yRadius: 1.5).fill()
        }
        ("listening" as NSString).draw(at: NSPoint(x: lr.minX + 52, y: TapeDraw.lineTop(Panel.hint, mid: lr.midY)), withAttributes: TapeDraw.at(Panel.hint, Native.ink))
    }
    private func drawButtons(_ i: Int) {
        let down = pressed?.key
        for (a, r) in shotButtons(i) {
            let over = hoverAct.map { $0.0 == i && $0.1 == a } ?? false, d = down == "shot\(i).\(a.rawValue)"
            if DeckRules.ShotAct.words.contains(a) {
                NSGraphicsContext.saveGraphicsState(); Panel.softShadow().set()
                Native.card.setFill(); NSBezierPath(roundedRect: r, xRadius: Panel.control, yRadius: Panel.control).fill()
                NSGraphicsContext.restoreGraphicsState()
                Panel.button(Panel.Button(glyph: a.glyph, word: a.word(), destructive: a == .delete), in: r, hover: over, down: d, enabled: enabled(a), font: Panel.hint)
            } else {
                let live = a == .voice && listens(i)
                NSGraphicsContext.saveGraphicsState(); Panel.softShadow().set()
                (live ? Native.coral : over ? Native.card : Native.card.withAlphaComponent(0.92)).setFill(); NSBezierPath(ovalIn: r).fill()
                NSGraphicsContext.restoreGraphicsState()
                let e = NSBezierPath(ovalIn: r.insetBy(dx: 0.25, dy: 0.25)); e.lineWidth = 0.5; (over ? Native.controlEdge : Native.line).setStroke(); e.stroke()
                TapeDraw.glyph(live ? "stop.fill" : a.glyph, r.insetBy(dx: 6.5, dy: 6.5), color: live ? .white : enabled(a) ? (over ? Native.ink : Native.muted) : Native.faint)
            }
        }
    }
    private func drawScroller() {
        let r = listRect, th = max(24, r.height * r.height / max(1, contentH))
        let ty = r.minY + (r.height - th) * scrollY / max(1, contentH - r.height)
        Native.faint.setFill(); NSBezierPath(roundedRect: NSRect(x: width - 6, y: ty, width: 3, height: th), xRadius: 1.5, yRadius: 1.5).fill()
    }
    private func drawFoot() {
        Panel.divider(x0: 0, x1: width, y: footY - 5)
        for (f, r) in footButtons() {
            let over = hoverFoot == f, d = pressed?.key == "foot\(f.rawValue)"
            Panel.button(footButton(f), in: r, hover: over, down: d, enabled: enabled(f))
        }
    }
    /// The tip for what the mouse is on: a symbol button's word (and key), the close x, the head.
    private func drawTip() {
        guard pressed == nil, held == nil, dragDeck == nil else { return }
        if let (i, a) = hoverAct, DeckRules.ShotAct.tools.contains(a), let r = shotButtons(i).first(where: { $0.0 == a })?.1 {
            Panel.tip(word: a == .voice && listens(i) ? "Stop the caption" : a.tip, over: r, bar: r, bounds: bounds)
        } else if let (i, a) = hoverAct, a == .delete, let r = shotButtons(i).first(where: { $0.0 == a })?.1 {
            Panel.tip(word: a.tip, over: r, bar: r, bounds: bounds)
        } else if hoverFoot == .next, let r = footButtons().first?.1 {
            Panel.tip(word: "Take the next shot", key: captureKey, over: r, bar: r, bounds: bounds)
        } else if hoverFoot == .insertAll, let r = footButtons().last?.1 {
            Panel.tip(word: count > 1 ? "Insert all \(count) shots into your field" : "Insert the shot into your field", key: returnHint ? "↵" : "", over: r, bar: r, bounds: bounds)
        } else if hoverClose {
            Panel.tip(word: "Close · the shots stay in the journal", over: closeRect, bar: closeRect, bounds: bounds)
        }
    }
}

/// A hovered card shown large (about 480 pt wide) above the deck, with its caption and a take's words so far. Never
/// takes the mouse or the keys.
final class HandPreview {
    let panel: CapturePanel
    let view = HandPreviewView()
    private(set) var card: Int?

    init() {
        panel = CapturePanel(contentRect: NSRect(x: 0, y: 0, width: 10, height: 10), styleMask: [.nonactivatingPanel, .borderless],
                             backing: .buffered, defer: true)
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = false
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
        panel.ignoresMouseEvents = true; panel.hidesOnDeactivate = false; panel.animationBehavior = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.contentView = view
    }

    /// Card `i` large, its bottom just above the deck, its middle over the hovered card, whole on the screen.
    func show(card i: Int, over r: NSRect, in hand: HandView) {
        guard let m = hand.model, m.pics.indices.contains(i), let w = hand.window else { return }
        card = i
        view.model = m; view.card = i
        let size = view.fit()
        let at = w.convertToScreen(hand.convert(r, to: nil))
        let deck = w.frame
        let scr = (NSScreen.screens.first { $0.frame.intersects(deck) } ?? NSScreen.main)?.visibleFrame ?? deck
        var x = at.midX - size.width / 2, y = deck.maxY - 4
        if y + size.height > scr.maxY - 8 { y = deck.minY - size.height + 4 }   // no room above: under the deck
        x = min(max(x, scr.minX + 8), scr.maxX - 8 - size.width)
        y = min(max(y, scr.minY + 8), scr.maxY - 8 - size.height)
        panel.setFrame(NSRect(x: x.rounded(), y: y.rounded(), width: size.width, height: size.height), display: true)
        panel.orderFrontRegardless()
    }
    func hide() { card = nil; panel.orderOut(nil) }
    func refresh() { if card != nil { let f = panel.frame; let s = view.fit(); if s != f.size { panel.setFrame(NSRect(origin: f.origin, size: s), display: true) }; view.needsDisplay = true } }
}

final class HandPreviewView: NSView {
    weak var model: CaptureNote?
    var card = 0
    override var isFlipped: Bool { true }
    static let pad: CGFloat = 14, capLH: CGFloat = 18
    static var capFont: NSFont { Native.text(13) }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }

    private var pic: CaptureNote.Pic? { model.flatMap { $0.pics.indices.contains(card) ? $0.pics[card] : nil } }
    private var imageSize: NSSize {
        guard let p = pic else { return NSSize(width: DeckRules.previewW, height: 300) }
        // the picture within previewW x 340, its shape kept
        let w = CGFloat(max(1, p.shot.width)), h = CGFloat(max(1, p.shot.height))
        let k = min(DeckRules.previewW / w, 340 / h)
        return NSSize(width: max(220, (w * k).rounded()), height: max(120, (h * k).rounded()))
    }
    private var lines: [(String, Bool)] {
        guard let m = model, let p = pic else { return [] }
        let live = m.listeningFor == p.id ? m.heardLive.trimmingCharacters(in: .whitespaces) : ""
        let chars = max(20, Int(imageSize.width / (13 * 0.52)))
        var out = DeckRules.label(p.caption, width: chars, lines: 3).map { ($0, false) }
        if !live.isEmpty { out += DeckRules.labelTail(live, width: chars).map { ($0.line, true) } }
        return Array(out.suffix(4))
    }
    @discardableResult
    func fit() -> NSSize {
        let s = imageSize, l = lines.count
        let sz = NSSize(width: s.width + 2 * Self.pad, height: s.height + 2 * Self.pad + (l > 0 ? CGFloat(l) * Self.capLH + 8 : 0))
        frame = NSRect(origin: .zero, size: sz)
        return sz
    }
    override func draw(_ dirty: NSRect) {
        guard let p = pic else { return }
        let s = imageSize, body = bounds.insetBy(dx: 4, dy: 4)
        let bg = NSBezierPath(roundedRect: body, xRadius: 12, yRadius: 12)
        NSGraphicsContext.saveGraphicsState(); Native.floatShadow().set(); Native.card.setFill(); bg.fill(); NSGraphicsContext.restoreGraphicsState()
        bg.lineWidth = 0.5; Native.rule.setStroke(); bg.stroke()
        let ir = NSRect(x: Self.pad, y: Self.pad, width: s.width, height: s.height)
        if let th = p.thumb {
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(roundedRect: ir, xRadius: 8, yRadius: 8).addClip()
            _ = TapeDraw.picture(th, in: ir)
            NSGraphicsContext.restoreGraphicsState()
        }
        for (k, (l, faint)) in lines.enumerated() {
            TapeDraw.line(l, NSRect(x: ir.minX, y: ir.maxY + 8 + CGFloat(k) * Self.capLH, width: ir.width, height: Self.capLH + 2),
                          TapeDraw.at(Self.capFont, faint ? Native.muted : Native.ink))
        }
    }
}

// The one floating-panel style (caret-cozy round, 23 November 2026; the user: "map all the rest of the tools and caret's,
// like the screenshot things, that kinda has to be a bit more cozy"). Everything Drafter floats outside its window (the
// chips and cards at the caret, the pickers, the capture deck, the tips) draws its ground, its keys, its buttons and its
// rows with these pieces, so they read like the calm one-column journal: a soft card with a hairline edge and 12 pt
// corners, 13 pt words, keys as small rounded key caps, bordered buttons that name their key, the main one filled.
// AppKit drawing (flipped views) and the same pieces for SwiftUI. Semantic colours only (app/Look.swift, docs/look.md).
// Rebuild B (26 November 2026, the user: "less like a document"): the ground is frosted glass
// (GlassHost blurs the app below, the ground draws a light tint and a hairline over it), corners are 18 pt, the keys
// sit in one dark pill whose blue end is the main action (`pill`), and a panel rises 6 pt as it fades in (`appear`).
// No state, no files.
import AppKit
import SwiftUI

enum Panel {
    // MARK: sizes (points)

    /// A floating panel's corner; a control's (a button, a chip, a row) is `control`; a key cap's `key`.
    static let corner: CGFloat = 18, control: CGFloat = 8, key: CGFloat = 5
    /// Room inside a panel, between two things in it, between a word and its key.
    static let pad: CGFloat = 12, gap: CGFloat = 8
    /// One row of a list: the journal stream's row (kind symbol, one line, app and time at the right).
    static let rowH: CGFloat = 32, symbol: CGFloat = 16
    /// A button and a key cap.
    static let buttonH: CGFloat = 28, capH: CGFloat = 20

    // MARK: type

    /// Words on a panel: 13 pt like the journal's body; hints 12 pt; a key cap's label 11 pt.
    static var font: NSFont { Native.text(13) }
    static var strong: NSFont { Native.text(13, .medium) }
    static var hint: NSFont { Native.text(12) }
    static var capFont: NSFont { Native.text(11, .medium) }
    static var timeFont: NSFont { Native.num(12) }

    // MARK: the ground

    /// A panel's ground. `glass`: the panel sits in a GlassHost, so the ground is a light tint over the blur; without it
    /// the raised card colour. Then a bright inner rim and a 0.5 pt hairline edge. `shadow`: the one soft float shadow
    /// too, drawn outside the card only (draw it only where the view has room round the card; a panel with its own
    /// window shadow passes false).
    static func ground(_ b: NSRect, radius: CGFloat = corner, shadow: Bool = false, glass: Bool = false) {
        let box = NSBezierPath(roundedRect: b.insetBy(dx: 0.25, dy: 0.25), xRadius: radius, yRadius: radius)
        if shadow { outerShadow(box, around: b) }
        (glass ? Native.glassTint : Native.card).setFill(); box.fill()
        let rim = NSBezierPath(roundedRect: b.insetBy(dx: 1, dy: 1), xRadius: max(0, radius - 1), yRadius: max(0, radius - 1))
        Native.glassTop.setStroke(); rim.lineWidth = 0.5; rim.stroke()
        Native.glassEdge.setStroke(); box.lineWidth = 0.5; box.stroke()
    }
    /// The soft float shadow of `box`, outside it only: a glass tint over it would show it through otherwise.
    static func outerShadow(_ box: NSBezierPath, around b: NSRect) {
        NSGraphicsContext.saveGraphicsState()
        let clip = NSBezierPath(rect: b.insetBy(dx: -80, dy: -80)); clip.append(box); clip.windingRule = .evenOdd; clip.addClip()
        softShadow().set(); NSColor.black.setFill(); box.fill()
        NSGraphicsContext.restoreGraphicsState()
    }
    /// The soft shadow under what floats: wider and lighter than a window's.
    static func softShadow() -> NSShadow { Native.floatShadow() }
    /// A hairline across a panel, inset by its padding.
    static func divider(x0: CGFloat, x1: CGFloat, y: CGFloat) {
        Native.line.setFill(); NSRect(x: x0, y: y.rounded() - 0.25, width: x1 - x0, height: 0.5).fill()
    }

    // MARK: key caps

    /// A key cap's width for `k`.
    static func capWidth(_ k: String, h: CGFloat = capH) -> CGFloat {
        max(h, (TapeDraw.width(k, TapeDraw.at(capFont, Native.ink)) + 10).rounded(.up))
    }
    /// A small key cap: a soft fill, a hairline edge, 5 pt corners, the key in 11 pt. `on`: the key in use (a stronger
    /// fill). `onFill`: on a filled (accent) button, the cap in its words' colour. Returns its width.
    @discardableResult
    static func keycap(_ k: String, x: CGFloat, y: CGFloat, h: CGFloat = capH, on: Bool = false, onFill: Bool = false) -> CGFloat {
        let w = capWidth(k, h: h), r = NSRect(x: x, y: y, width: w, height: h)
        let p = NSBezierPath(roundedRect: r.insetBy(dx: 0.25, dy: 0.25), xRadius: key, yRadius: key)
        if onFill {
            Native.onPrimary.withAlphaComponent(0.22).setFill(); p.fill()
        } else {
            (on ? Native.selected : Native.key).setFill(); p.fill()
            (on ? Native.blue.withAlphaComponent(0.5) : Native.line).setStroke(); p.lineWidth = 0.5; p.stroke()
        }
        let f = capFont, a = TapeDraw.at(f, onFill ? Native.onPrimary : on ? Native.ink : Native.muted)
        let tw = TapeDraw.width(k, a)
        (k as NSString).draw(at: NSPoint(x: (r.midX - tw / 2).rounded(), y: TapeDraw.lineTop(f, mid: r.midY)), withAttributes: a)
        return w
    }
    /// Key caps and their words in a row ("↑↓ choose  ⇥ put in  esc close"), from `x` on the line round `mid`: since
    /// Rebuild B they sit in the dark key pill. Returns the x after it.
    @discardableResult
    static func hints(_ pairs: [(key: String, word: String)], x: CGFloat, mid: CGFloat, color: NSColor = Native.muted) -> CGFloat {
        x + pill(pairs, x: x, mid: mid)
    }
    static func hintsWidth(_ pairs: [(key: String, word: String)]) -> CGFloat { pillWidth(pairs) }

    // MARK: the key pill (Rebuild B)

    static let pillH: CGFloat = 30
    /// A cap inside the pill: faint white, white key; on the blue end a lighter cap.
    @discardableResult
    static func hudCap(_ k: String, x: CGFloat, mid: CGFloat, onBlue: Bool = false, draw: Bool = true) -> CGFloat {
        let h: CGFloat = 18, a = TapeDraw.at(capFont, Native.onHud), w = max(h, (TapeDraw.width(k, a) + 10).rounded(.up))
        guard draw else { return w }
        let r = NSRect(x: x, y: (mid - h / 2).rounded(), width: w, height: h)
        (onBlue ? NSColor.white.withAlphaComponent(0.24) : Native.hudCap).setFill()
        NSBezierPath(roundedRect: r, xRadius: key, yRadius: key).fill()
        let tw = TapeDraw.width(k, a)
        (k as NSString).draw(at: NSPoint(x: (r.midX - tw / 2).rounded(), y: TapeDraw.lineTop(capFont, mid: r.midY)), withAttributes: a)
        return w
    }
    /// The one key pill: near black, each key a faint white cap with its word, the main action (`go`) at its end in the
    /// accent colour with its own cap. From `x` on the line round `mid`; returns its width (`draw` false measures only).
    @discardableResult
    static func pill(_ pairs: [(key: String, word: String)], go: (key: String, word: String)? = nil, x: CGFloat, mid: CGFloat,
                     draw: Bool = true, shadow: Bool = true) -> CGFloat {
        let wa = TapeDraw.at(hint, Native.onHudMuted), ga = TapeDraw.at(strongHint, Native.onHud)
        var w: CGFloat = 10
        for (i, p) in pairs.enumerated() { w += hudCap(p.key, x: 0, mid: 0, draw: false) + 6 + TapeDraw.width(p.word, wa) + (i < pairs.count - 1 ? 14 : 0) }
        var goW: CGFloat = 0
        if let g = go { goW = 10 + TapeDraw.width(g.word, ga) + 6 + hudCap(g.key, x: 0, mid: 0, draw: false) + 6 }
        w += go == nil ? 10 : (pairs.isEmpty ? 3 - 10 + 0 : 12) + goW + 3
        w = w.rounded(.up)
        guard draw else { return w }
        let r = NSRect(x: x, y: (mid - pillH / 2).rounded(), width: w, height: pillH)
        let shape = NSBezierPath(roundedRect: r, xRadius: pillH / 2, yRadius: pillH / 2)
        if shadow {
            NSGraphicsContext.saveGraphicsState()
            let sh = NSShadow(); sh.shadowColor = NSColor.black.withAlphaComponent(0.22); sh.shadowBlurRadius = 10; sh.shadowOffset = NSSize(width: 0, height: -4)
            sh.set(); Native.hud.setFill(); shape.fill()
            NSGraphicsContext.restoreGraphicsState()
        }
        Native.hud.setFill(); shape.fill()
        NSColor.white.withAlphaComponent(0.08).setStroke(); shape.lineWidth = 0.5; shape.stroke()
        var cx = r.minX + 10
        for p in pairs {
            cx += hudCap(p.key, x: cx, mid: r.midY) + 6
            (p.word as NSString).draw(at: NSPoint(x: cx, y: TapeDraw.lineTop(hint, mid: r.midY)), withAttributes: wa)
            cx += TapeDraw.width(p.word, wa) + 14
        }
        if let g = go {
            let gr = NSRect(x: r.maxX - 3 - goW, y: r.minY + 3, width: goW, height: pillH - 6)
            Native.go.setFill(); NSBezierPath(roundedRect: gr, xRadius: gr.height / 2, yRadius: gr.height / 2).fill()
            (g.word as NSString).draw(at: NSPoint(x: gr.minX + 10, y: TapeDraw.lineTop(strongHint, mid: gr.midY)), withAttributes: ga)
            hudCap(g.key, x: gr.maxX - 6 - hudCap(g.key, x: 0, mid: 0, draw: false), mid: gr.midY, onBlue: true)
        }
        return w
    }
    static func pillWidth(_ pairs: [(key: String, word: String)], go: (key: String, word: String)? = nil) -> CGFloat {
        pill(pairs, go: go, x: 0, mid: 0, draw: false)
    }
    static var strongHint: NSFont { Native.text(12, .medium) }

    // MARK: motion (Rebuild B)

    /// A panel's way in: it fades in and rises 6 pt (80 ms). Already on screen, or Reduce Motion on: it just shows.
    static func appear(_ w: NSWindow) {
        let d = Native.motion("rise")
        guard d > 0, !w.isVisible else { w.alphaValue = 1; w.orderFrontRegardless(); return }
        let end = w.frame
        w.alphaValue = 0
        w.setFrameOrigin(NSPoint(x: end.minX, y: end.minY - Native.rise))
        w.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { c in
            c.duration = d; c.timingFunction = CAMediaTimingFunction(name: .easeOut)
            w.animator().alphaValue = 1
            w.animator().setFrameOrigin(end.origin)
        }
    }

    // MARK: buttons

    /// A bordered button's face: its symbol, its word, its key (as a cap at the right).
    struct Button {
        var glyph: String? = nil
        var word: String
        var key = ""
        var prominent = false
        var destructive = false
    }
    /// The button's width at `font`.
    static func buttonWidth(_ b: Button, font f: NSFont = font) -> CGFloat {
        let ww = TapeDraw.width(b.word, TapeDraw.at(f, Native.ink))
        return (10 + (b.glyph == nil ? 0 : 15 + 6) + ww + (b.key.isEmpty ? 0 : 8 + capWidth(b.key, h: 18)) + 10).rounded(.up)
    }
    /// A bordered button: the control fill with a hairline edge; the main one filled with the accent. `hover` lifts it,
    /// `down` darkens it, `enabled` false greys it.
    static func button(_ b: Button, in r: NSRect, hover: Bool = false, down: Bool = false, enabled: Bool = true, live: Bool = false, font f: NSFont = font) {
        let shape = NSBezierPath(roundedRect: r.insetBy(dx: 0.25, dy: 0.25), xRadius: control, yRadius: control)
        let filled = b.prominent || live
        if filled {
            let a = Native.blue
            (down ? a.blended(withFraction: 0.2, of: .black) ?? a : hover ? a.blended(withFraction: 0.1, of: .white) ?? a : a)
                .withAlphaComponent(enabled ? 1 : 0.45).setFill(); shape.fill()
        } else {
            (down ? Native.soft : hover && enabled ? Native.hover : Native.card).setFill(); shape.fill()
            NSColor.controlColor.withAlphaComponent(Native.dark ? 0.08 : 0.6).setFill(); shape.fill()
            (hover && enabled ? Native.controlEdge : Native.line).setStroke(); shape.lineWidth = 0.5; shape.stroke()
        }
        var ink: NSColor = filled ? Native.onPrimary : (b.destructive && hover ? Native.crit : Native.ink)
        if !enabled { ink = filled ? Native.onPrimary.withAlphaComponent(0.75) : Native.faint }
        var x = r.minX + 10
        if let g = b.glyph {
            TapeDraw.glyph(g, NSRect(x: x, y: (r.midY - 7.5).rounded(), width: 15, height: 15), color: filled ? ink : (enabled ? Native.muted : Native.faint))
            x += 15 + 6
        }
        let a = TapeDraw.at(f, ink), capW = b.key.isEmpty ? 0 : capWidth(b.key, h: 18)
        let right = r.maxX - 10 - (capW > 0 ? capW + 8 : 0)
        TapeDraw.line(b.word, NSRect(x: x, y: TapeDraw.lineTop(f, mid: r.midY), width: max(0, right - x) + 2, height: f.ascender - f.descender + 4), a)
        if capW > 0 { keycap(b.key, x: r.maxX - 10 - capW, y: (r.midY - 9).rounded(), h: 18, onFill: filled) }
    }

    // MARK: a row like the journal's

    /// One row as in the journal stream: the kind's symbol in its colour, one line of words, then the app and the time
    /// at the right in the quiet colour. `chosen`: a soft lift with the control corner. Returns nothing; draws in `r`.
    static func row(_ r: NSRect, symbol mark: String?, tint: NSColor = Native.muted, text: String, app: String = "", time: String = "",
                    chosen: Bool = false, hover: Bool = false, font f: NSFont = font, ink: NSColor = Native.ink) {
        if chosen || hover {
            (chosen ? Native.pick : Native.hover).setFill()
            NSBezierPath(roundedRect: r, xRadius: control, yRadius: control).fill()
        }
        var x = r.minX + 10
        if let m = mark {
            TapeDraw.glyph(m, NSRect(x: x, y: (r.midY - symbol / 2).rounded(), width: symbol, height: symbol), color: tint)
            x += symbol + 10
        }
        var right = r.maxX - 10
        let ta = TapeDraw.at(timeFont, Native.faint)
        if !time.isEmpty {
            let tw = TapeDraw.width(time, ta); right -= tw
            (time as NSString).draw(at: NSPoint(x: right, y: TapeDraw.lineTop(timeFont, mid: r.midY)), withAttributes: ta)
            right -= 12
        }
        if !app.isEmpty {
            let aa = TapeDraw.at(hint, Native.faint), aw = min(TapeDraw.width(app, aa), 120)
            right -= aw
            TapeDraw.line(app, NSRect(x: right, y: TapeDraw.lineTop(hint, mid: r.midY), width: aw, height: 17), aa)
            right -= 12
        }
        TapeDraw.line(text, NSRect(x: x, y: TapeDraw.lineTop(f, mid: r.midY), width: max(0, right - x), height: f.ascender - f.descender + 4), TapeDraw.at(f, ink))
    }

    // MARK: the tip

    /// A hover tip: the panel's ground, its word and key cap, above `r` (under it when there is no room).
    static func tip(word: String, key: String = "", over r: NSRect, bar: NSRect, bounds: NSRect) {
        guard !word.isEmpty else { return }
        let a = TapeDraw.at(font, Native.ink), ww = TapeDraw.width(word, a)
        let kw = key.isEmpty ? 0 : capWidth(key) + 8
        let w = ww + kw + 2 * 10, h: CGFloat = 30
        var y = bar.minY - 6 - h
        if y < bounds.minY + 2 { y = bar.maxY + 6 }
        let x = min(max(r.midX - w / 2, bounds.minX + 4), bounds.maxX - 4 - w)
        let t = NSRect(x: x.rounded(), y: y.rounded(), width: w.rounded(.up), height: h)
        ground(t, radius: control, shadow: true)
        (word as NSString).draw(at: NSPoint(x: t.minX + 10, y: TapeDraw.lineTop(font, mid: t.midY)), withAttributes: a)
        if !key.isEmpty { keycap(key, x: t.minX + 10 + ww + 8, y: (t.midY - capH / 2).rounded()) }
    }
}

// MARK: SwiftUI (the journal stream and any SwiftUI panel use the same pieces)

/// A small key cap.
struct PanelKeyCap: View {
    let key: String
    init(_ key: String) { self.key = key }
    var body: some View {
        Text(key).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
            .padding(.horizontal, 5).frame(minWidth: Panel.capH, minHeight: Panel.capH)
            .background(RoundedRectangle(cornerRadius: Panel.key).fill(Color(nsColor: Native.key)))
            .overlay(RoundedRectangle(cornerRadius: Panel.key).strokeBorder(Color(nsColor: Native.line), lineWidth: 0.5))
            .accessibilityLabel("key \(key)")
    }
}

/// A bordered button that names its key; `prominent` fills the main one.
struct PanelButton: View {
    let word: String
    var symbol: String? = nil
    var key = ""
    var prominent = false
    let action: () -> Void
    var body: some View {
        let label = HStack(spacing: 6) {
            if let s = symbol { Image(systemName: Native.symbolName(s)).font(.system(size: 12)) }
            Text(word).font(.system(size: 13))
            if !key.isEmpty { PanelKeyCap(key) }
        }
        if prominent { Button(action: action) { label }.buttonStyle(.borderedProminent).controlSize(.regular) }
        else { Button(action: action) { label }.buttonStyle(.bordered).controlSize(.regular) }
    }
}

/// A cap inside the key pill: faint white, the key in white.
struct HudCap: View {
    let key: String
    var onBlue = false
    init(_ key: String, onBlue: Bool = false) { self.key = key; self.onBlue = onBlue }
    var body: some View {
        Text(key).font(.system(size: 11, weight: .medium)).foregroundStyle(.white)
            .padding(.horizontal, 5).frame(minWidth: 18, minHeight: 18)
            .background(RoundedRectangle(cornerRadius: Panel.key).fill(.white.opacity(onBlue ? 0.24 : 0.14)))
            .accessibilityLabel("key \(key)")
    }
}

/// The key pill (Rebuild B): near black, each key a faint cap with its word, the main action at its end in the
/// accent colour; clicking the blue end runs it.
struct HudPill: View {
    struct Key: Identifiable { let key: String; let word: String; var id: String { key + word } }
    let keys: [Key]
    var go: Key? = nil
    var action: (() -> Void)? = nil
    init(_ keys: [(String, String)], go: (String, String)? = nil, action: (() -> Void)? = nil) {
        self.keys = keys.map { Key(key: $0.0, word: $0.1) }
        self.go = go.map { Key(key: $0.0, word: $0.1) }
        self.action = action
    }
    var body: some View {
        HStack(spacing: 14) {
            ForEach(keys) { k in
                HStack(spacing: 6) { HudCap(k.key); Text(k.word).font(.system(size: 12)).foregroundStyle(.white.opacity(0.62)) }
            }
            if let g = go {
                Button { action?() } label: {
                    HStack(spacing: 6) { Text(g.word).font(.system(size: 12, weight: .medium)); HudCap(g.key, onBlue: true) }
                        .foregroundStyle(.white).padding(.leading, 10).padding(.trailing, 6).frame(height: 24)
                        .background(Capsule().fill(Color(nsColor: Native.go)))
                }.buttonStyle(.plain).padding(.leading, keys.isEmpty ? -7 : 0)
            }
        }
        .padding(.leading, 10).padding(.trailing, go == nil ? 10 : 3).frame(height: Panel.pillH)
        .background(Capsule().fill(Color(nsColor: Native.hud)))
        .overlay(Capsule().strokeBorder(.white.opacity(0.08), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.22), radius: 10, y: 4)
    }
}

extension View {
    /// A floating panel's ground in SwiftUI (Rebuild B): the popover material with the glass tint over it, a bright rim,
    /// a hairline edge, 18 pt corners, the soft shadow.
    func panelGround() -> some View {
        self.padding(Panel.pad).glassCard()
    }
    /// The glass card itself, without the padding.
    func glassCard(radius: CGFloat = Panel.corner) -> some View {
        self.background {
            ZStack {
                RoundedRectangle(cornerRadius: radius).fill(.regularMaterial)
                RoundedRectangle(cornerRadius: radius).fill(Color(nsColor: Native.glassTint))
            }
        }
        .overlay(RoundedRectangle(cornerRadius: radius - 1).strokeBorder(Color(nsColor: Native.glassTop), lineWidth: 0.5).padding(1))
        .overlay(RoundedRectangle(cornerRadius: radius).strokeBorder(Color(nsColor: Native.glassEdge), lineWidth: 0.5))
        .shadow(color: .black.opacity(Native.dark ? 0.35 : 0.14), radius: 12, y: 6)
    }
    /// Rebuild B's way in for a SwiftUI piece: it fades in and rises 6 pt.
    func riseIn(_ shown: Bool) -> some View {
        self.opacity(shown ? 1 : 0).offset(y: shown ? 0 : Native.rise)
            .animation(.easeOut(duration: Native.motion("rise")), value: shown)
    }
}

/// Frosted glass behind a floating panel (Rebuild B): the app below blurred, masked to the card, which sits `inset`
/// from the window's edge (the room for the drawn shadow) with `radius` corners. The panel's drawing view goes inside
/// and fills it; its ground then passes `glass: true`.
final class GlassHost: NSVisualEffectView {
    init(_ content: NSView, inset: CGFloat, radius: CGFloat = Panel.corner) {
        super.init(frame: content.frame)
        material = .popover; blendingMode = .behindWindow; state = .active
        maskImage = Self.mask(inset: inset, radius: radius)
        content.frame = bounds; content.autoresizingMask = [.width, .height]
        addSubview(content)
    }
    required init?(coder: NSCoder) { fatalError("not used") }
    /// A stretchable mask: the rounded card, clear round it.
    static func mask(inset: CGFloat, radius: CGFloat) -> NSImage {
        let side = 2 * (inset + radius) + 1
        let img = NSImage(size: NSSize(width: side, height: side), flipped: false) { r in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: r.insetBy(dx: inset, dy: inset), xRadius: radius, yRadius: radius).fill()
            return true
        }
        let c = inset + radius
        img.capInsets = NSEdgeInsets(top: c, left: c, bottom: c, right: c)
        img.resizingMode = .stretch
        return img
    }
}

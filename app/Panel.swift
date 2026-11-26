// The one floating-panel style (caret-cozy round, 23 November 2026; the user: "map all the rest of the tools and caret's,
// like the screenshot things, that kinda has to be a bit more cozy"). Everything Drafter floats outside its window (the
// chips and cards at the caret, the pickers, the capture deck, the tips) draws its ground, its keys, its buttons and its
// rows with these pieces, so they read like the calm one-column journal: a soft card with a hairline edge and 12 pt
// corners, 13 pt words, keys as small rounded key caps, bordered buttons that name their key, the main one filled.
// AppKit drawing (flipped views) and the same pieces for SwiftUI. Semantic colours only (app/Look.swift, docs/look.md).
// No state, no files.
import AppKit
import SwiftUI

enum Panel {
    // MARK: sizes (points)

    /// A floating panel's corner; a control's (a button, a chip, a row) is `control`; a key cap's `key`.
    static let corner: CGFloat = 12, control: CGFloat = 8, key: CGFloat = 5
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

    /// A panel's ground: the raised card colour, a 0.5 pt hairline edge. `shadow`: the one soft float shadow too (draw
    /// it only where the view has room round the card; a panel with its own window shadow passes false).
    static func ground(_ b: NSRect, radius: CGFloat = corner, shadow: Bool = false) {
        let box = NSBezierPath(roundedRect: b.insetBy(dx: 0.25, dy: 0.25), xRadius: radius, yRadius: radius)
        if shadow {
            NSGraphicsContext.saveGraphicsState(); softShadow().set(); Native.card.setFill(); box.fill(); NSGraphicsContext.restoreGraphicsState()
        }
        Native.card.setFill(); box.fill()
        Native.line.setStroke(); box.lineWidth = 0.5; box.stroke()
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
    /// Key caps and their words in a row ("↑↓ choose  ⇥ put in  esc close"), from `x` on the line round `mid`.
    /// Returns the x after the last.
    @discardableResult
    static func hints(_ pairs: [(key: String, word: String)], x: CGFloat, mid: CGFloat, color: NSColor = Native.muted) -> CGFloat {
        var x = x
        let a = TapeDraw.at(hint, color)
        for (k, w) in pairs {
            x += keycap(k, x: x, y: (mid - capH / 2).rounded()) + 6
            (w as NSString).draw(at: NSPoint(x: x, y: TapeDraw.lineTop(hint, mid: mid)), withAttributes: a)
            x += TapeDraw.width(w, a) + 14
        }
        return x
    }
    static func hintsWidth(_ pairs: [(key: String, word: String)]) -> CGFloat {
        let a = TapeDraw.at(hint, Native.muted)
        return pairs.reduce(0) { $0 + capWidth($1.key) + 6 + TapeDraw.width($1.word, a) + 14 } - (pairs.isEmpty ? 0 : 14)
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

extension View {
    /// A floating panel's ground in SwiftUI: the popover material, a hairline edge, 12 pt corners, the soft shadow.
    func panelGround() -> some View {
        self.padding(Panel.pad)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Panel.corner))
            .overlay(RoundedRectangle(cornerRadius: Panel.corner).strokeBorder(Color(nsColor: Native.line), lineWidth: 0.5))
            .shadow(color: .black.opacity(Native.dark ? 0.35 : 0.14), radius: 9, y: 6)
    }
}

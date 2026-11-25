// The screenshot tool's pills (look round, 15 November 2026; Andrii: "for all of the buttons we need glyphs", "a better
// toolbar", he likes macOS ⌘⇧5): one floating pill of 42 pt glyph buttons (32 until the key and strip round) in groups split by hairlines. The key sits
// small under each glyph; the word comes up in a tip over the button on hover (and is the button's VoiceOver name), so
// the bar itself carries no words. The chosen button has a lifted fill and an edge; the main one (done) is filled.
// The capture pill (app/Capture.swift), the markup pill (app/Markup.swift) and the strip's keys (app/CaptureNote.swift)
// all draw with these pieces. Layout and hit tests are pure: ShotRules.pill / attach / markHit (app/ShotRules.swift).
// Drawing only, in flipped coordinates (y down).
import AppKit

/// One button's face.
struct PillFace {
    var glyph: String? = nil
    var icon: NSImage? = nil          // an app's own icon (the send-to list)
    var swatch: NSColor? = nil        // a colour to pick
    var dot: CGFloat? = nil           // a stroke size to pick (the dot's diameter)
    var key = ""
    var word = ""
    var on = false
    var primary = false
}

enum ShotPill {
    static let radius: CGFloat = 28, buttonRadius: CGFloat = 11
    /// Key and strip round (15 November 2026, Andrii: bigger): glyph 18 → 22 pt, the key 8 → 11 pt, the tip 12 → 14 pt.
    static let glyphSize: CGFloat = 22, keyFont: CGFloat = 11, swatch: CGFloat = 19

    /// The bar: the card colour, a hairline edge, the one float shadow, round ends.
    static func bar(_ r: NSRect) {
        let path = NSBezierPath(roundedRect: r, xRadius: min(radius, r.height / 2), yRadius: min(radius, r.height / 2))
        NSGraphicsContext.saveGraphicsState()
        Native.floatShadow().set(); Native.card.setFill(); path.fill()
        NSGraphicsContext.restoreGraphicsState()
        let edge = NSBezierPath(roundedRect: r.insetBy(dx: 0.25, dy: 0.25), xRadius: min(radius, r.height / 2) - 0.25, yRadius: min(radius, r.height / 2) - 0.25)
        Native.rule.setStroke(); edge.lineWidth = 0.5; edge.stroke()
    }
    static func divider(x: CGFloat, bar r: NSRect) {
        Native.line.setFill(); NSRect(x: x.rounded() - 0.5, y: r.minY + 15, width: 1, height: r.height - 30).fill()
    }

    /// A button: hover lifts it, on lifts it and draws its edge, primary fills it. The glyph sits in the upper part, the
    /// key small under it (none on swatches and sizes: their tip says it).
    static func button(_ f: PillFace, _ r: NSRect, hover: Bool) {
        let shape = NSBezierPath(roundedRect: r, xRadius: buttonRadius, yRadius: buttonRadius)
        if f.primary { Native.primary.setFill(); shape.fill() }
        else if f.on || hover { (f.on ? Native.soft : Native.hover).setFill(); shape.fill() }
        if f.on, !f.primary {
            let e = NSBezierPath(roundedRect: r.insetBy(dx: 0.5, dy: 0.5), xRadius: buttonRadius - 0.5, yRadius: buttonRadius - 0.5)
            Native.controlEdge.setStroke(); e.lineWidth = 1; e.stroke()
        }
        let ink: NSColor = f.primary ? Native.onPrimary : (f.on || hover) ? Native.ink : Native.muted
        if let c = f.swatch {
            let d = swatch, cr = NSRect(x: r.midX - d / 2, y: r.midY - d / 2, width: d, height: d)
            c.setFill(); NSBezierPath(ovalIn: cr).fill()
            Native.rule.setStroke(); let e = NSBezierPath(ovalIn: cr.insetBy(dx: 0.5, dy: 0.5)); e.lineWidth = 0.5; e.stroke()
            if f.on { Native.ink.setStroke(); let ring = NSBezierPath(ovalIn: cr.insetBy(dx: -3, dy: -3)); ring.lineWidth = 1.5; ring.stroke() }
            return
        }
        if let d = f.dot {
            ink.setFill(); NSBezierPath(ovalIn: NSRect(x: r.midX - d / 2, y: r.midY - d / 2, width: d, height: d)).fill()
            return
        }
        let hasKey = !f.key.isEmpty
        let g: CGFloat = hasKey ? 18 : glyphSize
        let gr = NSRect(x: (r.midX - g / 2).rounded(), y: hasKey ? r.minY + 5 : (r.midY - g / 2).rounded(), width: g, height: g)
        if let icon = f.icon {
            icon.draw(in: gr.insetBy(dx: -1, dy: -1), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high])
        } else if let name = f.glyph {
            TapeDraw.glyph(name, gr, color: ink)
        }
        if hasKey {
            // the key as a small cap under the glyph (caret-cozy round: the same key cap everywhere, app/Panel.swift)
            let h: CGFloat = 14, w = max(h, Panel.capWidth(f.key, h: h) - 2)
            let kr = NSRect(x: (r.midX - w / 2).rounded(), y: r.maxY - 4 - h, width: w, height: h)
            let p = NSBezierPath(roundedRect: kr, xRadius: 4, yRadius: 4)
            (f.primary ? Native.onPrimary.withAlphaComponent(0.22) : Native.key).setFill(); p.fill()
            let font = Native.text(9.5, .semibold), a = TapeDraw.at(font, f.primary ? Native.onPrimary : Native.muted)
            let tw = TapeDraw.width(f.key, a)
            (f.key as NSString).draw(at: NSPoint(x: (kr.midX - tw / 2).rounded(), y: TapeDraw.lineTop(font, mid: kr.midY)), withAttributes: a)
        }
    }

    /// The hover tip: the panels' tip (Panel.tip), the word and its key cap, over the bar (under it when there is no room).
    static func tip(_ f: PillFace, over r: NSRect, bar: NSRect, bounds: NSRect) {
        Panel.tip(word: f.word, key: f.key, over: r, bar: bar, bounds: bounds)
    }

    /// A whole pill: bar, hairlines, buttons, then the tip of the hovered one.
    static func draw(_ p: ShotRules.Pill, faces: [PillFace], hover: Int?, bounds: NSRect) {
        bar(p.bar)
        for x in p.dividers { divider(x: x, bar: p.bar) }
        for (i, r) in p.items.enumerated() where i < faces.count { button(faces[i], r, hover: hover == i) }
        if let h = hover, h < faces.count, h < p.items.count { tip(faces[h], over: p.items[h], bar: p.bar, bounds: bounds) }
    }

    /// The pill drawn into a non-flipped view (the dimmed screen): through a flipped image over `area`.
    static func drawUnflipped(_ area: NSRect, _ body: @escaping (NSRect) -> Void) {
        let img = NSImage(size: area.size, flipped: true) { b in body(b); return true }
        img.draw(in: area)
    }
}

/// The apps' own icons for the send-to list: Claude, Codex, Aleph and the front terminal (Claude Code), when that app
/// is on this Mac; nil else (the list draws the target's line glyph).
enum ShotIcons {
    private static var cache: [String: NSImage] = [:]
    private static var missing: Set<String> = []
    static func app(_ bundle: String) -> NSImage? {
        if let i = cache[bundle] { return i }
        if missing.contains(bundle) { return nil }
        guard let u = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) else { missing.insert(bundle); return nil }
        let i = NSWorkspace.shared.icon(forFile: u.path)
        cache[bundle] = i
        return i
    }
    static func icon(_ t: ShotTarget) -> NSImage? {
        switch t {
        case .claude, .codex, .aleph: return ShotPack.appBundle(t, aleph: ShotSend.alephBundle).flatMap(app)
        case .claudeCode:
            let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
            let running = [front].compactMap { $0 } + NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier)
            return app(ShotPack.claudeCodeApp(running: running))
        default: return nil
        }
    }
}

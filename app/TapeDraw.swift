// The tape (look round "Tape", 14 November 2026): one row type everywhere. A mono time gutter on the left with the
// kind's line glyph, one line of text, the source app as a small glyph at the right. The chosen row is a quiet lift of
// the surface (the theme's `soft`) with a 2 pt edge in the kind's colour, and unfolds in place. Hour dividers are
// hairlines with the hour in mono. The Quick panel, the switcher, the window and Settings draw with these pieces, so
// they read as one tape. Drawing only (AppKit, flipped views); no state, no files.
//
// Second pass (same day; Andrii: "a little less blocky, less pixelated", "maybe not as blue"): line glyphs for every
// interface mark, no sprocket holes, no
// colour bands on every row, 1 pt hairlines, rounder corners, more air. Blue stays for the caret and focus only; the
// panel reads in grey alone.
import AppKit

/// The four kinds on the tape: one mark and one series colour each (copied blue, typed mint, said violet, call coral).
enum TapeKind: CaseIterable {
    case copied, typed, said, call
    init(_ k: QuickKind) { self = k == .copied ? .copied : k == .typed ? .typed : .said }
    /// The kind's symbol: the waves stand in for "said".
    var mark: String {
        switch self { case .copied: return "copy"; case .typed: return "keys"; case .said: return "waves"; case .call: return "phone" }
    }
    var color: NSColor {
        switch self { case .copied: return Native.blue; case .typed: return Native.mint; case .said: return Native.violet; case .call: return Native.coral }
    }
    /// The kind's name for people: a noun (Andrii, 14 November: no past-tense verbs as names).
    var name: String {
        switch self { case .copied: return "Clips"; case .typed: return "Drafts"; case .said: return "Voice notes"; case .call: return "Recordings" }
    }
    /// The stored kind value the journal's rules use (TapeRules): copied, typed, spoken, call.
    var word: String {
        switch self { case .copied: return "copied"; case .typed: return "typed"; case .said: return "spoken"; case .call: return "call" }
    }
}

enum TapeDraw {
    // MARK: sizes (in points)
    /// The chosen row's edge in the kind's colour.
    static let edge: CGFloat = 2
    /// The chosen row: a step off the surface (darker in light, lighter in dark), never the accent.
    static var lift: NSColor { Native.soft }
    /// Keycaps sit between the key corner and the control corner.
    static var keyRadius: CGFloat { ((Native.corner(1) + Native.corner(2)) / 2).rounded() }

    // MARK: the source app

    /// The symbol for the app a row came from, by its name; nil when none fits (nothing is drawn then).
    static func appMark(_ app: String) -> String? {
        let a = app.lowercased()
        if a.isEmpty { return nil }
        func any(_ ws: [String]) -> Bool { ws.contains { a.contains($0) } }
        if any(["claude", "chatgpt", "codex", "perplexity", "copilot", "gemini"]) { return "sparkle" }
        if any(["telegram", "beeper", "slack", "whatsapp", "signal", "messages", "messenger", "discord", "teams", "viber"]) { return "chat" }
        if any(["mail", "outlook", "spark", "superhuman", "mimestream"]) { return "mail" }
        if any(["safari", "chrome", "arc", "firefox", "dia", "browser", "edge", "orion"]) { return "globe" }
        if any(["terminal", "iterm", "warp", "ghostty", "kitty", "alacritty"]) { return "terminal" }
        if any(["xcode", "code", "cursor", "zed", "nova", "sublime", "intellij", "pycharm", "webstorm"]) { return "file-edit" }
        if any(["calendar", "fantastical", "notion calendar", "cron"]) { return "calendar" }
        if any(["zoom", "facetime", "meet", "whereby"]) { return "phone" }
        if any(["preview", "photos", "figma", "pixelmator", "screenshot"]) { return "image" }
        if any(["maps"]) { return "map" }
        if any(["notes", "obsidian", "notion", "pages", "textedit", "word", "docs", "bear", "craft", "drafts"]) { return "file" }
        return nil
    }

    // MARK: time

    private static let hm: DateFormatter = { let f = DateFormatter(); f.dateFormat = "HH:mm"; return f }()
    private static let dm: DateFormatter = { let f = DateFormatter(); f.dateFormat = "d.MM"; return f }()
    static func time(_ t: Double) -> String { hm.string(from: Date(timeIntervalSince1970: t)) }
    /// Today's rows by hour, older ones by day: the divider key (cheap: no calendar, the zone's offset once).
    static func bucket(_ t: Double, now: Double) -> Int {
        let off = Double(TimeZone.current.secondsFromGMT()), h = Int(floor((t + off) / 3600)), today = Int(floor((now + off) / 86400))
        return h / 24 == today ? h : -(h / 24)
    }
    /// A divider's label: the hour ("11:00") on the day of `now`, the date ("13.11") before it.
    static func label(_ t: Double, now: Double) -> String {
        let k = bucket(t, now: now)
        return k >= 0 ? String(format: "%02d:00", ((k % 24) + 24) % 24) : dm.string(from: Date(timeIntervalSince1970: t))
    }
    /// A row's time: "12:41" today, "13.11" before.
    static func stamp(_ t: Double, now: Double) -> String { bucket(t, now: now) >= 0 ? time(t) : dm.string(from: Date(timeIntervalSince1970: t)) }

    // MARK: text

    static func at(_ font: NSFont, _ color: NSColor, lh: CGFloat? = nil, cut: NSLineBreakMode = .byTruncatingTail, strike: NSColor? = nil) -> [NSAttributedString.Key: Any] {
        let p = NSMutableParagraphStyle(); p.lineBreakMode = cut
        if let lh { p.minimumLineHeight = lh; p.maximumLineHeight = lh }
        var a: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color, .paragraphStyle: p]
        if let strike { a[.strikethroughStyle] = NSUnderlineStyle.single.rawValue; a[.strikethroughColor] = strike }
        return a
    }
    /// Where to draw a line of `font` so its letters sit centred on `mid` (flipped).
    static func lineTop(_ font: NSFont, mid: CGFloat) -> CGFloat {
        let lh = font.ascender - font.descender + font.leading
        return (mid - lh / 2).rounded()
    }
    /// One line, cut at the end (or the middle).
    static func line(_ s: String, _ r: NSRect, _ a: [NSAttributedString.Key: Any]) {
        (s as NSString).draw(with: r, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: a)
    }
    static func width(_ s: String, _ a: [NSAttributedString.Key: Any]) -> CGFloat { ceil((s as NSString).size(withAttributes: a).width) }
    /// Shared header geometry: use the fitted title width and only complete metadata facts.
    @discardableResult
    static func headerText(_ title: String, _ summary: String, x: CGFloat, right: CGFloat, mid: CGFloat,
                           titleFont: NSFont, summaryFont: NSFont, ink: NSColor = Native.ink) -> CGFloat {
        let room = max(0, right - x), a = at(titleFont, ink), sa = at(summaryFont, Native.faint)
        let tw = min(width(title, a), room * (summary.isEmpty ? 1 : 0.6))
        line(title, NSRect(x: x, y: lineTop(titleFont, mid: mid), width: tw, height: titleFont.ascender - titleFont.descender + 4), a)
        let sx = x + tw + 12, sw = max(0, right - sx)
        let fitted = JournalLayout.headerSummary(summary) { width($0, sa) <= sw }
        line(fitted, NSRect(x: sx, y: lineTop(summaryFont, mid: mid), width: sw, height: summaryFont.ascender - summaryFont.descender + 4), sa)
        return tw
    }
    /// Wrapped text, at most `lines` lines of `lh`: the height it takes.
    static func lines(_ s: String, width w: CGFloat, font: NSFont, lh: CGFloat, max n: Int) -> Int {
        let a = at(font, .black, lh: lh, cut: .byWordWrapping)
        let h = (s as NSString).boundingRect(with: NSSize(width: w, height: lh * CGFloat(n + 1)), options: [.usesLineFragmentOrigin], attributes: a).height
        return min(n, max(1, Int((h / lh).rounded(.up))))
    }
    static func block(_ s: String, x: CGFloat, y: CGFloat, width w: CGFloat, font: NSFont, color: NSColor, lh: CGFloat, max n: Int, strike: NSColor? = nil) {
        let a = at(font, color, lh: lh, cut: .byWordWrapping, strike: strike)
        let lift = ((lh - (font.ascender - font.descender + font.leading)) / 2).rounded()   // the line's spare room goes above the letters
        (s as NSString).draw(with: NSRect(x: x, y: y - lift, width: w, height: lh * CGFloat(n)), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: a)
    }

    // MARK: pieces

    /// A 1 pt hairline across, in the line colour.
    static func hairline(x0: CGFloat, x1: CGFloat, y: CGFloat, color: NSColor = Native.line) {
        color.setFill(); NSRect(x: x0, y: y, width: x1 - x0, height: 1).fill()
    }
    /// A symbol drawn at `r` in one colour.
    static func glyph(_ name: String, _ r: NSRect, color: NSColor = Native.muted) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let img = Native.glyph(name)
        ctx.saveGState()
        ctx.beginTransparencyLayer(in: r, auxiliaryInfo: nil)
        img.draw(in: r, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        color.setFill(); r.fill(using: .sourceIn)
        ctx.endTransparencyLayer()
        ctx.restoreGState()
    }
    static let capH: CGFloat = 24
    /// A keycap in a 24 pt slot: the panels' small key cap (Panel.keycap), centred in it. on: the key in use.
    /// Returns the slot's width.
    @discardableResult
    static func keycap(_ k: String, x: CGFloat, y: CGFloat, on: Bool = false) -> CGFloat {
        let w = max(capH, Panel.capWidth(k))
        Panel.keycap(k, x: x + (w - Panel.capWidth(k)) / 2, y: y + (capH - Panel.capH) / 2, on: on)
        return w
    }
    /// A keycap and its word: "↵ paste". Returns the x after it, with the 16 pt gap.
    @discardableResult
    static func keyWord(_ k: String, _ word: String, x: CGFloat, y: CGFloat, on: Bool = false, color: NSColor = Native.muted, gap: CGFloat = 16) -> CGFloat {
        let w = keycap(k, x: x, y: y, on: on)
        let f = Panel.font, a = at(f, color)
        (word as NSString).draw(at: NSPoint(x: x + w + 8, y: lineTop(f, mid: y + capH / 2)), withAttributes: a)
        return x + w + 8 + width(word, a) + gap
    }
    /// A kind filter: the kind's glyph at 16 in a 28 pt square, no box. Pressed is ink, the rest faint.
    static func kindButton(_ k: TapeKind, x: CGFloat, y: CGFloat, pressed: Bool) {
        glyph(k.mark, NSRect(x: x + 6, y: y + 6, width: 16, height: 16), color: pressed ? Native.ink : Native.faint)
    }
    /// A mark (a symbol in the ink colour), optionally faded.
    static func mark(_ name: String, _ r: NSRect, alpha: CGFloat = 1) {
        guard alpha < 1, let ctx = NSGraphicsContext.current?.cgContext else { Native.drawMark(name, in: r); return }
        ctx.saveGState(); ctx.setAlpha(alpha); Native.drawMark(name, in: r); ctx.restoreGState()
    }
    /// The four kind buttons from the right edge `xr`: returns their left edge.
    @discardableResult
    static func kinds(right xr: CGFloat, y: CGFloat, pressed: (TapeKind) -> Bool) -> CGFloat {
        let x0 = xr - 4 * 28 - 3 * 2
        for (i, k) in TapeKind.allCases.enumerated() { kindButton(k, x: x0 + CGFloat(i) * 30, y: y, pressed: pressed(k)) }
        return x0
    }

    /// The gutter of one row: a hairline on its right, the time and the kind's glyph. On the chosen row the 2 pt edge
    /// in the kind's colour at its left. `top`: the glyph and time sit at the top of a tall row instead of its middle.
    static func gutter(_ r: NSRect, kind: TapeKind?, time: String?, mark: String? = nil, chosen: Bool, top: CGFloat? = nil, size: CGFloat = 12, gap: CGFloat = 8, pad: CGFloat = 12, glyphSize: CGFloat = 16) {
        if chosen, let kind { kind.color.setFill(); NSRect(x: r.minX, y: r.minY, width: edge, height: r.height).fill() }
        Native.line.setFill(); NSRect(x: r.maxX - 1, y: r.minY, width: 1, height: r.height).fill()
        let markY = top.map { r.minY + $0 } ?? r.midY - glyphSize / 2
        let mx = r.maxX - pad - glyphSize
        if let m = mark ?? kind?.mark { glyph(m, NSRect(x: mx, y: markY, width: glyphSize, height: glyphSize), color: chosen ? Native.ink : Native.muted) }
        if let time {
            let a = at(Native.mono(size), chosen ? Native.ink : Native.muted)
            let w = width(time, a)
            (time as NSString).draw(at: NSPoint(x: mx - gap - w, y: lineTop(Native.mono(size), mid: markY + glyphSize / 2)), withAttributes: a)
        }
    }

    /// The floating surface: the panels' one ground (Panel.ground: card colour, a hairline edge, 12 pt corners; the
    /// panel adds the one float shadow).
    static func surface(_ b: NSRect, radius: CGFloat = Panel.corner) { Panel.ground(b, radius: radius) }
}

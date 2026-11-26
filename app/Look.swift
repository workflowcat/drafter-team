// The native look (23 November 2026, the user: "kill pixelkit references for now entirely and just use whatever the
// model thinks is best"). One small file, no themes: the system font, the semantic system colours (light, dark and the user's
// accent colour follow macOS by themselves), SF Symbols for marks and glyphs, native corners. Rules: docs/look.md.
import AppKit
import SwiftUI

enum Native {
    static var dark: Bool { NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua }

    // MARK: colours (semantic only)

    static let paper = NSColor.windowBackgroundColor          // the window's ground
    static let card = NSColor.controlBackgroundColor          // a raised card or panel
    static let ink = NSColor.labelColor                       // words
    static let muted = NSColor.secondaryLabelColor            // second words
    static let faint = NSColor.tertiaryLabelColor             // hints, times, the quietest words
    static let line = NSColor.separatorColor                  // hairlines
    static let rule = NSColor.gridColor                       // a stronger edge around a card
    static let controlEdge = NSColor.tertiaryLabelColor       // an outline control's edge
    static let soft = NSColor.quaternarySystemFill            // a soft lift under a chosen word or a chip
    static let blue = NSColor.controlAccentColor              // the accent: links, focus, an item
    static let violet = NSColor.systemPurple                  // an action
    static let mint = NSColor.systemGreen                     // done, taken
    static let coral = NSColor.systemRed                      // live, recording
    static let warn = NSColor.systemOrange                    // a fix, a warning
    static let ok = NSColor.systemGreen, crit = NSColor.systemRed
    static let okBg = NSColor.systemGreen.withAlphaComponent(0.15)
    static let warnBg = NSColor.systemOrange.withAlphaComponent(0.15)
    static let critBg = NSColor.systemRed.withAlphaComponent(0.15)
    static let selected = NSColor.controlAccentColor.withAlphaComponent(0.15)
    static let actionBg = selected
    static let key = NSColor.quaternarySystemFill             // a keycap
    static let keyEdge = NSColor.tertiaryLabelColor           // its bottom edge
    static let primary = NSColor.controlAccentColor           // a primary button
    static let primaryEdge = NSColor.controlAccentColor
    static let onPrimary = NSColor.alternateSelectedControlTextColor
    static let onCut = NSColor.white                          // words on the black notch housing
    static let onCutMuted = NSColor.white.withAlphaComponent(0.6)
    /// The window behind the panes, a row under the pointer, the chosen row.
    static let well = NSColor.windowBackgroundColor
    static let hover = NSColor.quinarySystemFill
    static let pick = NSColor.selectedContentBackgroundColor.withAlphaComponent(0.18)
    /// A kind's mark colour (JournalMeta.kinds: blue, mint, violet, coral, neutral).
    static func series(_ name: String) -> NSColor {
        switch name { case "blue": return blue; case "mint": return mint; case "violet": return violet; case "coral": return coral; default: return muted }
    }

    // MARK: shapes and motion

    /// Corners: 0 square, 1 keys and tags, 2 controls, 3 floating panels (12 pt since the caret-cozy round).
    static func corner(_ i: Int) -> CGFloat { [0, 4, 6, 12][min(3, max(0, i))] }
    /// Radii: "pane", "card", "row".
    static func radius(_ k: String) -> CGFloat { ["pane": 12, "card": 10, "row": 6][k] ?? 8 }
    /// How long a motion takes, in seconds ("fold", "fade"); 0 when Reduce Motion is on.
    static func motion(_ k: String) -> Double {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : (["fold": 0.12, "fade": 0.08][k] ?? 0)
    }
    /// The one shadow on what floats.
    /// The one soft shadow under what floats (caret-cozy round: wider and lighter than a window's).
    static func floatShadow() -> NSShadow {
        let sh = NSShadow()
        sh.shadowColor = NSColor.black.withAlphaComponent(dark ? 0.35 : 0.14)
        sh.shadowBlurRadius = 18; sh.shadowOffset = NSSize(width: 0, height: -6)
        return sh
    }
    /// A floating panel's outline: rounded; `hanging` (it hangs from the top edge) keeps the top corners square.
    static func outline(_ b: NSRect, hanging: Bool = false) -> NSBezierPath {
        let c = corner(3)
        guard hanging else { return NSBezierPath(roundedRect: b, xRadius: c, yRadius: c) }
        let p = NSBezierPath(roundedRect: NSRect(x: b.minX, y: b.minY, width: b.width, height: b.height), xRadius: c, yRadius: c)
        p.append(NSBezierPath(rect: NSRect(x: b.minX, y: b.midY, width: b.width, height: b.height / 2)))
        p.windingRule = .nonZero
        return p
    }

    // MARK: type (the system font)

    /// Words.
    /// The type scale (style round, 26 November 2026): 10 tiny, 11 caption, 12 small, 13 body, 14 reading,
    /// 15 heading, 17 page title, 22 display. No other sizes and no half points; tests/look_scale.sh checks it.
    static let scale: [CGFloat] = [10, 11, 12, 13, 14, 15, 17, 22]
    static func text(_ size: CGFloat, _ w: NSFont.Weight = .regular) -> NSFont { .systemFont(ofSize: size, weight: w) }
    static func body(_ size: CGFloat) -> NSFont { text(size) }
    /// A title or a state word.
    static func display(_ size: CGFloat) -> NSFont { .systemFont(ofSize: size, weight: .semibold) }
    /// Numbers, times, keys: the system font with even digits, so columns line up.
    static func mono(_ size: CGFloat, _ w: NSFont.Weight = .regular) -> NSFont { .monospacedDigitSystemFont(ofSize: size, weight: w) }
    static func num(_ size: CGFloat, _ w: NSFont.Weight = .regular) -> NSFont { .monospacedDigitSystemFont(ofSize: size, weight: w) }

    // MARK: symbols (SF Symbols)

    /// The app's names for its marks and glyphs, as SF Symbols. A name not here is tried as a symbol itself.
    static let symbols: [String: String] = [
        // line glyphs (interface)
        "search": "magnifyingglass", "copy": "doc.on.doc", "play": "play.fill", "pause": "pause.fill", "folder": "folder",
        "more": "ellipsis", "refresh": "arrow.clockwise", "close": "xmark", "filter": "line.3.horizontal.decrease",
        "external": "arrow.up.forward.square", "send": "paperplane", "check": "checkmark", "chevron-right": "chevron.right",
        "chevron-down": "chevron.down", "list": "list.bullet", "edit": "pencil", "keys": "command", "waves": "waveform",
        "phone": "phone", "sparkle": "sparkles", "chat": "bubble.left", "mail": "envelope", "globe": "globe",
        "terminal": "terminal", "file-edit": "doc.text", "calendar": "calendar", "image": "photo", "map": "map",
        "file": "doc", "bookmark": "bookmark", "arrows-vertical": "arrow.up.arrow.down", "pinned": "pin.fill",
        "settings": "gearshape", "help": "questionmark.circle", "user": "person", "person": "person", "pin": "pin",
        "arrow-left": "arrow.left", "text": "textformat", "download": "arrow.down.circle", "plus": "plus", "hash": "number",
        "trash": "trash", "link": "link", "cloud": "cloud", "marquee": "rectangle.dashed", "app-window": "macwindow",
        "device-desktop": "desktopcomputer", "arrow-up-right": "arrow.up.right", "scribble": "scribble", "square": "square",
        "highlight": "highlighter", "blur": "drop.halffull", "crop": "crop", "circle-number": "1.circle",
        "arrow-back-up": "arrow.uturn.backward", "corner-down-left": "return", "microphone": "mic", "clipboard": "clipboard",
        "coin": "dollarsign.circle", "at": "at", "scissors": "scissors", "arrows-left-right": "arrow.left.arrow.right",
        "markdown": "doc.plaintext", "tag": "tag", "grip": "line.3.horizontal", "box": "shippingbox", "website": "globe",
        // marks (things: kinds of offer, apps, states)
        "mic": "mic.fill", "idcard": "person.text.rectangle", "bolt": "bolt.fill", "translate": "character.bubble",
        "pencil": "pencil", "spark": "sparkles", "waveform": "waveform", "verified": "checkmark.seal.fill",
        "document": "doc.text", "keyboard": "keyboard", "layers": "square.stack", "cog": "gearshape", "bulb": "lightbulb",
        "quote": "quote.opening", "browser": "safari", "code": "chevron.left.forwardslash.chevron.right",
        "people": "person.2", "book": "book", "clock": "clock",
    ]
    private static var symbolCache: [String: NSImage] = [:]
    /// The SF Symbol for one of the app's names, as a template image (it takes the colour around it).
    static func glyph(_ name: String) -> NSImage {
        if let i = symbolCache[name] { return i }
        let i = NSImage(systemSymbolName: symbolName(name), accessibilityDescription: name) ?? NSImage()
        i.isTemplate = true
        symbolCache[name] = i
        return i
    }
    /// The symbol's system name; "circle" when neither the table nor the system knows it.
    static func symbolName(_ name: String) -> String {
        if let s = symbols[name] { return s }
        return NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil ? name : "circle"
    }
    /// A symbol drawn into `r` in one colour, kept to its own shape (fit, centred).
    static func drawSymbol(_ name: String, in r: NSRect, color: NSColor) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let base = glyph(name)
        let img = base.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: r.height * 0.8, weight: .regular)) ?? base
        let s = img.size, k = min(r.width / max(1, s.width), r.height / max(1, s.height))
        let fit = NSRect(x: r.midX - s.width * k / 2, y: r.midY - s.height * k / 2, width: s.width * k, height: s.height * k)
        ctx.saveGState()
        ctx.beginTransparencyLayer(in: r, auxiliaryInfo: nil)
        img.draw(in: fit, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        color.setFill(); r.fill(using: .sourceIn)
        ctx.endTransparencyLayer()
        ctx.restoreGState()
    }
    /// A mark (the kind of an offer, a state) as its symbol: in `tint`, or in `line` when there is none.
    static func drawMark(_ name: String, in r: NSRect, tint: NSColor? = nil, line: NSColor = Native.ink) {
        drawSymbol(name, in: r, color: tint ?? line)
    }
}

/// What kind an offer or a record is: one mark and one colour, the same at the caret, in the strip and in the window.
/// Item (a thing put in: a snippet, a person, a fact, words) in the accent colour, action (it does something or
/// rewrites) purple, a fix orange.
enum Kind {
    case snippet, person, fact, voice, link, action, lookup, translate, rework, fix, next
    var mark: String {
        switch self {
        case .snippet: return "bookmark"; case .person: return "idcard"; case .fact: return "calendar"; case .voice: return "mic"
        case .link: return "link"; case .action: return "bolt"; case .lookup: return "search"; case .translate: return "translate"
        case .rework: return "spark"; case .fix: return "pencil"; case .next: return "chat"
        }
    }
    var color: NSColor {
        switch self {
        case .snippet, .person, .fact, .link, .next: return Native.blue
        case .voice: return Native.violet   // said, as in the journal (TapeKind.said)
        case .action, .lookup, .translate, .rework: return Native.violet
        case .fix: return Native.warn
        }
    }
    /// The kind of a chip from its action id.
    static func of(_ id: String) -> Kind {
        switch id {
        case "snippet": return .snippet; case "person": return .person; case "fact": return .fact; case "preset": return .link
        case "lookup": return .lookup; case "translate": return .translate; case "proofread", "pauseRewrite": return .fix
        default: return id.hasPrefix("voice.") ? .voice : .action
        }
    }
}

/// The same colours for SwiftUI.
enum UIInk {
    static let paper = Color(nsColor: Native.paper), ink = Color(nsColor: Native.ink)
    static let muted = Color(nsColor: Native.muted), faint = Color(nsColor: Native.faint)
    static let line = Color(nsColor: Native.line), soft = Color(nsColor: Native.soft)
    static let blue = Color(nsColor: Native.blue), coral = Color(nsColor: Native.coral)
    static let selected = Color(nsColor: Native.selected), key = Color(nsColor: Native.key)
    static let keyEdge = Color(nsColor: Native.keyEdge), rule = Color(nsColor: Native.rule), card = Color(nsColor: Native.card)
    static let mint = Color(nsColor: Native.mint), violet = Color(nsColor: Native.violet), warn = Color(nsColor: Native.warn)
    static let primary = Color(nsColor: Native.primary), onPrimary = Color(nsColor: Native.onPrimary)
    static let controlEdge = Color(nsColor: Native.controlEdge)
    static let ok = Color(nsColor: Native.ok), okBg = Color(nsColor: Native.okBg)
    static let warnBg = Color(nsColor: Native.warnBg)
    static let crit = Color(nsColor: Native.crit), critBg = Color(nsColor: Native.critBg)
    static let well = Color(nsColor: Native.well), hover = Color(nsColor: Native.hover), pick = Color(nsColor: Native.pick)
}

/// The system font for SwiftUI.
enum NativeFont {
    static func text(_ size: CGFloat, _ w: NSFont.Weight = .regular) -> Font { Font(Native.text(size, w)) }
    static func display(_ size: CGFloat) -> Font { Font(Native.display(size)) }
    static func mono(_ size: CGFloat, _ w: NSFont.Weight = .regular) -> Font { Font(Native.mono(size, w)) }
    static func num(_ size: CGFloat, _ w: NSFont.Weight = .regular) -> Font { Font(Native.num(size, w)) }
}

/// An SF Symbol in SwiftUI by the app's name for it, in the colour of the text around it.
struct Glyph: View {
    let name: String
    var size: CGFloat = 16
    init(_ name: String, size: CGFloat = 16) { self.name = name; self.size = size }
    var body: some View {
        Image(systemName: Native.symbolName(name)).font(.system(size: size * 0.8)).frame(width: size, height: size).accessibilityHidden(true)
    }
}

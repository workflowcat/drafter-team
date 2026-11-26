// The grey text at the caret and the action chip under it. A non-activating panel: it never takes focus or clicks
// (a click on the chip is caught on the event tap, Keys.handle and hitChip).
import AppKit
import ScreenCaptureKit

final class Ghost {
    static let shared = Ghost()
    let panel: NSPanel
    let label = NSTextField(labelWithString: "")
    let chip = NSTextField(labelWithString: "")
    private(set) var text = ""
    /// How many characters at the end of `text` the model was less sure of: drawn lighter (2026-10-21, Cotypist's few words).
    var unsure = 0
    private var ghostColor = NSColor.secondaryLabelColor
    private(set) var action: [String: Any]? = nil
    /// The letters a fix replaces (Fixer.swift): the ghost reads "→ word" and typing through it does not keep it.
    private(set) var replace = ""
    /// Mid-line (setting `midLine`, 2026-11-15): text follows the caret on its line, so the grey words cannot sit at the
    /// caret without covering it. They are drawn on a small card just under the caret's line, starting at the caret.
    private(set) var mid = false
    let midBox: Ground = { let g = Ground(); g.radius = 6; return g }()
    /// Fallback anchor (round 2026-11-17-anchor): the field gave no place for the caret, so the grey words sit on the
    /// action chip's row near the field (Focus.chipAnchor) instead of inline. Tab takes them as always.
    private(set) var boxed = false
    var visible: Bool { panel.isVisible && (!text.isEmpty || action != nil) }

    let chipBox = Ground()
    let mark = KindMark()
    private var fontCache: (AXUIElement, NSFont, NSColor?)?

    init() {
        panel = NSPanel(contentRect: .zero, styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: true)
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = false
        panel.level = .popUpMenu; panel.ignoresMouseEvents = true; panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        let v = NSView(); panel.contentView = v
        label.lineBreakMode = .byClipping
        chip.lineBreakMode = .byTruncatingTail
        chipBox.addSubview(mark); chipBox.addSubview(chip)
        v.addSubview(midBox); v.addSubview(label); v.addSubview(chipBox)
        midBox.isHidden = true
    }

    /// The field's font and text colour at the caret (read once per field), else a size from the caret's height.
    /// No colour from AX (Chromium, Dia): GhostRules.ghostColour's mid grey, the same on light and dark pages.
    private func fieldFont(_ height: CGFloat) -> (NSFont, NSColor) {
        func tint(_ c: NSColor?) -> NSColor {
            let rgb = c?.usingColorSpace(.sRGB).map { (Double($0.redComponent), Double($0.greenComponent), Double($0.blueComponent)) }
            let g = GhostRules.ghostColour(field: rgb)
            return NSColor(srgbRed: g.0, green: g.1, blue: g.2, alpha: g.3)
        }
        var web = false
        if let s = Keys.shared.spot {
            if let c = fontCache, CFEqual(c.0, s.el) { return (c.1, tint(c.2)) }
            if let (f, col) = Focus.font(s.el, caret: s.caret) { fontCache = (s.el, f, col); return (f, tint(col)) }
            web = Focus.isWeb(s.app)
        }
        return (.systemFont(ofSize: GhostRules.fallbackSize(caretHeight: Double(height), web: web)), tint(nil))
    }

    /// A click (event tap location, top-left based) on the action chip: keys round three runs an outside action only
    /// by click, so the tap swallows that click and runs the chip. The panel itself never takes clicks.
    func hitChip(_ p: CGPoint) -> Bool {
        guard panel.isVisible, action != nil, !chipBox.isHidden, !isDraft else { return false }
        let h = NSScreen.screens.first?.frame.height ?? 0
        let f = chipBox.frame.offsetBy(dx: panel.frame.minX, dy: panel.frame.minY)
        return f.insetBy(dx: -2, dy: -2).contains(NSPoint(x: p.x, y: h - p.y))
    }

    /// A click (event tap location, top-left based) on a visible next-message / instant-reply draft card:
    /// expands if folded and truncated, else inserts the shown draft option instead of clicking through to the app.
    func hitDraft(_ p: CGPoint) -> Bool {
        guard panel.isVisible, isDraft, !card.isHidden else { return false }
        let h = NSScreen.screens.first?.frame.height ?? 0
        let f = card.frame.offsetBy(dx: panel.frame.minX, dy: panel.frame.minY)
        return f.insetBy(dx: -2, dy: -2).contains(NSPoint(x: p.x, y: h - p.y))
    }

    /// AX rects are top-left based on the primary screen; Cocoa windows are bottom-left.
    func cocoa(_ r: CGRect) -> CGRect {
        let h = NSScreen.screens.first?.frame.height ?? 0
        return CGRect(x: r.minX, y: h - r.maxY, width: r.width, height: r.height)
    }

    /// Ghost-hide round (2026-11-18): the plain ghost's length as drawn (with every part added) and how many of its
    /// letters the user typed into it, for the "ghost gone" log line. Numbers only, never its words.
    private(set) var shownLen = 0
    private(set) var typedIn = 0
    /// Timestamp and reason when a visible plain ghost vanished involuntarily (used by KeyRules.tabHoldAfterVanish).
    private(set) var lastPlainHidden: (at: Date, why: String)?
    func clearLastPlainHidden() { lastPlainHidden = nil }
    /// A plain grey ghost (no chip, fix offer or next-message card) with words on screen.
    var plainVisible: Bool { visible && action == nil && replace.isEmpty && !isDraft && !text.isEmpty }

    /// One line per plain ghost that leaves the screen: how ("vanished": nothing in its place; "shorter" / "longer":
    /// other grey words took its place), why, its length, the letters the user typed into it, what was left, and the new
    /// ghost's length. `why` is a fixed word from the caller. The user, 18 November 2026: the ghost gets shorter, "but
    /// sometimes it just disappears" - both show here.
    func gone(_ why: String, new: Int? = nil) {
        guard plainVisible else { return }
        let how = new.map { $0 < text.count ? "shorter" : "longer" } ?? "vanished"
        log("ghost gone \(how) \(why) len \(shownLen) typed \(typedIn) left \(text.count)" + (new.map { " new \($0)" } ?? ""))
    }

    func show(_ suggestion: String, action: [String: Any]?, at caret: CGRect, replace: String = "", mid: Bool = false, why: String = "replaced") {
        // the same words drawn again at the caret (realign) keep their counts; anything else is a new ghost
        if suggestion != text || action != nil || !replace.isEmpty {
            if plainVisible { gone(why, new: action == nil && replace.isEmpty ? suggestion.count : nil) }
            shownLen = suggestion.count; typedIn = 0
        }
        plain()
        self.mid = mid && action == nil && replace.isEmpty && !suggestion.isEmpty
        boxed = !self.mid && action == nil && replace.isEmpty && !suggestion.isEmpty && Focus.chipAnchor == caret
        midBox.isHidden = !self.mid
        if !self.replace.isEmpty, replace.isEmpty { Fixer.hidden() }   // a fix offer covered by a chip ends here (Argon 22)
        text = suggestion; self.action = action; self.replace = replace; altHint = ""
        let c = cocoa(caret)
        // the grey words in the field's own font, as if already typed; no keycap after them since 1 November 2026
        // (The user: "I know what tab does, clean it up")
        let (font0, fieldColor) = fieldFont(c.height)
        let font = boxed ? Native.text(13) : font0
        let color = self.mid ? Native.muted : boxed ? Native.ink : fieldColor   // on the card's ground, not the field's: the card's own quiet ink
        label.font = font; label.textColor = color; ghostColor = color
        unsure = min(unsure, suggestion.count)
        paint(suggestion)
        label.sizeToFit()
        let lh = max(c.height, label.frame.height)
        var w: CGFloat = suggestion.isEmpty ? 0 : label.frame.width
        // a chip: a flat row under the caret - kind square, then the offer
        var chipH: CGFloat = 0, chipW: CGFloat = 0
        if let a = action, let t = a["chip"] as? String {
            // a chip: a flat row under the caret - the kind's mark in its colour, then the offer in the system font
            mark.kind = Kind.of(a["id"] as? String ?? "")
            chip.font = Native.text(13); chip.textColor = Native.ink
            chip.isHidden = false
            chip.stringValue = t.hasPrefix("⇥ ") ? String(t.dropFirst(2)) : t
            // the pause rewrite (app/PauseRewrite.swift): up to 3 lines, the changed words marked in the accent ink
            let rewrite = a["id"] as? String == "pauseRewrite"
            chip.maximumNumberOfLines = rewrite ? 3 : 1
            chip.lineBreakMode = rewrite ? .byWordWrapping : .byTruncatingTail
            if let ms = a["marks"] as? [[Int]], !ms.isEmpty {
                let at = NSMutableAttributedString(string: chip.stringValue, attributes: [.font: Native.text(13), .foregroundColor: Native.ink])
                let n = (chip.stringValue as NSString).length
                for m in ms where m.count == 2 && m[0] >= 0 && m[1] > 0 && m[0] + m[1] <= n {
                    at.addAttributes([.underlineStyle: NSUnderlineStyle.single.rawValue, .foregroundColor: Native.blue],
                                     range: NSRange(location: m[0], length: m[1]))
                }
                chip.attributedStringValue = at
            }
            if rewrite { chip.frame.size = chip.sizeThatFits(NSSize(width: 420, height: 200)) } else { chip.sizeToFit() }
            let tw = min(chip.frame.width, 420)
            // the panels' row: 30 pt, 10 pt in, the kind's symbol, 8 pt, the words, 12 pt out
            chipH = max(30, chip.frame.height + 12)
            chipW = 10 + 16 + 8 + tw + 12
            chipBox.frame = NSRect(x: 0, y: 0, width: chipW, height: chipH)
            mark.frame = NSRect(x: 10, y: ((chipH - 16) / 2).rounded(), width: 16, height: 16)
            chip.frame = NSRect(x: 34, y: ((chipH - chip.frame.height) / 2).rounded(), width: tw, height: chip.frame.height)
            chipBox.isHidden = false; chipBox.needsDisplay = true; mark.needsDisplay = true
            w = max(w, chipW)
        } else { chipBox.isHidden = true }
        if self.mid { placeMid(c, lh: lh); appear(); return }
        if boxed { fitBoxed(at: c); appear(); return }
        let gap: CGFloat = chipH > 0 ? 6 : 0
        let frame = NSRect(x: c.maxX, y: c.minY - chipH - gap, width: w + 4, height: lh + chipH + gap)
        panel.setFrame(frame, display: false)
        // baseline: the grey text sits on the caret's line, centred in its height like the text it continues
        label.frame = NSRect(x: 0, y: chipH + gap + (lh - label.frame.height) / 2, width: label.frame.width, height: label.frame.height)
        appear()
    }

    /// The grey words as a chip: the action chip's ground and row, a mark, then the words; its top under `c` (a chip
    /// anchor's 1-pt rect), or kept where it is (`c` nil) as the words change. The panel never follows the typing.
    private func fitBoxed(at c: CGRect? = nil) {
        label.sizeToFit()
        if label.superview?.subviews.last !== label { panel.contentView?.addSubview(label, positioned: .above, relativeTo: chipBox) }
        mark.kind = .next
        let tw = min(label.frame.width, 420)
        let h = max(30, label.frame.height + 12), w = 34 + tw + 12
        let o = c.map { NSPoint(x: $0.minX, y: $0.minY - h) } ?? panel.frame.origin
        panel.setFrame(NSRect(x: o.x, y: o.y, width: w, height: h), display: c == nil)
        chipBox.frame = NSRect(x: 0, y: 0, width: w, height: h)
        mark.frame = NSRect(x: 10, y: ((h - 16) / 2).rounded(), width: 16, height: 16)
        chip.isHidden = true; chipBox.isHidden = false; chipBox.needsDisplay = true; mark.needsDisplay = true
        label.frame = NSRect(x: 34, y: ((h - label.frame.height) / 2).rounded(), width: tw, height: label.frame.height)
    }

    /// The mid-line card: the grey words on a flat card ground one line under the caret, its left edge at the caret,
    /// so the text after the caret stays readable and the words read as what
    /// goes in at that point. Above the caret's line when there is no room under it.
    static let midPad: CGFloat = 5, midGap: CGFloat = 2
    private func placeMid(_ c: CGRect, lh: CGFloat) {
        let p = Ghost.midPad
        let w = label.frame.width + 2 * p, h = lh + 2
        var y = c.minY - Ghost.midGap - h
        if let scr = NSScreen.screens.first(where: { $0.frame.contains(CGPoint(x: c.midX, y: c.midY)) }) ?? NSScreen.main,
           y < scr.visibleFrame.minY { y = c.maxY + Ghost.midGap }
        panel.setFrame(NSRect(x: c.maxX - p, y: y, width: w, height: h), display: false)
        midBox.frame = NSRect(x: 0, y: 0, width: w, height: h); midBox.needsDisplay = true
        label.frame = NSRect(x: p, y: (h - label.frame.height) / 2, width: label.frame.width, height: label.frame.height)
    }

    /// Grey words show at full strength in their first frame (14 November 2026, speed first: a 90 ms fade from zero
    /// made the logged "shown" come before the words could be read). A new chip still fades in over 90 ms (none under
    /// Reduce Motion); one that follows another while the user types just changes, so nothing blinks.
    private func appear() {
        if panel.isVisible || action == nil || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            panel.alphaValue = 1; panel.orderFrontRegardless(); return
        }
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in ctx.duration = 0.09; panel.animator().alphaValue = 1 }
    }

    /// The user's next message for an empty box (2026-10-20, like ChatGPT's suggested prompt): a small card just above the
    /// field (the app's placeholder stays uncovered). Several options: "‹ 2/5 · label ›" on top, the message in two
    /// lines under it; ←/→ flip, ↓ opens the whole message, ↑ folds it back, Tab puts the shown one in.
    private(set) var isDraft = false
    private(set) var expanded = false
    private(set) var cut = false   // folded and the message has more lines than the two shown (GhostRules.draftTab)
    let card: Ground = { let g = Ground(); g.radius = Panel.corner; return g }()
    let head = NSTextField(labelWithString: "")
    let cardKey = KeyCap()   // ↓ / ↑: the whole message or folded
    let cardMark = KindMark()   // the next message: an item, blue
    private var draftField: CGRect?, draftCaret = CGRect.zero
    private var options: [[String: String]] = [], index = 0
    /// The next-message option on show (nil when no card): its extra keys, e.g. "promise" (app/Promises.swift).
    var shownOption: [String: String]? { isDraft && index < options.count ? options[index] : nil }

    func showDraft(_ opts: [[String: String]], field: CGRect?, caret: CGRect) {
        gone("draft")   // a next-message card in the place of grey words
        options = opts; index = 0; expanded = false; draftField = field; draftCaret = caret
        layoutDraft()
    }

    /// Instant replies: option i of the card shown now (⌥1-3), nil when there is no such option.
    func draftOption(_ i: Int) -> [String: String]? { isDraft && i >= 0 && i < options.count ? options[i] : nil }

    func flip(_ by: Int) {
        guard isDraft, options.count > 1 else { return }
        index = (index + by + options.count) % options.count
        layoutDraft()
    }

    func expand(_ on: Bool) { guard isDraft, expanded != on else { return }; expanded = on; layoutDraft() }

    private func layoutDraft() {
        guard index < options.count else { return }
        let o = options[index]
        text = o["text"] ?? ""; action = nil; isDraft = true; mid = false; midBox.isHidden = true
        let c = cocoa(draftCaret)
        let size = max(11, min(14, c.height * 0.72))
        let width = min(520, max(240, (draftField?.width ?? 440) * 0.8))
        if card.superview == nil {
            panel.contentView?.addSubview(card, positioned: .below, relativeTo: label)
            panel.contentView?.addSubview(head)
            panel.contentView?.addSubview(cardKey)
            panel.contentView?.addSubview(cardMark)
        }
        card.isHidden = false; head.isHidden = false; cardMark.isHidden = false; chipBox.isHidden = true
        card.needsDisplay = true
        // head: the kind's mark, the gist, "1/3 ←→" in quiet mono; one keycap on the right says what ↓/↑ do
        cardMark.kind = .next
        let gist = o["label"] ?? ""
        let h1 = NSMutableAttributedString(string: gist, attributes: [.font: Native.text(12, .medium), .foregroundColor: Native.muted])
        if options.count > 1 {
            h1.append(NSAttributedString(string: "   \(index + 1)/\(options.count) ←→", attributes: [.font: Native.mono(10.5), .foregroundColor: Native.faint]))
        }
        head.attributedStringValue = h1
        head.lineBreakMode = .byTruncatingTail
        head.sizeToFit()
        cardKey.label = expanded ? "↑" : "↓"
        cardKey.size = 10; cardKey.faint = false; cardKey.fit(); cardKey.isHidden = false; cardKey.needsDisplay = true
        label.font = Native.text(size + 0.5); label.textColor = Native.ink
        label.lineBreakMode = .byWordWrapping; label.maximumNumberOfLines = expanded ? 10 : 2
        label.cell?.truncatesLastVisibleLine = true
        label.preferredMaxLayoutWidth = width - 24
        label.stringValue = text
        let fit = label.sizeThatFits(NSSize(width: width - 24, height: 600))
        if !expanded { label.maximumNumberOfLines = 0; cut = label.sizeThatFits(NSSize(width: width - 24, height: 6000)).height > fit.height + 0.5; label.maximumNumberOfLines = 2 } else { cut = false }
        let hh = max(16, head.frame.height, cardKey.frame.height)
        let h = fit.height + hh + 26
        let x = (draftField.map { cocoa($0).minX } ?? c.minX - 8)
        let top = draftField.map { cocoa($0).maxY } ?? c.maxY
        panel.setFrame(NSRect(x: x, y: top + 10, width: width, height: h), display: false)
        card.frame = NSRect(x: 0, y: 0, width: width, height: h)
        let k1 = cardKey.frame.width
        let headY = h - 10 - hh
        cardKey.frame.origin = NSPoint(x: width - 10 - k1, y: (headY + (hh - cardKey.frame.height) / 2).rounded())
        cardMark.frame = NSRect(x: 10, y: (headY + (hh - 16) / 2).rounded(), width: 16, height: 16); cardMark.needsDisplay = true
        head.frame = NSRect(x: 32, y: (headY + (hh - head.frame.height) / 2).rounded(), width: width - 52 - k1, height: head.frame.height)
        label.frame = NSRect(x: 12, y: 10, width: width - 24, height: fit.height)
        panel.orderFrontRegardless()
    }

    private func plain() {
        guard isDraft else { return }
        isDraft = false; expanded = false; card.isHidden = true; head.isHidden = true; cardKey.isHidden = true; cardMark.isHidden = true
        label.lineBreakMode = .byClipping; label.maximumNumberOfLines = 1; label.preferredMaxLayoutWidth = 0
    }

    /// Parity round: a quiet "1/3" after the grey words while other ideas are ready (⌥1-⌥3); "" = none. Only drawn,
    /// never part of `text`.
    private(set) var altHint = ""
    func hint(_ h: String) {
        guard visible, action == nil, replace.isEmpty, !isDraft, h != altHint else { return }
        altHint = h
        paint(text)
        if boxed { fitBoxed(); return }
        label.sizeToFit()
        var f = panel.frame
        f.size.width = label.frame.width + (mid ? 2 * Ghost.midPad : 4)
        panel.setFrame(f, display: true)
        if mid { midBox.frame.size.width = f.size.width; midBox.needsDisplay = true }
    }

    /// The grey words: the sure part in the ghost colour, the less sure tail at half of it.
    private func paint(_ t: String) {
        let font = label.font ?? .systemFont(ofSize: 13)
        let cut = t.index(t.endIndex, offsetBy: -min(unsure, t.count))
        let m = NSMutableAttributedString()
        // a fix: a coral arrow, then the whole word as it should be
        if !replace.isEmpty { m.append(NSAttributedString(string: " → ", attributes: [.font: font, .foregroundColor: Native.warn])) }
        m.append(NSAttributedString(string: String(t[..<cut]), attributes: [.font: font, .foregroundColor: ghostColor]))
        m.append(NSAttributedString(string: String(t[cut...]), attributes: [.font: font, .foregroundColor: ghostColor.withAlphaComponent(ghostColor.alphaComponent * 0.55)]))
        if !altHint.isEmpty, replace.isEmpty {
            m.append(NSAttributedString(string: "  " + altHint, attributes: [.font: NSFont.systemFont(ofSize: max(9, font.pointSize * 0.7)),
                                                                        .foregroundColor: ghostColor.withAlphaComponent(ghostColor.alphaComponent * 0.6),
                                                                        .baselineOffset: font.pointSize * 0.25]))
        }
        label.attributedStringValue = m
    }

    /// Two-step ghost (round two, 2026-11-13): more words at the end of the grey text being shown, in place. Nothing
    /// moves and the words already there stay as they were; `unsure` is how many characters at the end are lighter.
    func extend(_ more: String, unsure tail: Int) {
        guard visible, action == nil, !isDraft, replace.isEmpty, !more.isEmpty else { return }
        text += more; shownLen += more.count
        unsure = max(0, min(tail, text.count))
        paint(text)
        if boxed { fitBoxed(); return }
        label.sizeToFit()
        var f = panel.frame
        f.size.width = max(f.size.width, label.frame.width + (mid ? 2 * Ghost.midPad : 4))
        panel.setFrame(f, display: true)
        if mid { midBox.frame.size.width = f.size.width; midBox.needsDisplay = true }
    }

    /// Typing the same letters as the ghost keeps it and only drops what was typed.
    /// Letters that only differ as apostrophes, quotes or a no-break space match (GhostRules.typedInto).
    func consume(_ typed: String) -> Bool {
        guard !text.isEmpty, action == nil, !isDraft, replace.isEmpty, let n = GhostRules.typedInto(ghost: text, typed: typed) else { return false }
        typedIn += n
        if text.count == n { hide("typed all"); return true }   // typed it all: nothing left to show
        text.removeFirst(n)
        unsure = min(unsure, text.count); altHint = ""   // the other ideas were for the spot before these letters
        paint(text)
        if boxed { fitBoxed(); return true }   // a chip stays put while the user types into it
        label.sizeToFit()
        var f = panel.frame
        // move right by the width of what was typed
        let typedW = (typed as NSString).size(withAttributes: [.font: label.font as Any]).width
        f.origin.x += typedW; f.size.width = label.frame.width + (mid ? 2 * Ghost.midPad : 4)
        panel.setFrame(f, display: true)
        if mid { midBox.frame.size.width = f.size.width; midBox.needsDisplay = true }
        return true
    }

    func hide(_ why: String = "other") {
        if plainVisible {
            lastPlainHidden = GhostRules.involuntaryHide(why) ? (Date(), why) : nil
        }
        gone(why)
        if !replace.isEmpty { Fixer.hidden() }   // a fix offer went: taken, typed over or expired (log)
        text = ""; action = nil; replace = ""; unsure = 0; altHint = ""; mid = false; boxed = false; midBox.isHidden = true; plain()
        panel.orderOut(nil)
    }

    func flash(_ s: String) {
        guard let scr = NSScreen.main else { return }
        hide("flash")
        label.font = Native.text(13, .medium); label.textColor = .secondaryLabelColor; label.stringValue = s; label.sizeToFit()
        chipBox.isHidden = true; panel.alphaValue = 1
        let f = scr.visibleFrame
        panel.setFrame(NSRect(x: f.maxX - label.frame.width - 24, y: f.maxY - 34, width: label.frame.width + 8, height: 24), display: false)
        label.frame.origin = NSPoint(x: 4, y: 4)
        panel.orderFrontRegardless()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { [weak self] in
            if self?.text.isEmpty == true && self?.action == nil { self?.panel.orderOut(nil) }
        }
    }
}


/// The suggestion panel (2026-10-21; native colours since 23 November 2026): the system look, one
/// ink, square corners (2 px), no shadow; a colour only as a small square for the kind of offer.


/// A keycap: the panels' small key cap (Panel.keycap); with `tint` (the field's text colour) a quiet cap in that ink.
final class KeyCap: NSView {
    var label = "tab" { didSet { invalidateIntrinsicContentSize(); needsDisplay = true } }
    var size: CGFloat = 11
    var faint = false
    var tint: NSColor?   // the field's text colour, for the keycap after the grey words
    private var ink: NSColor { tint ?? Native.muted }
    private var attrs: [NSAttributedString.Key: Any] {
        [.font: Native.text(size, .medium), .foregroundColor: ink.withAlphaComponent(faint ? 0.55 : 1)]
    }
    override var intrinsicContentSize: NSSize {
        let t = (label as NSString).size(withAttributes: attrs)
        return NSSize(width: max(ceil(t.height) + 6, ceil(t.width) + 10), height: ceil(t.height) + 6)
    }
    func fit() { setFrameSize(intrinsicContentSize) }
    override func draw(_ r: NSRect) {
        let b = bounds, p = NSBezierPath(roundedRect: b.insetBy(dx: 0.25, dy: 0.25), xRadius: Panel.key, yRadius: Panel.key)
        (tint == nil ? Native.key : ink.withAlphaComponent(faint ? 0.06 : 0.09)).setFill(); p.fill()
        (tint == nil ? Native.line : ink.withAlphaComponent(faint ? 0.14 : 0.22)).setStroke(); p.lineWidth = 0.5; p.stroke()
        let t = (label as NSString).size(withAttributes: attrs)
        (label as NSString).draw(at: NSPoint(x: ((b.width - t.width) / 2).rounded(), y: ((b.height - t.height) / 2).rounded()), withAttributes: attrs)
    }
}

/// A panel ground at the caret (a chip, a card): the panels' one ground (Panel.ground), its corner by size.
final class Ground: NSView {
    var radius: CGFloat = Panel.control
    override func draw(_ r: NSRect) { Panel.ground(bounds, radius: radius) }
}

/// The kind of offer as its symbol, drawn in the kind's colour (`Kind` in Look.swift).
final class KindMark: NSView {
    var kind: Kind = .action { didSet { needsDisplay = true } }
    override func draw(_ r: NSRect) { Native.drawMark(kind.mark, in: bounds, tint: kind.color) }
}


extension Ghost {
    /// Test: a picture of the panel and what is around it into data/ghost.png (post <bundle id>.ghostshot).
    func shot() {
        guard panel.isVisible, let scr = NSScreen.screens.first else { log("ghostshot: nothing shown"); return }
        let f = panel.frame, h = scr.frame.height
        let r = CGRect(x: f.minX - 260, y: h - f.maxY - 60, width: max(560, f.width + 300), height: f.height + 120)
        SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: true) { c, _ in
            guard let d = c?.displays.first else { return }
            let cfg = SCStreamConfiguration()
            cfg.sourceRect = r; cfg.width = Int(r.width * 2); cfg.height = Int(r.height * 2)
            SCScreenshotManager.captureImage(contentFilter: SCContentFilter(display: d, excludingWindows: []), configuration: cfg) { img, _ in
                let out = Home.data.appendingPathComponent("ghost.png")
                if let img, let dest = CGImageDestinationCreateWithURL(out as CFURL, "public.png" as CFString, 1, nil) {
                    CGImageDestinationAddImage(dest, img, nil); CGImageDestinationFinalize(dest)
                }
                log("ghostshot: \(img == nil ? "failed" : "saved")")
            }
        }
    }
}

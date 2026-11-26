// The picker's drawing (picker round, 15 November 2026; the user: "the quick pick over the last copies looks poor"). One
// window for ⌃⌥V and ⌘⇧V (app/Quick.swift): the full form has the search head, the list and the action pill at its
// foot; the quick form (⌘⇧V held) is the same card without the head, the five newest copies and the held chord's
// buttons. The look is the screenshot strip's (app/CaptureNote.swift, app/ShotPill.swift): the card colour with a
// hairline edge and the one float shadow drawn here, glyph buttons with the key small under the glyph, the chosen one
// lifted with an edge, the main one filled. Rows are 48 pt: a 32 pt tile (the picture itself, the file's own icon, a
// link's or the kind's line glyph), the text, then the app's own icon, its name and how long ago. The chosen row is
// lifted with an edge and a 2 pt bar in the kind's colour; in the full form it unfolds to its whole text (or the
// picture, the address, the path), its written forms (← →) and the rewrite. Which buttons show: QuickRules.buttons
// (pure, tested). Drawing only, flipped; no state but the icon caches.
import AppKit
import UniformTypeIdentifiers

final class QuickView: NSView {
    weak var model: Quick?
    override var isFlipped: Bool { true }

    // MARK: sizes (points; the card's own coordinates, the panel adds `pad` round it for the shadow)

    static let pad: CGFloat = 16
    static let W: CGFloat = 560
    static let headH: CGFloat = 48, rowH: CGFloat = 48, listPad: CGFloat = 6, footH: CGFloat = 52
    static let fullRows = 8
    static var listH: CGFloat { CGFloat(fullRows) * rowH + 2 * listPad }
    /// The full card's height.
    static var H: CGFloat { headH + 1 + listH + footH }
    static var fullFrame: NSSize { NSSize(width: W + 2 * pad, height: H + 2 * pad) }
    static func cardSize(_ m: Quick) -> NSSize {
        if m.look == .full { return NSSize(width: W, height: H) }
        return NSSize(width: W, height: 2 * listPad + CGFloat(max(1, m.shown.count)) * rowH + footH)
    }
    static func frameSize(_ m: Quick) -> NSSize { let c = cardSize(m); return NSSize(width: c.width + 2 * pad, height: c.height + 2 * pad) }

    static let rowX: CGFloat = 8, tile: CGFloat = 32
    static var tileX: CGFloat { rowX + 8 }
    static var textX: CGFloat { tileX + tile + 12 }
    static var textW: CGFloat { W - rowX - 12 - 20 - textX }   // the pin mark's room at the right
    static var textFont: NSFont { Native.text(14) }                // asked each time: a theme can change the face
    static var metaFont: NSFont { Native.text(12) }
    static let pictureH: CGFloat = 150

    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }
    /// Whole rows in view at the last draw (the preview prints it).
    var drawnRows = 0

    private func listY(_ m: Quick) -> CGFloat { m.look == .full ? Self.headH + 1 : 0 }
    private func listRoom(_ m: Quick) -> CGFloat { Self.cardSize(m).height - listY(m) - Self.footH }

    // MARK: layout (only the rows in view are measured)

    private var chosenCache: (key: String, h: CGFloat)?
    private func height(_ m: Quick, _ i: Int) -> CGFloat {
        guard i == m.sel, m.look == .full else { return Self.rowH }
        let it = m.items[m.shown[i]]
        let key = "\(it.id)|\(m.mode)|\(m.run)|\(m.result.count)|\(m.cmds.count)|\(it.pinned)|\(it.ocr.count)|\(m.formIx)|\(m.custom.isEmpty)"
        if let c = chosenCache, c.key == key { return c.h }
        let h = m.mode == .rework ? rework(m, it, y: 0, draw: false) : max(Self.rowH, unfold(m, it, y: 0, draw: false))
        chosenCache = (key, h)
        return h
    }
    /// The first row in view: the chosen row stays fully in view, and the view moves only when it has to, so nothing
    /// jumps when the list changes; no empty tail at the end of the list.
    func fitTop(_ m: Quick) -> Int {
        let n = m.shown.count
        guard n > 0 else { return 0 }
        let room = listRoom(m) - 2 * Self.listPad
        var top = max(0, min(m.top, m.sel, n - 1))
        func span(_ a: Int, _ b: Int) -> CGFloat {
            var h: CGFloat = 0
            for i in a...b { h += height(m, i); if h > room { break } }
            return h
        }
        while top < m.sel, span(top, m.sel) > room { top += 1 }
        while top > 0 {
            var h = height(m, top - 1), i = top
            while i < n, h <= room { h += height(m, i); i += 1 }
            if h <= room { top -= 1 } else { break }
        }
        return top
    }

    // MARK: the card

    override func draw(_ dirty: NSRect) {
        guard let m = model else { return }
        let size = Self.cardSize(m)
        let card = NSRect(x: Self.pad, y: Self.pad, width: size.width, height: size.height)
        Panel.ground(card, radius: Native.corner(3), shadow: true, glass: true)   // the glass (GlassHost blurs what is below)
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(roundedRect: card.insetBy(dx: 1, dy: 1), xRadius: max(0, Native.corner(3) - 1), yRadius: max(0, Native.corner(3) - 1)).addClip()
        let t = NSAffineTransform(); t.translateX(by: Self.pad, yBy: Self.pad); t.concat()
        if m.look == .full { drawHead(m) }
        drawList(m)
        drawFoot(m, y: size.height - Self.footH)
        NSGraphicsContext.restoreGraphicsState()
    }

    /// The search glyph over the tiles' column, what the user types with the caret, the four kind filters at the right.
    private func drawHead(_ m: Quick) {
        let W = Self.W, h = Self.headH
        TapeDraw.glyph("search", NSRect(x: Self.tileX + 8, y: h / 2 - 8, width: 16, height: 16), color: m.query.isEmpty ? Native.muted : Native.ink)
        let kx = TapeDraw.kinds(right: W - 12, y: (h - 28) / 2) { k in m.kind.map { TapeKind($0) == k } ?? (k != .call) }
        let qf = Native.text(15), qa = TapeDraw.at(qf, Native.ink, cut: .byTruncatingHead)
        let qx = Self.textX, qw = kx - 12 - qx
        TapeDraw.line(m.query, NSRect(x: qx, y: TapeDraw.lineTop(qf, mid: h / 2), width: qw, height: 22), qa)
        if m.mode == .list {
            Native.blue.setFill()
            NSRect(x: qx + min(qw, m.query.isEmpty ? 0 : TapeDraw.width(m.query, qa) + 1), y: h / 2 - 10, width: 2, height: 20).fill()
        }
        TapeDraw.hairline(x0: 0, x1: W, y: h)
    }

    private func drawList(_ m: Quick) {
        let y0 = listY(m), room = listRoom(m), W = Self.W
        NSGraphicsContext.saveGraphicsState()
        NSRect(x: 0, y: y0, width: W, height: room).clip()
        drawnRows = 0
        if m.shown.isEmpty {
            let none = m.items.isEmpty ? "Nothing copied, typed or said yet" : "Nothing matches"
            let f = Native.text(14), a = TapeDraw.at(f, Native.muted), tw = TapeDraw.width(none, a)
            let mid = y0 + min(room / 2, 96)
            TapeDraw.glyph(m.items.isEmpty ? "clipboard" : "search", NSRect(x: (W - 24) / 2, y: mid - 34, width: 24, height: 24), color: Native.faint)
            TapeDraw.line(none, NSRect(x: (W - tw) / 2, y: TapeDraw.lineTop(f, mid: mid + 4), width: tw + 2, height: 20), a)
            NSGraphicsContext.restoreGraphicsState()
            return
        }
        m.top = fitTop(m)
        var y = y0 + Self.listPad, i = m.top
        while i < m.shown.count, y < y0 + room {
            let h = height(m, i)
            drawRow(m, m.items[m.shown[i]], NSRect(x: Self.rowX, y: y, width: W - 2 * Self.rowX, height: h), on: i == m.sel)
            y += h; i += 1
            if y <= y0 + room - Self.listPad { drawnRows += 1 }
        }
        if m.shown.count > i - m.top {   // where the view is when the list runs longer
            let n = CGFloat(m.shown.count), vis = CGFloat(i - m.top), r = room - 2 * Self.listPad
            let th = max(18, r * vis / n), ty = y0 + Self.listPad + (r - th) * CGFloat(m.top) / max(1, n - vis)
            Native.rule.setFill(); NSBezierPath(roundedRect: NSRect(x: W - 5, y: ty, width: 3, height: th), xRadius: 1.5, yRadius: 1.5).fill()
        }
        NSGraphicsContext.restoreGraphicsState()
    }

    // MARK: a row

    private func drawRow(_ m: Quick, _ it: QuickItem, _ r: NSRect, on: Bool) {
        if on {   // the journal's chosen row (app/Panel.swift): a soft accent lift, the control corner
            Native.pick.setFill(); NSBezierPath(roundedRect: r, xRadius: Panel.control, yRadius: Panel.control).fill()
        }
        let tr = NSRect(x: Self.tileX, y: r.minY + 8, width: Self.tile, height: Self.tile)
        if it.pinned { TapeDraw.glyph("bookmark", NSRect(x: r.maxX - 12 - 14, y: r.minY + 9, width: 14, height: 14), color: on ? Native.ink : Native.muted) }
        let unfolded = on && m.look == .full
        if unfolded, m.mode == .rework { tile(it, tr, on: on); _ = rework(m, it, y: r.minY, draw: true); return }
        if unfolded, !((it.clip == .image || (it.clip == .file && it.shape == .pdf)) && !it.picture.isEmpty) { tile(it, tr, on: on) }
        if unfolded { unfold(m, it, y: r.minY, draw: true); return }
        tile(it, tr, on: on)
        // two lines: what it is, then where from and when (the chosen copy's written form in the quick form)
        let x = Self.textX, w = Self.textW, f = Self.textFont
        let l1 = NSRect(x: x, y: TapeDraw.lineTop(f, mid: r.minY + 17), width: w, height: 20)
        let form = on ? m.shownForm(it) : nil
        if form == nil, TapeDraw.clipLine(it.clip, text: it.text, title: it.title, bytes: it.bytes, ocr: it.ocr, l1, font: f, shape: it.shape, note: it.note, look: it.look, picture: !it.picture.isEmpty) {}
        else {
            TapeDraw.line(Self.flat(form?.text ?? it.text), l1,
                          TapeDraw.at(f, it.image ? Native.muted : Native.ink, cut: it.single ? .byTruncatingMiddle : .byTruncatingTail))
        }
        let fs = on ? m.forms(it).forms : []
        if !fs.isEmpty {
            let s = "\(form?.name ?? m.firstFormName(it)) · \(m.formIx + 1)/\(fs.count + 1)"
            TapeDraw.glyph("arrows-left-right", NSRect(x: x, y: r.minY + 27, width: 14, height: 14), color: Native.ink)
            TapeDraw.line(s, NSRect(x: x + 20, y: TapeDraw.lineTop(Self.metaFont, mid: r.minY + 34), width: w - 20, height: 16), TapeDraw.at(Self.metaFont, Native.muted))
        } else {
            meta(m, it, x: x, mid: r.minY + 34, width: w, on: on)
        }
    }

    /// The whole text on one line (its lines joined), so a list shows more than its first item.
    static func flat(_ s: String) -> String {
        s.prefix(600).split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// The 32 pt tile: the picture itself, the file's own icon, else a quiet square with the link's or the kind's glyph.
    private func tile(_ it: QuickItem, _ r: NSRect, on: Bool) {
        if it.clip == .image, !it.picture.isEmpty, let img = TapeDraw.thumb(History.clipURL(it.picture)) { Self.fill(img, in: r); return }
        // clip kinds round: a PDF file's first page, a colour's swatch
        if it.clip == .file, it.shape == .pdf, !it.picture.isEmpty, let img = TapeDraw.thumb(History.clipURL(it.picture)) { Self.fill(img, in: r); return }
        if it.shape == .color, let c = ClipKindRules.color(it.text) { TapeDraw.swatch(c, in: r); return }
        if it.clip == .file, let icon = Icons.file(it.text) {
            icon.draw(in: r, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high])
            return
        }
        let box = NSBezierPath(roundedRect: r.insetBy(dx: 0.5, dy: 0.5), xRadius: Native.corner(2) - 0.5, yRadius: Native.corner(2) - 0.5)
        (on ? Native.card : Native.soft).setFill(); box.fill()
        Native.line.setStroke(); box.lineWidth = 1; box.stroke()
        let g = it.clip == .link ? "link" : it.clip == .image ? (it.shape == .pdf ? "file" : "image") : it.clip == .file ? "file"
            : it.shape == .code ? "terminal" : it.shape == .table ? "list" : it.shape == .rich ? "text" : TapeKind(it.kind).mark
        TapeDraw.glyph(g, NSRect(x: r.midX - 8, y: r.midY - 8, width: 16, height: 16), color: on ? Native.ink : Native.muted)
    }

    /// A picture filling `r` (cut to its middle), the theme's control corner and a hairline.
    static func fill(_ img: NSImage, in r: NSRect) {
        let s = max(r.width / max(1, img.size.width), r.height / max(1, img.size.height))
        let w = r.width / s, h = r.height / s
        let from = NSRect(x: (img.size.width - w) / 2, y: (img.size.height - h) / 2, width: w, height: h)
        let path = NSBezierPath(roundedRect: r, xRadius: Native.corner(2), yRadius: Native.corner(2))
        NSGraphicsContext.saveGraphicsState(); path.addClip()
        img.draw(in: r, from: from, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high])
        NSGraphicsContext.restoreGraphicsState()
        Native.line.setStroke(); let e = NSBezierPath(roundedRect: r.insetBy(dx: 0.5, dy: 0.5), xRadius: Native.corner(2) - 0.5, yRadius: Native.corner(2) - 0.5); e.lineWidth = 1; e.stroke()
    }

    /// The second line: the app's own icon (else its line glyph), its name and how long ago.
    private func meta(_ m: Quick, _ it: QuickItem, x: CGFloat, mid: CGFloat, width w: CGFloat, on: Bool) {
        var tx = x
        let ir = NSRect(x: x, y: (mid - 7).rounded(), width: 14, height: 14)
        if let icon = Icons.app(it.app) {
            icon.draw(in: ir.insetBy(dx: -1, dy: -1), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high])
            tx += 20
        } else if let g = TapeDraw.appMark(it.app) {
            TapeDraw.glyph(g, ir, color: Native.faint); tx += 20
        }
        let s = QuickRules.meta(app: it.app, at: it.at, now: m.now)
        TapeDraw.line(s, NSRect(x: tx, y: TapeDraw.lineTop(Self.metaFont, mid: mid), width: x + w - tx, height: 16), TapeDraw.at(Self.metaFont, on ? Native.muted : Native.faint))
    }

    /// The chosen row in the full form, unfolded: the picture large, else its whole text (the written form ← → chose),
    /// a link's whole address or a file's folder; then where from and when; then the written forms as a row of names.
    /// Returns the height.
    @discardableResult
    func unfold(_ m: Quick, _ it: QuickItem, y y0: CGFloat, draw: Bool) -> CGFloat {
        let x = Self.textX, w = Self.textW, f = Self.textFont
        var y = y0 + 7
        if it.clip == .image || (it.clip == .file && it.shape == .pdf), !it.picture.isEmpty, let img = TapeDraw.thumb(History.clipURL(it.picture)) {
            // the picture (a PDF's first page) takes the tile's column too
            let box = NSRect(x: Self.tileX, y: y + 1, width: Self.W - 2 * Self.rowX - 16 - 24, height: Self.pictureH)
            let s = min(box.width / max(1, img.size.width), box.height / max(1, img.size.height))
            let h = (img.size.height * s).rounded()
            if draw { TapeDraw.picture(img, in: box) }
            y += 1 + h + 10
            if draw { TapeDraw.clipLine(it.clip, text: it.text, title: it.title, bytes: it.bytes, ocr: it.ocr, NSRect(x: Self.tileX, y: TapeDraw.lineTop(f, mid: y + 9), width: box.width, height: 20), font: f, shape: it.shape, note: it.note, look: it.look, picture: !it.picture.isEmpty) }
            y += 20
            if draw { meta(m, it, x: Self.tileX, mid: y + 9, width: box.width, on: true) }
            return y + 18 + 9 - y0
        }
        let shown = m.shownForm(it) == nil
        switch it.clip {
        case .file where it.shape == .files:
            // several files: the count and size, then each name with its own icon (up to 5)
            if draw { TapeDraw.clipLine(it.clip, text: it.text, title: "", bytes: it.bytes, ocr: "", NSRect(x: x, y: TapeDraw.lineTop(f, mid: y + 10), width: w, height: 20), font: f, shape: it.shape) }
            y += 22
            let paths = it.text.split(separator: "\n").map(String.init), f2 = Native.text(12)
            for p in paths.prefix(5) {
                if draw {
                    Icons.file(p)?.draw(in: NSRect(x: x, y: y + 1, width: 16, height: 16), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
                    TapeDraw.line((p as NSString).abbreviatingWithTildeInPath, NSRect(x: x + 22, y: TapeDraw.lineTop(f2, mid: y + 9), width: w - 22, height: 17), TapeDraw.at(f2, Native.muted, cut: .byTruncatingMiddle))
                }
                y += 18
            }
            if paths.count > 5 {
                if draw { TapeDraw.line("+ \(paths.count - 5) more", NSRect(x: x + 22, y: TapeDraw.lineTop(f2, mid: y + 9), width: w - 22, height: 17), TapeDraw.at(f2, Native.faint)) }
                y += 18
            }
        case .text where it.shape == .table && shown:
            // a table: its size, then the top-left cells as a small grid
            if draw { TapeDraw.clipLine(it.clip, text: it.text, title: "", bytes: 0, ocr: "", NSRect(x: x, y: TapeDraw.lineTop(f, mid: y + 10), width: w, height: 20), font: f, shape: it.shape, note: it.note) }
            y += 24
            let cells = ClipKindRules.cells(it.text, rows: 4, cols: 5, chars: 16)
            y += TapeDraw.grid(cells, x: x, y: y, width: w, font: Native.text(12), draw: draw) + 2
        case .text where it.shape == .code && shown:
            // code: monospace, its first lines as they are, the language guessed beside where from
            let mono = Native.mono(12), body = it.text.split(separator: "\n", omittingEmptySubsequences: false).prefix(6).joined(separator: "\n")
            let n = TapeDraw.lines(body, width: w, font: mono, lh: 17, max: 6)
            if draw { TapeDraw.block(body, x: x, y: y + 1, width: w, font: mono, color: Native.ink, lh: 17, max: 6) }
            y += 1 + CGFloat(n) * 17
        case .link, .file:
            if draw { TapeDraw.clipLine(it.clip, text: it.text, title: it.title, bytes: it.bytes, ocr: "", NSRect(x: x, y: TapeDraw.lineTop(f, mid: y + 10), width: w, height: 20), font: f, shape: it.shape, note: it.note) }
            y += 20
            let more = it.clip == .link ? it.text : (it.text as NSString).abbreviatingWithTildeInPath
            let f2 = Native.text(12), n = TapeDraw.lines(more, width: w, font: f2, lh: 17, max: 2)
            if draw { TapeDraw.block(more, x: x, y: y + 2, width: w, font: f2, color: Native.muted, lh: 17, max: 2) }
            y += 2 + CGFloat(n) * 17
        default:
            let body = m.chosenText(it)
            let n = TapeDraw.lines(body, width: w, font: f, lh: 20, max: 4)
            if draw { TapeDraw.block(body, x: x, y: y + 1, width: w, font: f, color: it.image ? Native.muted : Native.ink, lh: 20, max: 4) }
            y += 1 + CGFloat(n) * 20
        }
        y += 4
        if draw { meta(m, it, x: x, mid: y + 8, width: w, on: true) }
        y += 16
        let fs = it.clip == .text || m.formatted(it) ? m.forms(it).forms : []
        if !fs.isEmpty {
            y += 8
            if draw { formNames([m.firstFormName(it)] + fs.map(\.name), chosen: m.formIx, x: x, y: y, width: w) }
            y += 22
        }
        return y + 9 - y0
    }

    /// The written forms as names in a row: the shown one raised with an edge, the rest muted; ← → step.
    private func formNames(_ names: [String], chosen: Int, x x0: CGFloat, y: CGFloat, width w: CGFloat) {
        let f = Native.text(12), mono = Native.mono(11)
        var x = x0
        let ka = TapeDraw.at(mono, Native.faint)
        ("← →" as NSString).draw(at: NSPoint(x: x, y: TapeDraw.lineTop(mono, mid: y + 11)), withAttributes: ka)
        x += TapeDraw.width("← →", ka) + 10
        for (i, n) in names.enumerated() {
            let on = i == chosen, a = TapeDraw.at(f, on ? Native.ink : Native.muted)
            let tw = TapeDraw.width(n, a), r = NSRect(x: x, y: y, width: tw + 16, height: 22)
            if r.maxX > x0 + w { break }
            if on {
                let rad = TapeDraw.keyRadius
                let b = NSBezierPath(roundedRect: r.insetBy(dx: 0.5, dy: 0.5), xRadius: rad, yRadius: rad)
                Native.card.setFill(); b.fill(); Native.controlEdge.setStroke(); b.lineWidth = 1; b.stroke()
            }
            (n as NSString).draw(at: NSPoint(x: r.minX + 8, y: TapeDraw.lineTop(f, mid: r.midY)), withAttributes: a)
            x = r.maxX + 4
        }
    }

    // MARK: the foot: the chosen row's keys as glyph buttons, and the one line that says what just happened

    private func row(_ m: Quick) -> QuickRules.PickerRow? {
        guard let it = m.current else { return nil }
        return QuickRules.PickerRow(clip: it.clip, target: it.clip == .text ? m.target(it)?.kind : nil,
                                    forms: m.mode == .list && (it.clip == .text || m.formatted(it)) ? m.forms(it).forms.count : 0,
                                    image: it.image, picture: !it.picture.isEmpty, pinned: it.pinned,
                                    shape: it.shape, formatted: m.formatted(it))
    }
    func buttons(_ m: Quick) -> [[QuickRules.PickerButton]] {
        QuickRules.buttons(row(m), quick: m.look == .quick, rework: m.mode == .rework, result: m.run == .result)
    }

    private func drawFoot(_ m: Quick, y: CGFloat) {
        let W = Self.W, h = Self.footH
        // Rebuild B: the keys in the one dark pill, the main action at its blue end; the rest drop from the end when
        // the pill would run into the notice at the right
        let all = buttons(m).flatMap { $0 }
        let go = all.first { $0.primary }.map { (key: $0.key, word: $0.word) }
        var pairs = all.filter { !$0.primary }.map { (key: $0.key, word: $0.word) }
        let room = W - 2 * Self.rowX - (m.notice.isEmpty && m.mode != .rework ? 0 : 200)
        while !pairs.isEmpty, Panel.pillWidth(pairs, go: go) > room { pairs.removeLast() }
        let pw = Panel.pill(pairs, go: go, x: Self.rowX + 4, mid: y + h / 2, shadow: false)
        let p = (bar: NSRect(x: Self.rowX + 4, y: y, width: pw, height: h), 0)
        // the right side: a removal's undo, a rewrite's length change, else nothing
        let right = W - 14, mid = y + h / 2
        if m.mode == .rework, m.run == .result, let it = m.source {
            let s = "\(it.text.count) → \(m.result.count)", a = TapeDraw.at(Native.mono(12), Native.muted)
            (s as NSString).draw(at: NSPoint(x: right - TapeDraw.width(s, a), y: TapeDraw.lineTop(Native.mono(12), mid: mid)), withAttributes: a)
        } else if !m.notice.isEmpty {
            let parts = m.notice.components(separatedBy: " · ⌘Z ")
            let f = Native.text(13), a = TapeDraw.at(f, Native.muted)
            var x = right
            if parts.count > 1 {   // "⌘Z brings it back": the key and its words
                let wa = TapeDraw.at(Native.text(13), Native.muted), ww = TapeDraw.width(parts[1], wa)
                x -= ww; (parts[1] as NSString).draw(at: NSPoint(x: x, y: TapeDraw.lineTop(f, mid: mid)), withAttributes: wa)
                let kw = max(TapeDraw.capH, TapeDraw.width("⌘Z", TapeDraw.at(Native.mono(12, .medium), Native.ink)) + 12)
                x -= 8 + kw; TapeDraw.keycap("⌘Z", x: x, y: mid - TapeDraw.capH / 2)
                x -= 14
            }
            let lw = min(TapeDraw.width(parts[0], a), x - p.bar.maxX - 16)
            TapeDraw.line(parts[0], NSRect(x: x - lw, y: TapeDraw.lineTop(f, mid: mid), width: lw, height: 20), a)
        }
    }

    // MARK: rewrite

    private static func verb(_ c: Quick.Cmd) -> String {
        switch c.id {
        case "plain": return "plain"
        case "oneline": return "one line"
        case "quote": return "quote"
        case "translate": return c.hint.contains("English") ? "→ EN" : c.hint.contains("Україн") ? "→ UA" : "translate"
        default: return c.name.lowercased()
        }
    }

    /// Rewrite, unfolded in the chosen row: the user's text (struck lightly above the result once one came back), the verbs as
    /// numbered keycaps (1-3 on this Mac; below the hairline the rework list, with the cloud glyph when it goes to
    /// Claude), and the field for the user's own words. ↵ ⌫ esc are on the foot. Returns the height.
    @discardableResult
    func rework(_ m: Quick, _ it: QuickItem, y y0: CGFloat, draw: Bool) -> CGFloat {
        let x = Self.textX, w = Self.textW
        var y = y0 + 8
        if m.run == .result {
            let f1 = Native.text(13), n1 = TapeDraw.lines(it.text, width: w, font: f1, lh: 18, max: 2)
            if draw { TapeDraw.block(it.text, x: x, y: y + 2, width: w, font: f1, color: Native.muted, lh: 18, max: 2, strike: Native.faint) }
            y += 2 + CGFloat(n1) * 18 + 6
            let f2 = Native.text(15), n2 = TapeDraw.lines(m.result, width: w, font: f2, lh: 22, max: 4)
            if draw { TapeDraw.block(m.result, x: x, y: y, width: w, font: f2, color: Native.ink, lh: 22, max: 4) }
            y += CGFloat(n2) * 22 + 10
        } else {
            let n = TapeDraw.lines(it.text, width: w, font: Self.textFont, lh: 20, max: 3)
            if draw { TapeDraw.block(it.text, x: x, y: y, width: w, font: Self.textFont, color: Native.ink, lh: 20, max: 3) }
            y += CGFloat(n) * 20 + 8
            if m.run == .working || m.run == .failed {
                let s = m.resultName.lowercased() + (m.run == .working ? " · writing…" : " · nothing new came back")
                if draw { TapeDraw.line(s, NSRect(x: x, y: y, width: w, height: 18), TapeDraw.at(Native.text(13), Native.muted)) }
                y += 24
            }
        }
        // the verbs: four to a line, "/ own" closes the first line (the three on this Mac)
        if draw { TapeDraw.hairline(x0: x, x1: x + w, y: y) }
        y += 2 + 10
        let gap: CGFloat = 8, colW = (w - 3 * gap) / 4, rowStep = TapeDraw.capH + 8
        let cloud = m.cmds.contains { $0.cloud }
        func cell(_ c: Int) -> (CGFloat, CGFloat) {
            let r = c / 4
            return (x + CGFloat(c % 4) * (colW + gap), y + CGFloat(r) * rowStep + (r > 0 ? 12 : 0))
        }
        let cells = m.cmds.count + 1
        if draw {
            for (i, c) in m.cmds.enumerated() {
                let (cx, cy) = cell(i < 3 ? i : i + 1)
                let ok = m.usable(c)
                let key = i < 10 ? "\((i + 1) % 10)" : "·"
                let kw = TapeDraw.keycap(key, x: cx, y: cy, on: i == m.rsel && m.custom.isEmpty)
                TapeDraw.line(Self.verb(c), NSRect(x: cx + kw + 7, y: cy + 4, width: colW + gap - kw - 9, height: 18), TapeDraw.at(Native.text(13), ok ? Native.ink : Native.faint))
            }
            let (ox, oy) = cell(min(3, cells - 1))
            let kw = TapeDraw.keycap("/", x: ox, y: oy, on: !m.custom.isEmpty)
            TapeDraw.line("own", NSRect(x: ox + kw + 7, y: oy + 4, width: colW - kw - 7, height: 18), TapeDraw.at(Native.text(13), Native.ink))
            if m.cmds.count > 3 {
                let ry = y + rowStep + 2
                TapeDraw.hairline(x0: x, x1: x + w - (cloud ? 24 : 0), y: ry)
                if cloud { TapeDraw.glyph("cloud", NSRect(x: x + w - 16, y: ry - 8, width: 16, height: 16), color: Native.muted) }
            }
        }
        let rows = (cells + 3) / 4
        y += CGFloat(rows) * rowStep + (rows > 1 ? 12 : 0) - 8 + 12
        // the user's own words
        if draw {
            let r = NSRect(x: x, y: y, width: w, height: 32)
            let b = NSBezierPath(roundedRect: r.insetBy(dx: 0.5, dy: 0.5), xRadius: Native.corner(2), yRadius: Native.corner(2))
            Native.card.setFill(); b.fill(); (m.custom.isEmpty ? Native.controlEdge : Native.blue).setStroke(); b.lineWidth = 1; b.stroke()
            let sa = TapeDraw.at(Native.mono(13), Native.faint), f = Native.text(14)
            ("/" as NSString).draw(at: NSPoint(x: r.minX + 10, y: TapeDraw.lineTop(Native.mono(13), mid: r.midY)), withAttributes: sa)
            let ta = TapeDraw.at(f, m.custom.isEmpty ? Native.faint : Native.ink, cut: .byTruncatingHead)
            let tx = r.minX + 26, tw = r.width - 36
            TapeDraw.line(m.custom.isEmpty ? "your own words" : m.custom, NSRect(x: tx, y: TapeDraw.lineTop(f, mid: r.midY), width: tw, height: 20), ta)
            if m.run != .working {
                Native.blue.setFill()
                NSRect(x: tx + (m.custom.isEmpty ? -3 : min(tw, TapeDraw.width(m.custom, ta) + 1)), y: r.midY - 9, width: 2, height: 18).fill()
            }
        }
        y += 32
        return y + 12 - y0
    }

    // MARK: VoiceOver

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .list }
    override func accessibilityLabel() -> String? {
        guard let m = model else { return nil }
        let chosen = m.current.map { Self.flat(m.chosenText($0)) } ?? "nothing"
        return "Clipboard picker, \(m.shown.count) rows, chosen: \(chosen). " + buttons(m).flatMap { $0 }.map { "\($0.word) \($0.key)" }.joined(separator: ", ")
    }
}

/// The apps' own icons by the name a row keeps (the front app's localized name), and the files' own icons; cached.
/// nil: no such app on this Mac (the row draws the app's line glyph, TapeDraw.appMark).
enum Icons {
    private static var apps: [String: NSImage] = [:], noApp: Set<String> = []
    private static var files: [String: NSImage] = [:]
    static func app(_ name: String) -> NSImage? {
        guard !name.isEmpty else { return nil }
        if let i = apps[name] { return i }
        if noApp.contains(name) { return nil }
        var path = NSWorkspace.shared.runningApplications.first { $0.localizedName == name }?.bundleURL?.path
        if path == nil {
            let dirs = ["/Applications", "/System/Applications", "/System/Applications/Utilities", "/Applications/Utilities", NSHomeDirectory() + "/Applications"]
            path = dirs.map { "\($0)/\(name).app" }.first { FileManager.default.fileExists(atPath: $0) }
        }
        guard let p = path else { noApp.insert(name); return nil }
        let i = NSWorkspace.shared.icon(forFile: p)
        apps[name] = i
        return i
    }
    /// The first file of a file row: its own icon when it is there, else its type's icon.
    static func file(_ text: String) -> NSImage? {
        guard let first = text.split(separator: "\n").first.map(String.init), !first.isEmpty else { return nil }
        let path = (first as NSString).expandingTildeInPath
        if let i = files[path] { return i }
        if files.count > 200 { files.removeAll() }
        let i = FileManager.default.fileExists(atPath: path) ? NSWorkspace.shared.icon(forFile: path)
            : NSWorkspace.shared.icon(for: UTType(filenameExtension: (path as NSString).pathExtension) ?? .data)
        files[path] = i
        return i
    }
}

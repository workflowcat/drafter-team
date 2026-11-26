// Pick parts, the panel (15 November 2026). One long text as pieces; the user picks the ones the user needs and keeps them as a
// new clip (Return), puts them in where the user was (⌘Return), or keeps the rest instead (⌥Return). The source is never
// changed. Rules and the key state machine: app/PickRules.swift. Saving: History.keepPick.
//
// The panel takes the keys itself: Drafter comes to the front while it is open (its own bundle is a skipped app, so
// no ghost text, chips or autocorrect act on what the user types here), and their app comes back when it closes. Insert goes
// through Capture.put, the Quick panel's way (never a skipped app, a password field or under secure input).
import AppKit
import Carbon

final class PickPanel {
    static let shared = PickPanel()

    /// Open on a text. `sourceId`: PickRules.sourceId(kind:text:) of the item it came from (QuickItem.id for a row
    /// without a picture). `sourceApp`: the app that item came from (the new clip keeps it). `mine`: the text is the user's
    /// own writing (a draft, a sent line, a voice take). `things`: a finder for the "things" level (nil: the
    /// detector, FoundRules.pickThings, with dates read against `written`, when the text was written).
    static func open(text: String, sourceId: String, sourceApp: String, mine: Bool = false, written: Date = Date(), things: PickThings? = nil) {
        shared.open(text: text, sourceId: sourceId, sourceApp: sourceApp, mine: mine, things: things ?? FoundRules.pickThings(written: written))
    }
    /// Open on what is on the clipboard now (the global chord).
    static func openClipboard() {
        guard let s = NSPasteboard.general.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else {
            Pill.shared.flash("No text on the clipboard"); return
        }
        open(text: s, sourceId: PickRules.sourceId(kind: "copied", text: s), sourceApp: NSWorkspace.shared.frontmostApplication?.localizedName ?? "")
    }

    // MARK: the doors (one line each where the lead wires them; docs/rounds/2026-11-15-pick.md)

    // The global chord is the setting `pickKey` (⌃⌥P by default, KeyMap "pick"), read in Quick.tap.
    /// A Quick panel or switcher row (text rows only; a link, file or picture has nothing to pick).
    static func open(_ it: QuickItem) {
        guard it.clip == .text, !it.image else { Pill.shared.flash("Only a text has parts to pick"); return }
        open(text: it.text, sourceId: it.id, sourceApp: it.app, mine: it.kind != .copied, written: Date(timeIntervalSince1970: it.at))
    }
    /// A journal item: the user's change if the user made one, else the stored text; the id is the stored text's.
    static func open(_ it: TapeItem) {
        guard it.doc == nil, (it.entry?.clip ?? .text) == .text, !it.current.isEmpty else { Pill.shared.flash("Only a text has parts to pick"); return }
        open(text: it.current, sourceId: PickRules.sourceId(kind: it.quick?.rawValue ?? "copied", text: it.text), sourceApp: it.app, mine: it.kind != .copied,
             written: Date(timeIntervalSince1970: it.at))
    }
    /// After a copy (History.watchClipboard): a long text gets a quiet "Pick parts" button in the strip.
    static func offerAfterCopy(_ text: String) {
        guard PickRules.worthPicking(text) else { return }
        let n = PickRules.split(text, .sentences).count
        Pill.shared.flash("Copied · \(n) sentences", button: StripButton("Pick parts", key: "⌃⌥P", style: .quiet) { openClipboard() })
    }

    var state = PickState(text: "")
    private(set) var isOpen = false
    var note = ""                         // a word in the status line for a moment ("Nothing picked")
    private var noteWork: DispatchWorkItem?
    private var sourceId = "", sourceApp = "", mine = false
    private var origin: NSRunningApplication?
    var preview = false
    let panel: PickWindow
    let view = PickView()

    init() {
        panel = PickWindow(contentRect: NSRect(origin: .zero, size: PickView.size), styleMask: [.borderless], backing: .buffered, defer: false)
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true
        panel.level = .floating; panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.isReleasedWhenClosed = false
        view.frame = NSRect(origin: .zero, size: PickView.size)
        view.model = self
        panel.contentView = GlassHost(view, inset: 0)   // Rebuild B: frosted glass
        NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: panel, queue: .main) { [weak self] _ in
            self?.close("away", back: false)
        }
    }

    func open(text: String, sourceId: String, sourceApp: String, mine: Bool, things: PickThings?) {
        if IsSecureEventInputEnabled() { Pill.shared.flash("Pick parts is off while secure input is on"); return }
        let t0 = Date()
        if isOpen { close("again", back: false) }
        self.sourceId = sourceId; self.sourceApp = sourceApp; self.mine = mine
        origin = PutBack.remember()
        state = PickState(text: text, things: things)
        note = ""; view.top = 0
        place()
        isOpen = true
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(view)
        view.needsDisplay = true
        log("pick: open, \(text.count) chars, \(state.pieces.count) \(PickRules.levelId(state.level)), \(Int(Date().timeIntervalSince(t0) * 1000)) ms")
    }

    /// back: the user's app comes to the front again.
    func close(_ why: String, back: Bool = true) {
        guard isOpen else { return }
        isOpen = false
        panel.orderOut(nil)
        if back, origin != nil { PutBack.raise(origin, "pick") }   // only over Drafter itself (PutRules)
        log("pick: closed (\(why))")
    }

    /// The screen with the mouse, centred, in its upper third.
    private func place() {
        let mouse = NSEvent.mouseLocation
        let s = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        let vis = s?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let size = PickView.size
        let y = min(max(vis.maxY - vis.height / 3 - size.height / 2, vis.minY + 8), vis.maxY - size.height - 8)
        panel.setFrame(NSRect(x: vis.midX - size.width / 2, y: y, width: size.width, height: size.height), display: false)
    }

    // MARK: keys and actions

    func key(_ k: PickKey) {
        switch state.key(k) {
        case .none: return
        case .redraw: break
        case .nothing(let w): say(w)
        case .close: close("esc")
        case .save(let s): keep(s, rest: false)
        case .saveRest(let s): keep(s, rest: true)
        case .insert(let s): insert(s)
        }
        view.needsDisplay = true
    }
    func say(_ w: String) {
        note = w; noteWork?.cancel()
        let job = DispatchWorkItem { [weak self] in self?.note = ""; self?.view.needsDisplay = true }
        noteWork = job
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5, execute: job)
    }

    /// The pick (or the rest) as a new clip and on the clipboard; the note beside the strip undoes both.
    private func keep(_ text: String, rest: Bool) {
        let ranges = state.picked.sorted().map { state.pieces[$0].range }
        let rec = PickRecord(text: text, from: sourceId, picked: ranges, at: Date().timeIntervalSince1970, level: state.level, rest: rest, mine: mine)
        guard !preview else { say(rest ? "The rest kept" : "Kept"); return }
        let before = NSPasteboard.general.string(forType: .string)
        History.keepPick(rec, app: sourceApp)
        History.copy(text)
        close(rest ? "kept the rest" : "kept")
        log("pick: kept \(rest ? "the rest" : "\(ranges.count) \(PickRules.levelId(state.level))"), \(text.count) chars")
        let app = sourceApp
        Pill.shared.flash(rest ? "The rest is a new clip · on the clipboard" : "Your pick is a new clip · on the clipboard",
                          button: StripButton("Undo", key: "", style: .primary) {
            History.keepPick(rec, app: app, remove: true)
            if NSPasteboard.general.string(forType: .string) == text, let before { History.copy(before) }
            log("pick: undo keep")
        })
    }

    /// Into the app the user came from; nothing is kept.
    private func insert(_ text: String) {
        guard !preview else { say("In the field"); return }
        guard let o = origin, !o.isTerminated else {
            close("insert, no app", back: false); History.copy(text); Pill.shared.flash("On the clipboard · ⌘V to paste"); return
        }
        close("insert")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            let how = Capture.put(text: text, origin: o)
            log("pick: insert \(text.count) chars, \(how)")
        }
    }

    // MARK: preview (made-up texts only)

    func preview(_ folder: String) throws {
        preview = true
        defer { preview = false; isOpen = false }
        let dark = Native.dark ? "-dark" : ""
        func shot(_ name: String) throws {
            view.needsDisplay = true
            guard let rep = UIShots.bitmap(view), let d = rep.representation(using: .png, properties: [:]) else { throw NSError(domain: "Pick", code: 1) }
            try d.write(to: URL(fileURLWithPath: folder + "/pick-\(name)\(dark).png"))
        }
        func load(_ t: String, _ l: PickLevel? = nil) { state = PickState(text: t, level: l, things: FoundRules.pickThings(written: Date(timeIntervalSince1970: 1_794_729_600))); note = ""; view.top = 0; isOpen = true }

        load(Self.prose, .sentences)
        state.picked = [1, 4, 7]; state.cursor = 4
        try shot("sentences")
        load(Self.list)
        state.picked = [1, 2, 5]; state.cursor = 5
        try shot("items")
        load(Self.mixed, .things)
        state.picked = [0, 3]; state.cursor = 3
        try shot("things")
        load(Self.mixed, .lines)
        for k: PickKey in [.char("/"), .char("r"), .char("e"), .char("n"), .char("t")] { _ = state.key(k) }
        _ = state.key(.down); _ = state.key(.shiftDown)
        try shot("filter")
        load(Self.prose, .paragraphs)
        _ = state.key(.enter)
        if case .nothing(let w) = state.key(.enter) { note = w }
        try shot("nothing")
    }

    static let prose = """
    We moved the studio meeting to Thursday. Olena books the big room on the second floor. The heating there works again, so bring nothing warm.

    The budget for the winter fair grew by 2.5 percent, e.g. for the stands and the lights. Taras asks whether we still need the second van. If not, he cancels it by Monday.

    For the drawings, use the shared folder at https://example.com/fair/drawings. Iryna will check them on Wednesday. Questions go to the fair chat, not to email.
    """
    static let list = """
    Packing for the fair:
    - two folding tables
    - extension cords, the long ones
    - price cards in Ukrainian and English
    - the blue tablecloth
    1. call the venue about parking
    2. print 40 flyers
    - [ ] spare batteries for the card reader
    """
    static let mixed = """
    Rent for December: 18 500 грн, due 2026-12-05.
    Deposit back from the old place: $400 on 20 листопада.
    Contract scan: https://example.com/docs/lease-2026.pdf
    Landlord: owner@example.org, after 18:00 only.
    Next rent review on March 1, 2027.
    Rent calculator: https://example.com/calc?city=kyiv
    """
}

/// A panel that takes the keys (the Quick panel's never does: it works through the event tap).
final class PickWindow: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

// MARK: drawing

final class PickView: NSView {
    weak var model: PickPanel?
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }

    static let W: CGFloat = 640, H: CGFloat = 470
    static let headH: CGFloat = 44, footH: CGFloat = 76, gutter: CGFloat = 44, side: CGFloat = 16
    static var size: NSSize { NSSize(width: W, height: H) }
    static var listY: CGFloat { headH + 1 }
    static var listH: CGFloat { H - listY - footH }
    static var textX: CGFloat { gutter }
    static var textW: CGFloat { W - gutter - side - 28 }
    static var font: NSFont { Native.text(14) }
    static let lh: CGFloat = 20, pad: CGFloat = 7

    var top = 0
    private var rowRects: [(piece: Int, r: NSRect)] = []
    private var levelRects: [(PickLevel, NSRect)] = []
    private var actionRects: [(PickKey, NSRect)] = []

    /// Lines a piece may take: sentences and items 3, paragraphs 4, lines and things 2.
    private func maxLines(_ l: PickLevel) -> Int { l == .paragraphs ? 4 : (l == .lines || l == .things) ? 2 : 3 }
    private func display(_ s: PickState, _ p: PickPiece) -> String {
        let t = (s.text as NSString).substring(with: p.range)
        return s.level == .paragraphs ? t.replacingOccurrences(of: "\n", with: " ") : t
    }
    private func rowH(_ s: PickState, _ i: Int) -> CGFloat {
        let n = TapeDraw.lines(display(s, s.pieces[i]), width: Self.textW, font: Self.font, lh: Self.lh, max: maxLines(s.level))
        return CGFloat(n) * Self.lh + Self.pad * 2
    }
    /// The first row in view: the cursor row stays whole in view, and the view moves only when it has to.
    private func fitTop(_ s: PickState, _ shown: [Int]) -> Int {
        guard !shown.isEmpty else { return 0 }
        let cur = min(s.cursor, shown.count - 1)
        var t = max(0, min(top, cur))
        func span(_ a: Int, _ b: Int) -> CGFloat { (a...b).reduce(0) { $0 + rowH(s, shown[$1]) } }
        while t < cur, span(t, cur) > Self.listH { t += 1 }
        while t > 0 {
            var h = rowH(s, shown[t - 1]), i = t
            while i < shown.count, h <= Self.listH { h += rowH(s, shown[i]); i += 1 }
            if h <= Self.listH { t -= 1 } else { break }
        }
        return t
    }

    override func draw(_ dirty: NSRect) {
        guard let m = model else { return }
        let s = m.state, W = Self.W
        TapeDraw.surface(bounds, glass: true)
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: max(0, Native.corner(3) - 1), yRadius: max(0, Native.corner(3) - 1)).addClip()

        // head: the filter at the left, the five levels at the right
        let midH = Self.headH / 2
        TapeDraw.glyph(s.filtering || !s.query.isEmpty ? "filter" : "search", NSRect(x: Self.side, y: midH - 8, width: 16, height: 16),
                       color: s.filtering ? Native.ink : Native.muted)
        levelRects = []
        var lx = W - Self.side
        for l in PickLevel.allCases.reversed() {
            let on = l == s.level
            let a = TapeDraw.at(Native.text(13, on ? .medium : .regular), on ? Native.ink : Native.muted)
            let w = TapeDraw.width(l.word, a), cap: CGFloat = 20
            let r = NSRect(x: lx - (cap + 6 + w + 10), y: midH - 13, width: cap + 6 + w + 10, height: 26)
            if on {
                Native.soft.setFill(); NSBezierPath(roundedRect: r, xRadius: Native.corner(2), yRadius: Native.corner(2)).fill()
            }
            let ka = TapeDraw.at(Native.mono(11, .medium), on ? Native.ink : Native.faint)
            let ks = "\(l.rawValue)", kw = TapeDraw.width(ks, ka)
            (ks as NSString).draw(at: NSPoint(x: r.minX + 5 + (cap - kw) / 2, y: TapeDraw.lineTop(Native.mono(11), mid: midH)), withAttributes: ka)
            (l.word as NSString).draw(at: NSPoint(x: r.minX + 5 + cap + 2, y: TapeDraw.lineTop(Native.text(13), mid: midH)), withAttributes: a)
            levelRects.append((l, r))
            lx = r.minX - 2
        }
        let qx = Self.side + 16 + 10, qw = lx - 12 - qx
        if s.filtering || !s.query.isEmpty {
            let qa = TapeDraw.at(Native.text(14), Native.ink, cut: .byTruncatingHead)
            TapeDraw.line(s.query, NSRect(x: qx, y: TapeDraw.lineTop(Native.text(14), mid: midH), width: qw, height: 22), qa)
            if s.filtering {
                Native.blue.setFill()
                NSRect(x: qx + min(qw, s.query.isEmpty ? 0 : TapeDraw.width(s.query, qa) + 1), y: midH - 9, width: 2, height: 18).fill()
            }
        } else {
            TapeDraw.keycap("/", x: qx, y: midH - TapeDraw.capH / 2)
        }
        TapeDraw.hairline(x0: 0, x1: W, y: Self.headH)

        // the pieces
        let shown = s.shown
        top = fitTop(s, shown)
        let y0 = Self.listY
        NSGraphicsContext.saveGraphicsState()
        NSRect(x: 0, y: y0, width: W, height: Self.listH).clip()
        rowRects = []
        if shown.isEmpty {
            let t = s.pieces.isEmpty ? "No \(s.level.noun(2)) in this text" : "Nothing holds “\(s.query)”"
            TapeDraw.line(t, NSRect(x: Self.textX, y: y0 + 12, width: Self.textW, height: 20), TapeDraw.at(Native.text(14), Native.muted))
        }
        var y = y0, vi = top
        let q = PickRules.fold(s.query)
        while vi < shown.count, y < y0 + Self.listH {
            let i = shown[vi], p = s.pieces[i], h = rowH(s, i)
            let r = NSRect(x: 0, y: y, width: W, height: h)
            let picked = s.picked.contains(i), cur = vi == min(s.cursor, shown.count - 1)
            if picked { Native.soft.setFill(); r.fill() }
            if cur { Native.blue.setFill(); NSRect(x: 0, y: y, width: TapeDraw.edge, height: h).fill() }
            // the check: an empty box, or a filled one with a check mark (never colour alone)
            let box = NSRect(x: Self.side, y: y + Self.pad + (Self.lh - 16) / 2, width: 16, height: 16)
            let bp = NSBezierPath(roundedRect: box.insetBy(dx: 0.5, dy: 0.5), xRadius: 4, yRadius: 4)
            if picked {
                Native.ink.setFill(); bp.fill()
                TapeDraw.glyph("check", box.insetBy(dx: 1, dy: 1), color: Native.card)
            } else {
                (cur ? Native.ink : Native.rule).setStroke(); bp.lineWidth = 1; bp.stroke()
            }
            if cur {   // the focus ring around the box of the row the keys act on
                let ring = NSBezierPath(roundedRect: box.insetBy(dx: -3, dy: -3), xRadius: 6, yRadius: 6)
                Native.blue.setStroke(); ring.lineWidth = 1.5; ring.stroke()
            }
            let text = display(s, p)
            let tw = Self.textW - (s.level == .things ? 48 : 0)
            drawText(text, query: q, x: Self.textX, y: y + Self.pad, width: tw, lines: maxLines(s.level), color: Native.ink)
            if s.level == .things {
                if let g = Self.thingGlyph[p.kind] ?? Self.foundGlyph(p.kind) {
                    TapeDraw.glyph(g, NSRect(x: W - Self.side - 16, y: y + Self.pad + (Self.lh - 16) / 2, width: 16, height: 16), color: Native.muted)
                } else {   // no symbol for this kind yet (amount): its word
                    let ka = TapeDraw.at(Native.mono(11), Native.muted), kw = TapeDraw.width(p.kind, ka)
                    (p.kind as NSString).draw(at: NSPoint(x: W - Self.side - kw, y: TapeDraw.lineTop(Native.mono(11), mid: y + Self.pad + Self.lh / 2)), withAttributes: ka)
                }
            }
            rowRects.append((i, r))
            y += h; vi += 1
        }
        // a thin bar at the right when the list runs past the view
        let total = shown.reduce(CGFloat(0)) { $0 + rowH(s, $1) }
        if total > Self.listH {
            let before = shown.prefix(top).reduce(CGFloat(0)) { $0 + rowH(s, $1) }
            let th = max(24, Self.listH * Self.listH / total), ty = y0 + (Self.listH - th) * min(1, before / max(1, total - Self.listH))
            Native.rule.setFill(); NSBezierPath(roundedRect: NSRect(x: W - 6, y: ty, width: 3, height: th), xRadius: 1.5, yRadius: 1.5).fill()
        }
        NSGraphicsContext.restoreGraphicsState()

        // the foot: the count, the result's first line, the keys
        let fy = Self.H - Self.footH
        TapeDraw.hairline(x0: 0, x1: W, y: fy)
        let st = s.status
        let ca = TapeDraw.at(Native.mono(12), m.note.isEmpty ? Native.muted : Native.ink)
        TapeDraw.line(m.note.isEmpty ? st.count : m.note, NSRect(x: Self.side, y: fy + 10, width: W / 2, height: 18), ca)
        if !st.first.isEmpty {
            TapeDraw.glyph("copy", NSRect(x: W / 2, y: fy + 11, width: 14, height: 14), color: Native.faint)
            TapeDraw.line(st.first, NSRect(x: W / 2 + 20, y: fy + 9, width: W / 2 - 20 - Self.side, height: 18), TapeDraw.at(Native.text(13), Native.ink))
        }
        actionRects = []
        let ky = fy + 38
        var kx = Self.side
        for (k, cap, word) in [(PickKey.enter, "↵", "Keep"), (.cmdEnter, "⌘↵", "Insert"), (.optEnter, "⌥↵", "Keep the rest"), (.undo, "⌘Z", "Undo")] {
            let on = k == .enter && !s.picked.isEmpty
            let x2 = TapeDraw.keyWord(cap, word, x: kx, y: ky, on: false, color: on ? Native.ink : Native.muted)
            actionRects.append((k, NSRect(x: kx, y: ky, width: x2 - kx - 16, height: TapeDraw.capH)))
            kx = x2
        }
        // list marks kept or dropped: a check after the word when kept
        let ma = TapeDraw.at(Native.text(13), Native.muted)
        let mw = TapeDraw.width("Marks", ma)
        let mx = W - Self.side - 18 - mw - 8 - TapeDraw.capH
        if s.pieces.contains(where: { $0.body != $0.range }) {
            TapeDraw.keyWord("M", "Marks", x: mx, y: ky, color: s.marks ? Native.ink : Native.muted)
            if s.marks { TapeDraw.glyph("check", NSRect(x: W - Self.side - 16, y: ky + 4, width: 16, height: 16), color: Native.ink) }
            actionRects.append((.char("m"), NSRect(x: mx, y: ky, width: W - Self.side - mx, height: TapeDraw.capH)))
        }
        NSGraphicsContext.restoreGraphicsState()
    }

    /// A thing the detector found: the glyph the cards and the reader use for its kind ("amount" is money).
    static func foundGlyph(_ kind: String) -> String? {
        let g = JournalMeta.foundGlyph(kind == "amount" ? "money" : kind)
        return g == "hash" ? nil : g
    }
    static let thingGlyph = ["link": "globe", "date": "calendar", "email": "mail", "person": "user", "project": "folder", "file": "file", "place": "map"]

    /// Wrapped text with the filter's matches on a soft accent tint.
    private func drawText(_ s: String, query: String, x: CGFloat, y: CGFloat, width w: CGFloat, lines n: Int, color: NSColor) {
        let a = TapeDraw.at(Self.font, color, lh: Self.lh, cut: .byWordWrapping)
        let str = NSMutableAttributedString(string: s, attributes: a)
        if !query.isEmpty {
            let folded = PickRules.fold(s) as NSString
            if folded.length == (s as NSString).length {           // folding kept the length: ranges line up
                var at = 0
                while at < folded.length {
                    let r = folded.range(of: query, range: NSRange(location: at, length: folded.length - at))
                    if r.location == NSNotFound || r.length == 0 { break }
                    str.addAttribute(.backgroundColor, value: Native.selected, range: r)
                    at = r.location + r.length
                }
            }
        }
        let lift = ((Self.lh - (Self.font.ascender - Self.font.descender + Self.font.leading)) / 2).rounded()
        str.draw(with: NSRect(x: x, y: y - lift, width: w, height: Self.lh * CGFloat(n)), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    }

    // MARK: input

    override func keyDown(with e: NSEvent) {
        guard let m = model else { return }
        let f = e.modifierFlags
        guard let k = PickKeyMap.map(code: Int(e.keyCode), chars: e.characters ?? "", cmd: f.contains(.command), shift: f.contains(.shift),
                                     alt: f.contains(.option), filtering: m.state.filtering) else { return }
        m.key(k)
    }

    private var down: Int?, dragged = false
    private func piece(at p: NSPoint) -> Int? { rowRects.first { $0.r.contains(p) }?.piece }

    override func mouseDown(with e: NSEvent) {
        guard let m = model else { return }
        let p = convert(e.locationInWindow, from: nil)
        if let l = levelRects.first(where: { $0.1.contains(p) })?.0 { m.state.setLevel(l); needsDisplay = true; return }
        if let k = actionRects.first(where: { $0.1.contains(p) })?.0 { m.key(k); return }
        down = piece(at: p); dragged = false
    }
    override func mouseDragged(with e: NSEvent) {
        guard let m = model, let a = down, let b = piece(at: convert(e.locationInWindow, from: nil)) else { return }
        if b == a && !dragged { return }
        m.state.drag(from: a, to: b, start: !dragged)
        dragged = true; needsDisplay = true
    }
    override func mouseUp(with e: NSEvent) {
        guard let m = model, let a = down else { return }
        if !dragged { m.state.click(a); needsDisplay = true }
        down = nil; dragged = false
    }
    override func scrollWheel(with e: NSEvent) {
        guard let m = model else { return }
        let n = m.state.shown.count
        guard n > 0, abs(e.scrollingDeltaY) > 2 else { return }
        m.state.cursor = max(0, min(n - 1, m.state.cursor + (e.scrollingDeltaY < 0 ? 1 : -1)))
        needsDisplay = true
    }
}

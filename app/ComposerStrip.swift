// Strip style "composer" (setting stripStyle, the default since 14 November 2026). StripRules.swift says where each
// part goes and why; this file holds the state and draws it. One view draws everything (no text fields).
// The band beside the camera housing says the state (left) and his level and the keys (right); the words sit under it,
// large and in the primary text colour, 1 line growing to 4, then the older lines scroll up. In `live` insert mode
// (setting voiceInsert) the words go into the field, so the strip shows the band only: one place where words show.
// Notch-black in both appearances (drawn in the dark tokens). Colour: coral only for live, mint only for "in the field",
// warn only for a side not heard; one of them at a time.
import AppKit

struct StripContent {
    enum Phase { case listening, piece, finishing, armed, kept, inserted, copied, recording, offer, message }
    var phase: Phase = .listening
    var words = ""                    // a note's words (live while listening, the final text in a draft)
    var quiet = false                 // no microphone signal yet
    var insertNext = false            // finishing: ↩ was pressed, the text goes in once it is read
    var held = false                  // live mode finishing: one ↩ held back
    var reason = ""                   // on the clipboard: why
    var place = "", button = "Insert" // a draft: where Return puts it ("→ Claude", "No text field in Finder"), its button
    var inBand = false                // a short message: in the band beside the mark
    var title = "", point = "", time = "", warning = false, call = false
    var rows: [String] = []           // an offer's rows, or a message
    var kind = "", side = ""
    var me: CGFloat = 0, them: CGFloat?
    var wave: [CGFloat] = []          // his level, newest last, 0 ... 1
    var countdown: (Date, Double)?
    var lines = 0                     // lines of words shown (a note grows, never shrinks while it lasts)
    // round three: Return while he speaks puts in what he said so far and the note goes on
    var band = ""                     // the quiet line in place of "Listening": "Inserting → Claude", "In the field"
    var bandOK = false                // the band says it is in the field (mint)
    var waking = false                // the voice engine loads; his audio is kept and goes in when it is ready
    var lang = ""                     // the language pin: "UK" / "EN" after the state word, "" unpinned
}

final class ComposerStrip: StripFace {
    static let shared = ComposerStrip()
    let view = ComposerView()

    private var panel: NSPanel?
    private var hits: NSPanel?
    private let hitView = HitView()
    private var controls: [StripButton] = []
    private var hideToken = 0, layoutGen = 0
    private var screenID: NSNumber?
    private var warned: String?
    private var heldMe: Float = 0, heldThem: Float = 0, levelAt = Date.distantPast, meSeen = false, themSeen = false
    private var countdownTimer: Timer?
    private var bandGen = 0
    // the preview: a made-up housing and menu bar, nothing put on screen
    var previewing = false
    var previewNotch: CGFloat?
    var previewBar: CGFloat = 32
    var previewScreen: CGFloat = 1512
    var previewLive: Bool?

    private var c: StripContent { get { view.c } set { view.c = newValue } }
    /// Words show in the strip only when the field is not typed into while he speaks.
    private var wordsShow: Bool { !(previewLive ?? (Drafter.shared.settings.voiceInsert == "live")) }

    private func make() -> NSPanel {
        let p = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false; p.backgroundColor = .clear; p.hasShadow = false; p.ignoresMouseEvents = true
        p.identifier = OwnChrome.strip   // left out of Drafter's own screen pictures
        p.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 2)
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        p.contentView = view
        return p
    }

    // MARK: the screen and the housing

    private var screen: NSScreen? {
        NSScreen.screens.first { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber) == screenID } ?? NSScreen.main
    }
    private func pin() {
        guard panel?.isVisible != true || !NSScreen.screens.contains(where: { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber) == screenID }) else { return }
        screenID = NSScreen.main?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
    }
    private var notch: CGFloat {
        if let previewNotch { return previewNotch }
        guard let s = screen, s.safeAreaInsets.top > 0, let l = s.auxiliaryTopLeftArea, let r = s.auxiliaryTopRightArea else { return 0 }
        return max(120, s.frame.width - l.width - r.width)
    }
    private var bar: CGFloat {
        if previewing { return previewBar }
        guard let s = screen else { return 24 }
        return s.safeAreaInsets.top > 0 ? s.safeAreaInsets.top : s.frame.maxY - s.visibleFrame.maxY
    }

    var mode: StripMode {
        switch c.phase {
        case .listening, .piece, .finishing, .armed, .kept, .inserted, .copied:
            return .take(lines: c.lines, level: c.phase == .listening || c.phase == .piece, buttons: c.phase == .armed && !controls.isEmpty)
        case .recording: return .long(call: c.call)
        case .offer: return .offer(rows: min(2, c.rows.count))
        case .message: return .message(lines: c.lines, button: !controls.isEmpty, inBand: c.inBand)
        }
    }

    /// Lays the strip out for what it shows now and puts it in place; a new size slides (0.2 s), pinned to its top.
    private func place() {
        let bw = controls.isEmpty ? 0 : controls.reduce(CGFloat(-8)) { $0 + $1.frame.width + 8 }
        let sw = previewing ? previewScreen : (screen?.frame.width ?? 1512)
        let l = StripRules.layout(mode, notch: notch, bar: bar, screen: sw, buttons: bw)
        view.layout = l
        let size = view.outer(l)
        let cur = previewing || panel?.isVisible != true ? size : (panel?.frame.size ?? size)
        view.frame = NSRect(origin: .zero, size: cur)
        var x = l.buttons?.minX ?? 0
        for b in controls {
            if let r = l.buttons { b.setFrameOrigin(NSPoint(x: view.inset(l).left + x, y: cur.height - r.maxY)) }
            b.autoresizingMask = [.minYMargin]
            x += b.frame.width + 8
        }
        guard let p = panel else { return }
        let s = screen
        let midX = previewing ? 0 : (s?.frame.midX ?? 0)
        let topY: CGFloat = previewing ? 0 : {
            guard let s else { return 0 }
            return l.hangs ? s.frame.maxY : s.visibleFrame.maxY - (l.top - bar)
        }()
        let target = NSRect(x: midX - view.inset(l).left - l.centre, y: topY - size.height, width: size.width, height: size.height)
        layoutGen += 1; let gen = layoutGen
        if previewing { view.needsDisplay = true; return }
        if p.isVisible, p.frame.size != target.size, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            hits?.orderOut(nil)
            NSAnimationContext.runAnimationGroup({ ctx in ctx.duration = 0.2; ctx.timingFunction = CAMediaTimingFunction(name: .easeOut); p.animator().setFrame(target, display: true) },
                                                 completionHandler: { [weak self] in
                                                     guard let self, gen == self.layoutGen else { return }
                                                     self.placeHits(target)
                                                 })
        } else {
            if p.frame != target { p.setFrame(target, display: true) }
            DispatchQueue.main.async { [weak self] in
                guard let self, gen == self.layoutGen else { return }
                self.placeHits(target)
            }
        }
        view.needsDisplay = true
    }

    private func placeHits(_ frame: NSRect) {
        guard !controls.isEmpty, !previewing, panel?.isVisible == true else { hits?.orderOut(nil); return }
        if hits == nil {
            let h = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            h.isOpaque = false; h.backgroundColor = .clear; h.hasShadow = false; h.ignoresMouseEvents = false
            h.identifier = OwnChrome.strip
            h.acceptsMouseMovedEvents = true
            h.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 3)
            h.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            h.contentView = hitView
            hits = h
        }
        let u = controls.dropFirst().reduce(controls[0].frame) { $0.union($1.frame) }.insetBy(dx: -4, dy: -3)
        hitView.origin = u.origin
        hits?.setFrame(NSRect(x: frame.minX + u.minX, y: frame.minY + u.minY, width: u.width, height: u.height), display: true)
        hits?.orderFrontRegardless()
    }

    private func setControls(_ list: [StripButton]) {
        controls.forEach { $0.removeFromSuperview() }
        controls = list; list.forEach { view.addSubview($0) }
        hitView.buttons = list
        if list.isEmpty { hits?.orderOut(nil) }
    }
    private func open() {
        hideToken += 1
        if panel == nil { panel = make() }
        pin()
    }
    private func present() { if !previewing { panel?.orderFrontRegardless() } }
    private func close() { layoutGen += 1; panel?.orderOut(nil); hits?.orderOut(nil) }
    private func say(_ label: String) {
        view.setAccessibilityElement(true); view.setAccessibilityRole(.group); view.setAccessibilityLabel(label)
    }
    private func announce(_ text: String) {
        guard !previewing else { return }
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                             userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }
    /// The lines the words need now (a note grows, never shrinks while it lasts).
    private func fit(_ text: String, grow: Bool = true) {
        c.words = text
        let n = wordsShow ? view.lineCount(text) : 0
        let before = c.lines
        c.lines = grow ? max(c.lines, n) : n
        if c.lines != before { place() } else { view.needsDisplay = true }
    }
    private func takePhase(_ p: StripContent.Phase, _ label: String, text: String? = nil) {
        open(); setControls([]); countdownTimer?.invalidate()
        let keep = c.phase == .listening || c.phase == .piece || c.phase == .finishing || c.phase == .armed
        if !keep { c = StripContent() }
        c.phase = p; c.quiet = false
        say(label)
        if let text { c.lines = 0; c.words = ""; fit(text, grow: false) } else { place() }
        present()
    }

    // MARK: a voice note

    func listening() {
        open(); setControls([]); countdownTimer?.invalidate()
        c = StripContent(); meSeen = false
        say("Listening")
        place(); present()
    }

    func level(_ pk: Float, them: Float? = nil) {
        heldMe = max(heldMe, pk); if let them { heldThem = max(heldThem, them) }
        // the audio's rate of calls stops here; Reduce Motion is asked only for the ones drawn (native round)
        guard Date().timeIntervalSince(levelAt) > (c.phase == .recording ? 0.25 : 0.08) else { return }
        let still = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        levelAt = Date()
        meSeen = meSeen || heldMe >= 0.004; themSeen = themSeen || heldThem >= 0.004
        if c.phase == .recording {
            c.me = still ? (meSeen ? 0.3 : 0) : Pill.share(heldMe)
            if them != nil { c.them = still ? (themSeen ? 0.3 : 0) : Pill.share(heldThem) }
            view.needsDisplay = true
        } else if c.phase == .listening || c.phase == .piece {
            if still { c.wave = meSeen ? [0.4] : [] }
            else { c.wave.append(Pill.share(heldMe)); if c.wave.count > 64 { c.wave.removeFirst(c.wave.count - 64) } }
            view.redrawLevel()
        }
        heldMe = 0; heldThem = 0
    }

    /// The live words. Empty while the strip is open: a live-mode piece went into the field.
    func draft(_ text: String) {
        guard panel?.isVisible == true || previewing else { return }
        if text.isEmpty {
            // live mode: a piece went into the field (enter mode has no pieces; an empty draft is noise there)
            if c.phase == .listening, !wordsShow { c.phase = .piece; say("In the field, still listening"); view.needsDisplay = true }
            return
        }
        if c.phase == .piece { c.phase = .listening }
        guard c.phase == .listening else { return }
        fit(text)
    }

    func langMark(_ mark: String) {
        guard panel?.isVisible == true || previewing, c.phase == .listening || c.phase == .piece else { return }
        c.lang = mark; say(mark.isEmpty ? "Listening" : "Listening · " + mark); view.needsDisplay = true
    }

    func note(_ text: String?) {
        guard panel?.isVisible == true || previewing, c.phase == .listening else { return }
        c.quiet = text != nil; say(text == nil ? "Listening" : "No microphone signal"); view.needsDisplay = true
    }

    /// Return while he speaks: the segment so far is on its way to the field; the new segment's words start fresh, the
    /// level goes on. The line says where it goes.
    func segment(_ line: String) {
        guard panel?.isVisible == true || previewing, c.phase == .listening || c.phase == .piece else { return }
        bandGen += 1
        c.phase = .listening; c.band = line; c.bandOK = false; c.words = ""   // the room keeps its size
        say(line + ", still listening")
        view.needsDisplay = true
    }

    /// A segment's insert landed (or went to the clipboard). While he still speaks it is a short mark in the band that
    /// never hides his live words; once the note is over it is the usual receipt.
    func segmentDone(ok: Bool, reason: String) {
        guard c.phase == .listening || c.phase == .piece || c.phase == .finishing else { ok ? inserted() : copied(reason); return }
        bandGen += 1; let gen = bandGen
        c.band = ok ? "In the field" : "On the clipboard · " + reason; c.bandOK = ok
        say(c.band + ", still listening"); announce(ok ? "In the field" : "On the clipboard")
        view.needsDisplay = true
        guard !previewing else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + (ok ? 1.5 : 3)) { [weak self] in
            guard let self, gen == self.bandGen else { return }
            self.c.band = ""; self.c.bandOK = false; self.view.needsDisplay = true
        }
    }

    func waking(_ on: Bool) {
        guard c.waking != on, panel?.isVisible == true || previewing else { return }
        c.waking = on
        if c.phase == .listening { say(on ? "Waking, your words are kept" : "Listening"); view.needsDisplay = true }
    }

    func reading() { finishing(insert: false) }

    func finishing(insert: Bool) {
        guard c.phase != .inserted, c.phase != .recording else { return }
        let was = c.phase
        takePhase(.finishing, insert ? "Finishing, then it goes in" : "Finishing")
        if was != .finishing { c.band = ""; c.bandOK = false }
        c.insertNext = insert || (was == .finishing && c.insertNext)
        view.needsDisplay = true
    }

    func held() {
        guard c.phase == .finishing || c.phase == .listening || c.phase == .piece else { return }
        if c.phase != .finishing { takePhase(.finishing, "Finishing") }
        c.held = true; say("Finishing, press Return again"); announce("Finishing, press Return again")
        view.needsDisplay = true
    }

    func armed(_ text: String) {
        takePhase(.armed, "Draft ready. Return inserts it, Escape drops it.", text: text)
        draftKeys()
        announce("Draft ready")
    }

    /// The draft's keys as buttons (as an offer's): a filled Insert (or Copy where there is no field) and a quiet Drop.
    /// A click does what the key does.
    private func draftKeys() {
        let go = StripButton(c.button, key: StripRules.key(.ret, tight: true), style: .primary) { Talk.shared.flowEvent(.ret) }
        go.toolTip = c.button + ": Return"
        let drop = StripButton("Drop", key: StripRules.key(.esc), style: .quiet) { Talk.shared.flowEvent(.esc) }
        drop.toolTip = "Drop: Esc. The voice note stays in the journal."
        setControls([go, drop])
        place()
    }

    /// Where a draft goes if he presses Return now (Talk reads the focused field, at most 4 times a second).
    func target(_ place: String, button: String) {
        guard c.phase == .armed || previewing else { return }
        let relabel = c.button != button
        c.place = place; c.button = button
        say("Draft ready. " + place)
        if relabel, c.phase == .armed { draftKeys() } else { view.needsDisplay = true }
    }

    func kept(_ text: String) {
        takePhase(.kept, "In the journal. Control Option R inserts it again.", text: text)
        hide(after: VoiceFlowRules.keptFor)
    }

    func landed() { inserted() }

    func inserted() {
        guard panel?.isVisible == true || previewing else { return }
        takePhase(.inserted, "In the field")
        c.lines = 0; c.words = ""; place()
        if !previewing { view.drawIn() }
        announce("In the field")
        hide(after: VoiceFlowRules.shownFor)
    }

    func copied(_ reason: String) {
        takePhase(.copied, "On the clipboard. " + reason)
        c.reason = reason; c.lines = 1; c.words = ""; place()
        announce("On the clipboard")
        hide(after: max(3, VoiceFlowRules.shownFor + 1.5))
    }

    // MARK: a long recording or a call

    func recording(call: Bool, seconds: Int, title: String, outline: [String], event: String = "", shots: Int = 0, warning: String? = nil) {
        let first = c.phase != .recording
        open()
        if first {
            c = StripContent(); c.phase = .recording; c.call = call; c.them = call ? 0 : nil
            meSeen = false; themSeen = false
            // Stop stays in reach for the whole recording; a click arms it, a second within 3 s stops (a stray click never
            // ends a call). Plain, not coral: the live dot is the one coral thing.
            let stop = StripButton("Stop & save", key: StripRules.key(.shiftRightOption), style: .plain, confirm: "Click again to stop") { Talk.shared.stopRecording("the strip") }
            stop.toolTip = "Stop & save: ⇧ Right Option"
            setControls([stop])
            announce(call ? "Recording a call" : "Recording")
        }
        c.call = call
        c.time = String(format: "%d:%02d", seconds / 60, seconds % 60)
        c.title = !event.isEmpty ? event : !title.isEmpty ? title : (call ? "Call" : "Long recording")
        c.warning = warning != nil
        c.point = warning ?? outline.first ?? (call ? "Both sides, on this Mac" : "Your microphone, on this Mac")
        if warning != warned { warned = warning; if let warning { announce(warning) } }
        say((call ? "Recording a call, " : "Recording, ") + c.time)
        if first || panel?.isVisible != true { place() } else { view.needsDisplay = true }
        present()
    }

    // MARK: offers and messages

    func offer(_ rows: [String], kind: String, side: String = "", controls list: [StripButton], seconds: Double) {
        open(); countdownTimer?.invalidate()
        c = StripContent(); c.phase = .offer; c.rows = Array(rows.prefix(3)); c.kind = kind; c.side = side
        setControls(list)
        place(); present()
        c.countdown = (Date(), seconds)
        let step = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 1.0 : 0.1
        if !previewing {
            countdownTimer = Timer.scheduledTimer(withTimeInterval: step, repeats: true) { [weak self] t in
                guard let self, let cd = self.c.countdown, Date().timeIntervalSince(cd.0) < cd.1 else { t.invalidate(); return }
                self.view.needsDisplay = true
            }
        }
        hide(after: seconds)
        let spoken = ([kind] + Array(rows.prefix(3)) + list.map { $0.spoken }).joined(separator: ". ")
        say(spoken); announce(spoken)
    }

    func offerRow(_ i: Int, _ text: String) {
        guard panel?.isVisible == true || previewing, c.phase == .offer, i < c.rows.count else { return }
        c.rows[i] = text; view.needsDisplay = true
    }

    func hide(after: Double = 0) {
        hideToken += 1; let mine = hideToken
        DispatchQueue.main.asyncAfter(deadline: .now() + after) { [weak self] in
            guard let self, mine == self.hideToken else { return }
            self.countdownTimer?.invalidate(); self.close()
        }
    }

    func show(_ text: String, seconds: Double, lines n: Int = 2) {
        message(text, lines: n, button: nil)
        hide(after: seconds)
    }

    func flash(_ text: String, button: StripButton? = nil) {
        message(text, lines: 2, button: button)
        hide(after: button == nil ? 1.8 : 5)
    }

    private func message(_ text: String, lines n: Int, button: StripButton?) {
        open(); countdownTimer?.invalidate()
        c = StripContent(); c.phase = .message
        let t = text.count > 420 ? String(text.prefix(417)) + "…" : text
        c.rows = [t]
        setControls(button.map { [$0] } ?? [])
        c.lines = 1
        // with the housing: one short line sits in the band beside the mark, a second row only for a longer text
        c.inBand = notch > 0
        place()
        if c.inBand, view.fitsOneLine(t), StripRules.problems(view.layout, mode).isEmpty { say(t); present(); return }
        c.inBand = false
        place()   // one line first, to know the room
        c.lines = min(max(1, n), view.linesNeeded(t))
        if c.lines > 1 { place() }
        say(t)
        present()
    }

    // MARK: preview (made-up text only)

    /// Puts a made-up state on the view without the clock (the preview renders only).
    func previewSet(_ f: (inout StripContent) -> Void) { f(&c); place() }
    func previewLevels(_ n: Int) {
        for i in 0..<n { levelAt = .distantPast; heldMe = 0; level(Float(0.004 + 0.18 * abs(sin(Double(i) * 0.7) * sin(Double(i) * 0.23)))) }
    }
    func previewStart(notch: CGFloat, bar: CGFloat, screen: CGFloat = 1512, live: Bool = false) {
        previewing = true; previewNotch = notch; previewBar = bar; previewScreen = screen; previewLive = live
        if panel == nil { panel = make() }
    }

    func preview(_ folder: String) throws {
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        previewStart(notch: 200, bar: { if let s = NSScreen.main, s.safeAreaInsets.top > 0 { return s.safeAreaInsets.top }; return 32 }())
        listening(); draft("A made-up note for the strip")
        try UIShots.composerScene(self, folder + "/listening.png")
    }
}

// MARK: the view

final class ComposerView: NSView {
    var c = StripContent()
    var layout = StripRules.layout(.take(lines: 0, level: true), notch: 200, bar: 32)
    private var drawnAt: Date?
    init() {
        super.init(frame: .zero)
        appearance = NSAppearance(named: .darkAqua)   // merges with the black housing: the dark tokens in both appearances
    }
    required init?(coder: NSCoder) { fatalError() }

    /// Room around the strip: the small outward curves where a hanging strip meets the top edge.
    func inset(_ l: StripLayout) -> NSEdgeInsets { l.hangs ? NSEdgeInsets(top: 0, left: 8, bottom: 0, right: 8) : NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0) }
    func outer(_ l: StripLayout) -> CGSize {
        let i = inset(l); return CGSize(width: l.size.width + i.left + i.right, height: l.size.height + i.top + i.bottom)
    }
    /// A layout rect (y down from the strip's top) in this view (y up, pinned to the top while the panel slides).
    func R(_ r: CGRect) -> NSRect {
        let i = inset(layout)
        return NSRect(x: i.left + r.minX, y: bounds.height - i.top - r.maxY, width: r.width, height: r.height)
    }

    func drawIn() {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { drawnAt = nil; return }
        drawnAt = Date()
        for k in 1...3 { DispatchQueue.main.asyncAfter(deadline: .now() + 0.045 * Double(k)) { [weak self] in self?.needsDisplay = true } }
    }
    func redrawLevel() {
        if let l = layout.level { setNeedsDisplay(R(l).insetBy(dx: -2, dy: -4)) } else { needsDisplay = true }
    }

    // MARK: type

    static let wordsFont = Native.text(14.5)
    private var stateFont: NSFont { Native.text(12, .medium) }
    private var keyFont: NSFont { Native.text(11) }
    private func a(_ f: NSFont, _ col: NSColor, align: NSTextAlignment = .left, wrap: Bool = false, lh: CGFloat = 20) -> [NSAttributedString.Key: Any] {
        let p = NSMutableParagraphStyle(); p.alignment = align; p.lineBreakMode = wrap ? .byWordWrapping : .byTruncatingTail
        if wrap { p.minimumLineHeight = lh; p.maximumLineHeight = lh }
        return [.font: f, .foregroundColor: col, .paragraphStyle: p]
    }
    private func line(_ s: NSAttributedString, _ r: CGRect) {
        let rr = R(r), h = ceil(s.size().height)
        s.draw(with: NSRect(x: rr.minX, y: (rr.midY - h / 2).rounded(), width: rr.width, height: h), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    }
    private func line(_ s: String, _ r: CGRect, _ at: [NSAttributedString.Key: Any]) { line(NSAttributedString(string: s, attributes: at), r) }

    /// The room one line of words has (the strip's width less its sides).
    private var room: CGFloat { (layout.size.width - 36) - 2 }
    private func shownLines(_ t: String) -> [String] {
        let f = ComposerView.wordsFont
        return StripRules.lines(t, room: room) { ($0 as NSString).size(withAttributes: [.font: f]).width }
    }
    func lineCount(_ t: String) -> Int { shownLines(t).count }

    /// The text fits the layout's text rect on one line.
    func fitsOneLine(_ t: String) -> Bool {
        guard let r = layout.text else { return false }
        return (t as NSString).size(withAttributes: [.font: Native.text(13.5)]).width <= r.width
    }

    func linesNeeded(_ t: String) -> Int {
        guard let r = layout.text else { return 1 }
        let at = a(Native.text(13.5), Native.ink, wrap: true)
        let h = (t as NSString).boundingRect(with: NSSize(width: r.width, height: 1000), options: [.usesLineFragmentOrigin], attributes: at).height
        return max(1, Int(ceil(h / 20)))
    }

    /// The state word and the keys for a note's phase.
    private var stateWord: String {
        switch c.phase {
        case .listening: return (!c.band.isEmpty ? c.band : c.quiet ? "No microphone signal" : c.waking ? "Waking" : "Listening") + langWord
        case .piece: return "In the field · listening" + langWord
        case .finishing: return !c.band.isEmpty ? c.band : "Finishing"
        case .armed: return "Draft ready"
        case .kept: return "In the journal"
        case .inserted: return "In the field"
        case .copied: return "On the clipboard"
        default: return ""
        }
    }
    private var langWord: String { c.lang.isEmpty ? "" : " · " + c.lang }
    /// Key hints: a key, then the verb it does ("↩ Insert").
    private var keys: [(String, String)] {
        switch c.phase {
        case .listening, .piece: return [(StripRules.key(.ret, tight: true), "Insert"), (StripRules.key(.rightOption, tight: true), "Stop")]
        case .finishing: return c.held ? [("↩", "Press again")] : c.insertNext ? [("", "Goes in next"), ("Esc", "Drop")] : [("Esc", "Drop")]
        case .armed: return []                      // the buttons under the words say it
        case .kept:
            let st = Drafter.shared.settings
            return StripRules.againKey(tap: st.againTap && st.voice, chord: st.againKey).map { [($0, "Insert again")] } ?? []
        case .inserted: return [("⌘Z", "Undo")]
        case .copied: return [("⌘V", "Paste")]
        default: return []
        }
    }
    private func keysText(_ list: [(String, String)]) -> NSAttributedString {
        let s = NSMutableAttributedString()
        for (i, (k, v)) in list.enumerated() {
            if i > 0 { s.append(NSAttributedString(string: "   ", attributes: a(keyFont, Native.muted))) }
            if !k.isEmpty { s.append(NSAttributedString(string: k + " ", attributes: a(Native.text(12, .semibold), Native.ink.withAlphaComponent(0.92), align: .right))) }
            s.append(NSAttributedString(string: v, attributes: a(keyFont, c.phase == .armed ? Native.ink : Native.muted, align: .right)))   // ↩ Insert reads at once
        }
        let p = NSMutableParagraphStyle(); p.alignment = .right; p.lineBreakMode = .byTruncatingHead
        s.addAttribute(.paragraphStyle, value: p, range: NSRange(location: 0, length: s.length))
        return s
    }

    // MARK: draw

    override func draw(_ dirty: NSRect) {
        let l = layout
        drawGround(l)
        drawMark(l)
        switch c.phase {
        case .recording: drawLong(l)
        case .offer: drawOffer(l)
        case .message: drawMessage(l)
        default: drawTake(l)
        }
    }

    private func drawGround(_ l: StripLayout) {
        let b = R(l.bounds)
        NSColor.black.setFill()
        if !l.hangs {   // no housing: a capsule just under the menu bar
            let r = min(16, b.height / 2)
            NSBezierPath(roundedRect: b, xRadius: r, yRadius: r).fill(); return
        }
        // it grows out of the housing: square at the top edge, round below, small outward curves where it meets the top
        let r: CGFloat = b.height > 44 ? 18 : 12
        let p = NSBezierPath(roundedRect: b, xRadius: r, yRadius: r)
        p.append(NSBezierPath(rect: NSRect(x: b.minX, y: b.maxY - r, width: b.width, height: r)))
        p.fill()
        fillet(corner: NSPoint(x: b.minX, y: b.maxY), left: true, f: 8)
        fillet(corner: NSPoint(x: b.maxX, y: b.maxY), left: false, f: 8)
    }
    /// A concave curve outside `corner` along the screen's top edge: the square of side f beside it, less a quarter circle.
    private func fillet(corner p: NSPoint, left: Bool, f: CGFloat) {
        let dx: CGFloat = left ? -f : f
        let path = NSBezierPath()
        path.move(to: NSPoint(x: p.x + dx, y: p.y)); path.line(to: p); path.line(to: NSPoint(x: p.x, y: p.y - f))
        path.appendArc(withCenter: NSPoint(x: p.x + dx, y: p.y - f), radius: f, startAngle: left ? 0 : 180, endAngle: 90, clockwise: !left)
        path.close(); path.fill()
    }

    private func drawMark(_ l: StripLayout) {
        let m = R(l.mark)
        func dot(_ col: NSColor, ring: Bool = false) {
            let d = NSRect(x: m.midX - 4, y: m.midY - 4, width: 8, height: 8)
            if ring { col.setStroke(); let p = NSBezierPath(ovalIn: d.insetBy(dx: 0.75, dy: 0.75)); p.lineWidth = 1.5; p.stroke() }
            else { col.setFill(); NSBezierPath(ovalIn: d).fill() }
        }
        switch c.phase {
        case .listening: c.quiet ? dot(Native.faint, ring: true) : dot(Native.coral)
        case .piece: TapeDraw.glyph("check", m, color: Native.mint)
        case .finishing: TapeDraw.glyph("waves", m, color: Native.muted)
        case .armed: TapeDraw.glyph("edit", m, color: Native.ink)
        case .kept: TapeDraw.glyph("bookmark", m, color: Native.muted)
        case .inserted:
            let step = drawnAt.map { min(1, CGFloat(Date().timeIntervalSince($0) / 0.135) + 0.34) } ?? 1
            NSGraphicsContext.saveGraphicsState(); NSRect(x: m.minX, y: m.minY, width: (m.width * step).rounded(), height: m.height).clip()
            TapeDraw.glyph("check", m, color: Native.mint)
            NSGraphicsContext.restoreGraphicsState()
        case .copied: TapeDraw.glyph("copy", m, color: Native.muted)
        case .recording: c.warning ? dot(Native.faint, ring: true) : dot(Native.coral)
        case .offer: TapeDraw.glyph(c.kind == "Call" ? "phone" : "chat", m, color: Native.muted)
        case .message: TapeDraw.glyph("check", m, color: Native.muted)
        }
    }

    private func drawTake(_ l: StripLayout) {
        if let s = l.state { line(stateWord, s, a(stateFont, c.phase == .armed ? Native.ink : c.bandOK && (c.phase == .listening || c.phase == .finishing) ? Native.mint : Native.muted)) }
        if let lv = l.level { drawLevel(lv) }
        if c.phase == .armed, let h = l.hints {    // where Return puts the draft, as the focus moves
            line(c.place, h, a(stateFont, c.button == "Insert" ? Native.ink : Native.warn, align: .right))
        } else if let h = l.hints { line(keysText(keys), h) }
        guard let r = l.text else { return }
        if c.phase == .copied {
            line(c.reason, CGRect(x: r.minX, y: r.minY, width: r.width, height: StripRules.line), a(ComposerView.wordsFont, Native.ink))
            return
        }
        let ls = shownLines(c.words)
        guard !ls.isEmpty else { return }
        // the newest line at the bottom of the room; while he speaks the newest two words, still changing, one step quieter
        let n = ls.count, top = r.minY + r.height - CGFloat(n) * StripRules.line
        let quietFrom = c.phase == .listening ? StripRules.newestFrom(ls[n - 1], words: 2) : ls[n - 1].count
        for (i, t) in ls.enumerated() {
            let row = CGRect(x: r.minX, y: top + CGFloat(i) * StripRules.line, width: r.width, height: StripRules.line)
            if i == n - 1, quietFrom < t.count {
                let s = NSMutableAttributedString(string: String(t.prefix(quietFrom)), attributes: a(ComposerView.wordsFont, Native.ink))
                s.append(NSAttributedString(string: String(t.dropFirst(quietFrom)), attributes: a(ComposerView.wordsFont, Native.muted)))
                line(s, row)
            } else {
                line(t, row, a(ComposerView.wordsFont, i == 0 && t.hasPrefix("… ") ? Native.muted : Native.ink))
            }
        }
    }

    /// His level: small bars, the newest nearest the housing's side away from it (they run right to left).
    private func drawLevel(_ lv: CGRect) {
        let r = R(lv)
        let live = c.phase == .listening && !c.quiet
        let n = Int(r.width / 4), mid = r.midY.rounded()
        (live ? Native.muted : Native.key).setFill()
        for i in 0..<n {
            let v: CGFloat = i < c.wave.count ? c.wave[c.wave.count - 1 - i] : 0
            let h = max(2, ((2 + v * (r.height - 2)) / 2).rounded() * 2)
            let x = r.minX + CGFloat(i) * 4
            NSBezierPath(roundedRect: NSRect(x: x, y: mid - h / 2, width: 2, height: h), xRadius: 1, yRadius: 1).fill()
        }
    }

    private func drawLong(_ l: StripLayout) {
        if let s = l.state { line((c.call ? "Call · " : "Recording · ") + c.time, s, a(stateFont, Native.muted)) }
        if let t = l.text { line(c.title, t, a(Native.text(16), Native.ink)) }
        let sides: [(String, CGFloat, NSColor)] = [("me", c.me, Native.ink)] + (c.them.map { [("them", $0, Native.muted)] } ?? [])
        for (i, (name, v, col)) in sides.enumerated() where i < l.levels.count {
            let r = R(l.levels[i])
            Native.key.setFill(); NSBezierPath(roundedRect: r, xRadius: 2, yRadius: 2).fill()
            if v > 0 { col.setFill(); NSBezierPath(roundedRect: NSRect(x: r.minX, y: r.minY, width: max(4, (r.width * v).rounded()), height: r.height), xRadius: 2, yRadius: 2).fill() }
            if i < l.labels.count { line(name, l.labels[i], a(Native.text(11), Native.muted)) }
        }
        if let t2 = l.text2 {
            if c.warning {
                let s = NSMutableAttributedString(string: "⚠ ", attributes: a(Native.text(13), Native.warn))
                s.append(NSAttributedString(string: c.point, attributes: a(Native.text(13), Native.ink)))
                line(s, t2)
            } else {
                line(c.point, t2, a(Native.text(13), Native.muted))
            }
        }
    }

    private func drawOffer(_ l: StripLayout) {
        if let s = l.state { line(c.side.isEmpty ? c.kind : c.kind + " · " + c.side, s, a(stateFont, Native.muted)) }
        if let t = l.text, let q = c.rows.first { line(q, t, a(Native.text(16), Native.ink)) }
        if let t2 = l.text2, c.rows.count > 1 { line(c.rows.dropFirst().joined(separator: " · "), t2, a(Native.text(13), Native.muted)) }
        if let cd = l.countdown, let (from, secs) = c.countdown {
            let left = max(0, 1 - Date().timeIntervalSince(from) / secs), r = R(cd)
            Native.faint.setFill()
            NSRect(x: r.minX, y: r.minY, width: (r.width * left).rounded(), height: r.height).fill()
        }
    }

    private func drawMessage(_ l: StripLayout) {
        guard let r = l.text, let t = c.rows.first else { return }
        if c.lines > 1 { (t as NSString).draw(with: R(r), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: a(Native.text(13.5), Native.ink, wrap: true)) }
        else { line(t, r, a(Native.text(13.5), Native.ink)) }
    }
}

extension UIShots {
    /// The composer on a made-up top of the screen: desktop, menu bar, the housing drawn in black.
    static func composerScene(_ s: ComposerStrip, _ path: String) throws {
        let v = s.view, l = v.layout
        let bad = StripRules.problems(l, s.mode)
        precondition(bad.isEmpty, "composer \(path): \(bad)")
        try notchScene(v, path, notch: l.notch.width, bar: s.previewBar, centre: v.inset(l).left + l.centre,
                       top: l.hangs ? 0 : l.top, floating: !l.hangs)
    }
    /// A strip on a made-up top of the screen: desktop, menu bar, the housing drawn in black, the strip with its
    /// `centre` under the screen's centre and its top `top` below the screen's top edge.
    static func notchScene(_ view: NSView, _ path: String, notch: CGFloat, bar: CGFloat, centre: CGFloat, top: CGFloat, floating: Bool) throws {
        guard let img = bitmap(view) else { return }
        let w = max(820, 2 * max(centre, view.bounds.width - centre) + 80), h = max(view.bounds.height + max(0, top) + 30, bar + 60)
        try picture(NSSize(width: w, height: h), path) { r in
            scene(r, notch: notch, bar: bar)
            img.over(NSRect(x: (w / 2 - centre).rounded(), y: h - top - view.bounds.height, width: view.bounds.width, height: view.bounds.height))
        }
    }
    /// The made-up desktop, menu bar and housing.
    static func scene(_ r: NSRect, notch: CGFloat, bar: CGFloat) {
        let dark = Native.dark, w = r.width, h = r.height
        NSColor.underPageBackgroundColor.setFill(); r.fill()
        NSColor.windowBackgroundColor.withAlphaComponent(0.92).setFill()
        NSRect(x: 0, y: h - bar, width: w, height: bar).fill()
        let menu: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 13, weight: .regular), .foregroundColor: dark ? NSColor.white : NSColor.black]
        ("  Notes    File    Edit    View" as NSString).draw(at: NSPoint(x: 8, y: h - bar + (bar - 16) / 2), withAttributes: menu)
        ("12:40" as NSString).draw(at: NSPoint(x: w - 52, y: h - bar + (bar - 16) / 2), withAttributes: menu)
        if notch > 0 {
            NSColor.black.setFill()
            NSBezierPath(roundedRect: NSRect(x: (w - notch) / 2, y: h - bar, width: notch, height: bar), xRadius: 8, yRadius: 8).fill()
            NSRect(x: (w - notch) / 2, y: h - 10, width: notch, height: 10).fill()
        }
    }
}

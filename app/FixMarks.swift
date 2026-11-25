// Visible undo for autocorrect (2026-11-01, as on the iPad). A word Drafter fixed keeps a thin dotted underline until
// the sentence ends (. ! ? or Return), the field or app changes, or two minutes pass. The mouse over it, or the caret
// in it, shows his own word in a small chip above; a click on the chip, or Tab while the caret is in the word, puts his
// word back and keeps it (data/autocorrect-keep.txt: never fixed again). Backspace right after a fix still works too.
// Native fields: the word is a UTF-16 range of the value. Chromium and Electron (Beeper, Claude, Chrome): text markers.
import AppKit
import ApplicationServices

final class FixMarks {
    static let shared = FixMarks()

    final class Mark {
        let el: AXUIElement, pid: pid_t
        let word: String, old: String, kind: String, wasUk: Bool, at = Date()
        var loc = -1                                  // native field: start of the word in the value (UTF-16)
        var lead: String?                             // native field: the few characters just before it, to find it again
        var start: AXTextMarker?, end: AXTextMarker?  // web field: the word as text markers
        var rect: CGRect?                             // AX (top-left) screen coordinates
        let line = Dots()
        let panel: NSPanel
        init(el: AXUIElement, pid: pid_t, word: String, old: String, kind: String, wasUk: Bool) {
            AXUIElementSetMessagingTimeout(el, 0.15)
            self.el = el; self.pid = pid; self.word = word; self.old = old; self.kind = kind; self.wasUk = wasUk
            panel = FixMarks.overlay()
            panel.contentView = line
        }
    }

    private(set) var marks: [Mark] = []
    private let chipPanel = FixMarks.overlay()
    private let chipBox = Ground(), chipText = NSTextField(labelWithString: ""), chipMark = KindMark()
    private var shown: Mark?, byCaret = false, leftAt: Date?, hover: (mark: Mark, since: Date)?
    private var timer: Timer?, tick = 0, refreshSeq = 0

    init() {
        chipMark.kind = .fix
        chipText.font = Native.text(13); chipText.textColor = Native.ink; chipText.lineBreakMode = .byClipping
        let v = NSView(); chipPanel.contentView = v
        v.addSubview(chipBox); chipBox.addSubview(chipMark); chipBox.addSubview(chipText)
    }

    static func overlay() -> NSPanel {
        let p = NSPanel(contentRect: .zero, styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: true)
        p.isOpaque = false; p.backgroundColor = .clear; p.hasShadow = false
        p.level = .popUpMenu; p.ignoresMouseEvents = true; p.hidesOnDeactivate = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        return p
    }

    /// Tab takes the chip: only while the caret is in the fixed word and the chip shows.
    var tabReady: Bool { shown != nil && byCaret && chipPanel.isVisible }
    var chipVisible: Bool { chipPanel.isVisible }

    // MARK: adding

    /// Right after Autocorrect.apply: find the new word before the caret once its key events have landed.
    func add(new: String, old: String, kind: String, wasUk: Bool, el: AXUIElement, pid: pid_t, markers: Bool, tries: Int = 3) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            guard let now = Focus.focused(), CFEqual(now, el), NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { return }
            let word = String(new.dropLast()), was = String(old.dropLast())
            guard !word.isEmpty else { return }
            let m = Mark(el: el, pid: pid, word: word, old: was, kind: kind, wasUk: wasUk)
            if !markers, self.placeNative(m, new: new) || self.placeMarkers(m) { self.keep(m); return }
            if markers, self.placeMarkers(m) { self.keep(m); return }
            if tries > 1 { self.add(new: new, old: old, kind: kind, wasUk: wasUk, el: el, pid: pid, markers: markers, tries: tries - 1) }
            else { log("fix mark: word not found") }
        }
    }

    private func placeNative(_ m: Mark, new: String) -> Bool {
        guard let value: String = Focus.attr(m.el, kAXValueAttribute), let r = Focus.range(m.el), r.length == 0 else { return false }
        // he may have typed on before the key events landed: the nearest copy of the new word before the caret
        let ns = value as NSString, c = min(max(r.location, 0), ns.length), n = (new as NSString).length
        guard c >= n else { return false }
        let lo = max(0, c - n - 40), found = ns.range(of: new, options: .backwards, range: NSRange(location: lo, length: c - lo))
        guard found.location != NSNotFound else { return false }
        m.loc = found.location
        m.rect = Focus.bounds(m.el, m.loc, (m.word as NSString).length)
        return m.rect != nil
    }

    private func placeMarkers(_ m: Mark) -> Bool {
        // walk back from the caret (he may have typed on) until the text from here starts with the new word and its space
        guard let caret = caretMarker(m.el) else { return false }
        let n = (m.word as NSString).length
        var back = [caret], found = -1
        for i in 1...(n + 25) {
            guard let p = prev(m.el, back[i - 1]) else { return false }
            back.append(p)
            if i >= n + 1, let t = text(m.el, p, caret), same(String(t.prefix(m.word.count + 1)), m.word + " ") { found = i; break }
        }
        guard found > 0 else { return false }
        let s = back[found], e = back[found - n]
        guard same(text(m.el, s, e), m.word) else { return false }
        m.start = s; m.end = e
        m.rect = box(m.el, s, e)
        return m.rect != nil
    }

    /// Fix chip fixes (app/Proof.swift, from the reader check): each new word at a known place. Native: `loc` is its UTF-16 start in the
    /// value; web: `back` is the UTF-16 distance from its start to the caret, found in one walk back for all of them.
    func addAt(_ words: [(word: String, old: String, loc: Int?, back: Int?)], el: AXUIElement, pid: pid_t) {
        var walk: [AXTextMarker]?
        // the marker walk, made once for all words, only when a word needs it (a web field, or a range with no bounds:
        // Chrome's rich boxes answer the range but not its bounds)
        func markers() -> [AXTextMarker] {
            if let walk { return walk }
            var w: [AXTextMarker] = []
            let far = words.compactMap { $0.back }.max() ?? 0
            if far > 0, let c = caretMarker(el) {
                w = [c]
                for _ in 0..<(far + 30) { guard let p = prev(el, w.last!) else { break }; w.append(p) }
            }
            walk = w
            return w
        }
        var placed = 0
        for w in words {
            let m = Mark(el: el, pid: pid, word: w.word, old: w.old, kind: "proof", wasUk: false)
            let n = (w.word as NSString).length
            if let loc = w.loc { m.loc = loc; m.rect = Focus.bounds(el, loc, n) }
            if m.rect == nil, let d = w.back {
                let walk = markers()
                // one step per UTF-16 unit almost always; look a little past it for line breaks
                for i in ([d] + Array((d + 1)...(d + 30)) + [d - 1, d - 2]) where i >= n && i < walk.count {
                    if same(text(el, walk[i], walk[i - n]), w.word) { m.start = walk[i]; m.end = walk[i - n]; m.rect = box(el, walk[i], walk[i - n]); break }
                }
            }
            if m.rect != nil { keep(m, max: 6); placed += 1 }
        }
        if placed < words.count { log("fix mark: \(words.count - placed) proofread words not found") }
    }

    private func keep(_ m: Mark, max: Int = 3) {
        marks.append(m)
        while marks.count > max { drop(marks[0]) }
        draw(m)
        if timer == nil {
            timer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] _ in self?.beat() }
        }
        log("fix mark: \(m.kind), \(m.start == nil ? "native" : "markers")")
    }

    // MARK: keeping them right

    /// Is the mark still on its word? Native: find it again near where it was if text before it changed.
    private func valid(_ m: Mark) -> Bool {
        if let s = m.start, let e = m.end { return same(text(m.el, s, e), m.word) }
        let n = (m.word as NSString).length
        var r = CFRange(location: m.loc, length: n)
        if m.lead != nil, m.loc >= 0, let arg = AXValueCreate(.cfRange, &r), ax(m.el, kAXStringForRangeParameterizedAttribute as String, arg) as? String == m.word { return true }
        guard let value: String = Focus.attr(m.el, kAXValueAttribute) else { return false }
        let ns = value as NSString
        func lead(_ at: Int) -> String { ns.substring(with: NSRange(location: max(0, at - 8), length: at - max(0, at - 8))) }
        if m.loc >= 0, m.loc + n <= ns.length, ns.substring(with: NSRange(location: m.loc, length: n)) == m.word {
            if m.lead == nil { m.lead = lead(m.loc) }
            return true
        }
        // text before it changed: the word again nearby, only where it is the one place with the same characters before
        // it (Codex review 2026-11-01: the mark moved to another copy of the word, and undo changed that one)
        guard let want = m.lead else { return false }
        let lo = max(0, m.loc - 200), hi = min(ns.length, m.loc + n + 200)
        guard hi > lo else { return false }
        var hits: [Int] = [], from = lo
        while from < hi {
            let f = ns.range(of: m.word, options: [], range: NSRange(location: from, length: hi - from))
            guard f.location != NSNotFound else { break }
            if lead(f.location) == want { hits.append(f.location) }
            from = f.location + 1
        }
        guard hits.count == 1 else { return false }
        m.loc = hits[0]
        return true
    }

    private func measure(_ m: Mark) {
        if let s = m.start, let e = m.end { m.rect = box(m.el, s, e) } else { m.rect = Focus.bounds(m.el, m.loc, (m.word as NSString).length) }
        // scrolled out of the field: no line
        if let r = m.rect, let f = Focus.frame(m.el), !f.insetBy(dx: -2, dy: -2).contains(CGPoint(x: r.midX, y: r.midY)) { m.rect = nil }
    }

    private func draw(_ m: Mark) {
        guard let r = m.rect, r.width > 2 else { m.panel.orderOut(nil); return }
        let c = Ghost.shared.cocoa(r)
        m.panel.setFrame(NSRect(x: c.minX, y: c.minY - 1, width: c.width, height: 2), display: true)
        m.line.needsDisplay = true
        m.panel.orderFrontRegardless()
        note()
    }

    /// Check every mark again: field, app, words, place on screen.
    func refresh() {
        guard !marks.isEmpty else { return }
        let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let focused = Focus.focused()
        for m in marks {
            guard front == m.pid, let f = focused, CFEqual(f, m.el), Date().timeIntervalSince(m.at) < 120, valid(m) else { drop(m); continue }
            measure(m); draw(m)
        }
        if let s = shown { if marks.contains(where: { $0 === s }) { layoutChip(s) } else { hideChip() } }
    }

    private func beat() {
        tick += 1
        if tick % 4 == 0 { refresh() }
        guard !marks.isEmpty else { return }
        // the mouse over a fixed word (or over its chip) shows his word
        let p = NSEvent.mouseLocation
        // the chip covers the line above, so it waits for the mouse to rest on the word (0.3 s), not pass over it
        if let m = marks.last(where: { $0.rect.map { Ghost.shared.cocoa($0).insetBy(dx: -2, dy: -3).contains(p) } ?? false }) {
            leftAt = nil
            if hover?.mark !== m { hover = (m, Date()) }
            if shown !== m || !chipPanel.isVisible, Date().timeIntervalSince(hover!.since) >= 0.3 { show(m, caret: false) }
            return
        }
        hover = nil
        if shown != nil, !byCaret {
            if chipPanel.isVisible, chipPanel.frame.insetBy(dx: -4, dy: -4).contains(p) { leftAt = nil; return }
            if leftAt == nil { leftAt = Date() } else if Date().timeIntervalSince(leftAt!) > 0.35 { hideChip() }
        }
    }

    /// The caret in a fixed word: the chip shows, with Tab on it.
    func checkCaret() {
        guard !marks.isEmpty, let el = Focus.focused() else { if byCaret { hideChip() }; return }
        for m in marks.reversed() where CFEqual(el, m.el) {
            if let s = m.start, let e = m.end {
                guard let c = caretMarker(el), let upTo = text(el, s, c) else { continue }
                if !upTo.isEmpty, same(String(m.word.prefix(upTo.count)), upTo), upTo.count <= m.word.count, text(el, c, e) != nil {
                    show(m, caret: true); return
                }
            } else if let r = Focus.range(el), r.length == 0, r.location >= m.loc, r.location <= m.loc + (m.word as NSString).length {
                show(m, caret: true); return
            }
        }
        if byCaret { hideChip() }
    }

    // MARK: the chip

    private func show(_ m: Mark, caret: Bool) {
        shown = m; byCaret = caret; leftAt = nil
        layoutChip(m)
    }

    private func layoutChip(_ m: Mark) {
        guard let r = m.rect else { hideChip(); return }
        chipPanel.setFrame(chipFrame(m.old, over: r), display: true)
        chipPanel.orderFrontRegardless()
        note()
    }

    /// His own word in the chip, laid out; the chip's frame just above the word (AX rect, top-left).
    private func chipFrame(_ old: String, over r: CGRect) -> NSRect {
        let c = Ghost.shared.cocoa(r)
        chipText.stringValue = old
        chipText.sizeToFit()
        // no tab keycap (1 November 2026): Tab in the word still puts his word back
        let h = max(30, chipText.frame.height + 12)
        let w = 10 + 16 + 8 + chipText.frame.width + 12
        chipBox.frame = NSRect(x: 0, y: 0, width: w, height: h)
        chipMark.frame = NSRect(x: 10, y: ((h - 16) / 2).rounded(), width: 16, height: 16)
        chipText.frame.origin = NSPoint(x: 34, y: ((h - chipText.frame.height) / 2).rounded())
        chipBox.needsDisplay = true
        return NSRect(x: c.minX - 34, y: c.maxY + 3, width: w, height: h)   // his word stands over the fixed one
    }

    /// Preview (`--ui-preview`): the chip over a made-up word, laid out and never put on the screen.
    func previewChip(old: String, word: CGRect) -> NSPanel {
        chipPanel.setFrame(chipFrame(old, over: word), display: false)
        return chipPanel
    }

    func hideChip() { let was = chipPanel.isVisible; chipPanel.orderOut(nil); shown = nil; byCaret = false; leftAt = nil; if was { note() } }

    /// A click on the chip (CG point, top-left): Keys swallows it and calls `take`.
    func hitChip(_ p: CGPoint) -> Bool {
        guard shown != nil, chipPanel.isVisible else { return false }
        let h = NSScreen.screens.first?.frame.height ?? 0
        return chipPanel.frame.insetBy(dx: -2, dy: -2).contains(NSPoint(x: p.x, y: h - p.y))
    }

    // MARK: putting his word back

    func take(_ how: String) {
        guard let m = shown else { return }
        hideChip()
        guard let el = Focus.focused(), CFEqual(el, m.el), NSWorkspace.shared.frontmostApplication?.processIdentifier == m.pid, valid(m) else {
            drop(m); Ghost.shared.flash("Text has changed"); return
        }
        Keys.shared.cancel()
        var after = 0   // characters between the word and the caret: the caret goes back there after the swap
        // Chromium applies a selection set through AX a moment later (2026-11-01: the read-back came too early, the word
        // stayed selected and his next key typed over it). So: wait for it, and on any failure put the caret back.
        func settled(_ ok: () -> Bool) -> Bool {
            for i in 0..<8 { if ok() { return true }; if i < 7 { usleep(25_000) } }
            return false
        }
        if let s = m.start, let e = m.end {
            let caret = caretMarker(el)
            if let c = caret, let upTo = text(el, s, c), same(String(upTo.prefix(m.word.count)), m.word) { after = upTo.count - m.word.count }
            let range = AXTextMarkerRangeCreate(nil, s, e)
            guard AXUIElementSetAttributeValue(el, "AXSelectedTextMarkerRange" as CFString, range) == .success,
                  settled({ same(selected(el), m.word) }) else {
                if let c = caret { AXUIElementSetAttributeValue(el, "AXSelectedTextMarkerRange" as CFString, AXTextMarkerRangeCreate(nil, c, c)) }
                drop(m); Ghost.shared.flash("Could not put it back"); log("fix mark: selection did not take (markers)"); return
            }
            Focus.typeText(m.old)
        } else {
            let n = (m.word as NSString).length
            let was = Focus.range(el)
            if let r = was, r.length == 0, r.location >= m.loc + n,
               let v: String = Focus.attr(el, kAXValueAttribute) {
                after = ((v as NSString).substring(with: NSRange(location: m.loc + n, length: r.location - m.loc - n))).count
            }
            var sel = CFRange(location: m.loc, length: n)
            guard let arg = AXValueCreate(.cfRange, &sel), AXUIElementSetAttributeValue(el, kAXSelectedTextRangeAttribute as CFString, arg) == .success,
                  settled({ Focus.range(el).map { $0.location == m.loc && $0.length == n } ?? false }) else {
                if var back = was, let a = AXValueCreate(.cfRange, &back) { AXUIElementSetAttributeValue(el, kAXSelectedTextRangeAttribute as CFString, a) }
                drop(m); Ghost.shared.flash("Could not put it back"); log("fix mark: selection did not take (range)"); return
            }
            let app = NSWorkspace.shared.frontmostApplication
            if app.map({ Focus.isWeb($0) }) == true
                || Focus.setSelectedText(el, m.old) != .success {
                Focus.typeText(m.old)
            }
        }
        if after > 0 { FixMarks.arrowRight(after) }
        // the keyboard goes back only when nothing was typed after the fix but its space
        if m.kind.hasPrefix("layout"), after <= 1 { KeyLayout.select(uk: m.wasUk) }
        Autocorrect.spared.insert(m.old.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: .punctuationCharacters).lowercased())   // typo hold
        Autocorrect.keepWord(m.old)
        Autocorrect.last = nil
        drop(m)
        log("autocorrect undone by \(how) (\(m.kind))")
    }

    // MARK: ending

    func drop(_ m: Mark) {
        m.panel.orderOut(nil)
        marks.removeAll { $0 === m }
        if shown === m { hideChip() }
        if marks.isEmpty { timer?.invalidate(); timer = nil }
        note()
    }

    func clear() { for m in marks { drop(m) } }

    /// Every key while marks are up (from Keys): sentence end clears them; anything else checks them shortly after.
    func key(_ code: Int64, typed: String) {
        if code == 36 || code == 76 || typed.contains(where: { ".!?…".contains($0) }) { DispatchQueue.main.async { self.clear() }; return }
        if code == 53, chipVisible { DispatchQueue.main.async { self.hideChip() } }
        settle(0.15)
    }

    /// A click or a scroll: the caret or the page moved.
    func moved(scroll: Bool) {
        if scroll { for m in marks { m.panel.orderOut(nil) } ; if !byCaret { hideChip() } }
        settle(scroll ? 0.25 : 0.1)
    }

    private func settle(_ after: Double) {
        refreshSeq += 1
        let seq = refreshSeq
        DispatchQueue.main.asyncAfter(deadline: .now() + after) {
            guard seq == self.refreshSeq else { return }
            self.refresh(); self.checkCaret()
        }
    }

    // MARK: text markers (Chromium, Electron)

    func ax(_ el: AXUIElement, _ name: String, _ arg: CFTypeRef) -> CFTypeRef? {
        var v: CFTypeRef?
        return AXUIElementCopyParameterizedAttributeValue(el, name as CFString, arg, &v) == .success ? v : nil
    }
    func selected(_ el: AXUIElement) -> String? {
        var r: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, "AXSelectedTextMarkerRange" as CFString, &r) == .success, let r,
              CFGetTypeID(r) == AXTextMarkerRangeGetTypeID() else { return nil }
        return ax(el, "AXStringForTextMarkerRange", r) as? String
    }
    func caretMarker(_ el: AXUIElement) -> AXTextMarker? {
        var r: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, "AXSelectedTextMarkerRange" as CFString, &r) == .success, let r,
              CFGetTypeID(r) == AXTextMarkerRangeGetTypeID() else { return nil }
        return AXTextMarkerRangeCopyStartMarker(r as! AXTextMarkerRange)
    }
    func prev(_ el: AXUIElement, _ m: AXTextMarker) -> AXTextMarker? {
        guard let v = ax(el, "AXPreviousTextMarkerForTextMarker", m), CFGetTypeID(v) == AXTextMarkerGetTypeID() else { return nil }
        return (v as! AXTextMarker)
    }
    func text(_ el: AXUIElement, _ a: AXTextMarker, _ b: AXTextMarker) -> String? {
        ax(el, "AXStringForTextMarkerRange", AXTextMarkerRangeCreate(nil, a, b)) as? String
    }
    func box(_ el: AXUIElement, _ a: AXTextMarker, _ b: AXTextMarker) -> CGRect? {
        guard let v = ax(el, "AXBoundsForTextMarkerRange", AXTextMarkerRangeCreate(nil, a, b)), CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
        var r = CGRect.zero
        guard AXValueGetValue(v as! AXValue, .cgRect, &r), r.height > 2, r.height < 200, r.origin != .zero else { return nil }
        return r
    }
    /// Chromium writes a typed space as a no-break space at times.
    func same(_ a: String?, _ b: String) -> Bool {
        guard let a else { return false }
        return a.replacingOccurrences(of: "\u{A0}", with: " ") == b.replacingOccurrences(of: "\u{A0}", with: " ")
    }

    /// Test help (only while data/debug exists): where the marks and the chip are, for the test typer's ◌ ◉ ⎙ keys.
    private func note() {
        guard debugLog else { return }
        let h = NSScreen.screens.first?.frame.height ?? 0
        func ax(_ r: NSRect) -> [CGFloat] { [r.minX, h - r.maxY, r.width, r.height] }
        let j: [String: Any] = ["marks": marks.compactMap { $0.rect.map { [$0.minX, $0.minY, $0.width, $0.height] } },
                                "chip": chipPanel.isVisible ? ax(chipPanel.frame) : NSNull(), "byCaret": byCaret]
        if let d = try? JSONSerialization.data(withJSONObject: j) { try? d.write(to: Home.data.appendingPathComponent("fixmarks.json")) }
    }

    static func arrowRight(_ n: Int) {
        let src = CGEventSource(stateID: .hidSystemState)
        for _ in 0..<n {
            for down in [true, false] {
                let e = CGEvent(keyboardEventSource: src, virtualKey: 124, keyDown: down)
                e?.flags = []; e?.setIntegerValueField(.eventSourceUserData, value: Focus.mark); e?.post(tap: .cghidEventTap)
            }
        }
    }
}

/// The underline: pixel dots in the fix colour (warn), two on, two off.
final class Dots: NSView {
    override func draw(_ r: NSRect) {
        Native.warn.setFill()
        var x: CGFloat = 0
        while x < bounds.width { NSRect(x: x, y: 0, width: 2, height: 2).fill(); x += 4 }
    }
}

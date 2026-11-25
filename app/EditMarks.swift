// Edit mode, the UI (roadmap item 8, "side cursors"; 17 November 2026, docs/rounds/2026-11-17-editing.md; setting
// `editMarks`, on). When he edits rather than writes (EditRules.span, EditRules.due), the paragraph goes to the
// engine's `/marks` (engine/marks.py: local rules and his own word counts, no model, nothing leaves the Mac). Each mark
// is a short bar in the field's left margin at its line and a dotted line under its range (typo warn, tone violet,
// unclear muted). The mouse resting on either, or the caret in the range, shows a chip "old → new · why"; Tab or a
// click on the chip or bar puts the new text in; Esc puts the shown mark away, Esc twice all of them. A pill at the
// paragraph's side offers "Rewrite in my style" (⌥⇧Tab or a click): `/mystyle`, the local model only; Tab or a click
// puts that version over the paragraph. Any letter typed ends edit mode. Machinery as app/FixMarks.swift (overlay
// panels, AX range bounds, text markers for web fields). Never in password fields, skipped apps or under secure input.
import AppKit
import ApplicationServices
import Carbon

final class EditMarks {
    static let shared = EditMarks()

    final class Item {
        var mark: EditRules.Mark
        var rect: CGRect?                             // AX (top-left) screen coordinates
        var start: AXTextMarker?, end: AXTextMarker?  // web field: the range as text markers
        let line = KindDots(), bar = KindBar()
        let linePanel = FixMarks.overlay(), barPanel = FixMarks.overlay()
        init(_ m: EditRules.Mark) {
            mark = m
            let c = EditMarks.color(m.kind)
            line.color = c; bar.color = c
            linePanel.contentView = line; barPanel.contentView = bar
        }
        func hide() { linePanel.orderOut(nil); barPanel.orderOut(nil) }
    }

    private(set) var items: [Item] = []
    private var el: AXUIElement?, pid: pid_t = 0, web = false, viaMarkers = false
    private var span: EditRules.Span?
    private var spanStart: AXTextMarker?, spanEnd: AXTextMarker?
    private var shown: Int?, byCaret = false, hover: (i: Int, since: Date)?, leftAt: Date?
    private var lastMove: Double?, lastLetter: Double?, lastEsc: Date?
    private var restTimer: Timer?, beatTimer: Timer?, seq = 0
    private enum Style { case none, asking, ready(String) }
    private var style: Style = .none

    private let chipPanel = FixMarks.overlay(), pillPanel = FixMarks.overlay()
    private let chipBox = Ground(), chipText = NSTextField(labelWithString: ""), chipMark = KindMark()
    private let pillBox = Ground(), pillText = NSTextField(labelWithString: "")

    init() {
        chipMark.kind = .fix
        for t in [chipText, pillText] { t.font = Native.text(13); t.textColor = Native.ink; t.lineBreakMode = .byTruncatingTail }
        pillText.textColor = Native.muted
        let v = NSView(); chipPanel.contentView = v
        v.addSubview(chipBox); chipBox.addSubview(chipMark); chipBox.addSubview(chipText)
        let p = NSView(); pillPanel.contentView = p
        p.addSubview(pillBox); pillBox.addSubview(pillText)
    }

    static func color(_ kind: String) -> NSColor { kind == "typo" ? Native.warn : kind == "tone" ? Native.violet : Native.muted }

    /// Marks or the style pill are on screen (read on the tap, which runs on the main run loop).
    var up: Bool { !items.isEmpty || pillPanel.isVisible }
    private var styleReady: Bool { if case .ready = style { return true }; return false }

    // MARK: keys and clicks (from Keys, on the main run loop)

    /// Every key down while Drafter is on. true: the key was ours (swallow it).
    func key(_ code: Int64, mods: CGEventFlags, typed: String, ghost: Bool) -> Bool {
        let now = Date().timeIntervalSince1970
        if up {
            if code == 48, mods.isEmpty, !ghost {                                                    // Tab: apply
                if styleReady { DispatchQueue.main.async { self.applyStyle("tab") }; return true }
                if !items.isEmpty { DispatchQueue.main.async { self.applyTarget("tab") }; return true }
            }
            if code == 48, mods == [.maskAlternate, .maskShift] {                                   // ⌥⇧Tab: in my style
                DispatchQueue.main.async { self.askStyle() }; return true
            }
            if code == 53, mods.isEmpty {                                                            // Esc
                let since = lastEsc.map { Date().timeIntervalSince($0) }
                lastEsc = Date()
                switch EditRules.esc(shown: shown ?? (styleReady ? -1 : nil), sinceLastEsc: since) {
                case .all: DispatchQueue.main.async { self.clear("esc twice") }; return true
                case .dismiss(let i): DispatchQueue.main.async { if i < 0 { self.dropStyle() } else { self.dismiss(i) } }; return true
                case .pass: DispatchQueue.main.async { self.clear("esc") }; return false
                }
            }
        }
        let command = mods.contains(.maskCommand) || mods.contains(.maskControl)
        if EditRules.writes(code: Int(code), typed: typed, command: command) {
            lastLetter = now
            restTimer?.invalidate()
            if up { DispatchQueue.main.async { self.clear("typing") } }
        } else if EditRules.moves(code: Int(code)) || (command && code == 0) {                        // arrows, delete, ⌘A
            if code == 51 || code == 117, up { DispatchQueue.main.async { self.clear("delete") } }
            moved(at: now)
            if up { DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { self.checkCaret() } }
        }
        return false
    }

    /// A click anywhere: true when it landed on the chip, a bar or the pill (ours; Keys swallows it and its release).
    func click(_ p: CGPoint) -> Bool {
        if up {
            if hit(pillPanel, p) { DispatchQueue.main.async { self.styleReady ? self.applyStyle("click") : self.askStyle() }; return true }
            if shown != nil, hit(chipPanel, p) { DispatchQueue.main.async { self.applyTarget("click") }; return true }
            if let i = items.firstIndex(where: { $0.barPanel.isVisible && hit($0.barPanel, p, pad: 4) }) {
                DispatchQueue.main.async { self.apply(i, "click") }; return true
            }
        }
        moved(at: Date().timeIntervalSince1970)
        if up { DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { self.refresh(); self.checkCaret() } }
        return false
    }

    func scrolled() {
        guard up else { return }
        for it in items { it.hide() }
        chipPanel.orderOut(nil); pillPanel.orderOut(nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { self.refresh() }
    }

    private func hit(_ panel: NSPanel, _ p: CGPoint, pad: CGFloat = 2) -> Bool {
        guard panel.isVisible else { return false }
        let h = NSScreen.screens.first?.frame.height ?? 0
        return panel.frame.insetBy(dx: -pad, dy: -pad).contains(NSPoint(x: p.x, y: h - p.y))
    }

    /// A move (click, arrow, delete): look again once he rests with no letter typed.
    private func moved(at t: Double) {
        lastMove = t
        guard Drafter.shared.settings.editMarks else { return }
        restTimer?.invalidate()
        restTimer = Timer.scheduledTimer(withTimeInterval: EditRules.rest + 0.05, repeats: false) { [weak self] _ in self?.rested() }
    }

    // MARK: asking

    private func rested() {
        let now = Date().timeIntervalSince1970
        guard EditRules.due(lastMove: lastMove, lastLetter: lastLetter, now: now) else { return }
        if NSEvent.pressedMouseButtons != 0 { moved(at: now - EditRules.rest + 0.3); return }   // still dragging a selection
        let st = Drafter.shared.settings
        guard Drafter.shared.active, Talk.shared.keysFree, !Rework.shared.isOpen, Fields.cur == nil, !Focus.ownInFront,
              let front = NSWorkspace.shared.frontmostApplication, let el = Focus.focused() else { return }
        AXUIElementSetMessagingTimeout(el, 0.15)
        let role: String = Focus.attr(el, kAXRoleAttribute) ?? "", sub: String = Focus.attr(el, kAXSubroleAttribute) ?? ""
        guard EditRules.allowed(on: st.editMarks, secure: IsSecureEventInputEnabled(),
                                password: role == "AXSecureTextField" || sub == (kAXSecureTextFieldSubrole as String),
                                skipped: st.skip.contains(front.bundleIdentifier ?? "")) else { return }
        var found: EditRules.Span?, markers = false, value = ""
        var s0: AXTextMarker?, s1: AXTextMarker?
        if let v: String = Focus.attr(el, kAXValueAttribute), let r = Focus.range(el) {
            value = v
            found = EditRules.span(value: v, caret: r.location, selLen: r.length)
        } else if let (t, a, b) = markerSelection(el), (t as NSString).length >= EditRules.minSelection {
            found = EditRules.Span(text: String(t.prefix(EditRules.maxSpan)), offset: 0, trigger: .selection)
            markers = true; s0 = a; s1 = b
        }
        guard let raw = found else { if up { clear("no paragraph") }; return }
        let sp = EditRules.trimmed(raw)
        if let old = span, let e = self.el, CFEqual(e, el), old == sp, up { return }   // the same paragraph is already marked
        clear("new look")
        seq += 1; let mine = seq
        self.el = el; pid = front.processIdentifier; web = Focus.isWeb(front); viaMarkers = markers
        span = sp; spanStart = s0; spanEnd = s1
        let ctx = value.contains(EditRules.marker) ? testContext(value, span: sp) : Keys.shared.screenText(el)
        let t0 = Date()
        Engine.shared.post("/marks", ["text": sp.text, "context": ctx, "app": front.localizedName ?? ""], timeout: 1.5) { j in
            DispatchQueue.main.async { self.answer(j, mine: mine, t0: t0) }
        }
    }

    /// In a test field, lines holding "Вони: " or "Я: " (outside the span) stand in for the chat on screen.
    private func testContext(_ value: String, span: EditRules.Span) -> String {
        value.split(separator: "\n").map(String.init).filter { ($0.hasPrefix("Вони: ") || $0.hasPrefix("Я: ")) && !span.text.contains($0) }.joined(separator: "\n")
    }

    private func answer(_ j: [String: Any]?, mine: Int, t0: Date) {
        guard mine == seq, let sp = span, let el, let now = Focus.focused(), CFEqual(now, el),
              NSWorkspace.shared.frontmostApplication?.processIdentifier == pid, !IsSecureEventInputEnabled() else { return }
        let raw = (j?["marks"] as? [[String: Any]] ?? []).compactMap { m -> EditRules.Mark? in
            guard let at = m["at"] as? Int, let len = m["len"] as? Int, let old = m["old"] as? String, let new = m["new"] as? String else { return nil }
            return EditRules.Mark(at: at, len: len, old: old, new: new, kind: m["kind"] as? String ?? "", why: m["why"] as? String ?? "")
        }
        // the paragraph must still be there, unchanged
        if !viaMarkers {
            guard let v: String = Focus.attr(el, kAXValueAttribute), sp.offset + (sp.text as NSString).length <= (v as NSString).length,
                  (v as NSString).substring(with: NSRange(location: sp.offset, length: (sp.text as NSString).length)) == sp.text else { return }
        }
        let placed = EditRules.place(raw, in: viaMarkers ? EditRules.Span(text: sp.text, offset: 0, trigger: sp.trigger) : sp)
        items = placed.map { Item($0) }
        if viaMarkers { placeMarkers() }
        for it in items { measure(it) }
        items.removeAll { it in if it.rect == nil { it.hide(); return true }; return false }
        log("edit marks: \(sp.trigger.rawValue), \(raw.count)/\(items.count) marks in \(Int(Date().timeIntervalSince(t0) * 1000))ms (engine \(j?["ms"] as? Double ?? 0)ms), \(viaMarkers ? "markers" : "native")")
        guard !items.isEmpty || sp.trigger == .selection else { return }
        draw()
        if beatTimer == nil { beatTimer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] _ in self?.beat() } }
        checkCaret()
    }

    // MARK: places

    private func markerSelection(_ el: AXUIElement) -> (String, AXTextMarker, AXTextMarker)? {
        var r: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, "AXSelectedTextMarkerRange" as CFString, &r) == .success, let r,
              CFGetTypeID(r) == AXTextMarkerRangeGetTypeID() else { return nil }
        let range = r as! AXTextMarkerRange
        guard let t = FixMarks.shared.ax(el, "AXStringForTextMarkerRange", range) as? String else { return nil }
        return (t, AXTextMarkerRangeCopyStartMarker(range), AXTextMarkerRangeCopyEndMarker(range))
    }

    private func next(_ el: AXUIElement, _ m: AXTextMarker) -> AXTextMarker? {
        guard let v = FixMarks.shared.ax(el, "AXNextTextMarkerForTextMarker", m), CFGetTypeID(v) == AXTextMarkerGetTypeID() else { return nil }
        return (v as! AXTextMarker)
    }

    /// Web field: each mark's range as text markers, one walk forward from the selection's start (one step per UTF-16
    /// unit almost always; a little past it for line breaks).
    private func placeMarkers() {
        guard let el, let s0 = spanStart else { return }
        let far = (items.map { $0.mark.at + $0.mark.len }.max() ?? 0) + 30
        var walk = [s0]
        for _ in 0..<min(far, 1600) { guard let n = next(el, walk.last!) else { break }; walk.append(n) }
        let fm = FixMarks.shared
        for it in items {
            let m = it.mark, n = (m.old as NSString).length
            for i in ([m.at] + Array((m.at + 1)...(m.at + 30)) + [m.at - 1, m.at - 2]) where i >= 0 && i + n < walk.count {
                if fm.same(fm.text(el, walk[i], walk[i + n]), m.old) { it.start = walk[i]; it.end = walk[i + n]; break }
            }
        }
        items.removeAll { it in if it.start == nil { it.hide(); return true }; return false }
    }

    private func measure(_ it: Item) {
        guard let el else { it.rect = nil; return }
        if let s = it.start, let e = it.end { it.rect = FixMarks.shared.box(el, s, e) } else { it.rect = Focus.bounds(el, it.mark.at, it.mark.len) }
        if let r = it.rect, let f = Focus.frame(el), !f.insetBy(dx: -2, dy: -2).contains(CGPoint(x: r.midX, y: r.midY)) { it.rect = nil }
    }

    /// Still on its text? Native: the value at its range; web: the text between its markers.
    private func valid(_ it: Item) -> Bool {
        guard let el else { return false }
        if let s = it.start, let e = it.end { return FixMarks.shared.same(FixMarks.shared.text(el, s, e), it.mark.old) }
        guard let v: String = Focus.attr(el, kAXValueAttribute) else { return false }
        let ns = v as NSString
        return it.mark.at + it.mark.len <= ns.length && ns.substring(with: NSRange(location: it.mark.at, length: it.mark.len)) == it.mark.old
    }

    /// The left margin of the field (AX), for the bars and the pill.
    private func margin(_ r: CGRect) -> CGFloat {
        guard let el, let f = Focus.frame(el), f.minX + 2 < r.minX else { return r.minX - 7 }
        return max(f.minX - 7, 0)
    }

    private func draw() {
        for it in items {
            guard let r = it.rect, r.width > 1 else { it.hide(); continue }
            let c = Ghost.shared.cocoa(r)
            it.linePanel.setFrame(NSRect(x: c.minX, y: c.minY - 1, width: c.width, height: 2), display: true)
            it.line.needsDisplay = true
            it.linePanel.orderFrontRegardless()
            let lineH = min(r.height, 20)
            let bar = Ghost.shared.cocoa(CGRect(x: margin(r), y: r.minY + (min(r.height, 24) - lineH) / 2, width: 3, height: lineH))
            it.barPanel.setFrame(bar, display: true)
            it.bar.needsDisplay = true
            it.barPanel.orderFrontRegardless()
        }
        drawPill()
        if let s = shown, items.indices.contains(s) { layoutChip(items[s]) } else { chipPanel.orderOut(nil) }
    }

    private func spanRect() -> CGRect? {
        guard let el, let sp = span else { return nil }
        if viaMarkers, let s = spanStart, let n = next(el, s) { return FixMarks.shared.box(el, s, n) }
        return viaMarkers ? nil : Focus.bounds(el, sp.offset, min(1, (sp.text as NSString).length))
    }

    private func drawPill() {
        guard span != nil, let r = spanRect() ?? items.first?.rect else { pillPanel.orderOut(nil); return }
        switch style {
        case .none: pillText.stringValue = EditRules.styleLabel; pillText.textColor = Native.muted
        case .asking: pillText.stringValue = "Rewrite in my style …"; pillText.textColor = Native.muted
        case .ready(let t): pillText.stringValue = EditRules.styleResult(t); pillText.textColor = Native.ink
        }
        pillText.sizeToFit()
        let h = max(28, pillText.frame.height + 10), w = min(520, pillText.frame.width + 24)
        pillText.frame = NSRect(x: 12, y: ((h - pillText.frame.height) / 2).rounded(), width: w - 24, height: pillText.frame.height)
        pillBox.frame = NSRect(x: 0, y: 0, width: w, height: h)
        pillBox.needsDisplay = true
        let c = Ghost.shared.cocoa(r)
        pillPanel.setFrame(NSRect(x: Ghost.shared.cocoa(CGRect(x: margin(r), y: r.minY, width: 1, height: 1)).minX, y: c.maxY + 4, width: w, height: h), display: true)
        pillPanel.orderFrontRegardless()
    }

    private func layoutChip(_ it: Item) {
        guard let r = it.rect else { chipPanel.orderOut(nil); return }
        let c = Ghost.shared.cocoa(r)
        chipText.stringValue = EditRules.label(it.mark)
        chipText.sizeToFit()
        let h = max(30, chipText.frame.height + 12), tw = min(560, chipText.frame.width)
        let w = 10 + 16 + 8 + tw + 12
        chipBox.frame = NSRect(x: 0, y: 0, width: w, height: h)
        chipMark.frame = NSRect(x: 10, y: ((h - 16) / 2).rounded(), width: 16, height: 16)
        chipText.frame = NSRect(x: 34, y: ((h - chipText.frame.height) / 2).rounded(), width: tw, height: chipText.frame.height)
        chipBox.needsDisplay = true
        chipPanel.setFrame(NSRect(x: c.minX - 34, y: c.maxY + 3, width: w, height: h), display: true)
        chipPanel.orderFrontRegardless()
    }

    private func show(_ i: Int, caret: Bool) {
        guard items.indices.contains(i) else { return }
        shown = i; byCaret = caret; leftAt = nil
        layoutChip(items[i])
    }

    private func hideChip() { chipPanel.orderOut(nil); shown = nil; byCaret = false; leftAt = nil }

    /// Check every mark again: field, app, text, place on screen.
    private func refresh() {
        guard up, let el else { return }
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid, let f = Focus.focused(), CFEqual(f, el) else { clear("field changed"); return }
        let was = shown.map { items[$0] }
        items.removeAll { it in if !valid(it) { it.hide(); return true }; return false }
        for it in items { measure(it) }
        shown = was.flatMap { w in items.firstIndex { $0 === w } }
        if items.isEmpty, span?.trigger != .selection { clear("no marks left"); return }
        draw()
    }

    private func beat() {
        guard up else { beatTimer?.invalidate(); beatTimer = nil; return }
        let p = NSEvent.mouseLocation
        let i = items.indices.last { i in
            let it = items[i]
            if let r = it.rect, Ghost.shared.cocoa(r).insetBy(dx: -2, dy: -3).contains(p) { return true }
            return it.barPanel.isVisible && it.barPanel.frame.insetBy(dx: -4, dy: -2).contains(p)
        }
        if let i {
            leftAt = nil
            if hover?.i != i { hover = (i, Date()) }
            if shown != i || !chipPanel.isVisible, Date().timeIntervalSince(hover!.since) >= 0.3 { show(i, caret: false) }
            return
        }
        hover = nil
        if shown != nil, !byCaret {
            if chipPanel.frame.insetBy(dx: -4, dy: -4).contains(p) { leftAt = nil; return }
            if leftAt == nil { leftAt = Date() } else if Date().timeIntervalSince(leftAt!) > 0.35 { hideChip() }
        }
    }

    /// The caret in a mark: its chip shows, Tab applies it.
    private func checkCaret() {
        guard !items.isEmpty, let el, let c = caret(el) else { return }
        if let i = items.firstIndex(where: { c >= $0.mark.at && c <= $0.mark.at + $0.mark.len }) { show(i, caret: true) }
        else if byCaret { hideChip() }
    }

    /// The caret as a UTF-16 offset in the value (native fields only).
    private func caret(_ el: AXUIElement) -> Int? {
        guard !viaMarkers, let r = Focus.range(el), r.length == 0 else { return nil }
        return r.location
    }

    // MARK: applying

    private func applyTarget(_ how: String) {
        let c = el.flatMap { caret($0) }
        guard let i = EditRules.tabTarget(items.map { $0.mark }, caret: c, hovered: hover?.i, shown: shown) else { return }
        apply(i, how)
    }

    /// Ready to write into this field: still his, still in front, no secure input.
    private func writable() -> AXUIElement? {
        guard let el, let now = Focus.focused(), CFEqual(now, el), NSWorkspace.shared.frontmostApplication?.processIdentifier == pid,
              !IsSecureEventInputEnabled(), !Drafter.shared.settings.skip.contains(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "") else { return nil }
        let role: String = Focus.attr(el, kAXRoleAttribute) ?? "", sub: String = Focus.attr(el, kAXSubroleAttribute) ?? ""
        guard role != "AXSecureTextField", sub != (kAXSecureTextFieldSubrole as String) else { return nil }
        return el
    }

    private func settled(_ ok: () -> Bool) -> Bool {
        for i in 0..<8 { if ok() { return true }; if i < 7 { usleep(25_000) } }
        return false
    }

    func apply(_ i: Int, _ how: String) {
        guard items.indices.contains(i) else { return }
        let it = items[i], m = it.mark
        hideChip()
        guard let el = writable(), valid(it) else { drop(i); Ghost.shared.flash("Text has changed"); return }
        Keys.shared.cancel()
        let fm = FixMarks.shared
        if let s = it.start, let e = it.end {
            let range = AXTextMarkerRangeCreate(nil, s, e)
            guard AXUIElementSetAttributeValue(el, "AXSelectedTextMarkerRange" as CFString, range) == .success,
                  settled({ fm.same(fm.selected(el), m.old) }) else { drop(i); Ghost.shared.flash("Could not put it in"); return }
            write(m.new, el: el, ax: false)
        } else {
            var sel = CFRange(location: m.at, length: m.len)
            guard let arg = AXValueCreate(.cfRange, &sel), AXUIElementSetAttributeValue(el, kAXSelectedTextRangeAttribute as CFString, arg) == .success,
                  settled({ Focus.range(el).map { $0.location == m.at && $0.length == m.len } ?? false }) else {
                drop(i); Ghost.shared.flash("Could not put it in"); return
            }
            write(m.new, el: el, ax: !web)
        }
        let rest = EditRules.after(applying: m, items.map { $0.mark })
        it.hide()
        items.remove(at: i)
        for (k, x) in items.enumerated() where k < rest.count && !viaMarkers { x.mark = rest[k] }
        shown = nil
        log("edit marks: \(m.kind) applied by \(how), \(items.count) left")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { self.refresh() }
    }

    /// The selection replaced by `text`: an AX write in native fields, typed keys in web ones (empty: one Backspace).
    private func write(_ text: String, el: AXUIElement, ax: Bool) {
        if ax, Focus.setSelectedText(el, text) == .success { return }
        if text.isEmpty { EditMarks.backspace() } else { Focus.typeText(text) }
    }

    static func backspace() {
        let src = CGEventSource(stateID: .hidSystemState)
        for down in [true, false] {
            let e = CGEvent(keyboardEventSource: src, virtualKey: 51, keyDown: down)
            e?.flags = []; e?.setIntegerValueField(.eventSourceUserData, value: Focus.mark); e?.post(tap: .cghidEventTap)
        }
    }

    // MARK: in my style

    private func askStyle() {
        guard let sp = span, el != nil else { return }
        if case .asking = style { return }
        style = .asking; drawPill()
        let mine = seq, t0 = Date()
        let ctx = el.map { Keys.shared.screenText($0) } ?? ""
        Engine.shared.post("/mystyle", ["text": sp.text, "context": ctx], timeout: 45) { j in
            DispatchQueue.main.async {
                guard mine == self.seq, case .asking = self.style else { return }
                let out = (j?["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                log("edit marks: my style \(Int(Date().timeIntervalSince(t0) * 1000))ms, " + (out.isEmpty ? "none" : "\(sp.text.count) → \(out.count) chars"))
                if out.isEmpty || out == sp.text { self.style = .none; Ghost.shared.flash("No other version") } else { self.style = .ready(out) }
                self.drawPill()
            }
        }
    }

    private func dropStyle() { style = .none; drawPill() }

    private func applyStyle(_ how: String) {
        guard case .ready(let new) = style, let sp = span else { return }
        guard let el = writable() else { clear("field changed"); Ghost.shared.flash("Text has changed"); return }
        Keys.shared.cancel()
        if viaMarkers {
            // the selection must still be his (as Rework.apply): pasted over it
            guard Focus.selection() == sp.text else { clear("selection changed"); Ghost.shared.flash("Selection changed"); return }
            Focus.paste(new)
        } else {
            let n = (sp.text as NSString).length
            guard let v: String = Focus.attr(el, kAXValueAttribute), sp.offset + n <= (v as NSString).length,
                  (v as NSString).substring(with: NSRange(location: sp.offset, length: n)) == sp.text else {
                clear("text changed"); Ghost.shared.flash("Text has changed"); return
            }
            var sel = CFRange(location: sp.offset, length: n)
            guard let arg = AXValueCreate(.cfRange, &sel), AXUIElementSetAttributeValue(el, kAXSelectedTextRangeAttribute as CFString, arg) == .success,
                  settled({ Focus.range(el).map { $0.location == sp.offset && $0.length == n } ?? false }) else {
                clear("no selection"); Ghost.shared.flash("Could not put it in"); return
            }
            if web || new.contains("\n") || Focus.setSelectedText(el, new) != .success { Focus.paste(new) }
        }
        log("edit marks: my style applied by \(how), \(sp.text.count) → \(new.count) chars")
        clear("style applied")
    }

    // MARK: ending

    private func dismiss(_ i: Int) {
        guard items.indices.contains(i) else { return }
        log("edit marks: \(items[i].mark.kind) dismissed")
        drop(i)
    }

    private func drop(_ i: Int) {
        guard items.indices.contains(i) else { return }
        items[i].hide(); items.remove(at: i)
        hideChip()
        if items.isEmpty, span?.trigger != .selection { clear("no marks left") }
    }

    func clear(_ why: String) {
        let was = up
        seq += 1
        for it in items { it.hide() }
        items = []; span = nil; spanStart = nil; spanEnd = nil; style = .none
        hideChip(); pillPanel.orderOut(nil)
        beatTimer?.invalidate(); beatTimer = nil; hover = nil
        if was, debugLog { log("edit marks: cleared (\(why))") }
    }
}

/// The dotted line under a mark's range, in its kind's colour: two on, two off.
final class KindDots: NSView {
    var color = Native.warn
    override func draw(_ r: NSRect) {
        color.setFill()
        var x: CGFloat = 0
        while x < bounds.width { NSRect(x: x, y: 0, width: 2, height: 2).fill(); x += 4 }
    }
}

/// The side mark in the field's left margin, in the mark's kind colour.
final class KindBar: NSView {
    var color = Native.warn
    override func draw(_ r: NSRect) {
        color.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 1.5, yRadius: 1.5).fill()
    }
}

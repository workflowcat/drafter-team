// Strip style "classic" (setting stripStyle, default): the one-row strip as it was before the Tape round, restored
// unchanged from 0d395d6^1:app/Pill.swift on 14 November 2026. Only the type names changed (Pill -> ClassicStrip,
// PillView -> ClassicStripView); StripButton and HitView are shared and live in Pill.swift. Do not restyle this file.
// The voice strip: notch-black, a microphone, and three steady lines of subdued live words.
// Clicks go through it.
import AppKit

final class ClassicStrip: StripFace {
    static let shared = ClassicStrip()
    private var panel: NSPanel?
    private let box = ClassicStripView()
    private let words = NSTextField(labelWithString: "")
    private var hideToken = 0
    private let status = NSTextField(labelWithString: "")   // the notch row's right side: "Нотатка · 12:34"
    private var lines: CGFloat = 5
    private let state = NSTextField(labelWithString: "")
    private var previewing = false
    private var previewNotch: CGFloat?
    private var settledLength = 0
    private var styledDraft = false
    private var layoutGen = 0
    // the last row's buttons (offer keys, Stop & save, Undo); clicks reach them through `hits`, a small clear panel over
    // just that row, so the rest of the strip still lets clicks through (2026-11-01, Codex notch review)
    private var controls: [StripButton] = []
    private var hits: NSPanel?
    private let hitView = HitView()
    private var screenID: NSNumber?          // the display a take or offer started on: it stays there
    private var meSeen = false, themSeen = false

    private func make() -> NSPanel {
        let p = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false; p.backgroundColor = .clear; p.hasShadow = false; p.ignoresMouseEvents = true
        p.identifier = OwnChrome.strip   // left out of Drafter's own screen pictures
        p.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 2)   // over the menu bar, like the notch
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        // Explicit notch treatment: stay black in both macOS appearances.
        box.appearance = NSAppearance(named: .darkAqua)
        p.contentView = box

        words.font = Native.body(13)
        words.textColor = Native.muted
        words.lineBreakMode = .byWordWrapping
        words.maximumNumberOfLines = 5
        words.cell?.wraps = true
        words.alignment = .left
        box.addSubview(words)
        status.font = Native.mono(10)
        status.textColor = Native.muted; status.alignment = .right
        box.addSubview(status)
        state.font = Native.display(11); state.textColor = Native.muted
        box.addSubview(state)
        box.appearanceChanged = { [weak self] in self?.refreshAppearance() }
        return p
    }

    /// Size and place (2026-10-20, the user: "jumpy, a bit too big"): a slim island just wider than the notch while there
    /// is no text (dot and meter on the left wing, status on the right), opening downward to a fixed number of lines
    /// when there is. The size changes only when that changes, never per word, and then it slides (0.2 s), pinned to the top.
    private var screen: NSScreen? {
        NSScreen.screens.first { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber) == screenID } ?? NSScreen.main
    }
    /// A new take or offer stays on the display it started on (not the one focus moves to); one that is gone re-homes.
    private func pin() {
        guard panel?.isVisible != true || !NSScreen.screens.contains(where: { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber) == screenID }) else { return }
        screenID = NSScreen.main?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
    }
    private func notchWidth() -> CGFloat {
        if let previewNotch { return previewNotch }
        guard let s = screen, s.safeAreaInsets.top > 0, let l = s.auxiliaryTopLeftArea, let r = s.auxiliaryTopRightArea else { return 0 }
        return max(120, s.frame.width - l.width - r.width)
    }
    private func openWidth() -> CGFloat { let n = notchWidth(); return n > 0 ? max(n + 2 * 120, 460) : 460 }

    /// Lines a text really takes in the open strip, at most `max` (2026-10-30: a one-word receipt left two empty lines).
    private func fit(_ text: String, max n: Int) -> Int {
        let font = words.font ?? Native.body(13)
        var total = 0
        for para in text.components(separatedBy: "\n") {
            let r = (para.isEmpty ? " " : para as NSString).boundingRect(with: NSSize(width: openWidth() - 32, height: 1000),
                                                                         options: [.usesLineFragmentOrigin], attributes: [.font: font])
            total += max(1, Int(ceil(r.height / ceil(font.ascender - font.descender + font.leading))))
        }
        return min(n, max(1, total))
    }

    /// One line that fits the open strip, cut with "…" (an event title never wraps into the keys' row).
    private func clip(_ t: String) -> String {
        let a: [NSAttributedString.Key: Any] = [.font: words.font ?? Native.body(13)], room = openWidth() - 36
        if (t as NSString).size(withAttributes: a).width <= room { return t }
        var lo = 0, hi = t.count
        while lo < hi { let m = (lo + hi + 1) / 2; if ((String(t.prefix(m)) + "…") as NSString).size(withAttributes: a).width <= room { lo = m } else { hi = m - 1 } }
        return String(t.prefix(lo)).trimmingCharacters(in: .whitespaces) + "…"
    }

    private func setControls(_ list: [StripButton]) {
        controls.forEach { $0.removeFromSuperview() }
        controls = list; list.forEach { box.addSubview($0) }
        hitView.buttons = list
        if list.isEmpty { hits?.orderOut(nil) }
    }

    private func close() { layoutGen += 1; panel?.ignoresMouseEvents = true; panel?.orderOut(nil); hits?.orderOut(nil) }

    /// The clear panel over the buttons, placed for the strip's final frame.
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
        let u = controls.dropFirst().reduce(controls[0].frame) { $0.union($1.frame) }.insetBy(dx: -4, dy: -3)   // 30 pt targets
        hitView.origin = u.origin
        hits?.setFrame(NSRect(x: frame.minX + u.minX, y: frame.minY + u.minY, width: u.width, height: u.height), display: true)
        hits?.orderFrontRegardless()
        if debugLog { log("strip buttons: " + controls.map { "\($0.label) \(Int(frame.minX + $0.frame.midX)),\(Int(frame.minY + $0.frame.midY))" }.joined(separator: "; ")) }
    }

    private func announce(_ text: String) {
        guard !previewing else { return }
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                             userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }

    private func place() {
        guard let s = screen, let p = panel else { return }
        let bar: CGFloat = previewNotch == 0 ? 28 : (s.safeAreaInsets.top > 0 ? s.safeAreaInsets.top : 28)
        let notch = notchWidth()
        let open = !words.stringValue.isEmpty
        let w = open ? openWidth() : (notch > 0 ? notch + 2 * 86 : 260)
        let row: CGFloat = controls.isEmpty ? 0 : 34             // the buttons' row under the text
        let textH = open ? lines * 18 + 16 + row : 0
        let h = bar + textH
        // no notch (an external screen): a floating pill just under the menu bar instead of a hanging strip
        box.floating = notch == 0
        let topY = notch > 0 ? s.frame.maxY : s.visibleFrame.maxY - 6
        let target = NSRect(x: s.frame.midX - w / 2, y: topY - h, width: w, height: h)
        // children laid out from the top, for the size the window has now; autoresizing keeps them pinned while it slides
        let cur = p.isVisible ? p.frame.size : target.size
        func top(_ fromTop: CGFloat, _ height: CGFloat) -> CGFloat { cur.height - fromTop - height }
        let mid = bar / 2
        box.frame = NSRect(origin: .zero, size: cur)
        box.dotFromTop = mid - 3

        state.autoresizingMask = [.minYMargin]
        state.frame = NSRect(x: 30, y: top(mid - 7, 14), width: notch > 0 ? max(48, (w - notch) / 2 - 36) : 125, height: 14)
        words.autoresizingMask = [.minYMargin]
        words.frame = NSRect(x: 16, y: top(bar + 4, max(1, textH - 8 - row)), width: w - 32, height: max(1, textH - 8 - row))
        var bx: CGFloat = 16
        for b in controls { b.autoresizingMask = [.maxYMargin]; b.setFrameOrigin(NSPoint(x: bx, y: 8)); bx += b.frame.width + 8 }
        status.autoresizingMask = [.minYMargin, .minXMargin]
        let sx = notch > 0 ? w / 2 + notch / 2 + 6 : w - 130
        status.frame = NSRect(x: sx, y: top(mid - 8, 16), width: max(10, w - sx - 16), height: 16)
        // one layout at a time: a newer one makes an older animation's end do nothing (Codex round 4: stale button spots)
        layoutGen += 1; let gen = layoutGen
        if p.isVisible, p.frame.size != target.size, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            hits?.orderOut(nil)
            // while it slides, the strip itself takes clicks (and drops them), so a click meant for a button never
            // falls through to the app under it
            p.ignoresMouseEvents = controls.isEmpty
            NSAnimationContext.runAnimationGroup({ c in c.duration = 0.2; c.timingFunction = CAMediaTimingFunction(name: .easeOut); p.animator().setFrame(target, display: true) },
                                                 completionHandler: { [weak self] in
                                                     guard let self, gen == self.layoutGen else { return }
                                                     p.ignoresMouseEvents = true; self.placeHits(target)
                                                 })
        } else {
            p.ignoresMouseEvents = true
            if p.frame != target { p.setFrame(target, display: true) }
            DispatchQueue.main.async { [weak self] in   // after present() put the strip up
                guard let self, gen == self.layoutGen else { return }
                self.placeHits(target)
            }
        }
        box.needsDisplay = true
    }

    func listening() {
        hideToken += 1
        if panel == nil { panel = make() }
        pin(); setControls([])
        box.long = false; box.done = false; box.countdown = nil; box.levels = nil; meSeen = false
        setState("Listening", glyphOnly: true); status.stringValue = ""; lang = ""; lines = 3; words.maximumNumberOfLines = 3; stayOpen = false; oldText = ""; anchor = 0; prevWords = []
        status.textColor = Native.muted
        words.textColor = Native.muted
        words.stringValue = ""; styledDraft = false
        place()
        box.reading = false
        present()
    }

    private func setState(_ title: String, glyphOnly: Bool = false) {
        state.stringValue = glyphOnly ? "" : title; box.hearing = false
        box.setAccessibilityElement(true)
        box.setAccessibilityRole(.group)
        box.setAccessibilityLabel(title)
    }

    private func present() { if !previewing { panel?.orderFrontRegardless() } }

    /// Sound levels: a short take shows a small meter beside the microphone that moves with the user's voice (14 November
    /// 2026, look round: the strip should feel alive while it listens; 4 steps a second, never a glow); a long note or
    /// call shows small levels for me and for them (2026-10-30: is the other side being recorded? see it while it runs).
    private var heldMe: Float = 0, heldThem: Float = 0, levelAt = Date.distantPast
    func level(_ pk: Float, them: Float? = nil) {
        guard box.long else { return }   // a short take keeps a still microphone (30 October 2026)
        heldMe = max(heldMe, pk); if let them { heldThem = max(heldThem, them) }
        guard Date().timeIntervalSince(levelAt) > 0.25 else { return }
        levelAt = Date()
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            // still marks: a side lights once it has been heard, and stays (is it recorded? not how loud)
            meSeen = meSeen || heldMe >= 0.004; themSeen = themSeen || heldThem >= 0.004
            box.levels = (meSeen ? 2 : 0, them == nil ? nil : (themSeen ? 2 : 0))   // a short take: lit once heard
        } else {
            box.levels = (ClassicStripView.bars(heldMe), them == nil ? nil : ClassicStripView.bars(heldThem))
        }
        heldMe = 0; heldThem = 0
        box.needsDisplay = true
    }

    private func refreshAppearance() {
        state.textColor = Native.muted; status.textColor = Native.muted
        if styledDraft { renderDraft() } else { words.textColor = Native.muted }
        box.needsDisplay = true
    }

    /// The preview: the words heard so far (latest ~420 characters) in up to five lines under the notch.
    private var stayOpen = false   // opened once in this take: stays open until it ends (no snap shut on Enter)

    func draft(_ text: String) {
        if text.isEmpty, stayOpen {   // Enter put the words in: say so quietly, keep the size
            styledDraft = false; words.textColor = Native.muted; words.stringValue = ClassicStrip.insertedNote
            return
        }
        if !text.isEmpty { stayOpen = true }
        let was = words.stringValue.isEmpty
        // steady text (2026-10-20, flicker on long takes): the shown part starts at an anchor that only moves forward,
        // a whole sentence at a time, when three lines are full; between those moves the text only grows at the end
        if text.count < anchor { anchor = 0 }
        var shown = String(text.dropFirst(anchor))
        if fit(shown, max: 4) > 3 {
            let cut = shown.index(shown.endIndex, offsetBy: -140)
            let head = shown[..<cut]
            let at = head.lastIndex(where: { ".!?…".contains($0) }).map { shown.index(after: $0) } ?? head.lastIndex(of: " ") ?? cut
            anchor += shown.distance(from: shown.startIndex, to: at)
            shown = String(text.dropFirst(anchor)).trimmingCharacters(in: .whitespaces)
            oldText = ""          // a jump: shown at once, no fade
            setPlain(anchor > 0 ? "… " + shown : shown)
            if was != shown.isEmpty { place() }
            return
        }
        fadeIn(anchor > 0 ? "… " + shown.trimmingCharacters(in: .whitespaces) : shown)
        if was != shown.isEmpty { place() }
    }

    private var anchor = 0
    private func setPlain(_ t: String) {
        styledDraft = false
        oldText = t; prevWords = t.split(separator: " ", omittingEmptySubsequences: false)   // the next draft compares to this
        words.attributedStringValue = NSAttributedString(string: t, attributes: [.font: words.font ?? .systemFont(ofSize: 12),
                                                                                .foregroundColor: Native.muted])
    }

    private var lang = ""   // the take's language pin, "UK" / "EN", in the notch row's right side
    func langMark(_ mark: String) {
        guard panel?.isVisible == true, !box.long else { return }
        lang = mark; status.textColor = Native.muted; status.stringValue = mark
        box.setAccessibilityLabel(mark.isEmpty ? "Listening" : "Listening · " + mark)
    }
    /// A quiet word in the notch row's right side during a take ("no mic signal"); nil clears it.
    func note(_ text: String?) {
        guard panel?.isVisible == true, !box.long else { return }
        status.textColor = Native.muted
        setState(text == nil ? "Listening" : "Quiet", glyphOnly: true)
        status.stringValue = text == nil ? lang : "no mic signal"
    }

    static let insertedNote = "✓ In the field · still listening"
    /// Return while the user speaks (round three): the segment so far is on its way; said quietly where the words were, until
    /// the user's next words show. Its receipt replaces that line only while no new words came.
    private var bandLine = ""
    func segment(_ line: String) {
        guard panel?.isVisible == true, !box.long else { return }
        stayOpen = true; styledDraft = false; words.textColor = Native.muted
        bandLine = line + " · still listening"; words.stringValue = bandLine
    }
    func segmentDone(ok: Bool, reason: String) {
        guard panel?.isVisible == true, !box.long else { return }
        if box.reading || words.stringValue.isEmpty { ok ? landed() : copied(reason); return }
        guard words.stringValue == bandLine else { return }
        bandLine = ok ? ClassicStrip.insertedNote : "On the clipboard · " + reason + " · still listening"
        words.stringValue = bandLine
    }
    func waking(_ on: Bool) {
        guard panel?.isVisible == true, !box.long, !box.reading else { return }
        status.textColor = Native.muted; status.stringValue = on ? "waking" : ""
    }
    /// The take ended and its last words are being read. A strip that only said "Inserted" closes to the slim bar,
    /// so it never reads "Processing" over "Inserted" (2026-10-30).
    func reading() {
        box.reading = true; box.done = false; setState("Reading"); box.hearing = true; status.stringValue = ""; setControls([])
        if words.stringValue == ClassicStrip.insertedNote { words.stringValue = ""; stayOpen = false; place() }
        box.needsDisplay = true
    }

    // Stability is a reading aid, not confidence. New words are readable immediately.
    private var oldText = "", prevWords: [Substring] = []
    private func fadeIn(_ text: String) {
        let next = text.split(separator: " ", omittingEmptySubsequences: false)
        var agree = 0
        while agree < min(next.count, prevWords.count), next[agree] == prevWords[agree] { agree += 1 }
        if agree == next.count { agree = max(0, agree - 1) }
        prevWords = next; oldText = text
        settledLength = min(text.count, next.prefix(agree).reduce(0) { $0 + $1.count + 1 })
        styledDraft = true; renderDraft()
    }

    private func renderDraft() {
        let split = oldText.index(oldText.startIndex, offsetBy: settledLength)
        let font = words.font ?? Native.body(13)
        let value = NSMutableAttributedString(string: String(oldText[..<split]), attributes: [.font: font, .foregroundColor: Native.muted])
        value.append(NSAttributedString(string: String(oldText[split...]), attributes: [.font: font, .foregroundColor: Native.muted]))
        words.attributedStringValue = value
    }

    /// The take landed: the island closes back into the notch with a short check mark.
    func landed() {
        guard panel?.isVisible == true || previewing else { return }
        hideToken += 1; let mine = hideToken
        setControls([]); announce("In the field")
        words.stringValue = ""; oldText = ""; stayOpen = false; box.long = false; box.reading = false
        styledDraft = false; setState("In the field"); status.stringValue = ""; box.reading = false; box.done = true; box.countdown = nil
        box.levels = nil
        if !previewing { box.drawIn() }
        place()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) {
            guard mine == self.hideToken else { return }
            self.status.textColor = Native.muted
            self.close()
        }
    }

    /// Long recordings keep a named recording state, duration and a fixed four-line outline.
    /// `warning`: a side that is not being heard (`CallHealth`), shown in place of the second row while it lasts, so a
    /// silent microphone or a missing other side shows during the call, not after it (2026-11-10).
    private var warned: String?
    func recording(call: Bool, seconds: Int, title: String, outline: [String], event: String = "", shots: Int = 0, warning: String? = nil) {
        hideToken += 1
        if panel == nil { panel = make() }
        let first = !box.long
        if first {
            box.levels = (0, call ? 0 : nil); meSeen = false; themSeen = false; pin()
            // Stop stays in reach for the whole take (2026-11-01, Codex: the hint went after 20 s, just when it was needed);
            // a click arms it, a second within 3 s stops, so a stray click on the strip never ends a call
            setControls([StripButton("Stop & save", key: StripRules.key(.shiftRightOption), style: .stop, confirm: "Click again to stop") { Talk.shared.stopRecording("the strip") }])
            announce(call ? "Recording call" : "Recording note")
        }
        styledDraft = false; box.long = true; box.reading = false; box.done = false; box.countdown = nil; setState("Recording", glyphOnly: true); words.textColor = Native.muted
        // the time on the right (and the screenshots taken, small); the kind shows in the levels: a call has "them"
        status.stringValue = String(format: "%d:%02d", seconds / 60, seconds % 60) + (shots > 0 ? " · ▣\(shots)" : "")
        let name = !event.isEmpty ? event : !title.isEmpty ? title : (call ? "Recording call" : "Recording note")
        // two lines (1 November 2026, the user: "cleaner recording state"): the meeting or the outline's title, bright;
        // then the outline's first point, or what is recorded until there is one
        let point = warning.map { "⚠ " + $0 } ?? outline.first.map { $0.hasPrefix("→") ? $0 : "• " + $0 } ?? (call ? "Both sides, on this Mac" : "Your microphone, on this Mac")
        if warning != warned { warned = warning; if let warning { announce(warning) } }
        let body = [name, point].map(clip)
        setBody(body)
        let changed = lines != CGFloat(body.count) || first
        lines = CGFloat(body.count); words.maximumNumberOfLines = body.count
        if changed || !(panel?.isVisible ?? false) { place() }
        present()
    }

    /// An offer that waits for an answer (a call started: record it?), shown for `seconds`. `kind` names it on the left,
    /// `side` on the right (the app); up to three one-line rows (the question, who or why, what is recorded), then the
    /// keys as buttons that never get cut (2026-11-01, Codex notch review; the user: "not sure how to dismiss it"). A thin
    /// line along the bottom runs out with the time left (2026-10-30, the user's plan).
    func offer(_ rows: [String], kind: String, side: String = "", controls list: [StripButton], seconds: Double) {
        if panel == nil { panel = make() }
        pin()
        styledDraft = false; box.long = false; box.reading = true; box.done = false; setState(kind); status.stringValue = side; words.textColor = Native.muted
        let body = rows.prefix(3).map(clip)
        words.maximumNumberOfLines = body.count; setBody(body)
        lines = CGFloat(body.count)
        setControls(list)
        place(); present()
        startCountdown(seconds)
        hide(after: seconds)
        let said: [String] = [kind] + Array(rows.prefix(3)) + list.map { $0.spoken }
        announce(said.joined(separator: ". "))
    }

    /// One row of the offer on screen changed (who the call is likely with, from /prep): same size, same time left.
    func offerRow(_ i: Int, _ text: String) {
        var rows = words.stringValue.components(separatedBy: "\n")
        guard panel?.isVisible == true, i < rows.count, !controls.isEmpty else { return }
        rows[i] = clip(text); setBody(rows)
    }

    /// Rows of an offer or a recording: the first one bright (the question, the meeting), the rest muted.
    private func setBody(_ rows: [String]) {
        let t = NSMutableAttributedString()
        for (i, r) in rows.enumerated() {
            let f = words.font ?? Native.body(13)
            if i > 0, r.hasPrefix("⚠ ") {   // a side not heard: the mark in the warning colour, the words as they are
                t.append(NSAttributedString(string: "\n⚠ ", attributes: [.font: f, .foregroundColor: Native.warn]))
                t.append(NSAttributedString(string: String(r.dropFirst(2)), attributes: [.font: f, .foregroundColor: Native.ink]))
                continue
            }
            t.append(NSAttributedString(string: (i > 0 ? "\n" : "") + r, attributes: [.font: f, .foregroundColor: i == 0 ? Native.ink : Native.muted]))
        }
        words.attributedStringValue = t
    }

    private var countdownTimer: Timer?
    private func startCountdown(_ seconds: Double) {
        countdownTimer?.invalidate()
        box.countdown = (Date(), seconds)
        let step = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 1.0 : 0.1
        countdownTimer = Timer.scheduledTimer(withTimeInterval: step, repeats: true) { [weak self] t in
            guard let self, let c = self.box.countdown, Date().timeIntervalSince(c.0) < c.1 else { t.invalidate(); return }
            self.box.needsDisplay = true
        }
    }

    func hide(after: Double = 0) {
        hideToken += 1; let mine = hideToken
        DispatchQueue.main.asyncAfter(deadline: .now() + after) { if mine == self.hideToken { self.close() } }
    }

    /// A short line in the strip (no microphone, nothing heard…), then it goes.
    /// A longer text to read (a rewritten selection), shown under the notch for `seconds`.
    func show(_ text: String, seconds: Double, lines n: Int = 2) {
        if panel == nil { panel = make() }
        styledDraft = false; words.textColor = Native.muted; box.long = false; box.done = false; box.countdown = nil; setState("Drafter"); status.stringValue = ""
        pin(); setControls([])
        let k = fit(text, max: n); lines = CGFloat(k)
        words.maximumNumberOfLines = k
        words.stringValue = text.count > 420 ? String(text.prefix(417)) + "…" : text
        place(); box.reading = true
        present()
        hide(after: seconds)
    }

    /// A short receipt. With a `button` (Undo) it stays 5 s, so the button can be reached.
    func flash(_ text: String, button: StripButton? = nil) {
        if panel == nil { panel = make() }
        styledDraft = false; words.textColor = Native.muted; box.long = false; box.done = false; box.countdown = nil; setState("Drafter"); status.stringValue = ""
        pin(); setControls(button.map { [$0] } ?? [])
        lines = CGFloat(fit(text, max: 2)); words.maximumNumberOfLines = Int(lines); words.stringValue = text
        place(); box.reading = true
        present()
        hide(after: button == nil ? 1.8 : 5)
    }
    // Isolated renderer: no microphone, engine, real text fields, or screen capture.
    func preview(_ folder: String) throws {
        previewing = true
        previewNotch = 200
        // each state as it hangs from a made-up notch (or floats under a made-up menu bar)
        func shot(_ name: String) throws {
            let n = previewNotch ?? 0, bar = n == 0 ? 28 : (box.dotFromTop + 3) * 2
            try UIShots.strip(box, folder + "/\(name).png", notch: n, bar: bar)
        }
        listening()
        precondition(state.stringValue.isEmpty && status.stringValue.isEmpty)
        try shot("strip-idle")
        let sample = "Давай зробимо цей інтерфейс спокійнішим. Чіткий текст, менше зайвого і все на своєму місці."
        draft(sample); draft(sample + " Ще кілька слів.")
        let height = box.frame.height
        try shot("strip-listening")
        for (i, pk) in [Float(0.01), 0.05, 0.12, 0.2, 0.08].enumerated() { levelAt = .distantPast; heldMe = 0; level(pk); if i == 3 { try shot("strip-level") } }
        draft("")
        precondition(box.frame.height == height, "Inserting a piece must not collapse the strip")
        try shot("strip-inserted")
        reading()
        precondition(words.stringValue != ClassicStrip.insertedNote && state.stringValue == "Reading", "Never Reading over Inserted")
        try shot("strip-reading")
        recording(call: true, seconds: 83, title: "Voice panel design", outline: ["Agree on the voice panel design and the way it opens under the notch on every screen", "Keep the familiar shortcuts", "→ Check both appearances"],
                  event: "Design review: voice strip", shots: 3)
        box.levels = (3, 1)
        precondition(controls.count == 1 && controls[0].label == "Stop & save", "Stop stays in reach while recording")
        precondition(words.stringValue.components(separatedBy: "\n").count == 2 && box.bounds.contains(controls[0].frame), "Recording: a title line and one point")
        try shot("strip-recording")
        recording(call: true, seconds: 95, title: "Voice panel design", outline: [], event: "Design review: voice strip", shots: 3,
                  warning: "Not hearing the other side yet")
        box.levels = (2, 0)
        try shot("strip-warning")
        warned = nil
        Offer.show(CallWatch.ask(name: "Zoom", title: "Design review: voice strip with the whole product and design team", people: ["Mila Synthetic", "Sava Synthetic"]),
                   kind: "Call", side: "Zoom", accept: "Record", seconds: 30, app: "us.zoom.xos") {}
        box.countdown = (Date().addingTimeInterval(-10), 30)
        precondition(controls.map(\.label) == ["Record", "Dismiss", "Turn off offers in Zoom"], "The offer's keys are buttons")
        precondition(controls.allSatisfy { box.bounds.contains($0.frame) }, "Keys never cut")
        try shot("strip-offer")
        Offer.dismiss("preview")
        flash("Offers off in Slack", button: StripButton("Undo", key: "", style: .primary) {})
        try shot("strip-undo")
        landed()
        precondition(box.done && state.stringValue == "In the field")
        try shot("strip-done")
        flash("Copied · ⌘V to paste")
        precondition(lines == 1, "A one-line receipt takes one line")
        try shot("strip-receipt")
        listening()
        precondition(words.stringValue.isEmpty && !box.reading && !box.long)
        try shot("strip-reset")
        previewNotch = 0
        listening(); draft("A quieter interface, clear words, and the same familiar keys. This is a sample for a screen without a notch.")
        precondition(box.floating && box.bounds.contains(state.frame) && box.bounds.contains(status.frame))
        try shot("strip-floating")
    }

}

final class ClassicStripView: NSView {
    var dotFromTop: CGFloat = 10
    var floating = false
    var reading = false
    var long = false
    var done = false                              // the text went in: a check instead of the microphone
    var hearing = false                           // the last words are being read: a blue wave instead of the microphone
    var countdown: (Date, Double)?                // an offer's time: a thin line along the bottom that runs out
    var levels: (me: Int, them: Int?)?            // 0-4 bars each, a long note or call only
    var appearanceChanged: (() -> Void)?

    static func bars(_ pk: Float) -> Int { pk < 0.004 ? 0 : pk < 0.02 ? 1 : pk < 0.06 ? 2 : pk < 0.15 ? 3 : 4 }


    /// "me ▮▮▯▯  them ▮▯▯▯": four 2 pt bars, lit in the speaker's colour (as in Calls & notes: me blue, them coral).
    /// A short take has no names: its meter stands right after the microphone.
    private func drawLevels(_ l: (me: Int, them: Int?), mid: CGFloat, named: Bool) {
        var x: CGFloat = named ? 36 : 36
        let font = Native.mono(10)
        for (label, n, color) in [("me", l.me, Native.blue)] + (l.them.map { [("them", $0, Native.coral)] } ?? []) {
            if named {
                let a: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: Native.muted]
                let size = (label as NSString).size(withAttributes: a)
                (label as NSString).draw(at: NSPoint(x: x, y: (mid - size.height / 2).rounded()), withAttributes: a)
                x += ceil(size.width) + 4
            }
            for i in 0..<4 {
                let h = CGFloat(2 + i * 2)
                (i < n ? color : Native.faint.withAlphaComponent(0.35)).setFill()
                NSBezierPath(rect: NSRect(x: x + CGFloat(i * 3), y: (mid - 4).rounded(), width: 2, height: h)).fill()
            }
            x += 12 + 8
        }
    }
    /// The check draws in over three steps when a take lands (none under Reduce Motion).
    private var drawnAt: Date?
    func drawIn() {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { drawnAt = nil; return }
        drawnAt = Date()
        for k in 1...3 { DispatchQueue.main.asyncAfter(deadline: .now() + 0.045 * Double(k)) { [weak self] in self?.needsDisplay = true } }
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance(); appearanceChanged?(); needsDisplay = true
    }
    override func draw(_ r: NSRect) {
        let path = Native.outline(bounds, hanging: !floating)
        NSColor.black.setFill(); path.fill()
        let mid = bounds.height - dotFromTop - 3
        let mark = NSRect(x: 12, y: (mid - 8).rounded(), width: 16, height: 16)
        if done {
            // the verified mark in green, drawn in left to right as the take lands
            let step = drawnAt.map { min(1, CGFloat(Date().timeIntervalSince($0) / 0.135) + 0.34) } ?? 1
            NSGraphicsContext.saveGraphicsState()
            NSRect(x: mark.minX, y: mark.minY, width: (mark.width * step).rounded(), height: mark.height).clip()
            Native.drawMark("verified", in: mark, line: Native.mint)
            NSGraphicsContext.restoreGraphicsState()
        } else if reading {
            // reading the last words: the wave in blue; an offer or a note waits: the microphone, not live, in grey
            hearing ? Native.drawMark("waveform", in: mark, tint: Native.blue) : Native.drawMark("mic", in: mark, tint: Native.faint)
        } else {
            // the microphone in the live colour; no glow
            Native.drawMark("mic", in: mark, tint: Native.coral)
        }
        if let l = levels, !done, !reading { drawLevels(l, mid: mid + 1, named: long) }
        if let (from, secs) = countdown {
            let left = max(0, 1 - Date().timeIntervalSince(from) / secs)
            Native.faint.withAlphaComponent(0.6).setFill()
            NSBezierPath(rect: NSRect(x: 16, y: 3, width: ((bounds.width - 32) * left).rounded(), height: 1.5)).fill()
        }
    }
}

// The renders' way in (Preview.swift stripStyles): the same states through the same calls, shot as `preview` does.
extension ClassicStrip {
    func previewOn(notch: CGFloat) { previewing = true; previewNotch = notch; if panel == nil { panel = make() } }
    func previewLevels(_ n: Int) {
        for i in 0..<n { levelAt = .distantPast; heldMe = 0; level(Float(0.004 + 0.18 * abs(sin(Double(i) * 0.7) * sin(Double(i) * 0.23)))) }
    }
    func previewShot(_ path: String) throws {
        let n = previewNotch ?? 0, bar = n == 0 ? 28 : (box.dotFromTop + 3) * 2
        try UIShots.strip(box, path, notch: n, bar: bar)
    }
}

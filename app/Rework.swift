// ⌥Tab on a selection (1 November 2026; Apple Writing Tools, Raycast AI; item 7 in docs/typing-models-research.md).
// The user selects text in any field and presses ⌥Tab: a small list opens under the selection - Shorter, Fix, Clearer,
// Warmer, Formal, List, Translate - or the user types what to do. 1-7, or ↑ ↓ and Tab / Return, picks; the text goes to
// engine `/rework` (Claude through the user's `claude` sign-in, the local model offline) and the new text shows in the list.
// Tab or Return puts it over the selection (a paste, so line breaks never send a chat message); a digit tries another
// command; Esc keeps the user's text. Backspace as the very next key after Tab brings the user's text back (⌘Z in the app works too).
// Nothing leaves the Mac before the user picks a command. Not in skipped apps, password fields or under secure input.
// Synonyms (2026-11-15): on one word or a 2-3 word phrase the list starts with up to 6 offline synonyms from engine
// `/synonyms` (a thesaurus on this Mac, nothing sent); 1-6 pick them and the commands follow (SynonymRules).
import AppKit
import Carbon
import ScreenCaptureKit

final class Rework {
    static let shared = Rework()
    enum State { case closed, menu, working, result, failed }
    private(set) var state: State = .closed
    var isOpen: Bool { state != .closed }
    struct Cmd { let id: String; let name: String; var hint: String }
    var cmds: [Cmd] = [
        Cmd(id: "shorter", name: "Shorter", hint: "about half as long"),
        Cmd(id: "fix", name: "Fix", hint: "typos and endings only"),
        Cmd(id: "clearer", name: "Clearer", hint: "plain words, point first"),
        Cmd(id: "warmer", name: "Warmer", hint: "friendlier"),
        Cmd(id: "formal", name: "Formal", hint: "for a business message"),
        Cmd(id: "list", name: "List", hint: "one point a line"),
        Cmd(id: "translate", name: "Translate", hint: "→ English"),
    ]
    var sel = 0
    var typed = ""                  // the user's own instruction
    private(set) var original = "", result = "", ran = "", by = "", ms = 0
    private var el: AXUIElement?, pid: pid_t = 0, app = "", bundle = "", anchor = CGRect.zero, seq = 0
    private var screen = "", kb = ""   // the chat above and the keyboard when it opened (engine/whom.py; context stays on the Mac)
    struct Syn { let text: String; let base: Bool }
    private(set) var syns: [Syn] = []
    private var synAsked = false, synMs = 0, synPicked = 0
    /// Rows in the menu before the typed one: synonyms, then the commands.
    var rows: Int { syns.count + cmds.count }
    struct Done { let el: AXUIElement; let old: String; let new: String; let revision: Int; let at: Date }
    static var last: Done?

    /// "uk", "en" or nil: which letters most of the text is in (12+ letters; Russian is never "uk"). For the Translate
    /// row's hint; moved here from the translate chip (app/Translate.swift, removed 2026-11-17).
    static func lang(_ t: String, share: Double = 0.8) -> String? {
        var lat = 0, cyr = 0
        for u in t.unicodeScalars {
            if (65...90).contains(u.value) || (97...122).contains(u.value) { lat += 1 }
            else if (0x410...0x44F).contains(u.value) || [0x404, 0x406, 0x407, 0x454, 0x456, 0x457, 0x490, 0x491].contains(u.value) { cyr += 1 }
        }
        let n = lat + cyr
        guard n >= 12 else { return nil }
        if Double(cyr) / Double(n) >= share { return t.unicodeScalars.filter { Autocorrect.russian.contains($0) }.count > 2 ? nil : "uk" }
        if Double(lat) / Double(n) >= share { return "en" }
        return nil
    }

    let panel: NSPanel
    let view = ReworkView()

    init() {
        panel = NSPanel(contentRect: .zero, styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: true)
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true
        panel.level = .popUpMenu; panel.ignoresMouseEvents = true; panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.contentView = GlassHost(view, inset: 0)
    }

    /// In the event tap, no Accessibility calls: could ⌥Tab open the list here at all?
    func mayStart() -> Bool {
        let st = Drafter.shared.settings
        guard st.rework, Talk.shared.keysFree, !IsSecureEventInputEnabled(),
              let front = NSWorkspace.shared.frontmostApplication, !st.skip.contains(front.bundleIdentifier ?? "") else { return false }
        return true
    }

    /// ⌥Tab, off the tap: open on a selection. false = nothing selected here, the key goes on to the app.
    func start() -> Bool {
        if isOpen { close("⌥tab"); return true }
        guard mayStart(), let front = NSWorkspace.shared.frontmostApplication, let el = Focus.focused() else { return false }
        AXUIElementSetMessagingTimeout(el, 0.15)
        let role: String = Focus.attr(el, kAXRoleAttribute) ?? "", sub: String = Focus.attr(el, kAXSubroleAttribute) ?? ""
        guard role != "AXSecureTextField", sub != (kAXSecureTextFieldSubrole as String),
              let text = Focus.selection(), text.trimmingCharacters(in: .whitespacesAndNewlines).count >= 2,
              (text as NSString).length <= 3000 else { return false }
        Fields.end("rework")
        Keys.shared.cancel(); Ghost.shared.hide()
        self.el = el; pid = front.processIdentifier; app = front.localizedName ?? ""; bundle = front.bundleIdentifier ?? ""
        original = text; typed = ""; sel = 0; result = ""; ran = ""
        screen = Keys.shared.screenText(el); kb = KeyLayout.language
        cmds[6].hint = Rework.lang(text, share: 0.6) == "uk" ? "→ English" : "→ Українська"
        anchor = Focus.selectionRect(el) ?? Focus.frame(el) ?? CGRect(x: NSEvent.mouseLocation.x, y: 200, width: 1, height: 18)
        state = .menu
        syns = []; synAsked = false; synMs = 0; synPicked = 0
        Engine.shared.post("/rework", ["warm": true])
        if SynonymRules.asks(text) { askSynonyms(text, before: Focus.before(el) ?? "") }
        draw()
        log("rework: open, \(text.count) chars in \(front.bundleIdentifier ?? "?")")
        return true
    }

    func close(_ why: String) {
        guard isOpen else { return }
        state = .closed; seq += 1
        if synAsked { log(SynonymRules.logLine(shown: syns.count, picked: synPicked, ms: synMs)); synAsked = false }
        panel.orderOut(nil)
        log("rework: closed (\(why))")
    }

    /// Keys while the list is open. true = swallowed; false = it goes to the app (the list closed first).
    func key(_ code: Int64, typed ch: String, mods: CGEventFlags) -> Bool {
        if NSWorkspace.shared.frontmostApplication?.processIdentifier != pid { close("app changed"); return false }
        if code == 48, mods == .maskAlternate { close("⌥tab"); return true }
        if !mods.subtracting(.maskShift).isEmpty { close("shortcut"); return false }
        let digit = ch.count == 1 ? Int(ch).flatMap { SynonymRules.digit($0, synonyms: syns.count, commands: cmds.count) } : nil
        switch state {
        case .menu:
            switch code {
            case 53: close("esc")
            case 126: sel = max(0, sel - 1); draw()
            case 125: sel = min(rows, sel + 1); draw()
            case 36, 76, 48:
                if !typed.trimmingCharacters(in: .whitespaces).isEmpty { run("custom") }
                else if let p = SynonymRules.row(sel, synonyms: syns.count, commands: cmds.count) { pick(p) }
            case 51: if !typed.isEmpty { typed.removeLast(); draw() }
            case 123, 124, 115, 119, 116, 121: close("arrow"); return false
            default:
                if typed.isEmpty, let p = digit { pick(p) }
                else if let c = ch.unicodeScalars.first, !CharacterSet.controlCharacters.contains(c), typed.count < 200 {
                    typed += ch; sel = rows; draw()
                }
            }
            return true
        case .working, .result, .failed:
            switch code {
            case 53: close("esc"); return true
            case 36, 76, 48:
                // closed now, so a second key cannot apply it twice; the field is checked off the tap
                if state == .result { close("tab"); DispatchQueue.main.async { self.apply() } }
                return true
            default:
                if let p = digit { pick(p); return true }
                close("typed"); return false          // the user types on: their key goes to the app as usual
            }
        case .closed: return false
        }
    }

    /// A row the user picked: a synonym goes over the selection at once, a command runs.
    func pick(_ p: SynonymRules.Pick) {
        switch p {
        case .command(let i): run(cmds[i].id)
        case .synonym(let i):
            guard i < syns.count else { return }
            synPicked = i + 1; result = syns[i].text; ran = "synonym"
            close("synonym")                    // closed now, so a second key cannot apply it twice
            DispatchQueue.main.async { self.apply() }
        }
    }

    /// Offline synonyms for a short selection (engine/synonyms.py); they show only if the list is still untouched.
    private func askSynonyms(_ text: String, before: String) {
        synAsked = true
        let mine = seq, t0 = Date()
        Engine.shared.post("/synonyms", ["text": text, "before": String(before.suffix(200))], timeout: 1.5) { j in
            self.synMs = Int(Date().timeIntervalSince(t0) * 1000)
            guard mine == self.seq, self.state == .menu, self.typed.isEmpty, self.sel == 0 else { return }
            let items = (j?["items"] as? [[String: Any]] ?? []).prefix(SynonymRules.maxShown)
            self.syns = items.compactMap { d in
                guard let t = d["text"] as? String, !t.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
                return Syn(text: t, base: d["form"] as? String == "base")
            }
            if !self.syns.isEmpty { self.draw() }
        }
    }

    func run(_ cmd: String) {
        ran = cmd; state = .working; seq += 1
        let mine = seq, t0 = Date()
        draw()
        let st = Drafter.shared.settings
        Engine.shared.post("/rework", ["text": original, "cmd": cmd, "custom": cmd == "custom" ? typed : "", "app": app,
                                       "notes": WritingNotes.forApp(bundle, global: st.writingNote, perApp: st.appNotes), "kb": kb, "context": screen], timeout: 45) { j in
            guard mine == self.seq, self.state == .working else { return }
            let out = (j?["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            self.ms = Int(Date().timeIntervalSince(t0) * 1000)
            log("rework \(cmd) \(self.ms)ms by \(j?["by"] as? String ?? "-") " + (out.isEmpty ? "none" : "\(self.original.count) → \(out.count) chars"))
            if out.isEmpty { self.state = .failed } else { self.result = out; self.by = j?["by"] as? String ?? ""; self.state = .result }
            self.draw()
        }
    }

    /// Tab on the result: pasted over the selection, if it is still the user's selection; else it goes to the clipboard.
    func apply() {
        let new = result, old = original
        guard let el else { close("no field"); return }
        close("tab")   // already closed by the key; kept for other callers
        guard let now = Focus.focused(), CFEqual(now, el), NSWorkspace.shared.frontmostApplication?.processIdentifier == pid,
              Focus.selection() == old else {
            NSPasteboard.general.clearContents(); NSPasteboard.general.setString(new, forType: .string)
            Ghost.shared.flash("Selection changed · new text copied"); log("rework: selection changed, copied"); return
        }
        Focus.paste(new)
        Rework.last = Done(el: el, old: old, new: new, revision: Keys.shared.inputRevision, at: Date())
        log("rework applied \(ran), \(old.count) → \(new.count) chars")
    }

    /// Backspace as the very next key after Tab: the user's own text comes back.
    static func takeBack() -> Bool {
        guard let d = last, Keys.shared.inputRevision == d.revision + 1, Date().timeIntervalSince(d.at) < 60 else { last = nil; return false }
        last = nil
        guard let now = Focus.focused(), CFEqual(now, d.el), Focus.before(now)?.hasSuffix(Fixer.norm(d.new)) ?? false else { return false }
        DispatchQueue.main.async {
            Fields.left(d.new.count, shift: true)
            Focus.paste(d.old)
            log("rework taken back")
        }
        return true
    }

    // MARK: drawing

    func draw() {
        view.model = self
        let size = view.fit()
        // under the selection, else above it (AX rects are top-left based)
        let scr = NSScreen.screens.first(where: { $0.frame.contains(NSPoint(x: anchor.midX, y: (NSScreen.screens.first?.frame.height ?? 0) - anchor.midY)) }) ?? NSScreen.main
        let h = NSScreen.screens.first?.frame.height ?? 0, vis = scr?.visibleFrame ?? .zero
        var x = anchor.minX, y = h - anchor.maxY - 6 - size.height
        if y < vis.minY + 4 { y = h - anchor.minY + 6 }
        y = min(max(y, vis.minY + 4), vis.maxY - size.height - 4)
        x = min(max(x, vis.minX + 4), vis.maxX - size.width - 4)
        panel.setFrame(NSRect(x: x, y: y, width: size.width, height: size.height), display: true)
        view.needsDisplay = true
        panel.invalidateShadow()
        Panel.appear(panel)
    }
}

/// The list, the working line and the result, drawn flat on the window ground (small corners, a hairline).
final class ReworkView: NSView {
    weak var model: Rework?
    override var isFlipped: Bool { true }
    let W: CGFloat = 380, pad: CGFloat = 10, row: CGFloat = 24

    private func a(_ size: CGFloat, _ color: NSColor, mono: Bool = false, weight: NSFont.Weight = .regular) -> [NSAttributedString.Key: Any] {
        [.font: mono ? Native.mono(size, weight) : Native.text(size, weight), .foregroundColor: color]
    }
    private var resultText: NSAttributedString {
        let p = NSMutableParagraphStyle(); p.lineBreakMode = .byWordWrapping; p.lineSpacing = 2
        return NSAttributedString(string: model?.result ?? "", attributes: a(13, Native.ink).merging([.paragraphStyle: p]) { x, _ in x })
    }
    private func resultHeight() -> CGFloat {
        let r = resultText.boundingRect(with: NSSize(width: W - 2 * pad, height: 10_000), options: [.usesLineFragmentOrigin, .usesFontLeading])
        return min(ceil(r.height), 15 * 12)
    }

    func fit() -> NSSize {
        guard let m = model else { return .zero }
        switch m.state {
        case .menu: return NSSize(width: W, height: 28 + CGFloat(m.rows + 1) * row + 8 + (m.syns.isEmpty ? 0 : 6))
        case .working, .failed: return NSSize(width: W, height: 28 + row + 8)
        case .result: return NSSize(width: W, height: 28 + resultHeight() + 12 + row + 6)
        case .closed: return .zero
        }
    }

    private func cap(_ t: String, at p: NSPoint) -> CGFloat {   // the panels' small key cap; returns its width
        Panel.keycap(t, x: p.x, y: p.y - 2, h: 18)
    }

    override func draw(_ dirty: NSRect) {
        guard let m = model else { return }
        Panel.ground(bounds, glass: true)
        // head: the kind square, what is going on, esc on the right
        Native.drawMark(Kind.rework.mark, in: NSRect(x: pad - 2, y: 6, width: 16, height: 16), tint: Kind.rework.color)
        let name = m.ran == "custom" ? "Your words" : (m.cmds.first { $0.id == m.ran }?.name ?? "")
        let head: String
        switch m.state {
        case .menu: head = m.syns.isEmpty ? "Rework · \(m.original.count) characters" : "Synonyms · on this Mac"
        case .working: head = "\(name) · writing…"
        case .result: head = "\(name) · \(m.by) · \(String(format: "%.1f", Double(m.ms) / 1000)) s"
        case .failed: head = "\(name) · nothing better came back"
        case .closed: head = ""
        }
        (head as NSString).draw(at: NSPoint(x: pad + 20, y: 6), withAttributes: a(11.5, Native.muted))
        _ = cap("esc", at: NSPoint(x: W - pad - Panel.capWidth("esc", h: 18), y: 6))
        Native.rule.setFill(); NSRect(x: 0, y: 26, width: W, height: 1).fill()
        var y: CGFloat = 30
        switch m.state {
        case .menu:
            for (i, s) in m.syns.enumerated() {
                if i == m.sel { Native.pick.setFill(); NSBezierPath(roundedRect: NSRect(x: 4, y: y, width: W - 8, height: row), xRadius: Panel.control - 2, yRadius: Panel.control - 2).fill() }
                if let l = SynonymRules.label(i) { _ = cap(l, at: NSPoint(x: pad, y: y + 4)) }
                let t = s.text.trimmingCharacters(in: .whitespaces)
                (t as NSString).draw(with: NSRect(x: pad + 26, y: y + 4, width: W - pad * 2 - 26 - 80, height: 18),
                                     options: [.truncatesLastVisibleLine, .usesLineFragmentOrigin], attributes: a(13, Native.ink))
                if s.base { ("base form" as NSString).draw(at: NSPoint(x: W - pad - 66, y: y + 5), withAttributes: a(12, Native.faint)) }
                y += row
            }
            if !m.syns.isEmpty { Native.rule.setFill(); NSRect(x: 0, y: y + 2, width: W, height: 1).fill(); y += 6 }
            for (k, c) in m.cmds.enumerated() {
                let i = m.syns.count + k
                if i == m.sel { Native.pick.setFill(); NSBezierPath(roundedRect: NSRect(x: 4, y: y, width: W - 8, height: row), xRadius: Panel.control - 2, yRadius: Panel.control - 2).fill() }
                if let l = SynonymRules.label(i) { _ = cap(l, at: NSPoint(x: pad, y: y + 4)) }
                (c.name as NSString).draw(at: NSPoint(x: pad + 26, y: y + 4), withAttributes: a(13, Native.ink))
                (c.hint as NSString).draw(at: NSPoint(x: pad + 110, y: y + 5), withAttributes: a(12, Native.muted))
                y += row
            }
            if m.sel == m.rows { Native.pick.setFill(); NSBezierPath(roundedRect: NSRect(x: 4, y: y, width: W - 8, height: row), xRadius: Panel.control - 2, yRadius: Panel.control - 2).fill() }
            let t = m.typed.isEmpty ? "or type what to do…" : m.typed
            (t as NSString).draw(with: NSRect(x: pad + 26, y: y + 4, width: W - pad * 2 - 26 - 50, height: 18), options: [.truncatesLastVisibleLine, .usesLineFragmentOrigin],
                                 attributes: a(13, m.typed.isEmpty ? Native.faint : Native.ink))
            if !m.typed.isEmpty { _ = cap("⏎", at: NSPoint(x: W - pad - 22, y: y + 4)) }
        case .working, .failed:
            (("1-\(min(9, m.rows)) another") as NSString).draw(at: NSPoint(x: pad, y: y + 4), withAttributes: a(12, Native.muted))
        case .result:
            let h = resultHeight()
            resultText.draw(with: NSRect(x: pad, y: y + 2, width: W - 2 * pad, height: h), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
            y += h + 10
            Native.rule.setFill(); NSRect(x: 0, y: y - 4, width: W, height: 1).fill()
            var x = pad
            x += cap("tab", at: NSPoint(x: x, y: y + 2)) + 5
            ("replace" as NSString).draw(at: NSPoint(x: x, y: y + 2), withAttributes: a(12, Native.muted)); x += 62
            x += cap("1-\(min(9, m.rows))", at: NSPoint(x: x, y: y + 2)) + 5
            ("another" as NSString).draw(at: NSPoint(x: x, y: y + 2), withAttributes: a(12, Native.muted))
        case .closed: break
        }
    }
}

private var reworkShots = 0

extension Rework {
    /// Test: a picture of the list and the text around it into data/rework-N.png (post <bundle id>.reworkshot).
    func shot() {
        guard panel.isVisible, let scr = NSScreen.screens.first else { log("reworkshot: nothing shown"); return }
        let f = panel.frame, h = scr.frame.height
        let r = CGRect(x: f.minX - 40, y: h - f.maxY - 20, width: f.width + 80, height: f.height + 90)
        SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: true) { c, _ in
            guard let d = c?.displays.first else { return }
            let cfg = SCStreamConfiguration(); cfg.sourceRect = r; cfg.width = Int(r.width * 2); cfg.height = Int(r.height * 2)
            SCScreenshotManager.captureImage(contentFilter: SCContentFilter(display: d, excludingWindows: []), configuration: cfg) { img, _ in
                reworkShots += 1
                let out = Home.data.appendingPathComponent("rework-\(reworkShots).png")
                if let img, let dest = CGImageDestinationCreateWithURL(out as CFURL, "public.png" as CFString, 1, nil) {
                    CGImageDestinationAddImage(dest, img, nil); CGImageDestinationFinalize(dest)
                }
                log("reworkshot: \(img == nil ? "failed" : "saved")")
            }
        }
    }
}

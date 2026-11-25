// What is focused, what is typed before the caret, where the caret is, and how to put text there.
import AppKit
import ApplicationServices
import Carbon

struct Spot {
    let app: NSRunningApplication
    let el: AXUIElement
    let value: String          // whole field text
    let caret: Int             // UTF-16 offset
    let before: String
    let title: String
    var rect: CGRect?          // caret, in AX (top-left) screen coordinates; a fallback anchor when `anchor` is not exact
    let role: String
    var viaMarkers = false     // rich editor read through text markers: insert by paste only
    /// Mid-line (setting `midLine`, 2026-11-15): the rest of the caret's line, not blank, at a gap between words
    /// (GhostRules.midLineOK). Empty and `mid` false everywhere else.
    var lineAfter = ""
    var mid = false
    /// Where `rect` came from (round 2026-11-17-anchor): the caret itself, an estimate, or a chip place near the field.
    var anchor: AnchorKind = .exact
}

enum Focus {
    /// spot() runs on main and off it (the careful read, the context queue): the app it last saw and the per-process
    /// sets below are touched only under this lock (Argon 3: two threads inserting into one Set corrupt it).
    private static let stateLock = NSLock()
    private static var _lastApp: NSRunningApplication?
    static var lastApp: NSRunningApplication? {
        get { stateLock.lock(); defer { stateLock.unlock() }; return _lastApp }
        set { stateLock.lock(); _lastApp = newValue; stateLock.unlock() }
    }
    static let system = AXUIElementCreateSystemWide()
    private static var woken = Set<pid_t>()
    /// Marks `pid` woken (or enhanced) under the lock. -> true the first time.
    private static func firstWake(_ pid: pid_t) -> Bool { stateLock.lock(); defer { stateLock.unlock() }; return woken.insert(pid).inserted }
    private static func firstEnhance(_ pid: pid_t) -> Bool { stateLock.lock(); defer { stateLock.unlock() }; return enhanced.insert(pid).inserted }
    /// An Electron app asked while it is still starting forgets the ask (Beeper, 2026-11-16: asked in its first second,
    /// both flags read 0 forty minutes later, no ghost since). So the ask repeats while the flag reads off, at most once
    /// per `askGap` per process. -> true when it is time to ask again.
    private static var asked: [pid_t: Date] = [:]
    static let askGap: TimeInterval = 5
    private static func askDue(_ pid: pid_t, now: Date = Date()) -> Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        if let t = asked[pid], now.timeIntervalSince(t) < askGap { return false }
        asked[pid] = now; return true
    }
    private static func flagOff(_ a: AXUIElement, _ name: String) -> Bool {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(a, name as CFString, &v) == .success, let n = v as? NSNumber else { return true }
        return !n.boolValue
    }

    /// Drafter's own windows answer Accessibility on Drafter's main thread. Asked from any other thread, the call waits
    /// for main; when main is itself waiting in an AX call (the HIServices lock that background call holds), both wait
    /// for good (3 November 2026: `Talk.readNames` -> `screenContext` read Drafter's own window from a background queue
    /// while main sat in `Shots.tick` -> `windowTitle`; the call froze and his side of a 53-minute call was lost).
    /// So off the main thread nothing here touches Drafter's own process, its elements or the system-wide element while
    /// Drafter is in front (that one is answered by the front app, which is then Drafter).
    static let ownPid = getpid()
    static func offLimits(pid: pid_t) -> Bool { pid == ownPid && !Thread.isMainThread }
    static func offLimits(_ el: AXUIElement) -> Bool {
        guard !Thread.isMainThread else { return false }
        if CFEqual(el, system) { return ownInFront }    // it has no pid (AXUIElementGetPid fails on it; Argon 4)
        var pid: pid_t = 0
        guard AXUIElementGetPid(el, &pid) == .success else { return false }
        return pid == ownPid || (pid == 0 && ownInFront)
    }
    /// Drafter's own window is the front one (its window, the command panel).
    static var ownInFront: Bool { NSWorkspace.shared.frontmostApplication?.processIdentifier == ownPid }
    private static var refusals = 0
    private static let refusalLock = NSLock()
    private static func refused(_ what: String) {
        refusalLock.lock(); refusals += 1; let n = refusals; refusalLock.unlock()
        if n == 1 || n % 500 == 0 { log("accessibility: \(what) of Drafter's own window skipped off the main thread (\(n) so far)") }
    }

    @discardableResult
    static func trusted(prompt: Bool = false) -> Bool {
        let o = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: prompt] as CFDictionary
        return AXIsProcessTrustedWithOptions(o)
    }

    /// Every flag ask sent (both kinds); a put-in logs how many came while its deck was up (PutRules).
    private(set) static var asks = 0
    /// A Chromium browser (AXEnhancedUserInterface at once); other web apps are Electron (AXManualAccessibility first).
    static func browser(_ id: String) -> Bool {
        id.hasPrefix("com.google.Chrome") || id.hasPrefix("com.brave") || id.hasPrefix("com.microsoft.edgemac") || id.hasPrefix("company.thebrowser.") || id.hasPrefix("com.vivaldi") || id.hasPrefix("com.operasoftware")
    }

    /// Chrome and Electron apps (Beeper) build their accessibility tree only when asked. Never while a capture is up
    /// (PutRules.mayAskAccessibility): the ask can move the app's windows and the focus.
    static func wake(_ app: NSRunningApplication) {
        guard app.processIdentifier != ownPid, PutRules.mayAskAccessibility(captureUp: PutBack.captureUp) else { return }
        let a = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(a, 0.15)
        // the first time always; after that only while the app reads the flag as off (it forgot an early ask)
        guard firstWake(app.processIdentifier) || (isWeb(app) && askDue(app.processIdentifier) && flagOff(a, "AXManualAccessibility")) else { return }
        AXUIElementSetAttributeValue(a, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        asks += 1
        if browser(app.bundleIdentifier ?? "") {
            AXUIElementSetAttributeValue(a, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
            asks += 1
        }
    }

    static func attr<T>(_ el: AXUIElement, _ name: String) -> T? {
        if offLimits(el) { refused(name); return nil }
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, name as CFString, &v) == .success else { return nil }
        return v as? T
    }

    private static var enhanced: Set<pid_t> = []

    static func focused() -> AXUIElement? {
        // the app's own focused element first: Electron apps (Beeper) often give nothing through the system-wide one
        if let app = NSWorkspace.shared.frontmostApplication {
            if offLimits(pid: app.processIdentifier) { refused("focus"); return nil }
            let a = AXUIElementCreateApplication(app.processIdentifier)
            AXUIElementSetMessagingTimeout(a, 0.15)
            var f: CFTypeRef?
            if AXUIElementCopyAttributeValue(a, kAXFocusedUIElementAttribute as CFString, &f) == .success, let f { return (f as! AXUIElement) }
            // an Electron app that ignores AXManualAccessibility (Codex, 2026-10-21: "no focus" on every key) builds its
            // tree for AXEnhancedUserInterface, as Chrome does; asked once per process
            // never while a capture is up (PutRules.mayAskAccessibility); an Electron app gets AXManualAccessibility
            // first and AXEnhancedUserInterface only when that gave no focus
            let pid = app.processIdentifier
            if isWeb(app), PutRules.mayAskAccessibility(captureUp: PutBack.captureUp) {
                let first = firstEnhance(pid)
                if first || (askDue(pid) && flagOff(a, "AXEnhancedUserInterface")) {
                    AXUIElementSetAttributeValue(a, "AXManualAccessibility" as CFString, kCFBooleanTrue)
                    asks += 1
                    let enhanceNow = PutRules.enhancedAtOnce(browser: browser(app.bundleIdentifier ?? ""))
                    if !enhanceNow, AXUIElementCopyAttributeValue(a, kAXFocusedUIElementAttribute as CFString, &f) == .success, let f {
                        log("accessibility: manual mode \(first ? "asked" : "asked again") for \(app.bundleIdentifier ?? "?")")
                        return (f as! AXUIElement)
                    }
                    AXUIElementSetAttributeValue(a, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
                    asks += 1
                    log("accessibility: enhanced mode \(first ? "asked" : "asked again") for \(app.bundleIdentifier ?? "?")")
                    if AXUIElementCopyAttributeValue(a, kAXFocusedUIElementAttribute as CFString, &f) == .success, let f { return (f as! AXUIElement) }
                }
            }
        }
        if offLimits(system) { refused("focus"); return nil }
        AXUIElementSetMessagingTimeout(system, AXOff.timeout)   // the system-wide value is every element's default
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &v) == .success, let v else { return nil }
        return (v as! AXUIElement)
    }

    /// The field's own font at the caret (the character before it), so the grey text looks like the text around it.
    /// nil when the app does not say (many Chromium fields).
    static func font(_ el: AXUIElement, caret: Int) -> (NSFont, NSColor?)? {
        guard caret > 0, !offLimits(el) else { return nil }
        var r = CFRange(location: caret - 1, length: 1)
        guard let arg = AXValueCreate(.cfRange, &r) else { return nil }
        var v: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(el, kAXAttributedStringForRangeParameterizedAttribute as CFString, arg, &v) == .success,
              let a = v as? NSAttributedString, a.length > 0 else { return nil }
        let at = a.attributes(at: 0, effectiveRange: nil)
        guard let f = at[NSAttributedString.Key("AXFont")] as? [String: Any],
              let size = (f["AXFontSize"] as? NSNumber)?.doubleValue, size >= 8, size <= 40 else { return nil }
        let name = f["AXFontName"] as? String ?? ""
        let font = NSFont(name: name, size: size) ?? .systemFont(ofSize: size)
        var color: NSColor?
        if let c = at[NSAttributedString.Key("AXForegroundColor")], CFGetTypeID(c as CFTypeRef) == CGColor.typeID { color = NSColor(cgColor: c as! CGColor) }
        return (font, color)
    }

    static func range(_ el: AXUIElement) -> CFRange? {
        guard let v: AXValue = attr(el, kAXSelectedTextRangeAttribute) else { return nil }
        var r = CFRange(); return AXValueGetValue(v, .cfRange, &r) ? r : nil
    }

    static func bounds(_ el: AXUIElement, _ loc: Int, _ len: Int) -> CGRect? {
        if offLimits(el) { return nil }
        var r = CFRange(location: loc, length: len)
        guard let arg = AXValueCreate(.cfRange, &r) else { return nil }
        var v: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(el, kAXBoundsForRangeParameterizedAttribute as CFString, arg, &v) == .success,
              let v else { return nil }
        var rect = CGRect.zero
        guard AXValueGetValue(v as! AXValue, .cgRect, &rect), rect.height > 2, rect.height < 200 else { return nil }
        return rect
    }

    /// Chromium and Electron: the selection as a text marker range, measured with AXBoundsForTextMarkerRange.
    static func markerRect(_ el: AXUIElement) -> CGRect? {
        if offLimits(el) { return nil }
        var m: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, "AXSelectedTextMarkerRange" as CFString, &m) == .success, let m else { return nil }
        var v: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(el, "AXBoundsForTextMarkerRange" as CFString, m, &v) == .success, let v,
              CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
        var rect = CGRect.zero
        guard AXValueGetValue(v as! AXValue, .cgRect, &rect), rect.height > 2, rect.height < 200, rect.origin != .zero else { return nil }
        return CGRect(x: rect.maxX, y: rect.minY, width: 1, height: rect.height)
    }

    /// Caret rectangle: a zero-length range where the app supports it, else the character before the caret,
    /// else the text-marker way (Chromium, Electron).
    static func caretRect(_ el: AXUIElement, _ caret: Int, _ value: NSString) -> CGRect? {
        if let r = markerRect(el) { return r }
        if let r = bounds(el, caret, 0), r.origin != .zero {
            // TextEdit at the very end of the text gives the empty range a line too high (2026-11-01 probe: y 265 vs
            // 278 for the letter before, same x); the letter before is right there
            if caret > 0, caret == value.length, value.character(at: caret - 1) != 10, let p = bounds(el, caret - 1, 1), p.origin != .zero,
               abs(p.maxX - r.minX) < 2, abs(p.minY - r.minY) > r.height / 2 {
                return CGRect(x: p.maxX, y: p.minY, width: 1, height: p.height)
            }
            return CGRect(x: r.minX, y: r.minY, width: 1, height: r.height)
        }
        if caret > 0, value.character(at: caret - 1) != 10, let r = bounds(el, caret - 1, 1), r.origin != .zero {
            return CGRect(x: r.maxX, y: r.minY, width: 1, height: r.height)
        }
        return caret > 0 ? prevCharRect(el) : nil
    }

    static func windowTitle(_ app: NSRunningApplication) -> String {
        if offLimits(pid: app.processIdentifier) { refused("window title"); return "" }
        let a = AXUIElementCreateApplication(app.processIdentifier)
        // a short wait: a hung app must not hold the caller for 6 s (Shots and the capture read it off main, AXOff)
        AXUIElementSetMessagingTimeout(a, AXOff.timeout)
        guard let w: AXUIElement = attr(a, kAXFocusedWindowAttribute) else { return "" }
        return attr(w, kAXTitleAttribute) ?? ""
    }

    /// Rich editors in Chromium apps (Dia, Gmail, Notion-style boxes) give an AXGroup with no value and no caret
    /// range; their text and caret come through text markers instead. -> (before, after, caret rect)
    static func markers(_ el: AXUIElement) -> (String, String, CGRect?)? {
        if offLimits(el) { return nil }
        // only an editable box: a page or a video player has markers too
        var editable: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, "AXEditableAncestor" as CFString, &editable) == .success, editable != nil else { return nil }
        var r: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, "AXSelectedTextMarkerRange" as CFString, &r) == .success, let r,
              CFGetTypeID(r) == AXTextMarkerRangeGetTypeID() else { return nil }
        let sel = r as! AXTextMarkerRange
        var whole: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(el, "AXTextMarkerRangeForUIElement" as CFString, el, &whole) == .success,
              let whole, CFGetTypeID(whole) == AXTextMarkerRangeGetTypeID() else { return nil }
        let caret = AXTextMarkerRangeCopyStartMarker(sel), selEnd = AXTextMarkerRangeCopyEndMarker(sel)
        let start = AXTextMarkerRangeCopyStartMarker(whole as! AXTextMarkerRange), end = AXTextMarkerRangeCopyEndMarker(whole as! AXTextMarkerRange)
        func text(_ a: AXTextMarker, _ b: AXTextMarker) -> String {
            var v: CFTypeRef?
            let range = AXTextMarkerRangeCreate(nil, a, b)
            guard AXUIElementCopyParameterizedAttributeValue(el, "AXStringForTextMarkerRange" as CFString, range, &v) == .success else { return "" }
            return v as? String ?? ""
        }
        if !text(caret, selEnd).isEmpty { return nil }   // a selection: stay quiet
        let strip: (String) -> String = { $0.replacingOccurrences(of: "\u{FFFC}", with: "") }   // embedded objects
        let before = strip(text(start, caret)), after = strip(text(caret, end))
        let rect = prevCharRect(el, caret: caret) ?? markerRect(el)
        return (before, after, rect)
    }

    /// The caret as the right edge of the character before it, through text markers (Chromium, Electron).
    static func prevCharRect(_ el: AXUIElement, caret given: AXTextMarker? = nil) -> CGRect? {
        if offLimits(el) { return nil }
        var caret = given
        if caret == nil {
            var r: CFTypeRef?
            guard AXUIElementCopyAttributeValue(el, "AXSelectedTextMarkerRange" as CFString, &r) == .success, let r,
                  CFGetTypeID(r) == AXTextMarkerRangeGetTypeID() else { return nil }
            caret = AXTextMarkerRangeCopyStartMarker(r as! AXTextMarkerRange)
        }
        guard let caret else { return nil }
        // caret rect: the character before it, measured (a collapsed range often measures as nothing)
        var rect: CGRect?
        var prev: CFTypeRef?
        if AXUIElementCopyParameterizedAttributeValue(el, "AXPreviousTextMarkerForTextMarker" as CFString, caret, &prev) == .success, let prev,
           CFGetTypeID(prev) == AXTextMarkerGetTypeID() {
            var b: CFTypeRef?
            let range = AXTextMarkerRangeCreate(nil, prev as! AXTextMarker, caret)
            if AXUIElementCopyParameterizedAttributeValue(el, "AXBoundsForTextMarkerRange" as CFString, range, &b) == .success, let b {
                var rc = CGRect.zero
                if AXValueGetValue(b as! AXValue, .cgRect, &rc), rc.height > 2, rc.height < 200, rc.origin != .zero {
                    // Chromium can measure a whole paragraph; the ghost wants one line, the last one
                    let h = min(rc.height, 22)
                    rect = CGRect(x: rc.maxX, y: rc.maxY - h, width: 1, height: h)
                }
            }
        }
        return rect
    }

    /// Nil when Drafter must stay quiet: skipped app, password field, a selection, or the caret is not at a line end.
    /// `midLine`: the ghost paths in Keys pass the setting; then a caret at a gap mid-line gives a spot with `mid` set
    /// (GhostRules.midLineOK). Native fields use their value and range; Chromium and Electron only their text markers
    /// (their value miscounts line breaks); a web field with no markers or no caret rect stays "mid-line".
    static func spot(skip: [String], midLine: Bool = false, anchor: Bool = false) -> (Spot?, String) {
        var (s, why) = read(skip: skip, midLine: midLine)
        guard anchor, let sp = s, Thread.isMainThread, !offLimits(sp.el) else { return (s, why) }
        if why == "ok", sp.rect != nil {
            noteExact(sp); chipAnchor = nil
        } else if why == "no caret rect", let a = fallback(sp) {
            var f = sp; f.rect = a.rect; f.anchor = a.kind; s = f
            noteKind(sp, a); chipAnchor = a.kind == .chip ? a.rect : nil
        }
        return (s, why)   // why stays "no caret rect": Caret.note and the axprobe still count the field
    }

    // MARK: fallback anchor (roadmap item 6, docs/rounds/2026-11-17-anchor.md)

    /// The last field that gave a real caret rect, and when: a miss right after one is a missed read, not an editor
    /// without a caret rect (Claude and Beeper miss about 8 in 100 reads), so it stays quiet as before.
    private static var lastExact: (el: AXUIElement, at: Date)?
    /// The rect of the last chip-kind anchor: Ghost.show draws grey words given this rect as a chip (main thread only).
    static var chipAnchor: CGRect?
    private static var anchorSeen: [String: AnchorKind] = [:]
    private static func noteExact(_ s: Spot) {
        lastExact = (s.el, Date())
        if let l = AnchorRules.change(&anchorSeen, app: s.app.bundleIdentifier ?? "?", kind: .exact, source: "caret", role: s.role) { log(l) }
    }
    private static func noteKind(_ s: Spot, _ a: Anchor) {
        if let l = AnchorRules.change(&anchorSeen, app: s.app.bundleIdentifier ?? "?", kind: a.kind, source: a.source, role: s.role) { log(l) }
    }

    /// The field gave no caret rect: what else Accessibility answers, then AnchorRules picks. Main thread only.
    static func fallback(_ s: Spot) -> Anchor? {
        if offLimits(s.el) || s.mid { return nil }
        var i = AnchorInput()
        i.role = s.role
        i.before = s.before
        i.recentExact = lastExact.map { CFEqual($0.el, s.el) && Date().timeIntervalSince($0.at) < 2 } ?? false
        if i.recentExact { return nil }
        i.frame = frame(s.el)
        if !s.viaMarkers {
            // (b) the caret's line from its first character: the visual line where the field answers AXLineForIndex
            let ns = s.value as NSString
            let caret = min(max(s.caret, 0), ns.length)
            var start = (ns.substring(to: caret) as NSString).range(of: "\n", options: .backwards).location
            start = start == NSNotFound ? 0 : start + 1
            if let line = lineStart(s.el, caret: caret), line <= caret, line >= start { start = line }
            if start < caret {
                i.span = bounds(s.el, start, caret - start)
                i.lineStart = bounds(s.el, start, 1)
                i.before = ns.substring(to: caret)
                if let (f, _) = font(s.el, caret: caret) { i.fontSize = f.pointSize }
            }
        }
        if let f = i.frame, let scr = NSScreen.screens.first(where: { axFrame($0).intersects(f) }) ?? NSScreen.main {
            i.visible = axFrame(scr, visible: true)
        }
        let measure: (String, CGFloat) -> CGFloat = { t, size in (t as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: size)]).width }
        return AnchorRules.pick(i, measure: measure)
    }

    /// The first character of the visual line holding the caret, where the field answers AXLineForIndex/AXRangeForLine.
    private static func lineStart(_ el: AXUIElement, caret: Int) -> Int? {
        if offLimits(el) { return nil }
        var idx: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(el, kAXLineForIndexParameterizedAttribute as CFString, NSNumber(value: max(0, caret - 1)), &idx) == .success,
              let line = idx as? NSNumber else { return nil }
        var rv: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(el, kAXRangeForLineParameterizedAttribute as CFString, line, &rv) == .success,
              let rv, CFGetTypeID(rv) == AXValueGetTypeID() else { return nil }
        var r = CFRange()
        return AXValueGetValue(rv as! AXValue, .cfRange, &r) ? r.location : nil
    }

    /// A screen's frame (or visible frame) in AX coordinates (top-left of the primary screen).
    private static func axFrame(_ scr: NSScreen, visible: Bool = false) -> CGRect {
        let f = visible ? scr.visibleFrame : scr.frame
        let h = NSScreen.screens.first?.frame.height ?? f.height
        return CGRect(x: f.minX, y: h - f.maxY, width: f.width, height: f.height)
    }

    private static func read(skip: [String], midLine: Bool) -> (Spot?, String) {
        guard let app = NSWorkspace.shared.frontmostApplication else { return (nil, "no app") }
        lastApp = app
        if offLimits(pid: app.processIdentifier) { return (nil, "own app") }
        // password managers and the system's password prompts: never, even for voice's empty skip list (InsertRules.never)
        if skip.contains(app.bundleIdentifier ?? "") || InsertRules.neverInto(app.bundleIdentifier) { return (nil, "skipped app") }
        if IsSecureEventInputEnabled() { return (nil, "secure input") }
        wake(app)
        guard let el = focused() else { return (nil, "no focus") }
        AXUIElementSetMessagingTimeout(el, 0.15)
        let role: String = attr(el, kAXRoleAttribute) ?? ""
        let sub: String = attr(el, kAXSubroleAttribute) ?? ""
        if sub == (kAXSecureTextFieldSubrole as String) || role == "AXSecureTextField" { return (nil, "password field") }
        let plainValue: String? = attr(el, kAXValueAttribute)
        if (plainValue ?? "").isEmpty, role == "AXGroup" || role == "AXWebArea" || role == "AXTextArea",
           let (b, a, rect) = markers(el), !(b.isEmpty && a.isEmpty) {
            if !a.isEmpty, !a.hasPrefix("\n"), !a.trimmingCharacters(in: .whitespaces).isEmpty,
               a.first.map({ !$0.isNewline }) ?? false, !(a.components(separatedBy: "\n").first ?? "").trimmingCharacters(in: .whitespaces).isEmpty {
                guard midLine, let sp = midSpot(app, el, before: b, after: a, rect: rect, role: role, markers: true) else { return (nil, "mid-line") }
                return (sp, "ok")
            }
            var sp = Spot(app: app, el: el, value: b + a, caret: (b as NSString).length, before: b, title: windowTitle(app), rect: rect, role: role)
            sp.viaMarkers = true
            return (sp, rect == nil ? "no caret rect" : "ok")
        }
        guard let value = plainValue, let r = range(el) else { return (nil, "not text: \(role)") }
        if r.length > 0 { return (nil, "selection") }
        let ns = value as NSString
        let caret = min(max(r.location, 0), ns.length)
        if caret < ns.length, ns.character(at: caret) != 10 {
            // only at the end of a line, so a ghost never covers text that is already there
            let rest = ns.substring(from: caret)
            if !rest.hasPrefix("\n"), rest.trimmingCharacters(in: .whitespaces).isEmpty == false {
                // Chromium (the Claude app) counts each line break in the value but not in the caret offset, so after a
                // break the caret reads a letter early and Drafter stayed quiet for the rest of the message (2026-11-01:
                // «…styling of it \nl», caret before the l). The text markers give the two sides as they are.
                let m = markers(el)
                if let (b, a, mrect) = m, a.isEmpty || a.hasPrefix("\n") || (a.components(separatedBy: "\n").first ?? "").trimmingCharacters(in: .whitespaces).isEmpty {
                    let squash = { (t: String) in String(t.filter { !$0.isWhitespace }.suffix(16)) }
                    // at the very end: the plain value keeps his line breaks (markers may not), when both end alike
                    let atEnd = a.isEmpty && squash(value) == squash(b)
                    var sp = Spot(app: app, el: el, value: atEnd ? value : b + a, caret: atEnd ? ns.length : (b as NSString).length,
                                  before: atEnd ? value : b, title: windowTitle(app), rect: mrect, role: role)
                    sp.viaMarkers = true
                    return (sp, mrect == nil ? "no caret rect" : "ok")
                }
                if midLine {
                    // markers are the truth where there are any; a web field without them is not trusted mid-line
                    if let (b, a, mrect) = m {
                        if let sp = midSpot(app, el, before: b, after: a, rect: mrect, role: role, markers: true) { return (sp, "ok") }
                    } else if !isWeb(app), let sp = midSpot(app, el, before: ns.substring(to: caret), after: rest,
                                                             rect: caretRect(el, caret, ns), role: role, markers: false, value: value, caret: caret) {
                        return (sp, "ok")
                    }
                }
                return (nil, "mid-line")
            }
        }
        let before = ns.substring(to: caret)
        let rect = caretRect(el, caret, ns)
        return (Spot(app: app, el: el, value: value, caret: caret, before: before, title: windowTitle(app), rect: rect, role: role), rect == nil ? "no caret rect" : "ok")
    }

    /// A spot for a caret mid-line, or nil (inside a word, a long rest, no caret rect: GhostRules.midLineOK).
    private static func midSpot(_ app: NSRunningApplication, _ el: AXUIElement, before b: String, after a: String, rect: CGRect?,
                                role: String, markers: Bool, value: String? = nil, caret: Int? = nil) -> Spot? {
        let rest = GhostRules.lineRest(a)
        guard let rect, GhostRules.midLineOK(before: b, rest: rest) else { return nil }
        var sp = Spot(app: app, el: el, value: value ?? b + a, caret: caret ?? (b as NSString).length, before: b,
                      title: windowTitle(app), rect: rect, role: role)
        sp.viaMarkers = markers; sp.lineAfter = rest; sp.mid = true
        return sp
    }

    /// The text on screen just before the field: the conversation he is answering (chat apps, Claude, mail).
    /// Walks back from the field through earlier siblings and up the parents, nearest text first, so a long
    /// conversation is never read in full. Runs off the main thread; stops at `maxChars`, `maxNodes` or `budget` s.
    static func screenContext(_ el: AXUIElement, maxChars: Int = 2500, maxNodes: Int = 5000, budget: Double = 0.4) -> String {
        if offLimits(el) { refused("screen text"); return "" }
        let t0 = Date()
        var parts: [String] = [], chars = 0, nodes = 0
        func done() -> Bool { chars >= maxChars || nodes >= maxNodes || Date().timeIntervalSince(t0) > budget }
        func kids(_ e: AXUIElement) -> [AXUIElement] { (attr(e, kAXChildrenAttribute) as [AXUIElement]?) ?? [] }
        /// all text under e, last child first (so the nearest text comes first)
        func back(_ e: AXUIElement, _ depth: Int) {
            if done() || depth > 40 { return }
            nodes += 1
            AXUIElementSetMessagingTimeout(e, 0.05)
            let role: String = attr(e, kAXRoleAttribute) ?? ""
            if role == "AXStaticText" || role == "AXTextArea" || role == "AXTextField" {
                let v: String = (attr(e, kAXValueAttribute) as String?) ?? (attr(e, kAXTitleAttribute) as String?) ?? ""
                let t = v.trimmingCharacters(in: .whitespacesAndNewlines)
                // messages, not interface labels ("not done", "Used 2 tools", "Send"): 4+ words or 30+ characters
                let words = t.split(whereSeparator: { $0.isWhitespace }).count
                if (words >= 4 || t.count >= 30), !t.contains("⟦drafter-test⟧"), t.range(of: #"^(Used \d+ tools?|[\d.,]+k? tokens)"#, options: .regularExpression) == nil {
                    parts.append(t); chars += t.count
                }
                if role == "AXStaticText" { return }
            }
            if role == "AXSecureTextField" || role == "AXButton" || role == "AXMenu" || role == "AXMenuBar" { return }
            for k in kids(e).reversed() { back(k, depth + 1); if done() { return } }
        }
        var cur = el
        for _ in 0..<30 {
            guard let parent: AXUIElement = attr(cur, kAXParentAttribute) else { break }
            let sibs = kids(parent)
            if let i = sibs.firstIndex(where: { CFEqual($0, cur) }) {
                for k in sibs[..<i].reversed() { back(k, 0); if done() { break } }
            }
            if done() { break }
            let role: String = attr(parent, kAXRoleAttribute) ?? ""
            if role == "AXWindow" { break }
            cur = parent
        }
        // nearest first -> reading order; drop times and one-letter labels
        let keep = parts.reversed().filter { $0.count > 1 && $0.range(of: #"^\d{1,2}:\d{2}$"#, options: .regularExpression) == nil }
        var text = keep.joined(separator: "\n")
        if text.count > maxChars { text = String(text.suffix(maxChars)) }
        return text
    }

    /// The whole selection in the focused field (plain AX, or text markers in Chromium rich editors).
    static func selection() -> String? {
        guard let el = focused(), !offLimits(el) else { return nil }
        if let s: String = attr(el, kAXSelectedTextAttribute), !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return s }
        var r: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, "AXSelectedTextMarkerRange" as CFString, &r) == .success, let r,
              CFGetTypeID(r) == AXTextMarkerRangeGetTypeID() else { return nil }
        var v: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(el, "AXStringForTextMarkerRange" as CFString, r, &v) == .success,
              let t = v as? String, !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return t.replacingOccurrences(of: "\u{FFFC}", with: "")
    }

    /// The text before the caret, no-break spaces read as spaces (a native field's value, else text markers).
    static func before(_ el: AXUIElement) -> String? {
        if let v: String = attr(el, kAXValueAttribute), !v.isEmpty, let r = range(el) {
            let ns = v as NSString
            return ns.substring(to: min(max(r.location, 0), ns.length)).replacingOccurrences(of: "\u{A0}", with: " ")
        }
        if let (b, _, _) = markers(el) { return b.replacingOccurrences(of: "\u{A0}", with: " ") }
        return nil
    }

    /// The selected text's box (AX, top-left based): its range in a native field, its text markers in Chromium.
    static func selectionRect(_ el: AXUIElement) -> CGRect? {
        if offLimits(el) { return nil }
        if let r = range(el), r.length > 0, let b = bounds(el, r.location, r.length), b.origin != .zero, b.height > 2 { return b }
        var m: CFTypeRef?, v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, "AXSelectedTextMarkerRange" as CFString, &m) == .success, let m,
              AXUIElementCopyParameterizedAttributeValue(el, "AXBoundsForTextMarkerRange" as CFString, m, &v) == .success, let v,
              CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
        var rect = CGRect.zero
        guard AXValueGetValue(v as! AXValue, .cgRect, &rect), rect.height > 2, rect.origin != .zero else { return nil }
        return rect
    }

    /// Where an empty field starts (no character to measure a caret from): its left edge, one text line high.
    /// The field's whole frame (AX, top-left based).
    static func frame(_ el: AXUIElement) -> CGRect? {
        guard let pv: AXValue = attr(el, kAXPositionAttribute), let sv: AXValue = attr(el, kAXSizeAttribute) else { return nil }
        var p = CGPoint.zero, z = CGSize.zero
        AXValueGetValue(pv, .cgPoint, &p); AXValueGetValue(sv, .cgSize, &z)
        return z.width > 20 && z.height > 8 ? CGRect(origin: p, size: z) : nil
    }

    static func fieldStart(_ el: AXUIElement) -> CGRect? {
        guard let pv: AXValue = attr(el, kAXPositionAttribute), let sv: AXValue = attr(el, kAXSizeAttribute) else { return nil }
        var p = CGPoint.zero, z = CGSize.zero
        AXValueGetValue(pv, .cgPoint, &p); AXValueGetValue(sv, .cgSize, &z)
        guard z.width > 20, z.height > 8 else { return nil }
        let h = min(18, z.height - 4)
        return CGRect(x: p.x + 8, y: p.y + min(z.height / 2 - h / 2, 10), width: 1, height: h)
    }

    static func selectedText() -> String? {
        guard let el = focused(), let s: String = attr(el, kAXSelectedTextAttribute), !s.isEmpty, s.count < 60 else { return nil }
        return s
    }

    // MARK: insert

    static let mark: Int64 = 0x7479_7069   // "typi": our own key events, the tap lets them pass
    /// Characters put into fields other than by his letter keys (every write Drafter makes, and his ⌘V): a draft's
    /// length may come from them (DraftCaptureRules, Keys.keepDraft). Only `wrote` adds to it; every write path in the
    /// app goes through `setSelectedText`, `typeText` or `commandV`, which call it (tests/test_draft_writes.py).
    private(set) static var ownChars = 0
    static func wrote(_ n: Int) { stateLock.lock(); ownChars += n; stateLock.unlock() }

    /// The one AX text write (replaces the selection, or puts text at the caret), counted.
    @discardableResult
    static func setSelectedText(_ el: AXUIElement, _ text: String) -> AXError {
        if offLimits(el) { return .cannotComplete }   // never its own window off the main thread
        let r = AXUIElementSetAttributeValue(el, kAXSelectedTextAttribute as CFString, text as CFString)
        if r == .success { wrote(text.count) }
        return r
    }

    /// ⌘V into the front app, marked as Drafter's own so the tap lets it through; the clipboard's text is counted.
    static func commandV() {
        wrote(NSPasteboard.general.string(forType: .string)?.count ?? 0)
        let src = CGEventSource(stateID: .hidSystemState)
        for down in [true, false] {
            let e = CGEvent(keyboardEventSource: src, virtualKey: 9, keyDown: down)   // V
            e?.flags = .maskCommand
            e?.setIntegerValueField(.eventSourceUserData, value: mark)
            e?.post(tap: .cghidEventTap)
        }
    }

    /// Electron and Chromium apps (Codex, Claude, Beeper, Slack, browsers): an AX write can show in the box while the
    /// page never hears of it (2026-10-21, Codex: the text was not really in the composer), so they always get a paste.
    private static var webCache: [pid_t: Bool] = [:]
    static func isWeb(_ app: NSRunningApplication) -> Bool {
        stateLock.lock(); let known = webCache[app.processIdentifier]; stateLock.unlock()
        if let v = known { return v }
        let fw = app.bundleURL?.appendingPathComponent("Contents/Frameworks")
        let names = (fw.flatMap { try? FileManager.default.contentsOfDirectory(atPath: $0.path) }) ?? []
        let id = app.bundleIdentifier ?? ""
        let asar = app.bundleURL.map { FileManager.default.fileExists(atPath: $0.appendingPathComponent("Contents/Resources/app.asar").path) } ?? false
        // Electron renames its framework at times ("Codex Framework" in ChatGPT.app / Codex), but app.asar stays
        let v = asar || names.contains { $0.hasPrefix("Electron Framework") || $0.contains("Chromium") || $0.hasPrefix("Google Chrome Framework") }
            || ["com.google.Chrome", "com.brave.Browser", "com.microsoft.edgemac", "company.thebrowser.", "com.vivaldi", "com.operasoftware"].contains { id.hasPrefix($0) }
        stateLock.lock(); webCache[app.processIdentifier] = v; stateLock.unlock()
        return v
    }

    /// How long a paste keeps his clipboard swapped: a busy Electron app reads it late, and putting his own clipboard
    /// back first pasted that instead (0.4 s was too short for Codex).
    static var restoreDelay: Double { NSWorkspace.shared.frontmostApplication.map { isWeb($0) } == true ? 1.0 : 0.4 }

    /// Where a voice text can still go when there is no clean spot (caret mid-line, text selected, a rich box with no
    /// value): any focused element in a normal app gets a paste at its caret, as ⌘V would.
    static func pasteTarget(_ why: String) -> Bool {
        guard !["no app", "skipped app", "secure input", "password field", "no focus"].contains(why),
              !IsSecureEventInputEnabled(), focused() != nil else { return false }
        return true
    }

    /// AX first (replace the empty selection at the caret), checked by reading the field back; else paste.
    static func insert(_ text: String, at spot: Spot) -> String {
        // a rich editor read through markers has no value to check an AX write against: paste only
        if spot.viaMarkers || isWeb(spot.app) || offLimits(spot.el) { paste(text); return "paste" }
        if setSelectedText(spot.el, text) == .success {
            // insert audit 2026-11-23: a field that changed some other way (the app reformatted the text) took the
            // write; a paste on top of it put the text in twice (InsertRules.afterAXWrite)
            let w = InsertRules.afterAXWrite(old: spot.value, caret: spot.caret, before: spot.before, text: text, now: attr(spot.el, kAXValueAttribute))
            if !InsertRules.pasteAfterAX(w) { return w == .landed ? "ax" : "ax changed" }
        }
        paste(text)
        return "paste"
    }

    /// Types text at the caret as key events (no clipboard), in pieces of up to 16 UTF-16 units. Marked as Drafter's own.
    static func typeText(_ text: String) {
        guard !text.isEmpty else { return }
        // a line break or another control character sent as a key can send a chat message or move the focus: such a
        // text goes in as a paste (Codex review 2026-11-01: translations, snippets and take-backs typed "\n")
        if text.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F || $0.value == 0x85 || $0.value == 0x2028 || $0.value == 0x2029 }) {
            paste(text); return
        }
        wrote(text.count)
        let src = CGEventSource(stateID: .hidSystemState)
        let units = Array(text.utf16)
        var i = 0
        while i < units.count {
            var j = min(i + 16, units.count)
            if j < units.count, UTF16.isLeadSurrogate(units[j - 1]) { j -= 1 }   // never split an emoji
            var chunk = Array(units[i..<j])
            for down in [true, false] {
                let e = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: down)
                e?.flags = []; e?.setIntegerValueField(.eventSourceUserData, value: mark)
                e?.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: &chunk)
                e?.post(tap: .cghidEventTap)
            }
            i = j
        }
    }

    static func backspace(_ n: Int) {
        guard n > 0 else { return }
        let src = CGEventSource(stateID: .hidSystemState)
        for _ in 0..<n {
            for down in [true, false] {
                let e = CGEvent(keyboardEventSource: src, virtualKey: 51, keyDown: down)
                e?.flags = []; e?.setIntegerValueField(.eventSourceUserData, value: mark); e?.post(tap: .cghidEventTap)
            }
        }
    }

    /// Replace `old`, which sits right before the caret, with `new`. Only when the field still ends with it.
    static func replace(_ old: String, with new: String, done: @escaping (Bool) -> Void) {
        guard !old.isEmpty, !IsSecureEventInputEnabled(),
              let s = spot(skip: []).0, !offLimits(s.el), s.before.hasSuffix(old) else { done(false); return }
        if s.viaMarkers || isWeb(s.app) {
            // Rich fields cannot reliably set an AX range. Select with the same
            // marked arrow events as snippet fields, then verify before pasting.
            let revision = Keys.shared.inputRevision
            Fields.left(old.count, shift: true)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                guard !IsSecureEventInputEnabled(), Keys.shared.inputRevision == revision,
                      NSWorkspace.shared.frontmostApplication?.processIdentifier == s.app.processIdentifier,
                      let el = focused(), CFEqual(el, s.el), selection() == old else {
                    // Undo our Shift+Left selection even on a revision/selection
                    // mismatch. Never send recovery keys into another field.
                    if NSWorkspace.shared.frontmostApplication?.processIdentifier == s.app.processIdentifier,
                       let el = focused(), CFEqual(el, s.el), selection() != "" {
                        Fields.right(1)
                    }
                    done(false); return
                }
                paste(new)
                done(true)
            }
            return
        }
        let n = (old as NSString).length
        var r = CFRange(location: s.caret - n, length: n)
        guard let v = AXValueCreate(.cfRange, &r),
              AXUIElementSetAttributeValue(s.el, kAXSelectedTextRangeAttribute as CFString, v) == .success,
              let sel: String = attr(s.el, kAXSelectedTextAttribute), sel == old else { done(false); return }
        // a field that reformatted the new words still took them: no paste on top (InsertRules.replacedByAX)
        if Focus.setSelectedText(s.el, new) == .success,
           InsertRules.replacedByAX(old: s.value, new: new, now: attr(s.el, kAXValueAttribute)) { done(true); return }
        paste(new)   // the old words are selected, so a paste replaces them
        done(true)
    }

    /// `restore: false` leaves the text on the clipboard (a fallback paste that may have missed: ⌘V still has it).
    /// His clipboard while one of Drafter's pastes still sits on it, and that paste's change count.
    private static var owed: (items: [NSPasteboardItem], count: Int)?

    /// `write`: puts other types instead of the text (a picture, a file URL; round three), the same way back.
    /// Told of each text Drafter pastes (the app sets it to PasteWatch.own; a pure test leaves it nil).
    static var pasted: ((String) -> Void)?
    static func paste(_ text: String, restore: Bool = true, write: ((NSPasteboard) -> Void)? = nil) {
        let pb = NSPasteboard.general
        if write == nil { pasted?(text) }   // the paste trail (soft round, PasteWatch.own): where Drafter put a text, no text kept
        // a second paste before the first one put his clipboard back (Backspace right after a rework): what is on the
        // clipboard now is Drafter's own text, so the one to give back is still the first one's (Codex review 2026-11-01)
        let saved: [NSPasteboardItem]
        if let o = owed, pb.changeCount == o.count { saved = o.items }
        else {
            saved = pb.pasteboardItems?.map { item -> NSPasteboardItem in
                let copy = NSPasteboardItem()
                for t in item.types { if let d = item.data(forType: t) { copy.setData(d, forType: t) } }
                return copy
            } ?? []
        }
        owed = nil
        pb.clearContents()
        if let write { write(pb) } else { pb.setString(text, forType: .string) }
        pb.setString("1", forType: History.ownType)   // Drafter's own: the clipboard history skips it
        let mine = pb.changeCount
        if restore { owed = (saved, mine) }
        commandV()
        DispatchQueue.main.asyncAfter(deadline: .now() + restoreDelay) {
            guard restore, pb.changeCount == mine else { return }   // he copied something meanwhile (or another paste came): keep that
            owed = nil
            pb.clearContents()
            if !saved.isEmpty { pb.writeObjects(saved) }
            History.skipChange(pb.changeCount)   // his own clipboard back: not a new copy for the history
        }
    }

    /// `Drafter --probe`: prints what Drafter sees every second, for checking an app by hand.
    static func probeLoop() {
        setbuf(stdout, nil)
        if let i = CommandLine.arguments.firstIndex(of: "--app"), i + 1 < CommandLine.arguments.count,
           let app = NSRunningApplication.runningApplications(withBundleIdentifier: CommandLine.arguments[i + 1]).first {
            // that app's focused element, from the background (nothing is typed or clicked)
            wake(app); Thread.sleep(forTimeInterval: 1)
            let a = AXUIElementCreateApplication(app.processIdentifier)
            var f: CFTypeRef?
            AXUIElementCopyAttributeValue(a, kAXFocusedUIElementAttribute as CFString, &f)
            guard let f else { print("no focus in", app.localizedName ?? ""); return }
            let el = f as! AXUIElement
            print("role", (attr(el, kAXRoleAttribute) as String?) ?? "?", "value", ((attr(el, kAXValueAttribute) as String?) ?? "nil").debugDescription)
            if let (b, a2, r) = markers(el) { print("markers before=\(b.suffix(60).debugDescription) after=\(a2.prefix(40).debugDescription) rect=\(r as Any)") }
            else { print("no markers") }
            // the caret rect each way (2026-11-01: a ghost at the end of a TextEdit document sat a line too high)
            if NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier {
                let (sp, why) = spot(skip: [])
                print("spot \(why) before=\(String((sp?.before ?? "").suffix(40)).debugDescription) markers=\(sp?.viaMarkers ?? false)")
            }
            if let r = range(el) {
                print("caret \(r.location) markerRect \(markerRect(el) as Any) zero \(bounds(el, r.location, 0) as Any) prev \(r.location > 0 ? bounds(el, r.location - 1, 1) as Any : "-")")
            }
            return
        }
        print("trusted:", trusted(prompt: true))
        while true {
            let (s, why) = spot(skip: [])
            if let s {
                print("\(s.app.localizedName ?? "?") role=\(s.role) caret=\(s.caret) rect=\(s.rect.map { "\(Int($0.minX)),\(Int($0.minY)) h\(Int($0.height))" } ?? "none") before=…\(String(s.before.suffix(30)).debugDescription)")
            } else {
                print("-", why, lastApp?.localizedName ?? "")
                if let el = focused(), let (b, a, r) = markers(el) {
                    print("  markers before=…\(String(b.suffix(60)).debugDescription) after=\(String(a.prefix(60)).debugDescription)… rect=\(r.map { "\(Int($0.minX)),\(Int($0.minY))" } ?? "none")")
                }
            }
            if CommandLine.arguments.contains("--ocr"), let s0 = spot(skip: []).0, let r = s0.rect {
                let t = Date(); let c = Screen.textAbove(pid: s0.app.processIdentifier, caret: r)
                print(String(format: "ocr %.0f ms, %d chars, allowed %@:", Date().timeIntervalSince(t) * 1000, c.count, "\(Screen.allowed)"), c.suffix(400).debugDescription)
            }
            if CommandLine.arguments.contains("--context"), let el = focused() {
                let t = Date(); let c = screenContext(el)
                print(String(format: "context %.0f ms, %d chars:", Date().timeIntervalSince(t) * 1000, c.count), c.suffix(500).debugDescription)
            }
            if let el = focused(), !CommandLine.arguments.contains("--context"), !CommandLine.arguments.contains("--ocr") {
                var names: CFArray?; AXUIElementCopyParameterizedAttributeNames(el, &names)
                let r = range(el)
                let pos: AXValue? = attr(el, kAXPositionAttribute), size: AXValue? = attr(el, kAXSizeAttribute)
                var p = CGPoint.zero, z = CGSize.zero
                if let pos { AXValueGetValue(pos, .cgPoint, &p) }; if let size { AXValueGetValue(size, .cgSize, &z) }
                print("  value:", ((attr(el, kAXValueAttribute) as String?) ?? "nil").debugDescription)
                print("  param:", (names as? [String]) ?? [], "range:", r.map { "\($0.location),\($0.length)" } ?? "nil",
                      "frame:", p, z, "b0:", r.flatMap { bounds(el, $0.location, 0) } as Any, "b-1:", r.flatMap { $0.location > 0 ? bounds(el, $0.location - 1, 1) : nil } as Any, "marker:", markerRect(el) as Any)
            }
            Thread.sleep(forTimeInterval: 1)
        }
    }
}

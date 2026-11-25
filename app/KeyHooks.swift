// The keys round's hooks into the event tap (14 November 2026): Backspace takes back the last Tab, Esc twice pauses
// ghosts in this field. Keys.handle and Keys.accept call these; the rules are in KeyRules.swift (pure, tested). Kept
// apart from Keys.swift so the ghost request path there stays as it is.
import AppKit
import Carbon

enum KeyHooks {
    /// What the last Tab put in, its field and app (set on the main queue once the insert went out).
    static var tabUndo: (rule: TabUndo, el: AXUIElement, pid: pid_t)?
    static var esc = EscPause()

    /// Keys.accept after a Tab or ⇧Tab put `piece` in (`rev` = editRevision at that key; nil = not from a Tab key).
    static func tabDone(piece: String, given: String, full: String, rev: Int?, at s: Spot) {
        tabUndo = nil
        guard let rev, Drafter.shared.settings.tabBack,
              let u = KeyRules.tabUndo(piece: piece, given: given, full: full, rev: rev, at: Date().timeIntervalSince1970) else { return }
        tabUndo = (u, s.el, s.app.processIdentifier)
    }

    /// On the tap, for a Backspace with no modifiers: true = it took the Tab back and the key is swallowed. The field
    /// is read here, so a Backspace that cannot take it back goes to the app as usual.
    static func tabBack() -> Bool {
        guard let t = tabUndo else { return false }
        tabUndo = nil
        let k = Keys.shared
        guard KeyRules.tabBack(t.rule, rev: k.editRevision, now: Date().timeIntervalSince1970, on: Drafter.shared.settings.tabBack),
              !IsSecureEventInputEnabled(), let front = NSWorkspace.shared.frontmostApplication, front.processIdentifier == t.pid,
              !Drafter.shared.settings.skip.contains(front.bundleIdentifier ?? ""),
              let el = Focus.focused(), CFEqual(el, t.el), KeyRules.stillEnds(before: Focus.before(el) ?? "", piece: t.rule.piece) else { return false }
        k.stat?.taken -= t.rule.piece.count
        k.cancel()
        let piece = t.rule.piece, ghost = t.rule.ghost
        DispatchQueue.main.async {
            Focus.backspace(piece.count)
            log("tab taken back \(piece.count) chars \(front.bundleIdentifier ?? "?")")
            // the grey text again where the caret is once the app took the keys out
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                guard let s = Focus.spot(skip: Drafter.shared.settings.skip, midLine: Keys.midLine).0, CFEqual(s.el, el), let r = s.rect, !Ghost.shared.visible else { return }
                k.spot = s
                Ghost.shared.unsure = 0
                Ghost.shared.show(s.mid ? GhostRules.midText(ghost, rest: s.lineAfter) : ghost, action: nil, at: r, mid: s.mid)
            }
        }
        return true
    }

    /// The focused field as a pause key.
    static func fieldKey(_ app: NSRunningApplication?, _ el: AXUIElement) -> String {
        KeyRules.fieldKey(app: app?.bundleIdentifier ?? "?", element: UInt(bitPattern: Int(CFHash(el))))
    }

    /// Ghosts are paused in this field (Esc twice).
    static func paused(_ s: Spot) -> Bool {
        Drafter.shared.settings.escPause && esc.paused(fieldKey(s.app, s.el), now: Date().timeIntervalSince1970)
    }

    /// On the tap, for an Esc with no modifiers: true = the second of a pair that paused or resumed (swallowed; the
    /// first Esc already reached the app). A single Esc stays the app's.
    static func escTwice(ghostVisible: Bool) -> Bool {
        guard Drafter.shared.settings.escPause, let el = Focus.focused() else { return false }
        let app = NSWorkspace.shared.frontmostApplication, k = Keys.shared
        let recent = ghostVisible || Date().timeIntervalSince(k.shownAt) < KeyRules.ghostRecent
        switch esc.esc(key: fieldKey(app, el), now: Date().timeIntervalSince1970, rev: k.editRevision, ghostRecent: recent) {
        case .none: return false
        case .paused:
            k.cancel()
            DispatchQueue.main.async { Ghost.shared.flash("Suggestions paused here for 10 min · esc esc to resume") }
            log("esc pause on \(app?.bundleIdentifier ?? "?") \(Int(EscPause.minutes)) min")
            return true
        case .resumed:
            DispatchQueue.main.async { Ghost.shared.flash("Suggestions back here") }
            log("esc pause off \(app?.bundleIdentifier ?? "?")")
            return true
        }
    }

    /// On the tap, for any key down: true = the voice note's flow took it (swallowed). False: the key goes on to the
    /// tap's other rules as before. Return on an armed draft inserts it; any other key disarms it (and is the app's);
    /// Esc drops it. A long recording or a call is never the flow's (Esc and Return stay the app's there).
    static func voiceKey(_ code: Int64, _ flags: CGEventFlags) -> Bool {
        let t = Talk.shared
        guard t.flow.state != .idle, !t.long else { return false }
        // Return while Right Option is held (push to talk) is still a bare Return (VoiceFlowRules.key)
        let e = VoiceFlowRules.key(code: code, flags: flags.rawValue)
        return t.flowEvent(e, tap: true)
    }
}

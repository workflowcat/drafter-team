// Typography as you type (15 November 2026): the event-tap side of app/TypoGraphRules.swift (pure, tested). Wired as
// the layout fix and autocorrect are: the key goes to the app as usual, then the field is read once it landed, the rule
// decides, and when no other key came in between (15 ms, as Snippets.afterSpace) the swap is written with key events
// (Focus.backspace + Focus.typeText, as Autocorrect.replace). Space is checked inside Snippets.afterSpace, which reads
// the field on every space already; other keys read it only when TypoGraphRules.mayFire says the key may complete a
// combo. Backspace as the very next key puts the plain keys back (as Autocorrect.takeBack); the key after a take-back
// never swaps. Never in skipped apps, code apps (TypoRules.codeApps), password fields or while secure input is on.
// One log line per swap: "typography <kind> <ms>ms", the time from the key to the write; no text.
import AppKit
import Carbon

enum Typography {
    struct Done { let swap: TypoSwap; let rev: Int; let el: AXUIElement; let pid: pid_t; let at: Date }
    static var last: Done?
    private static var recent = "", recentRev = -1, mute = -1

    static func options(_ st: Settings) -> TypoOptions? {
        guard st.typography else { return nil }
        var o = TypoOptions()
        o.dash = st.typographyDash; o.spacedDash = st.typographySpacedDash; o.ellipsis = st.typographyEllipsis
        o.quotes = st.typographyQuotes; o.apostrophe = st.typographyApostrophe
        o.apostropheMark = st.typographyApostropheMark == "’" ? "’" : "ʼ"
        o.arrows = st.typographyArrows; o.math = st.typographyMath; o.symbols = st.typographySymbols
        o.hryvnia = st.typographyHryvnia; o.nbsp = st.typographyNbsp
        return o
    }

    /// On the tap, for each key with no modifiers but Shift (`rev` = Keys.editRevision at this key): notes it and
    /// says whether the field is worth reading after it lands. A gap in revisions (a click, an arrow) forgets the keys.
    static func noteKey(_ typed: String, rev: Int) -> Bool {
        if rev != recentRev + 1 { recent = "" }
        recentRev = rev
        guard Drafter.shared.settings.typography, typed.count == 1, let u = typed.unicodeScalars.first,
              u.value >= 0x20, u.value != 0x7F, !(0xF700...0xF8FF).contains(u.value) else { recent = ""; return false }
        let may = TypoGraphRules.mayFire(recent: recent, key: typed) && rev != mute
        recent = String((recent + typed).suffix(4))
        return may
    }

    /// The swap for the key that just landed in the field `s` (its `before` ends with the key), or nil.
    static func decide(_ s: Spot, key: String) -> TypoSwap? {
        let st = Drafter.shared.settings
        guard let o = options(st), Keys.shared.editRevision != mute, !IsSecureEventInputEnabled() else { return nil }
        let id = s.app.bundleIdentifier ?? ""
        guard !st.skip.contains(id), !TypoRules.codeApps.contains(id) else { return nil }
        let before = s.before.replacingOccurrences(of: "\u{A0}", with: " ")
        guard before.hasSuffix(key) else { return nil }
        let head = String(before.dropLast(key.count))
        return TypoGraphRules.swap(before: head, key: key, ukrainian: TypoGraphRules.ukrainian(head) ?? KeyLayout.ukrainianNow, options: o)
    }

    /// After a key other than space (Keys.handle): read the field once the key landed, swap when a combo completed.
    static func afterKey(_ key: String, revision: Int, at t0: Date) {
        DispatchQueue.main.async { look(key, revision, t0) }
    }

    private static func look(_ key: String, _ revision: Int, _ t0: Date) {
        guard Keys.shared.inputRevision == revision, Drafter.shared.active, Talk.shared.keysFree else { return }
        guard let s = Focus.spot(skip: Drafter.shared.settings.skip, midLine: true).0 else { return }
        if !s.before.replacingOccurrences(of: "\u{A0}", with: " ").hasSuffix(key) {
            // the app has not put the key in yet: look again for up to 0.2 s
            if Date().timeIntervalSince(t0) < 0.2 { DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { look(key, revision, t0) } }
            return
        }
        guard let w = decide(s, key: key) else { return }
        // keys the user typed meanwhile wait in the tap: let them through first, and swap only if there were none
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.015) {
            guard Keys.shared.inputRevision == revision, !IsSecureEventInputEnabled() else { return }
            write(w, key: key, at: s, t0: t0)
        }
    }

    /// Takes out the combo's characters and the key, puts the swap in, remembers it for Backspace.
    static func write(_ w: TypoSwap, key: String, at s: Spot, t0: Date) {
        Keys.shared.cancel()
        Focus.backspace(w.remove + key.count)
        Focus.typeText(w.insert)
        last = Done(swap: w, rev: Keys.shared.editRevision, el: s.el, pid: s.app.processIdentifier, at: Date())
        log("typography \(w.kind) \(Int(Date().timeIntervalSince(t0) * 1000))ms")
    }

    /// On the tap, for a Backspace with no modifiers right after a swap: true = the plain keys come back and this
    /// Backspace is swallowed. The field is read here, so a Backspace that cannot take it back goes to the app.
    static func takeBack() -> Bool {
        guard let d = last else { return false }
        last = nil
        let k = Keys.shared
        guard TypoGraphRules.takeBack(rev: k.editRevision, swapRev: d.rev, now: Date().timeIntervalSince1970, at: d.at.timeIntervalSince1970),
              !IsSecureEventInputEnabled(), let front = NSWorkspace.shared.frontmostApplication, front.processIdentifier == d.pid,
              let el = Focus.focused(), CFEqual(el, d.el), TypoGraphRules.stillEnds(before: Focus.before(el) ?? "", insert: d.swap.insert) else { return false }
        mute = k.editRevision + 1   // the next key leaves the plain keys alone
        recent = ""
        let n = d.swap.insert.count, plain = d.swap.plain, kind = d.swap.kind, ms = Int(Date().timeIntervalSince(d.at) * 1000)
        DispatchQueue.main.async {
            Focus.backspace(n)
            Focus.typeText(plain)
            log("typography taken back (\(kind)) \(ms)ms")
        }
        return true
    }
}

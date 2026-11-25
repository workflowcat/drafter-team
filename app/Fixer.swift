// Fix while typing (1 November 2026; Cursor Tab and Copilot's next edit: a ghost that replaces, not only adds).
// While a word is being typed, the engine (`/complete` with "fix", engine/words.py Words.fix) may answer that no word
// he writes starts with these letters but one he writes often is a letter away (missed, extra, swapped or wrong
// letter) or the same keys in the other layout. The ghost then shows "→ документи" in place of the grey words;
// Tab (or ⇧Tab) takes his letters out and types the word, the keyboard switches for a layout fix, and Backspace as
// the very next key puts his letters back (Autocorrect.last). The fixed word gets the dotted visible-undo line once
// he types the space after it. Not offered when the Mac's spellchecker knows the letters as a word or a word start.
//
// 13 November 2026: the same ghost carries autocorrect's fix at a word end (`offer`, src "space"), which Tab takes,
// and the mid-word ghost (src "word") shows only once he rests `rest` s mid-word. Live log 6-13 November: 405
// mid-word ghosts, 30 taken; 137 times he typed on through it and autocorrect fixed the word at the space anyway, so
// mid-burst he does not look at it. Every offer that showed ends in one line, no words in it:
// "fix offer <word|space> <kind> <taken|typed|expired> <ms>ms" (typed = any key or click after it).
import AppKit

enum Fixer {
    struct Pending { let el: AXUIElement; let pid: pid_t; let before: String; let old: String; let new: String; let kind: String
        var src = "word"; var rev = 0; var at = Date(); var shown = false; var feat = "" }
    static var pending: Pending?
    /// The fixed word, waiting for the space after it to get its visible-undo line.
    static var mark: (new: String, old: String, kind: String, wasUk: Bool, el: AXUIElement, pid: pid_t, markers: Bool)?
    /// Letters he put back with Backspace: no fix again while the word still starts with them.
    static var refused = ""
    /// Mid-word: shown only after this long with no key (he looks at the screen then).
    static let rest = 0.3
    /// An offer nobody answered goes by itself.
    static let expiry = 6.0

    static func norm(_ s: String) -> String { s.replacingOccurrences(of: "\u{A0}", with: " ") }

    /// From the /complete answer: still worth showing at this spot?
    static func check(old: String, new: String, kind: String, at s: Spot) -> Bool {
        guard Drafter.shared.settings.fixWord, !old.isEmpty, !new.isEmpty, new != old, norm(s.before).hasSuffix(old) else { return false }
        let low = old.lowercased()
        if !refused.isEmpty, low.hasPrefix(refused) { return false }
        refused = ""
        guard Autocorrect.refresh() else { return false }
        if Autocorrect.known(old) || Autocorrect.nameStarts(old) { return false }
        // the word start may be right after all: a word the Mac knows, or one that starts with these letters
        let lang = old.unicodeScalars.contains { KeyLayout.cyr.contains($0) } ? "uk" : "en"
        if Spell.known(old, lang) || Spell.starts(old, lang) { return false }
        return true
    }

    /// Mid-word fix from /complete: kept now, drawn only if no key comes for `rest` s.
    static func show(old: String, new: String, kind: String, at s: Spot, rect: CGRect, shownLog: String = "") {
        end("typed")
        let p = Pending(el: s.el, pid: s.app.processIdentifier, before: s.before, old: old, new: new, kind: kind,
                        src: "word", rev: Keys.shared.inputRevision, at: Date())
        pending = p
        DispatchQueue.main.asyncAfter(deadline: .now() + rest) {
            guard let q = pending, q.src == "word", q.rev == p.rev, q.at == p.at, Keys.shared.inputRevision == p.rev else { return }
            draw(new, old: old, rect: rect)
            if !shownLog.isEmpty { log(shownLog) }   // "shown" only once it is on screen (Argon 22)
        }
    }

    /// Autocorrect's fix at a word end (`old` and `new` end with the space just typed): "→ word" at the caret, Tab puts
    /// it in, any other key lets it go. Nothing older may replace it meanwhile.
    static func offer(old: String, new: String, kind: String, at s: Spot) {
        guard let rect = s.rect else { return }
        Keys.shared.cancel()                                  // the suggestion asked for this space, the reader check
        Keys.shared.shownSeq = Keys.shared.seq                // an answer already on its way is older
        end("typed")
        pending = Pending(el: s.el, pid: s.app.processIdentifier, before: s.before, old: old, new: new, kind: kind,
                          src: "space", rev: Keys.shared.inputRevision, at: Date(), feat: TypoEngine.tail(new))
        draw(String(new.dropLast()), old: old, rect: rect)
    }

    private static func draw(_ text: String, old: String, rect: CGRect) {
        guard var p = pending else { return }
        p.shown = true; p.at = Date(); pending = p
        Ghost.shared.unsure = 0
        Ghost.shared.show(text, action: nil, at: rect, replace: old)
        let at = p.at
        // TextEdit scrolls a beat after a new line: the first caret read sat a line too high (1 November test)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            if Ghost.shared.visible, Ghost.shared.replace == old, Ghost.shared.text == text { Keys.shared.realign() }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + expiry) {
            guard pending?.at == at, Ghost.shared.visible, Ghost.shared.replace == old else { return }
            Ghost.shared.hide()   // -> hidden() -> "expired" when nothing came since
        }
    }

    /// The ghost went (Ghost.hide): what became of the offer.
    static func hidden() {
        guard let p = pending else { return }
        guard p.shown else { pending = nil; return }   // something else took the place before it was drawn
        end(Keys.shared.inputRevision != p.rev ? "typed" : "expired")
    }

    /// One line per offer that showed; a mid-word fix that never showed (he typed on before `rest`) logs nothing.
    private static func end(_ how: String) {
        guard let p = pending else { return }
        pending = nil
        if p.shown { log("fix offer \(p.src) \(p.kind) \(how) \(Int(Date().timeIntervalSince(p.at) * 1000))ms" + p.feat) }
    }

    /// Tab on "→ word": his letters out, the word in (key events, as autocorrect does).
    static func apply() {
        guard let p = pending else { Ghost.shared.hide(); return }
        pending = nil
        Ghost.shared.hide()
        let ms = Int(Date().timeIntervalSince(p.at) * 1000)
        guard let s = Focus.spot(skip: Drafter.shared.settings.skip).0, CFEqual(s.el, p.el), s.app.processIdentifier == p.pid,
              norm(s.before) == norm(p.before) else { log("fix offer \(p.src) \(p.kind) changed \(ms)ms"); return }
        let wasUk = KeyLayout.ukrainianNow
        Keys.shared.cancel()
        Focus.backspace(p.old.count)
        Focus.typeText(p.new)
        if p.kind == "layout uk" { KeyLayout.select(uk: true) } else if p.kind == "layout en" { KeyLayout.select(uk: false) }
        log("fix offer \(p.src) \(p.kind) taken \(ms)ms" + p.feat)
        if p.src == "space" {
            // as an automatic fix: Backspace right after brings his word back, the word keeps its dotted line
            Autocorrect.last = Autocorrect.Fix(old: p.old, new: p.new, kind: p.kind, revision: Keys.shared.editRevision, el: s.el, at: Date(), wasUk: wasUk, deliberate: true)
            FixMarks.shared.add(new: p.new, old: p.old, kind: p.kind, wasUk: wasUk, el: s.el, pid: s.app.processIdentifier, markers: s.viaMarkers)
            Keys.shared.endStat()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) { if !Ghost.shared.visible { Keys.shared.ask() } }
            return
        }
        // Autocorrect's take-back expects `old` with the character typed after it; here there is none yet
        Autocorrect.last = Autocorrect.Fix(old: p.old + " ", new: p.new, kind: p.kind, revision: Keys.shared.editRevision, el: s.el, at: Date(), wasUk: wasUk, deliberate: true)
        mark = (p.new, p.old, p.kind, wasUk, s.el, s.app.processIdentifier, s.viaMarkers)
        Keys.shared.stat?.taken += p.new.count
        Keys.shared.endStat()
        log("fix taken \(p.kind) \(p.old.count) -> \(p.new.count) chars")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) { if !Ghost.shared.visible { Keys.shared.ask() } }
    }

    /// Any key after a taken fix: a space gives the word its dotted line; anything else drops the wait.
    static func key(_ typed: String) {
        guard let m = mark else { return }
        mark = nil
        guard typed == " " else { return }
        FixMarks.shared.add(new: m.new + " ", old: m.old + " ", kind: m.kind, wasUk: m.wasUk, el: m.el, pid: m.pid, markers: m.markers)
    }
}

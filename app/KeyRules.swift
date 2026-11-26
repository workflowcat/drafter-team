// Small keys (keys round, 14 November 2026), pure: no AppKit, no files. Backspace takes back the last Tab, Esc twice
// pauses ghosts in one field, which voice take a double tap of Right Option puts in again, and which copy ⌘⇧V steps to when pressed again
// right after a switcher paste (the key itself is read by QuickKeys.route in QuickRules.swift). Keys.swift and
// Quick.swift ask these. Tested by tests/key_rules.swift.
import Foundation

/// What one Tab put in, so the very next Backspace can take it out and show the grey text again.
struct TabUndo: Equatable {
    let piece: String     // what Tab (or ⇧Tab) put in the field
    let ghost: String     // the grey text to show again: the piece and what stayed grey after it
    let rev: Int          // Keys.editRevision at the Tab key (a ⇧ release does not count, any other key does)
    let at: Double        // seconds since 1970
}

/// Esc twice in one field pauses ghosts there for a while; the same again resumes them.
struct EscPause {
    static let window = KeyMap.doubleWindow   // seconds between the two Esc presses (0.4 before keys round three)
    static let minutes = 10.0
    enum Result: Equatable { case none, paused, resumed }

    private(set) var first: (at: Double, rev: Int, key: String, armed: Bool)?
    private(set) var until: [String: Double] = [:]

    /// One Esc (no modifiers) in field `key`. `rev`: Keys.editRevision at this Esc (another key between the two Esc
    /// presses breaks the pair). `ghostRecent`: a ghost is up, or was shown a moment ago. A pair pauses only when a
    /// ghost was there at either press; in a paused field any pair resumes.
    mutating func esc(key: String, now: Double, rev: Int, ghostRecent: Bool) -> Result {
        if let f = first, f.key == key, rev == f.rev + 1, now - f.at >= 0, now - f.at <= Self.window,
           f.armed || ghostRecent || paused(key, now: now) {
            first = nil
            if paused(key, now: now) { until[key] = nil; return .resumed }
            until = until.filter { $0.value > now }
            until[key] = now + Self.minutes * 60
            return .paused
        }
        first = (now, rev, key, ghostRecent)
        return .none
    }

    func paused(_ key: String, now: Double) -> Bool { (until[key] ?? 0) > now }
}

enum KeyRules {
    // MARK: 1. Backspace takes back the last Tab

    /// How long after the Tab its Backspace still takes it back (the next key decides anyway).
    static let tabBackSeconds = 10.0

    /// `given`: the word (or whole ghost) Tab read; `piece`: what really went in (letters typed meanwhile taken off);
    /// `full`: the grey text when Tab came. nil: nothing to take back.
    static func tabUndo(piece: String, given: String, full: String, rev: Int, at: Double) -> TabUndo? {
        guard !piece.isEmpty, !given.isEmpty, full.hasPrefix(given) else { return nil }
        return TabUndo(piece: piece, ghost: piece + String(full.dropFirst(given.count)), rev: rev, at: at)
    }

    /// This Backspace is the very next key after the Tab, soon enough, and the switch is on.
    static func tabBack(_ u: TabUndo?, rev: Int, now: Double, on: Bool) -> Bool {
        guard on, let u else { return false }
        return rev == u.rev + 1 && now >= u.at && now - u.at < tabBackSeconds
    }

    /// The field still ends with what Tab put in (a no-break space reads as a space; a field may drop a trailing one).
    static func stillEnds(before: String, piece: String) -> Bool {
        let b = norm(before), p = norm(piece)
        guard !p.isEmpty else { return false }
        return b.hasSuffix(p)
    }

    // MARK: 2. Esc twice

    /// One field: the app and its focused element's hash.
    static func fieldKey(app: String, element: UInt) -> String { app + "#" + String(element) }

    /// A ghost counts as "just shown" for this long after it went.
    static let ghostRecent = 1.5

    // MARK: 3. The last voice take again

    /// The newest take worth putting in again: rows newest first as (text, outcome); empty, failed, spoken-rule rows
    /// ("✎ …") and test rows are skipped.
    static func lastTake(_ rows: [(text: String, outcome: String)]) -> String? {
        for r in rows {
            let t = r.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if t.isEmpty || !r.outcome.isEmpty || t.hasPrefix("✎") || t.contains("⟦drafter-test⟧") { continue }
            return t
        }
        return nil
    }

    /// Keys round two (17 November 2026): a double tap of Right Option puts the last take in again (`againTap`), in
    /// place of ⌃⌥R. A single press is never delayed: the first tap starts a take at once, as before. The second press
    /// counts as the double tap only while that take is a short one (not ⇧ Right Option's long note or a call), the
    /// first press was a tap (released within the 0.5 s push-to-talk hold, so the take listens hands-free), it comes
    /// within `doubleTap` s of the first press, and no words were heard yet. Then the empty take is dropped and the
    /// last take goes in; any other second press ends the take as before. A tap-tap was an empty take until now.
    static let doubleTap = KeyMap.doubleWindow
    static func againTap(enabled: Bool, listening: Bool, long: Bool, held: Bool, sinceFirst: Double, words: Bool) -> Bool {
        enabled && listening && !long && !held && !words && sinceFirst >= 0 && sinceFirst <= doubleTap
    }

    /// Keys round two (17 November 2026) for a settings file saved before it (no "keysRound"): each key still at the
    /// old default moves to the new one; a key the user set themselves stays. ⌘⇧S goes back to apps (the user's decision).
    static func keysRoundTwo(_ j: [String: Any]) -> [String: Any] {
        var o = j
        if (o["captureKey"] as? String) == "⌃⌥S" { o["captureKey"] = "⌘⇧5" }
        o["captureCmdShiftS"] = false
        if (o["quickKey"] as? String) == "⌃⌥V" { o["quickKey"] = "" }
        if (o["againKey"] as? String) == "⌃⌥R" { o["againKey"] = "" }
        o["keysRound"] = 2
        return o
    }

    /// Keys round three (17 November 2026, docs/plans/2026-11-17-key-map.md) for a file at round two or before it:
    /// the ⌘⇧V swap and ⌥1-3 go off (both were on by default, now opt-in), Pick parts gets its own setting.
    static let keysRoundNow = 3
    static func keysRoundThree(_ j: [String: Any]) -> [String: Any] {
        var o = (j["keysRound"] as? Int) == nil ? keysRoundTwo(j) : j
        o["switchSwap"] = false
        o["alternatives"] = false
        if o["pickKey"] == nil { o["pickKey"] = KeyMap.defaultChord("pick") }
        o["keysRound"] = keysRoundNow
        return o
    }
    /// The file needs round three: no mark, or a mark under it.
    static func needsKeysRound(_ j: [String: Any]) -> Bool { ((j["keysRound"] as? Int) ?? 0) < keysRoundNow }

    // MARK: keys round three (the key map)

    /// Row 11: a settable global chord (`pickKey`): nil when off ("") or the same as another of Drafter's global chords.
    static func ownChord(_ key: String, others: [String]) -> String? {
        let k = key.trimmingCharacters(in: .whitespaces)
        guard !k.isEmpty else { return nil }
        return others.contains { !$0.isEmpty && KeyMap.norm($0) == KeyMap.norm(k) } ? nil : k
    }

    /// Row 1: ⌘⇧V goes to the front app when it is a skipped app (terminals, VS Code, Xcode, password managers),
    /// except Drafter's own window.
    static func skippedAppKeeps(front: String?, skip: [String], own: String) -> Bool {
        guard let f = front, !f.isEmpty, f != own else { return false }
        return skip.contains(f)
    }

    /// Rows 3 and 8: a key while the strip shows an offer. Tab takes a copy's form (never a call offer: a Tab meant
    /// for the app must never record a meeting); ⇧Tab steps the copy chip to its next form. A grey ghost up takes
    /// Tab and ⇧Tab first. Digits are never picked: they go to the app.
    enum OfferKey: Equatable { case accept, step, none }
    static func offerKey(code: Int, plain: Bool, shiftOnly: Bool, call: Bool, forms: Int, ghost: Bool) -> OfferKey {
        guard code == 48, !call, !ghost else { return .none }
        if plain { return .accept }
        if shiftOnly, forms > 1 { return .step }
        return .none
    }
    /// What a call offer shows as its key: ⇧ Right Option takes it when voice is on; else only the Record button.
    static func callOfferKey(voice: Bool) -> String { voice ? "⇧ right ⌥" : "" }

    /// Row 4: Tab on a chip. Chips that put text at the caret (a snippet, an emoji, a copy, a fix) are taken;
    /// a chip that runs an outside action (calendar, reminder, note, opening an app, a draft elsewhere)
    /// never runs on Tab: the Tab goes to the app and a click on the chip runs it.
    static let textKinds: Set<String> = ["expand", "replace", "replaceSelection", "proofread", "reader.note", "pauseRewrite", "insert", "copy"]
    static func tabRunsChip(kind: String?) -> Bool { kind.map { textKinds.contains($0) } ?? false }

    /// Row 4b (18 November 2026, the user: Tab "jumps to claude control once suggestion is done"): a plain Tab within
    /// `tabGrace` s of a Tab that took grey text, with no grey text left, stays with Drafter, so the rhythm of word-by-word
    /// Tabs never moves focus in the app. The window runs from the last take only: a slower Tab is the app's again.
    static let tabGrace: TimeInterval = 0.8
    /// Tab-drops round (2026-11-20): a short take owns the keys while it listens; a long note or call does not (its
    /// keys are free, Talk.keysFree), so grey text and Tab keep working through a call.
    static func takeOwnsKeys(listening: Bool, long: Bool) -> Bool { listening && !long }

    /// The Tab-take stamp behind `tabHeld` stands only for a Tab that put words in; an aborted Tab or any other key
    /// clears it, so the next Tab is not held for nothing (5 of 16 "tab held" lines on 19-20 November came right after
    /// a Tab that put nothing in).
    static func tabStamp(_ stamp: Date?, aborted: Bool, otherKey: Bool) -> Date? { aborted || otherKey ? nil : stamp }

    static func tabHeld(sinceTake: TimeInterval?, ghost: Bool) -> Bool {
        guard !ghost, let t = sinceTake else { return false }
        return t >= 0 && t < tabGrace
    }

    /// Hold one stray plain Tab if a visible plain ghost involuntarily vanished just moments ago (< 0.28 s),
    /// so Tab never jumps focus out of the composer into app buttons/toolbars.
    static let tabVanishGrace: Double = 0.28
    static func tabHoldAfterVanish(sinceVanish: Double?, ghost: Bool) -> Bool {
        guard !ghost, let t = sinceVanish else { return false }
        return t >= 0 && t < tabVanishGrace
    }

    /// Row 5: a Tab with nothing shown in an empty chat box never asks for a ghost (a next-message draft); it is the app's.
    static func tabAsks(code: Int, emptyBox: Bool) -> Bool { !(code == 48 && emptyBox) }

    /// Row 5: arrows on a next-message card act only once it is open (Tab opened it). nil: the key is the app's.
    enum CardArrow: Equatable { case flip(Int), fold }
    static func cardArrow(code: Int, expanded: Bool) -> CardArrow? {
        guard expanded else { return nil }
        switch code { case 123: return .flip(-1); case 124: return .flip(1); case 126: return .fold; default: return nil }
    }

    /// Row 9: a key pressed while Right Option is still held, before any words were heard, in a short take: the take
    /// is dropped at once and the key goes to the app (⌥ characters typed with the right hand).
    static func optionChordDrops(held: Bool, listening: Bool, long: Bool, words: Bool) -> Bool {
        held && listening && !long && !words
    }

    // MARK: 4. Swap on the switcher

    /// How long after a switcher paste ⌘⇧V swaps it.
    static let swapSeconds = 2.0

    /// The next older copy after row `i` when it can go in as text (a picture or a file: nil, the switcher opens).
    static func swapNext(_ isText: [Bool], after i: Int) -> Int? {
        let j = i + 1
        guard i >= 0, j < isText.count, isText[j] else { return nil }
        return j
    }

    static func norm(_ s: String) -> String { s.replacingOccurrences(of: "\u{A0}", with: " ") }
}

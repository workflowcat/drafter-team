// Pure rules for when a ghost answer may still be drawn or taken (2026-11-14, bugs round on the Argon review: a ghost on
// screen that Tab would not insert as drawn, a part drawn after a newer key or after an empty final). Keys.answer and
// Keys.accept ask these; tests/ghost_rules.swift checks them. No AppKit.
import Foundation

enum GhostRules {
    /// What a later line of a streamed answer does to the part of it already on screen.
    enum Next: Equatable { case extend(String), keep, redraw, drop }

    /// `raw`: the part drawn; `stillThis`: the ghost on screen is still (what is left of) that part; `text`: the new line.
    /// A final that does not grow the part replaces it (shorter, or another text: the finisher) or takes it away
    /// (empty) - before 14 November the part stayed on screen (Argon 9).
    /// Ghost-hide round (2026-11-18): a final that is only the start of the part (the same words, shorter) keeps the
    /// part, and once he typed into the part (`typedIn` letters) an empty final keeps it too: the letters he typed
    /// matched, so the words on screen were right (Andrii: "it completes but then it cuts off again suddenly").
    static func next(raw: String, stillThis: Bool, text: String, hasAction: Bool, final: Bool, typedIn: Int = 0) -> Next {
        guard stillThis, !hasAction else { return .keep }
        if text.hasPrefix(raw), text.count > raw.count { return .extend(String(text.dropFirst(raw.count))) }
        if text == raw || !final { return .keep }
        if !text.isEmpty, raw.hasPrefix(text) { return .keep }
        if text.isEmpty { return typedIn > 0 ? .keep : .drop }
        return .redraw
    }

    /// Ghost-hide round: what he typed since the ask, when the field read lags behind his keys (Electron apps, Claude
    /// and Beeper, put a letter in a beat late). `field`: the letters the read shows past the ask; `keys`: the
    /// printable keys he pressed since the ask (nil when a Tab, Backspace, arrow or shortcut came between). The keys
    /// win only when the read is their start; anything the app changed (a typography swap) leaves the read as it is.
    /// Before, the ghost was drawn from the late read and began with a letter he had already typed, so his next key
    /// did not match it and the ghost went.
    static func typedSince(field: String, keys: String?) -> String {
        guard let k = keys, k.count > field.count, k.hasPrefix(field) else { return field }
        return k
    }

    /// A newer answer that is shorter than the plain ghost on screen does not replace it once he typed into that
    /// ghost (`typedIn` > 0, every letter matched), nor when it is only the start of it (short-ghost round). A
    /// longer answer still replaces it.
    static func keepShown(visible: Bool, shown: String, new: String, typedIn: Int) -> Bool {
        guard visible, !new.isEmpty, shown.count > new.count else { return false }
        return typedIn > 0 || shown.hasPrefix(new)
    }

    /// The typo hold leaves a plain ghost on screen when he typed into it, or when it was drawn for the key now in
    /// the field (it passed the hold then; the debounced ask for the same key came after it).
    static func holdKeeps(typedIn: Int, shownRev: Int?, keyRev: Int) -> Bool {
        typedIn > 0 || shownRev == keyRev
    }

    /// Letters that read the same but come as different characters from the keyboard and the model: apostrophes,
    /// quotes, a no-break space. Typing one of them into the ghost keeps it.
    static func fold(_ c: Character) -> Character {
        switch c {
        case "\u{2019}", "\u{02BC}", "\u{2018}": return "'"
        case "\u{201C}", "\u{201D}", "\u{00AB}", "\u{00BB}": return "\""
        case "\u{00A0}": return " "
        default: return c
        }
    }
    /// How many characters of `ghost` the typed letters cover, when they match its start letter by letter (folded);
    /// nil when they do not.
    static func typedInto(ghost: String, typed: String) -> Int? {
        guard !typed.isEmpty, ghost.count >= typed.count else { return nil }
        return zip(ghost, typed).allSatisfy { fold($0) == fold($1) } ? typed.count : nil
    }

    /// Why a key did not go into the plain ghost on screen, for the "ghost gone" log line: "lag" when the ghost still
    /// starts with the letter typed just before (drawn from a late read) and this key is its next letter; "other"
    /// when he typed something else.
    static func missKind(ghost: String, typed: String, prev: String?) -> String {
        if let p = prev, !p.isEmpty, typedInto(ghost: ghost, typed: p + typed) != nil { return "lag" }
        return "other"
    }

    /// Short-ghost round (2026-11-18): typing hid the whole ghost (he typed it to its end) while the answer it came from
    /// is still streaming. Its later parts then draw their rest at the caret instead of being dropped, and no new ask
    /// goes out until that answer ends (a new ask stopped it: 93-101 ghosts a day typed to the end with no rest,
    /// 6 characters or less in 85-94% of them, 16-18 November).
    static func typedThrough(visible: Bool, paintedSeq: Int?, shownSeq: Int, finishedSeq: Int) -> Bool {
        !visible && paintedSeq == shownSeq && finishedSeq < shownSeq
    }

    /// A newer answer that is only the start of the plain ghost on screen (its first part, mostly one word) does not
    /// replace it: the same words, shorter, read as the ghost cut off while he types (short-ghost round, 2026-11-18:
    /// 317 of 731 ghosts he stopped typing through on 18 November were replaced in the same second by a shorter ghost;
    /// the log does not say how many of those were the same words). A longer answer still replaces it.
    static func keepLonger(visible: Bool, shown: String, new: String) -> Bool {
        keepShown(visible: visible, shown: shown, new: new, typedIn: 0)
    }

    /// A part (or its retry) whose answer already ended is never drawn (Argon 10: a part retried 15 ms later came
    /// after an empty final and showed).
    static func lateLine(final: Bool, mine: Int, finished: Int) -> Bool { !final && mine <= finished }

    /// A newer key came since the ask, but the field still reads as it was asked: the app has not put that key in
    /// yet, so the answer would be drawn at the old caret (Argon 11). The ask for the newer key follows.
    static func fieldBehind(revAsked: Int, revNow: Int, asked: String, now: String) -> Bool {
        revNow != revAsked && norm(now) == norm(asked)
    }

    /// Idle ghost (step 7): may the local model draft his next message here, with the caret resting? Only with the
    /// switch on, in a chat or AI box (AppKind via Keys.boxKind), never in a skipped app, a password field, under
    /// secure input or mid-line, and only in an empty box, after a finished sentence and a space, or on a new line
    /// (engine gatecore.idle_spot).
    static func idleAllowed(on: Bool, secure: Bool, password: Bool, skipped: Bool, chatBox: Bool, mid: Bool, before: String) -> Bool {
        guard on, !secure, !password, !skipped, chatBox, !mid else { return false }
        if before.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return true }
        if before.hasSuffix("\n") { return true }
        guard let last = before.last, last == " " else { return false }
        var t = Substring(before.dropLast())
        while let c = t.last, c == " " { t = t.dropLast() }
        while let c = t.last, "\"'»”)".contains(c) { t = t.dropLast() }
        return t.last.map { ".!?…".contains($0) } ?? false
    }
    /// How long the caret rests before the idle ghost is asked (bench: live key gaps, docs/rounds/2026-11-16-earlier.md).
    static let idleDelay = 0.6
    /// The idle request: the local model only (no kept-in-flight answer).
    static func idleBody(_ base: [String: Any]) -> [String: Any] {
        var b = base
        b["idle"] = true; b["keep_on"] = nil; b["mid"] = nil
        return b
    }

    /// Cadence round (2026-11-17, engine/cadence.py): with `combo` (setting comboModels) the engine keeps the fast model
    /// beside the picked one and answers a key with it when the gap before the key, `gapMs` (KeyGaps.lastMs, -1 when
    /// unknown), is short. `combo` always goes out, so turning the switch off lets the engine drop the second model.
    static func cadenceBody(combo: Bool, gapMs: Int) -> [String: Any] {
        combo && gapMs >= 0 ? ["combo": true, "gap_ms": gapMs] : ["combo": combo]
    }

    /// An answer asked at an older key than the grey text on screen never replaces it (Codex review 2026-11-16: an
    /// answer kept running while he typed, step 2 `keepTyping`, may come back after a newer one was drawn).
    static func olderThanShown(askedRev: Int?, shownRev: Int?, visible: Bool) -> Bool {
        guard visible, let a = askedRev, let s = shownRev else { return false }
        return a < s
    }

    /// Tab's word, read when the key came, is still what the ghost shows when the main queue gets to it: the ghost
    /// was not hidden meanwhile and a second fast Tab does not put the same word in twice (Argon 12).
    static func tabStillValid(visible: Bool, shown: String, isDraft: Bool, given: String) -> Bool {
        visible && !shown.isEmpty && !given.isEmpty && (isDraft || shown.hasPrefix(given))
    }

    /// The word Tab put in has landed before the caret (20 November 2026: the rest of the ghost vanished after a word
    /// in Claude and Beeper). Electron fields turn a trailing space into a no-break space and may drop or keep it, so
    /// spaces are compared loosely: "word " counts as landed when the field ends in "word", "word " or "word\u{00A0}".
    /// Tab-drops round (2026-11-20): the field read at Tab against what the spot expects (his letters and the words
    /// Tab put in already). `ahead`: the field holds the spot and maybe more he typed since; `behind`: the field has
    /// not caught up with Drafter's own last insert yet (two fast Tabs), look again; `other`: it changed under him.
    /// A no-break space reads as a space (Electron fields turn a trailing space into one).
    enum TabRead: Equatable { case ahead(String), behind, other }
    static func tabRead(expected: String, now: String) -> TabRead {
        func norm(_ x: String) -> String { x.replacingOccurrences(of: "\u{00A0}", with: " ").replacingOccurrences(of: "\u{202F}", with: " ") }
        let e = norm(expected), n = norm(now)
        if n.hasPrefix(e) { return .ahead(String(now.dropFirst(expected.count))) }
        if e.hasPrefix(n) { return .behind }
        return .other
    }

    /// Why a Tab put nothing in, for the log ("tab dropped <why>") and the ghost-gone line. nil: it goes in.
    /// Before 20 November each of these left the Tab silent.
    static func tabExit(valid: Bool, spot: Bool, sameField: Bool, read: TabRead?, looksLeft: Int, piece: String) -> String? {
        if !valid { return "ghost moved" }
        if !spot { return "no spot" }
        if !sameField { return "other field" }
        switch read {
        case .other?, nil: return "field changed"
        case .behind?: return looksLeft > 0 ? nil : "field behind"
        case .ahead?: break
        }
        return piece.isEmpty ? "nothing left" : nil
    }

    /// On the final look (`looksLeft <= 1`) in a lagging Electron/Chromium field (`sameField && read == .behind`),
    /// treat the field as caught-up when `now` lags `expected` (our locally tracked spot) only by characters already
    /// typed into the ghost (up to `tabBehindMaxLag`), so Tab inserts cleanly instead of dropping.
    static let tabBehindMaxLag = 8
    static func tabBehindCaughtUp(read: TabRead?, sameField: Bool, looksLeft: Int, expected: String, now: String) -> Bool {
        guard sameField, read == .behind, looksLeft <= 1 else { return false }
        let e = norm(expected).replacingOccurrences(of: "\u{202F}", with: " ")
        let n = norm(now).replacingOccurrences(of: "\u{202F}", with: " ")
        let lag = expected.count - now.count
        return lag >= 0 && lag <= tabBehindMaxLag && e.hasPrefix(n)
    }

    /// Hide reasons initiated by the user (or completion), vs involuntary vanishes where a stray Tab right after
    /// would otherwise jump focus out of the composer.
    static let userDismissReasons: Set<String> = ["esc", "shortcut", "taken", "typed all", "click"]
    static func involuntaryHide(_ why: String) -> Bool { !userDismissReasons.contains(why) }

    /// A Tab that took the whole grey text of a streamed answer that is still running: its later parts draw the rest
    /// at the caret (as when he types it through), instead of the immediate new ask that stopped the stream.
    static func tabThrough(wholeTaken: Bool, paintedSeq: Int?, shownSeq: Int, finishedSeq: Int) -> Bool {
        wholeTaken && typedThrough(visible: false, paintedSeq: paintedSeq, shownSeq: shownSeq, finishedSeq: finishedSeq)
    }

    static func pieceLanded(before: String, piece: String) -> Bool {
        func norm(_ x: String) -> String { x.replacingOccurrences(of: "\u{00A0}", with: " ").replacingOccurrences(of: "\u{202F}", with: " ") }
        let b = norm(before), p = norm(piece)
        if b.hasSuffix(p) { return true }
        let core = p.trimmingCharacters(in: .whitespaces)
        guard !core.isEmpty else { return true }
        return b.trimmingCharacters(in: .whitespaces).hasSuffix(core)
    }
    /// How long the rest of a ghost waits for the taken word to show in the field before it goes: 6 looks, 100 ms
    /// apart after the first at 80 ms (was 2 looks within 0.25 s; Electron apps update the field late).
    static let restLooks = 6, restLookGap = 0.1

    /// Tab on a next-message card (2026-11-14, Argon 14). Folded with lines hidden behind the fold (`cut`): the first
    /// Tab opens it and puts nothing in, so he never sends lines he did not see; open, or all of it shows: Tab puts it in.
    enum DraftTab: Equatable { case open, insert }
    static func draftTab(expanded: Bool, cut: Bool) -> DraftTab { !expanded && cut ? .open : .insert }

    /// Round five (2026-11-14): a key may be asked for at once (Keys.predict) when the last field read was made at the
    /// key just before it. Live 7-14 Nov: 41% of ghosts came the slow way (35 ms wait, a field read: 121 ms key to grey
    /// text against 88), because the read was older than 3 s (the first key after a pause) or missing after letters
    /// typed into the ghost or after a Tab. The answer is drawn only once the field holds the asked text, so an old
    /// read costs at most a wasted ask; 20 s keeps a field left for long out.
    static let predictAge = 20.0
    static func predictable(readRev: Int, keyRev: Int, age: Double) -> Bool { readRev == keyRev - 1 && age >= 0 && age < predictAge }

    /// The debounced ask after a key need not go out: the same text was asked at the key itself (Keys.predict), for
    /// this very key, and that answer is on its way or already came (round five: asking again drew the same ghost a
    /// second time and stopped the work the engine had started in the gap).
    static func askedAtKey(before: String, rev: Int, pending: Bool, now: String, keyRev: Int) -> Bool {
        (pending || rev == keyRev) && norm(before) == norm(now)
    }

    static func norm(_ s: String) -> String { s.replacingOccurrences(of: "\u{A0}", with: " ") }

    // MARK: long round (2026-11-14): sentence-length ghosts, the rolling ghost, futures and other ideas

    /// Setting `ghostLength`: "word" (round five's short ghost), "phrase", "sentence" (default). Anything else reads as
    /// the default.
    static func lengthMode(_ s: String) -> String { ["word", "phrase", "sentence"].contains(s) ? s : "sentence" }

    /// The shortest ghost shown (earlier round step 2): `minGhostShort` while `shortGhosts` is on, else `minGhost`.
    static func minLetters(minGhost: Int, short: Bool, minShort: Int) -> Int { max(0, short ? minShort : minGhost) }

    /// Earlier round (2026-11-16): what the request says about length and the lower gate. Outside "word" length (and
    /// outside Zoom, which stays strict) `words` sends the 3-5 words run ("length": "words", words_min, words_max);
    /// else the run of `mode` as before. `guess` asks for the lower gate's guesses, `shade` for them drawn lighter.
    /// `early` (setting earlyStart, step 6): the guesses' bar one notch lower, lower still after a space (engine
    /// gatecore.early_bar); only with `guess`. `guessBar` (setting, Bolder / Careful): the guesses' own bar, sent as
    /// "guess_bar" (engine gatecore.guess_bar, which also moves the selector's bar with it); nil keeps the engine's.
    static func runBody(mode: String, words: Bool, minWords: Int, maxWords: Int, guess: Bool, shade: Bool, strict: Bool, early: Bool = false,
                        guessBar: Double? = nil) -> [String: Any]? {
        let m = lengthMode(mode)
        guard m != "word", !strict else { return nil }
        var b: [String: Any] = ["length": m, "floor": 0.1, "cap": 24]
        if words {
            let lo = min(5, max(1, minWords))
            b["length"] = "words"; b["words_min"] = lo; b["words_max"] = min(8, max(lo, maxWords))
        }
        if guess {
            b["guess"] = true; b["guess_shade"] = shade; if early { b["early_start"] = true }
            if let g = guessBar { b["guess_bar"] = boldBar(g) }
        }
        return b
    }

    /// The Bolder / Careful slider's value: 0.05 (bolder: more guesses) to 0.35 (careful), in steps of 0.05.
    static func boldBar(_ v: Double) -> Double { (min(0.35, max(0.05, v)) * 20).rounded() / 20 }

    /// Words still grey: what is left of the ghost after Tab or letters typed into it.
    static func wordsLeft(_ rest: String) -> Int { rest.split(whereSeparator: { $0 == " " || $0 == "\n" }).count }

    /// The rolling ghost: once two words or fewer are left of a final ghost, the words after it are asked for (from the
    /// engine's prepared answer for the whole ghost, so mostly at once) and added at its end, so a sentence keeps
    /// coming while he Tabs. Once per ghost text (`askedFor` is the text the last roll asked for); never in "word"
    /// mode, never for a chip, a fix or a next-message card.
    static func rollWanted(rest: String, mode: String, final: Bool, plain: Bool, wanted: String, askedFor: String?) -> Bool {
        guard lengthMode(mode) != "word", final, plain, !rest.trimmingCharacters(in: .whitespaces).isEmpty, !rest.hasSuffix("\n") else { return false }
        return wordsLeft(rest) <= 2 && norm(wanted) != norm(askedFor ?? "")
    }

    /// The roll's answer goes on only while the field and the ghost still read as when it was asked.
    static func rollFits(asked: String, now: String) -> Bool { norm(asked) == norm(now) }

    /// The lighter tail after a roll: words added after a lighter part stay lighter; after a sure part they bring their
    /// own split.
    static func rollUnsure(old: Int, more: Int, moreUnsure: Int) -> Int { old > 0 ? old + more : min(more, moreUnsure) }

    /// The answer prepared for the letter just typed (engine /futures, fetched once the ghost was final): shown at once,
    /// no request, when the field before that letter is the base the futures were made for.
    static func future(base: String, before: String, typed: String, futures: [(letter: String, text: String, unsure: String)]) -> (text: String, unsure: String)? {
        guard !typed.isEmpty, norm(base) == norm(before) else { return nil }
        return futures.first(where: { $0.letter == typed }).map { ($0.text, $0.unsure) }
    }

    /// Other ideas for the same spot (⌃⇧Tab): the shown ghost first, then each prepared future as its letter and its
    /// words, none twice, none that only repeats the shown one.
    static func ideas(shown: String, futures: [(letter: String, text: String, unsure: String)]) -> [(text: String, unsure: Int)] {
        var out: [(text: String, unsure: Int)] = [(shown, 0)]
        for f in futures {
            let t = f.letter + f.text
            guard !f.text.isEmpty, !out.contains(where: { $0.text == t }), !shown.hasPrefix(t) else { continue }
            out.append((t, t.hasSuffix(f.unsure) ? f.unsure.count : 0))
        }
        return out
    }

    /// The next idea, wrapping back to the first; nil when there is no other idea to show.
    static func cycle(index: Int, count: Int) -> Int? { count > 1 ? (index + 1) % count : nil }

    // MARK: mid-line round (2026-11-15): a ghost with text after the caret on the same line (setting `midLine`)

    /// The rest of the caret's line: what follows the caret up to the next line break.
    static func lineRest(_ after: String) -> String {
        String(after.prefix(while: { $0 != "\n" && $0 != "\r" && $0 != "\u{2028}" }))
    }

    /// A mid-line rest longer than this keeps Drafter quiet: the caret is deep inside a paragraph, not at a gap.
    static let midRestMax = 120

    /// A ghost may show with text after the caret on its line only at a gap between words: the rest starts with a space
    /// or a punctuation mark (never a letter or digit, never an apostrophe or hyphen joining two letters, so never inside
    /// a word), it is at most `midRestMax` characters, and the caret's line has a letter or digit before it.
    /// `before`: the text before the caret; `rest`: the rest of its line (`lineRest`), not blank.
    static func midLineOK(before: String, rest: String) -> Bool {
        guard let first = rest.first, !rest.trimmingCharacters(in: .whitespaces).isEmpty, rest.count <= midRestMax else { return false }
        if first.isLetter || first.isNumber || first == "_" || first.isNewline { return false }
        // "don|'t", "well|-known": a joiner between two letters is inside a word
        if "'’‘-‐".contains(first), before.last?.isLetter == true, rest.dropFirst().first?.isLetter == true { return false }
        let line = before.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "\n" || $0 == "\r" }).last.map(String.init) ?? before
        return line.contains(where: { $0.isLetter || $0.isNumber })
    }

    /// The text after the caret sent to the engine mid-line: the rest of the line first, then at most `midLines` more
    /// lines, at most `midAfterMax` characters.
    static let midLines = 2, midAfterMax = 400
    static func midAfter(_ after: String) -> String {
        let lines = after.split(separator: "\n", maxSplits: midLines + 1, omittingEmptySubsequences: false)
        return String(lines.prefix(midLines + 1).joined(separator: "\n").prefix(midAfterMax))
    }

    /// A mid-line ghost as it may be drawn and put in: one line only (cut at a line break), never repeating the start of
    /// the rest at its end (the model wrote past the gap), no trailing space when the rest starts with one. "" = none.
    static func midText(_ ghost: String, rest: String) -> String {
        var g = String(ghost.prefix(while: { $0 != "\n" && $0 != "\r" }))
        let r = Array(rest)
        var k = min(g.count, r.count, 40)
        while k >= 2 {
            if g.hasSuffix(String(r[..<k])) { g = String(g.dropLast(k)); break }
            k -= 1
        }
        if rest.first?.isWhitespace == true { while g.last?.isWhitespace == true { g.removeLast() } }
        return g
    }

    /// The long round's two keys, ⌃Tab (to the sentence end) and ⌃⇧Tab (the next idea), are retired since keys round
    /// three (17 November 2026): browsers, Slack and Xcode switch tabs with them, so they always go to the app.
    enum LongKey: Equatable { case sentence, cycle, none }
    static func longKey(code: Int, control: Bool, shift: Bool, option: Bool, command: Bool, ghost: Bool, plain: Bool) -> LongKey { .none }

    /// Ghost size when the field gives no font size (2026-11-17, web ghost: Dia gives an empty AXFont, so the size
    /// comes from the caret). Chromium's caret box is about 1.2 times the font size (Georgia 15 -> 18, system-ui 13 -> 16),
    /// native boxes about 1.28: web 0.83, native 0.78, kept within 11-26.
    static func fallbackSize(caretHeight h: Double, web: Bool) -> Double {
        max(11, min(26, (h * (web ? 0.83 : 0.78)).rounded()))
    }

    /// Ghost colour (sRGB r, g, b, alpha). A field colour from AX: that colour at 0.38. None (Chromium never gives one):
    /// a mid grey that reads on light and dark pages alike; before 17 November it was labelColor or secondaryLabelColor,
    /// which in Dark mode are near white, so on a white web page the ghost all but vanished.
    static func ghostColour(field: (Double, Double, Double)?) -> (Double, Double, Double, Double) {
        if let f = field { return (f.0, f.1, f.2, 0.38) }
        return (0.55, 0.55, 0.57, 1)
    }
}

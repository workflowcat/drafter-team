import Foundation

// swiftc -parse-as-library app/GhostRules.swift tests/ghost_rules.swift -o app/build/ghost-rules-test && app/build/ghost-rules-test
// Argon review 2026-11-14, findings 9-12: when a streamed ghost's later lines, a retried part or a queued Tab may
// still draw or insert. Made-up words only.
@main
struct GhostRulesChecks {
    static var failures = 0
    static func check(_ ok: Bool, _ what: String) { if !ok { print("FAIL: " + what); failures += 1 } }

    /// Ghost-hide round (2026-11-18): the rules that keep a right ghost on screen while the user types its letters, then a
    /// letter-by-letter run through them the way Keys and Ghost use them. Made-up lines only.
    static func ghostHide() {
        typealias R = GhostRules
        check(R.next(raw: "see you", stillThis: true, text: "", hasAction: false, final: true, typedIn: 2) == .keep, "an empty final after he typed into the part keeps it")
        check(R.next(raw: "see you", stillThis: true, text: "", hasAction: false, final: true, typedIn: 0) == .drop, "an empty final with nothing typed still takes it away")
        check(R.next(raw: "see you", stillThis: true, text: "sea", hasAction: false, final: true, typedIn: 3) == .redraw, "other words still redraw")
        check(R.typedSince(field: "t", keys: "to") == "to", "a read one letter behind: the keys count")
        check(R.typedSince(field: "", keys: "to") == "to", "a read with none of the keys yet")
        check(R.typedSince(field: "to", keys: "to") == "to", "a read in step")
        check(R.typedSince(field: "t", keys: nil) == "t", "a Tab or arrow between: the read only")
        check(R.typedSince(field: "\u{2019}", keys: "'") == "\u{2019}", "a swap by the app: the read wins")
        check(R.keepShown(visible: true, shown: "orrow at noon", new: "omorrow", typedIn: 2), "a shorter newer answer never replaces a ghost he typed into")
        check(!R.keepShown(visible: true, shown: "orrow", new: "orrow at noon", typedIn: 2), "a longer one does")
        check(!R.keepShown(visible: true, shown: "orrow at noon", new: "ats", typedIn: 0), "nothing typed into it: other shorter words replace it, as before")
        check(R.typedInto(ghost: "it\u{2019}s fine", typed: "it's") == 4, "a plain apostrophe types into a curly one")
        check(R.typedInto(ghost: "see\u{00A0}you", typed: "see ") == 4, "a space types into a no-break space")
        check(R.typedInto(ghost: "see you", typed: "sea") == nil, "another letter does not")
        check(R.missKind(ghost: "torrow", typed: "o", prev: "t") == "lag", "the ghost still begins with the letter typed before")
        check(R.missKind(ghost: "orrow", typed: "x", prev: "t") == "other", "he typed something else")
        check(R.holdKeeps(typedIn: 2, shownRev: 10, keyRev: 12), "the typo hold leaves a ghost he typed into")
        check(R.holdKeeps(typedIn: 0, shownRev: 12, keyRev: 12), "the typo hold leaves a ghost drawn for this key")
        check(!R.holdKeeps(typedIn: 0, shownRev: 10, keyRev: 12), "an older ghost, nothing typed into it: the hold takes it")

        // the run: "see you to" + ghost "morrow at noon" (a two-step answer: part "morrow", then the rest)
        var ghost = "morrow", raw = "morrow", typedIn = 0, gone: String? = nil, drawn = 0
        func key(_ c: String) {
            guard gone == nil else { return }
            if let n = R.typedInto(ghost: ghost, typed: c) {
                typedIn += n; ghost.removeFirst(n)
                if ghost.isEmpty { gone = "typed all" }
            } else { gone = "typed other" }
        }
        func line(_ text: String, final: Bool) {          // a later line of the same streamed answer
            guard gone == nil else { return }
            switch R.next(raw: raw, stillThis: true, text: text, hasAction: false, final: final, typedIn: typedIn) {
            case .extend(let more): ghost += more; raw = text
            case .keep: break
            case .drop: gone = "stream empty"
            case .redraw: gone = "stream redraw"
            }
        }
        func newer(_ text: String) {                        // a newer ask's answer for the spot after the user's letters
            guard gone == nil else { return }
            if !R.keepShown(visible: true, shown: ghost, new: text, typedIn: typedIn) { gone = "newer"; ghost = text }
        }
        func newerEmpty() {}                                 // Keys.answer: an empty answer draws nothing, hides nothing
        key("m"); key("o")
        check(ghost == "rrow" && gone == nil, "two letters typed: the rest stays")
        line("morrow at noon", final: false)
        check(ghost == "rrow at noon", "the rest of the stream grows it while he types")
        key("r"); newer("row")
        check(ghost == "row at noon" && gone == nil, "a shorter newer answer leaves it")
        line("morrow", final: true)
        check(ghost == "row at noon" && gone == nil, "a final shorter than what is drawn leaves it")
        line("", final: true)
        check(gone == nil, "an empty final after he typed into it leaves it")
        // the whole ghost vanishing while the user types it: an empty newer answer is never drawn, the typo hold and the
        // screen check leave a ghost the user typed into
        newerEmpty()
        check(gone == nil && ghost == "row at noon", "an empty newer answer leaves it")
        if !R.holdKeeps(typedIn: typedIn, shownRev: 3, keyRev: 5) { gone = "typo hold" }
        check(gone == nil, "the typo hold leaves it")
        // a late field read draws the next ghost past every key the user pressed, so their next key goes into it
        let fieldSince = "a", keys = "at"
        let since = R.typedSince(field: fieldSince, keys: keys)
        let answer = "at noon"
        drawn = answer.count - since.count
        check(drawn == 5 && String(answer.dropFirst(since.count)) == " noon", "drawn from a lagging read: the ghost starts after the keys, not at the read")
        for c in "row at noo" { key(String(c)) }
        check(ghost == "n" && gone == nil, "typed letter by letter: the last letter is still there")
        key("n")
        check(gone == "typed all", "it goes only when he has typed all of it")
        ghost = "for the help"; typedIn = 0; gone = nil
        key("f"); key("o"); key("u")
        check(gone == "typed other" && ghost == "r the help", "or when he types something else")
    }

    /// Tab-drops round (2026-11-20): a Tab that put nothing in names why, a no-break space and a field one Tab
    /// behind no longer drop it, a repeated word goes in, and a whole streamed part keeps its rest. Made-up lines.
    static func tabDrops() {
        typealias R = GhostRules
        check(R.tabRead(expected: "see you ", now: "see you\u{00A0}") == .ahead(""), "1: a no-break space reads as the space Tab expects")
        check(R.tabRead(expected: "see you", now: "see you there") == .ahead(" there"), "the letters he typed since come back")
        check(R.tabRead(expected: "see you there ", now: "see you ") == .behind, "6: the field not yet holding the last Tab's word: behind")
        check(R.tabRead(expected: "see you", now: "sea") == .other, "a changed field")
        check(R.tabExit(valid: true, spot: true, sameField: true, read: .ahead(""), looksLeft: 3, piece: "there") == nil, "a good Tab goes in")
        check(R.tabExit(valid: true, spot: true, sameField: true, read: .behind, looksLeft: 2, piece: "there") == nil, "behind with looks left: read again")
        check(R.tabExit(valid: true, spot: true, sameField: true, read: .behind, looksLeft: 0, piece: "there") == "field behind", "behind with no looks left: named")
        check(R.tabExit(valid: false, spot: true, sameField: true, read: nil, looksLeft: 3, piece: "x") == "ghost moved", "a ghost gone since the key: named")
        check(R.tabExit(valid: true, spot: false, sameField: true, read: nil, looksLeft: 3, piece: "x") == "no spot", "no spot: named")
        check(R.tabExit(valid: true, spot: true, sameField: false, read: nil, looksLeft: 3, piece: "x") == "other field", "another field: named")
        check(R.tabExit(valid: true, spot: true, sameField: true, read: .other, looksLeft: 3, piece: "x") == "field changed", "a changed field: named")
        check(R.tabExit(valid: true, spot: true, sameField: true, read: .ahead(""), looksLeft: 3, piece: "") == "nothing left", "nothing left: named")
        // 6: two fast Tabs on "very very good": the second reads against the spot the first left, so "very" goes in again
        var spot = "it is "
        spot += "very "                                                   // the first Tab's word, the spot moved with it
        if case .ahead(let since) = R.tabRead(expected: spot, now: "it is very ") {
            var piece = "very "
            if !since.isEmpty, piece.hasPrefix(since) { piece = String(piece.dropFirst(since.count)) }
            check(piece == "very ", "6: a repeated word is not taken off as typed since")
        } else { check(false, "6: the second Tab reads ahead") }
        let old: R.TabRead = R.tabRead(expected: "it is ", now: "it is very ")
        check(old == .ahead("very "), "the old spot (before the fix) read the first word as typed since and took the second off")
        // 3: the whole first part taken while its answer still streams: the rest is drawn, no new ask stops it
        check(R.tabThrough(wholeTaken: true, paintedSeq: 7, shownSeq: 7, finishedSeq: 6), "3: whole part taken mid-stream: its rest comes")
        check(!R.tabThrough(wholeTaken: true, paintedSeq: 7, shownSeq: 7, finishedSeq: 7), "its answer had ended: ask at once")
        check(!R.tabThrough(wholeTaken: false, paintedSeq: 7, shownSeq: 7, finishedSeq: 6), "one word taken: the rest is on screen")
        // lagging Electron/Chromium field on final look: small typed lag treated as caught-up
        check(R.tabBehindCaughtUp(read: .behind, sameField: true, looksLeft: 1, expected: "see you tom", now: "see you "), "final look with 3-char typed lag: caught up")
        check(R.tabBehindCaughtUp(read: .behind, sameField: true, looksLeft: 1, expected: "see\u{00A0}you tomor", now: "see you"), "final look with nbsp and 6-char lag: caught up")
        check(R.tabBehindCaughtUp(read: .behind, sameField: true, looksLeft: 1, expected: "hello 12345678", now: "hello "), "final look at exact 8-char lag cap: caught up")
        check(!R.tabBehindCaughtUp(read: .behind, sameField: true, looksLeft: 1, expected: "hello 123456789", now: "hello "), "9-char lag exceeds cap: not caught up")
        check(!R.tabBehindCaughtUp(read: .behind, sameField: true, looksLeft: 2, expected: "see you tom", now: "see you "), "more looks left: keep waiting")
        check(!R.tabBehindCaughtUp(read: .behind, sameField: false, looksLeft: 1, expected: "see you tom", now: "see you "), "different field: never caught up")
        check(!R.tabBehindCaughtUp(read: .other, sameField: true, looksLeft: 1, expected: "see you tom", now: "sea"), "changed field: never caught up")
        check(!R.tabBehindCaughtUp(read: .behind, sameField: true, looksLeft: 1, expected: "see you tom", now: "see you x"), "non-prefix lag: never caught up")
        // involuntary vs user-dismiss hide reasons
        check(R.involuntaryHide("context") && R.involuntaryHide("cancel") && R.involuntaryHide("replaced") && R.involuntaryHide("rest not placed") && R.involuntaryHide("tab field behind"),
              "involuntary hide reasons arm vanish Tab hold")
        for why in ["esc", "shortcut", "taken", "typed all", "click"] {
            check(!R.involuntaryHide(why), "user dismiss reason \(why) does not arm vanish Tab hold")
        }
    }

    static func main() {
        typealias R = GhostRules
        // 9: the final line after a drawn part
        check(R.next(raw: "hello world,", stillThis: true, text: "hello world, again", hasAction: false, final: true) == .extend(" again"), "a longer final grows the part")
        check(R.next(raw: "hello world,", stillThis: true, text: "hello world,", hasAction: false, final: true) == .keep, "the same final keeps it")
        check(R.next(raw: "hello world,", stillThis: true, text: "", hasAction: false, final: true) == .drop, "an empty final takes the part away")
        check(R.next(raw: "hello world,", stillThis: true, text: "hello", hasAction: false, final: true) == .keep, "a shorter final that starts the part keeps it (ghost-hide round)")
        check(R.next(raw: "hello world,", stillThis: true, text: "help", hasAction: false, final: true) == .redraw, "another final (the finisher) redraws")
        check(R.next(raw: "hello world,", stillThis: false, text: "", hasAction: false, final: true) == .keep, "a ghost already gone or typed over is left alone")
        check(R.next(raw: "hello", stillThis: true, text: "hel", hasAction: false, final: false) == .keep, "a non-final line never takes words away")
        // 10: a part's retry after its final
        check(R.lateLine(final: false, mine: 10, finished: 10), "a part after its own final is late")
        check(!R.lateLine(final: false, mine: 11, finished: 10), "a newer request's part is not")
        check(!R.lateLine(final: true, mine: 10, finished: 10), "a final (and its retry) still goes on")
        // 11: a newer key the field has not taken yet
        check(R.fieldBehind(revAsked: 5, revNow: 6, asked: "hello ", now: "hello "), "newer key, field unchanged: behind")
        check(!R.fieldBehind(revAsked: 5, revNow: 6, asked: "hello ", now: "hello w"), "he typed its first letters: drawn as before")
        check(!R.fieldBehind(revAsked: 6, revNow: 6, asked: "hello ", now: "hello "), "no newer key: drawn")
        check(R.fieldBehind(revAsked: 5, revNow: 6, asked: "a\u{A0}b", now: "a b"), "no-break space counts as a space")
        // 12: a queued Tab
        check(R.tabStillValid(visible: true, shown: "there friend", isDraft: false, given: "there "), "the word still shows")
        check(!R.tabStillValid(visible: false, shown: "", isDraft: false, given: "there "), "the ghost went before the Tab ran")
        check(!R.tabStillValid(visible: true, shown: "friend", isDraft: false, given: "there "), "a second fast Tab with the same word")
        check(R.pieceLanded(before: "hello there ", piece: "there "), "the word landed as given")
        check(R.pieceLanded(before: "hello there\u{00A0}", piece: "there "), "a no-break space after the word counts")
        check(R.pieceLanded(before: "hello there", piece: "there "), "the field dropped the trailing space")
        check(!R.pieceLanded(before: "hello ", piece: "there "), "the word has not landed yet")
        check(!R.pieceLanded(before: "hello theme", piece: "there "), "another word is not this one")
        check(R.restLooks >= 4 && Double(R.restLooks) * R.restLookGap >= 0.4, "the rest waits at least 0.4 s for a late field")
        check(R.tabStillValid(visible: true, shown: "a whole message", isDraft: true, given: "a whole message"), "a next-message card")
        // 14: Tab on a folded next-message card
        check(R.draftTab(expanded: false, cut: true) == .open, "folded with hidden lines: the first Tab opens it")
        check(R.draftTab(expanded: true, cut: false) == .insert, "opened: the next Tab puts it in")
        check(R.draftTab(expanded: false, cut: false) == .insert, "all of it in two lines: Tab puts it in at once")
        // round five: which keys are asked for at once (Keys.predict)
        check(R.predictable(readRev: 9, keyRev: 10, age: 0.2), "a read at the key before: at once")
        check(R.predictable(readRev: 9, keyRev: 10, age: 12), "the first key after a pause of 12 s: at once (was 3 s)")
        check(!R.predictable(readRev: 9, keyRev: 10, age: 25), "a read older than 20 s: the slow way")
        check(!R.predictable(readRev: 8, keyRev: 10, age: 0.1), "a key came between the read and this one: the slow way")
        check(!R.predictable(readRev: 10, keyRev: 10, age: 0.1), "no key since the read: nothing to predict")
        check(!R.predictable(readRev: 9, keyRev: 10, age: -1), "a clock step back: the slow way")
        // round five: the debounced ask after a predicted one
        check(R.askedAtKey(before: "see you", rev: 4, pending: true, now: "see you", keyRev: 4), "still on its way: not asked again")
        check(R.askedAtKey(before: "see you", rev: 4, pending: false, now: "see you", keyRev: 4), "already came for this key: not asked again")
        check(!R.askedAtKey(before: "see you", rev: 3, pending: false, now: "see you", keyRev: 4), "came for an older key: asked")
        check(!R.askedAtKey(before: "see yuo", rev: 4, pending: false, now: "see you", keyRev: 4), "the field holds other text (the guess was wrong): asked")
        check(R.askedAtKey(before: "see\u{A0}you", rev: 4, pending: false, now: "see you", keyRev: 4), "no-break space counts as a space")
        // long round: sentence-length ghosts, rolling ghost, futures, other ideas, the two keys
        check(R.lengthMode("phrase") == "phrase" && R.lengthMode("word") == "word" && R.lengthMode("") == "sentence", "length setting reads, default sentence")
        // earlier round: 3-5 words and the lower gate in the request
        check(R.minLetters(minGhost: 5, short: true, minShort: 3) == 3 && R.minLetters(minGhost: 5, short: false, minShort: 3) == 5, "short ghosts switch picks the minimum")
        check(R.minLetters(minGhost: -1, short: false, minShort: 3) == 0, "never under 0")
        let idle = { (b: String) in R.idleAllowed(on: true, secure: false, password: false, skipped: false, chatBox: true, mid: false, before: b) }
        check(idle("") && idle("Thanks. ") && idle("Done!  ") && idle("hi\n") && idle("Він сказав «так.» "), "idle ghost: empty box, sentence end, new line")
        check(!idle("see you") && !idle("ok.") && !idle("so, "), "idle ghost: never mid-sentence or right on the stop")
        check(!R.idleAllowed(on: true, secure: true, password: false, skipped: false, chatBox: true, mid: false, before: ""), "idle ghost: never under secure input")
        check(!R.idleAllowed(on: true, secure: false, password: true, skipped: false, chatBox: true, mid: false, before: ""), "idle ghost: never in a password field")
        check(!R.idleAllowed(on: true, secure: false, password: false, skipped: true, chatBox: true, mid: false, before: ""), "idle ghost: never in a skipped app")
        check(!R.idleAllowed(on: false, secure: false, password: false, skipped: false, chatBox: true, mid: false, before: "") &&
              !R.idleAllowed(on: true, secure: false, password: false, skipped: false, chatBox: false, mid: false, before: ""), "idle ghost: switch off, or not a chat box")
        let ib = R.idleBody(["before": "", "keep_on": true])
        check(ib["idle"] as? Bool == true && ib["early"] == nil && ib["keep_on"] == nil, "idle request: local only")
        check(R.olderThanShown(askedRev: 4, shownRev: 6, visible: true), "an older answer never replaces newer grey text")
        check(!R.olderThanShown(askedRev: 6, shownRev: 6, visible: true) && !R.olderThanShown(askedRev: 7, shownRev: 6, visible: true), "the same or a newer key may")
        check(!R.olderThanShown(askedRev: 4, shownRev: 6, visible: false) && !R.olderThanShown(askedRev: nil, shownRev: 6, visible: true), "nothing on screen, or no revision: as before")
        let w = R.runBody(mode: "sentence", words: true, minWords: 3, maxWords: 5, guess: true, shade: true, strict: false)!
        check(w["length"] as? String == "words" && w["words_min"] as? Int == 3 && w["words_max"] as? Int == 5, "3-5 words asked")
        check(w["guess"] as? Bool == true && w["guess_shade"] as? Bool == true, "guesses asked, lighter")
        let off = R.runBody(mode: "sentence", words: false, minWords: 3, maxWords: 5, guess: false, shade: true, strict: false)!
        check(off["length"] as? String == "sentence" && off["guess"] == nil && off["words_min"] == nil, "switches off: the sentence run as before")
        check(R.runBody(mode: "word", words: true, minWords: 3, maxWords: 5, guess: true, shade: true, strict: false) == nil, "word length keeps its own rule")
        check(R.runBody(mode: "sentence", words: true, minWords: 3, maxWords: 5, guess: true, shade: true, strict: false, early: true)?["early_start"] as? Bool == true, "early start asks the lower notch")
        check(R.runBody(mode: "sentence", words: true, minWords: 3, maxWords: 5, guess: false, shade: true, strict: false, early: true)?["early_start"] == nil, "early start only with guesses")
        // short-ghost round (18 November 2026): a ghost typed to its end while its answer still streams keeps its rest
        check(R.typedThrough(visible: false, paintedSeq: 7, shownSeq: 7, finishedSeq: 6), "typed through a streaming ghost")
        check(!R.typedThrough(visible: false, paintedSeq: 7, shownSeq: 7, finishedSeq: 7), "its answer had ended: ask again")
        check(!R.typedThrough(visible: true, paintedSeq: 7, shownSeq: 7, finishedSeq: 6), "still on screen: nothing to do")
        check(!R.typedThrough(visible: false, paintedSeq: nil, shownSeq: 7, finishedSeq: 6), "not a streamed ghost")
        check(!R.typedThrough(visible: false, paintedSeq: 6, shownSeq: 7, finishedSeq: 6), "another answer's ghost")
        check(R.keepLonger(visible: true, shown: "meet you there at noon", new: "meet you"), "a shorter start of the same words keeps the ghost")
        check(!R.keepLonger(visible: true, shown: "meet you", new: "meet you there"), "a longer answer replaces it")
        check(!R.keepLonger(visible: true, shown: "meet you there", new: "see you"), "other words replace it")
        check(!R.keepLonger(visible: false, shown: "meet you there", new: "meet"), "nothing on screen: draw it")
        check(!R.keepLonger(visible: true, shown: "meet you", new: ""), "an empty answer is not drawn either way")
        // more-bold round (17 November 2026): the user's Bolder / Careful bar goes as guess_bar, in steps of 0.05 inside 0.05-0.35
        check(R.runBody(mode: "sentence", words: true, minWords: 3, maxWords: 5, guess: true, shade: true, strict: false, guessBar: 0.15)?["guess_bar"] as? Double == 0.15, "his bar is sent")
        check(R.runBody(mode: "sentence", words: true, minWords: 3, maxWords: 5, guess: false, shade: true, strict: false, guessBar: 0.15)?["guess_bar"] == nil, "no bar without guesses")
        check(R.runBody(mode: "sentence", words: true, minWords: 3, maxWords: 5, guess: true, shade: true, strict: false)?["guess_bar"] == nil, "no setting: the engine's bar")
        check(R.boldBar(0.0) == 0.05 && R.boldBar(0.9) == 0.35 && R.boldBar(0.17) == 0.15 && R.boldBar(0.4 - 0.25) == 0.15, "bold bar kept in range and steps")
        check(R.runBody(mode: "sentence", words: true, minWords: 3, maxWords: 5, guess: true, shade: true, strict: true) == nil, "Zoom stays strict")
        let odd = R.runBody(mode: "phrase", words: true, minWords: 9, maxWords: 2, guess: true, shade: false, strict: false)!
        check(odd["words_min"] as? Int == 5 && odd["words_max"] as? Int == 5 && odd["guess_shade"] as? Bool == false, "numbers kept in range; shade off")
        let cb = R.cadenceBody(combo: true, gapMs: 85)
        check(cb["combo"] as? Bool == true && cb["gap_ms"] as? Int == 85, "combo: the gap goes with it")
        check(R.cadenceBody(combo: true, gapMs: -1)["gap_ms"] == nil, "an unknown gap is not sent")
        let co = R.cadenceBody(combo: false, gapMs: 85)
        check(co["combo"] as? Bool == false && co["gap_ms"] == nil, "off: combo false, no gap")
        check(R.wordsLeft("go home ") == 2 && R.wordsLeft("") == 0, "words left")
        check(R.rollWanted(rest: "go home", mode: "sentence", final: true, plain: true, wanted: "a go home", askedFor: nil), "two words left: roll")
        check(!R.rollWanted(rest: "we can go home", mode: "sentence", final: true, plain: true, wanted: "a we can go home", askedFor: nil), "four left: not yet")
        check(!R.rollWanted(rest: "home", mode: "word", final: true, plain: true, wanted: "a home", askedFor: nil), "word mode never rolls")
        check(!R.rollWanted(rest: "home", mode: "sentence", final: false, plain: true, wanted: "a home", askedFor: nil), "a ghost still streaming does not roll")
        check(!R.rollWanted(rest: "home", mode: "sentence", final: true, plain: false, wanted: "a home", askedFor: nil), "a chip or fix does not roll")
        check(!R.rollWanted(rest: "home", mode: "sentence", final: true, plain: true, wanted: "a home", askedFor: "a\u{A0}home"), "asked once per text")
        check(R.rollFits(asked: "a go home", now: "a go home") && !R.rollFits(asked: "a go home", now: "a go hime"), "roll answer only while it still fits")
        check(R.rollUnsure(old: 4, more: 6, moreUnsure: 2) == 10, "after a lighter tail, all added words are lighter")
        check(R.rollUnsure(old: 0, more: 6, moreUnsure: 2) == 2, "after a sure part, the roll brings its own split")
        let fs: [(letter: String, text: String, unsure: String)] = [("b", "ook it", " it"), ("p", "lan", "")]
        check(R.future(base: "see the ", before: "see the ", typed: "b", futures: fs)?.text == "ook it", "his letter matches a prepared future")
        check(R.future(base: "see the ", before: "see the x", typed: "b", futures: fs) == nil, "another base: none")
        check(R.future(base: "see the ", before: "see the ", typed: "z", futures: fs) == nil, "no future for that letter")
        let ideas = R.ideas(shown: "car", futures: fs + [("c", "ar", "")])
        check(ideas.map { $0.text } == ["car", "book it", "plan"], "ideas: shown first, then futures, no repeat of the shown")
        check(ideas[1].unsure == 3, "a future keeps its lighter tail")
        check(R.cycle(index: 0, count: 3) == 1 && R.cycle(index: 2, count: 3) == 0 && R.cycle(index: 0, count: 1) == nil, "cycle wraps; one idea: nothing")
        check(R.longKey(code: 48, control: true, shift: false, option: false, command: false, ghost: true, plain: true) == .none, "⌃Tab is the app's (keys round three)")
        check(R.longKey(code: 48, control: true, shift: true, option: false, command: false, ghost: true, plain: true) == .none, "⌃⇧Tab is the app's (keys round three)")
        check(R.longKey(code: 48, control: true, shift: true, option: false, command: false, ghost: false, plain: true) == .none, "no ghost: the app gets ⌃⇧Tab")
        check(R.longKey(code: 48, control: true, shift: false, option: false, command: false, ghost: true, plain: false) == .none, "a chip: not ours")
        check(R.longKey(code: 48, control: false, shift: true, option: false, command: false, ghost: true, plain: true) == .none, "⇧Tab stays the whole ghost")
        check(R.longKey(code: 48, control: true, shift: false, option: true, command: false, ghost: true, plain: true) == .none, "⌃⌥Tab is not ours")
        // mid-line round (2026-11-15): when a ghost may show with text after the caret on its line
        check(R.lineRest(" the park.\nnext line") == " the park.", "the rest of the line stops at the break")
        check(R.lineRest("") == "", "nothing after the caret")
        check(R.midLineOK(before: "we walked to", rest: " the park."), "a gap before a word: shows")
        check(R.midLineOK(before: "see you at noon", rest: ", thanks"), "before a comma: shows")
        check(R.midLineOK(before: "(call me", rest: ")"), "before a closing bracket: shows")
        check(!R.midLineOK(before: "we wal", rest: "ked home"), "a letter after the caret: inside a word, quiet")
        check(!R.midLineOK(before: "room ", rest: "42 is free"), "a digit after the caret: quiet")
        check(!R.midLineOK(before: "we don", rest: "'t know"), "an apostrophe between letters: inside a word, quiet")
        check(!R.midLineOK(before: "a well", rest: "-known spot"), "a hyphen between letters: inside a word, quiet")
        check(R.midLineOK(before: "she said ", rest: "'hello'"), "a quote after a space: a gap, shows")
        check(!R.midLineOK(before: "abc", rest: "   "), "only spaces after the caret: not mid-line (the plain path)")
        check(!R.midLineOK(before: "abc", rest: ""), "nothing after the caret: not mid-line")
        check(!R.midLineOK(before: "first line\n", rest: " rest"), "nothing typed on the caret's line: quiet")
        check(!R.midLineOK(before: "word", rest: " " + String(repeating: "x", count: R.midRestMax)), "a long rest: quiet")
        check(R.midLineOK(before: "word", rest: " " + String(repeating: "x", count: R.midRestMax - 1)), "a rest at the cap: shows")
        check(R.midAfter(" end of line\nsecond\nthird\nfourth") == " end of line\nsecond\nthird", "after: the line and two more")
        check(R.midAfter(String(repeating: "y", count: 900)).count == R.midAfterMax, "after: capped")
        check(R.midText("the big park", rest: " park.") == "the big", "the ghost never repeats the rest at its end")
        check(R.midText("the big ", rest: " park.") == "the big", "no trailing space before a rest that starts with one")
        check(R.midText("one line\nanother", rest: ", ok") == "one line", "one line only")
        check(R.midText("p", rest: " p") == "p", "a single letter is no overlap")
        check(R.midText("for the help, thanks", rest: ", thanks") == "for the help", "the overlap with the punctuation goes too")
        // web ghost, 2026-11-17: size and colour when the field gives none
        check(R.fallbackSize(caretHeight: 18, web: true) == 15, "a Chromium caret of 18 gives size 15 (Georgia 15)")
        check(R.fallbackSize(caretHeight: 16, web: true) == 13, "a Chromium caret of 16 gives size 13")
        check(R.fallbackSize(caretHeight: 18, web: false) == 14, "native keeps 0.78")
        check(R.fallbackSize(caretHeight: 4, web: true) == 11, "no smaller than 11")
        check(R.fallbackSize(caretHeight: 80, web: true) == 26, "no larger than 26")
        let g = R.ghostColour(field: nil)
        check(g.3 == 1 && g.0 > 0.4 && g.0 < 0.7, "no field colour: a mid grey, fully opaque")
        let f = R.ghostColour(field: (0.1, 0.2, 0.3))
        check(f.0 == 0.1 && f.2 == 0.3 && f.3 == 0.38, "a field colour at 0.38")
        ghostHide()
        tabDrops()
        if failures > 0 { print("\(failures) failed"); exit(1) }
        print("ghost rules: all passed")
    }
}

import Foundation

// swiftc -parse-as-library app/KeyMap.swift app/KeyRules.swift app/QuickRules.swift app/PictureLookRules.swift app/ClipRules.swift tests/key_rules.swift -o app/build/key-rules-test && app/build/key-rules-test
// The keys round (14 November 2026) with made-up lines and event sequences: Backspace takes back the last Tab, Esc
// twice pauses one field, the last voice take again (⌃⌥R), and ⌘⇧V again swapping a switcher paste.
@main
struct KeyRuleChecks {
    static var failures = 0
    static func check(_ ok: Bool, _ what: String) { if !ok { print("FAIL: " + what); failures += 1 } }

    static func main() {
        tabBack(); escPause(); lastTake(); swapRows(); keySequences(); againTap(); keysRoundTwo(); roundThree()
        // row 4b: a Tab right after a take with nothing left stays with Drafter, a slower one is the app's
        check(KeyRules.tabHeld(sinceTake: 0.3, ghost: false), "Tab 0.3 s after a take, nothing left: held")
        check(!KeyRules.tabHeld(sinceTake: 1.2, ghost: false), "Tab 1.2 s after: the app's")
        check(!KeyRules.tabHeld(sinceTake: nil, ghost: false), "no take: the app's")
        check(!KeyRules.tabHeld(sinceTake: 0.3, ghost: true), "grey text up: Tab takes it, not held")
        // stray Tab right after involuntary plain-ghost vanish: held within 0.28 s
        check(KeyRules.tabHoldAfterVanish(sinceVanish: 0.0, ghost: false), "Tab immediately after vanish: held")
        check(KeyRules.tabHoldAfterVanish(sinceVanish: 0.15, ghost: false), "Tab 0.15 s after vanish: held")
        check(!KeyRules.tabHoldAfterVanish(sinceVanish: 0.28, ghost: false), "Tab at 0.28 s boundary: goes to app")
        check(!KeyRules.tabHoldAfterVanish(sinceVanish: 0.5, ghost: false), "Tab 0.5 s after vanish: goes to app")
        check(!KeyRules.tabHoldAfterVanish(sinceVanish: -0.05, ghost: false), "clock step back: not held")
        check(!KeyRules.tabHoldAfterVanish(sinceVanish: nil, ghost: false), "no vanish: not held")
        check(!KeyRules.tabHoldAfterVanish(sinceVanish: 0.1, ghost: true), "ghost visible: Tab takes it, not held")
        // tab-drops round (2026-11-20)
        let t = Date()
        check(KeyRules.tabStamp(t, aborted: true, otherKey: false) == nil, "2: a Tab that put nothing in clears the stamp")
        check(KeyRules.tabStamp(t, aborted: false, otherKey: true) == nil, "2: another key clears it")
        check(KeyRules.tabStamp(t, aborted: false, otherKey: false) == t, "a Tab that took words keeps it")
        check(!KeyRules.tabHeld(sinceTake: KeyRules.tabStamp(t, aborted: true, otherKey: false).map { Date().timeIntervalSince($0) }, ghost: false),
              "2: so the Tab after an aborted one is not held")
        check(!KeyRules.takeOwnsKeys(listening: true, long: true), "4: a long note or call leaves the keys to grey text and Tab")
        check(KeyRules.takeOwnsKeys(listening: true, long: false), "a short take owns them")
        check(!KeyRules.takeOwnsKeys(listening: false, long: false), "no take: nothing owns them")
        if failures > 0 { print("\(failures) failed"); exit(1) }
        print("key rules: all passed")
    }

    static func tabBack() {
        // Tab took one word of "meeting tomorrow at ten"
        let u = KeyRules.tabUndo(piece: "meeting ", given: "meeting ", full: "meeting tomorrow at ten", rev: 40, at: 100)
        check(u?.ghost == "meeting tomorrow at ten", "the ghost comes back whole: \(String(describing: u?.ghost))")
        check(KeyRules.tabBack(u, rev: 41, now: 100.5, on: true), "the very next key is Backspace: take it back")
        check(!KeyRules.tabBack(u, rev: 42, now: 100.5, on: true), "a key in between: Backspace is normal")
        check(!KeyRules.tabBack(u, rev: 41, now: 100.5, on: false), "switch off")
        check(!KeyRules.tabBack(u, rev: 41, now: 100 + KeyRules.tabBackSeconds + 1, on: true), "too late")
        check(!KeyRules.tabBack(nil, rev: 41, now: 100.5, on: true), "no Tab")
        // ⇧Tab took the whole ghost
        let w = KeyRules.tabUndo(piece: "see you there", given: "see you there", full: "see you there", rev: 7, at: 5)
        check(w?.ghost == "see you there" && KeyRules.tabBack(w, rev: 8, now: 6, on: true), "⇧Tab whole ghost")
        // a space typed meanwhile was taken off the piece: the ghost shown again starts where the caret is then
        let v = KeyRules.tabUndo(piece: "plan ", given: " plan ", full: " plan for friday", rev: 3, at: 1)
        check(v?.ghost == "plan for friday", "letters typed meanwhile stay his: \(String(describing: v?.ghost))")
        check(KeyRules.tabUndo(piece: "", given: "x", full: "x", rev: 1, at: 1) == nil, "nothing went in")
        check(KeyRules.tabUndo(piece: "a", given: "b", full: "c", rev: 1, at: 1) == nil, "ghost moved on")
        check(KeyRules.stillEnds(before: "Let us move the meeting ", piece: "meeting "), "field ends with it")
        check(KeyRules.stillEnds(before: "Let us move the meeting\u{A0}", piece: "meeting "), "no-break space reads as space")
        check(!KeyRules.stillEnds(before: "Let us move the meetings", piece: "meeting "), "field changed")
        check(!KeyRules.stillEnds(before: "abc", piece: ""), "empty piece")
    }

    static func escPause() {
        var p = EscPause()
        let f = "com.example.chat#42", g = "com.example.chat#43"
        check(p.esc(key: f, now: 10, rev: 1, ghostRecent: true) == .none, "one Esc: nothing")
        check(p.esc(key: f, now: 10.3, rev: 2, ghostRecent: false) == .paused, "two within 450 ms after a ghost: paused")
        check(p.paused(f, now: 11) && !p.paused(g, now: 11), "only this field")
        check(p.paused(f, now: 10.3 + 599) && !p.paused(f, now: 10.3 + 601), "for 10 minutes")
        check(p.esc(key: f, now: 20, rev: 3, ghostRecent: false) == .none, "a third Esc after the pair starts a new pair")
        check(p.esc(key: f, now: 20.2, rev: 4, ghostRecent: false) == .resumed && !p.paused(f, now: 21), "the same pair again resumes")
        // no ghost anywhere: a double Esc is the app's
        var q = EscPause()
        _ = q.esc(key: f, now: 1, rev: 1, ghostRecent: false)
        check(q.esc(key: f, now: 1.2, rev: 2, ghostRecent: false) == .none && !q.paused(f, now: 2), "no ghost: no pause")
        // too slow, a key between, another field
        var r = EscPause()
        _ = r.esc(key: f, now: 1, rev: 1, ghostRecent: true)
        check(r.esc(key: f, now: 1.5, rev: 2, ghostRecent: false) == .none, "500 ms apart: not a pair")
        _ = r.esc(key: f, now: 5, rev: 10, ghostRecent: true)
        check(r.esc(key: f, now: 5.1, rev: 12, ghostRecent: false) == .none, "a key between the two")
        _ = r.esc(key: f, now: 8, rev: 20, ghostRecent: true)
        check(r.esc(key: g, now: 8.1, rev: 21, ghostRecent: false) == .none, "another field")
        check(!r.paused(f, now: 9) && !r.paused(g, now: 9), "nothing paused")
        // a ghost shown at the second press is enough (it was hidden by nothing yet)
        var s = EscPause()
        _ = s.esc(key: f, now: 1, rev: 1, ghostRecent: false)
        check(s.esc(key: f, now: 1.1, rev: 2, ghostRecent: true) == .paused, "ghost at the second press")
        check(KeyRules.fieldKey(app: "com.example.chat", element: 42) == f, "field key")
    }

    static func lastTake() {
        check(KeyRules.lastTake([("Call the plumber about the kitchen tap", ""), ("older take", "")]) == "Call the plumber about the kitchen tap", "newest take")
        check(KeyRules.lastTake([("", "timeout"), ("  ", ""), ("✎ make it shorter\n- before: a\n- after: b", ""), ("Buy paper and pens", "")]) == "Buy paper and pens",
              "failed, empty and spoken-rule rows skipped")
        check(KeyRules.lastTake([("half a sentence", "incomplete"), ("⟦drafter-test⟧ hello", "")]) == nil, "only test or failed rows: none")
        check(KeyRules.lastTake([]) == nil, "no takes")
        check(KeyRules.lastTake([("  Send the drawings today \n", "")]) == "Send the drawings today", "trimmed")
    }

    static func swapRows() {
        check(KeyRules.swapNext([true, true, true], after: 0) == 1, "next older")
        check(KeyRules.swapNext([true, true, true], after: 2) == nil, "the oldest: nothing older")
        check(KeyRules.swapNext([true, false, true], after: 0) == nil, "a file or picture next: the switcher opens instead")
        check(KeyRules.swapNext([], after: 0) == nil && KeyRules.swapNext([true], after: -1) == nil, "edges")
    }

    /// Keys round two: a double tap of Right Option, never a delay on a single press.
    static func againTap() {
        func t(_ since: Double = 0.3, on: Bool = true, listening: Bool = true, long: Bool = false, held: Bool = false, words: Bool = false) -> Bool {
            KeyRules.againTap(enabled: on, listening: listening, long: long, held: held, sinceFirst: since, words: words)
        }
        check(t(), "tap, tap within 0.45 s on an empty take: the last take again")
        check(t(0.45) && !t(0.46) && !t(1.2), "the window ends at 0.45 s; later the second press stops the take as before")
        check(!t(words: true), "words heard: the second press ends the take (never drops speech)")
        check(!t(long: true), "⇧ Right Option's long note or a call: never")
        check(!t(held: true), "still held (push to talk): never")
        check(!t(on: false), "off: the second press stops the take")
        check(!t(listening: false), "no take running: a press starts one, at once")
        check(!t(-0.1), "a clock going back: never")
    }

    /// Keys round two: an old settings file moves to the new defaults; the user's own keys stay.
    static func keysRoundTwo() {
        let old: [String: Any] = ["captureKey": "⌃⌥S", "captureCmdShiftS": true, "quickKey": "⌃⌥V", "againKey": "⌃⌥R", "voice": true]
        let n = KeyRules.keysRoundTwo(old)
        check(n["captureKey"] as? String == "⌘⇧5" && n["captureCmdShiftS"] as? Bool == false, "capture: ⌘⇧5, Save As back to apps")
        check(n["quickKey"] as? String == "" && n["againKey"] as? String == "", "⌃⌥V and ⌃⌥R off")
        check(n["keysRound"] as? Int == 2 && n["voice"] as? Bool == true, "marked; other settings kept")
        let own: [String: Any] = ["captureKey": "⌃⌥⇧S", "quickKey": "⌃⌥C", "againKey": "", "captureCmdShiftS": true]
        let m = KeyRules.keysRoundTwo(own)
        check(m["captureKey"] as? String == "⌃⌥⇧S" && m["quickKey"] as? String == "⌃⌥C" && m["againKey"] as? String == "", "his own keys stay")
        check(KeyRules.keysRoundTwo([:])["captureKey"] == nil, "a key never saved keeps the new default")
    }

    /// Keys round three (the key map): made-up apps and states.
    static func roundThree() {
        let skip = ["com.example.terminal", "com.example.editor", "drafter.own"]
        check(KeyRules.skippedAppKeeps(front: "com.example.terminal", skip: skip, own: "drafter.own"), "row 1: ⌘⇧V in a skipped app is the app's")
        check(!KeyRules.skippedAppKeeps(front: "com.example.chat", skip: skip, own: "drafter.own"), "row 1: elsewhere the picker opens")
        check(!KeyRules.skippedAppKeeps(front: "drafter.own", skip: skip, own: "drafter.own") && !KeyRules.skippedAppKeeps(front: nil, skip: skip, own: "drafter.own"),
              "row 1: Drafter's own window and no front app keep the picker")

        func o(_ code: Int = 48, plain: Bool = true, shift: Bool = false, call: Bool = false, forms: Int = 3, ghost: Bool = false) -> KeyRules.OfferKey {
            KeyRules.offerKey(code: code, plain: plain, shiftOnly: shift, call: call, forms: forms, ghost: ghost)
        }
        check(o(call: true, forms: 0) == .none, "row 3: Tab never takes a call offer")
        check(o(plain: false, shift: true, call: true, forms: 0) == .none, "row 3: ⇧Tab neither")
        check(o() == .accept, "row 8: Tab takes the copy chip's form")
        check(o(plain: false, shift: true) == .step, "row 8: ⇧Tab steps the form")
        check(o(plain: false, shift: true, forms: 1) == .none, "row 8: one form: ⇧Tab is not the chip's")
        check(o(ghost: true) == .none && o(plain: false, shift: true, ghost: true) == .none, "a ghost up takes Tab and ⇧Tab first")
        check(o(19) == .none && o(20) == .none, "row 8: digits 2 and 3 are the app's")
        check(KeyRules.callOfferKey(voice: true) == "⇧ right ⌥" && KeyRules.callOfferKey(voice: false) == "", "row 3: the call offer never says tab")

        check(KeyRules.tabRunsChip(kind: "expand") && KeyRules.tabRunsChip(kind: "proofread") && KeyRules.tabRunsChip(kind: "copy") && !KeyRules.tabRunsChip(kind: "lookup.insert"), "row 4: text chips take Tab")
        for k in ["eventkit.event", "eventkit.reminder", "open", "python", "snippet.save", "draft", "something new"] {
            check(!KeyRules.tabRunsChip(kind: k), "row 4: Tab never runs \(k)")
        }
        check(!KeyRules.tabRunsChip(kind: nil), "row 4: a chip without a run kind is not Tab's")

        check(!KeyRules.tabAsks(code: 48, emptyBox: true), "row 5: Tab in an empty box asks nothing")
        check(KeyRules.tabAsks(code: 48, emptyBox: false) && KeyRules.tabAsks(code: 0, emptyBox: true), "row 5: elsewhere as before")
        check(KeyRules.cardArrow(code: 124, expanded: false) == nil && KeyRules.cardArrow(code: 125, expanded: false) == nil, "row 5: a folded card leaves arrows to the app")
        check(KeyRules.cardArrow(code: 123, expanded: true) == .flip(-1) && KeyRules.cardArrow(code: 124, expanded: true) == .flip(1)
              && KeyRules.cardArrow(code: 126, expanded: true) == .fold, "row 5: an opened card takes ← → ↑")

        func d(held: Bool = true, listening: Bool = true, long: Bool = false, words: Bool = false) -> Bool {
            KeyRules.optionChordDrops(held: held, listening: listening, long: long, words: words)
        }
        check(d(), "row 9: a key with Right Option held, nothing said: the take goes")
        check(!d(words: true), "row 9: words heard: the take stays (Return with push to talk)")
        check(!d(held: false) && !d(long: true) && !d(listening: false), "row 9: released, a long note, no take: nothing")

        check(KeyRules.ownChord("⌃⌥P", others: ["", "⌘⇧V", "", "⌘⇧5"]) == "⌃⌥P", "row 11: ⌃⌥P by default")
        check(KeyRules.ownChord("", others: []) == nil, "row 11: \"\" is off")
        check(KeyRules.ownChord("⇧⌘V", others: ["⌘⇧V"]) == nil, "row 11: never another of Drafter's chords")

        let file = ClipRules.actions(.file)
        check(ClipRules.rowAction(file, code: 8, cmd: true, alt: false, ctrl: false, shift: false)?.id == "copyFile", "row 10: ⌘C copies the file")
        check(ClipRules.rowAction(file, code: 8, cmd: true, alt: true, ctrl: false, shift: false)?.id == "path", "row 10: ⌥⌘C copies the path")
        check(ClipRules.rowAction(file, code: 8, cmd: true, alt: false, ctrl: true, shift: false) == nil
              && ClipRules.rowAction(file, code: 8, cmd: true, alt: false, ctrl: false, shift: true) == nil, "row 10: other modifiers match nothing")
        check(ClipRules.rowAction(ClipRules.actions(.link), code: 17, cmd: true, alt: true, ctrl: false, shift: false) == nil
              && ClipRules.rowAction(ClipRules.actions(.link), code: 17, cmd: true, alt: false, ctrl: false, shift: false)?.id == "untracked", "row 10: ⌥⌘T is not ⌘T")
    }

    static func keySequences() {
        let V = 9, R = 15, A = 0
        func machine() -> QuickKeys {
            var k = QuickKeys(panelKey: QuickRules.hotkey("⌃⌥V"), switchKey: QuickRules.hotkey("⌘⇧V"))
            k.againKey = QuickRules.hotkey("⌃⌥R"); k.quickForm = true   // the held small list (switchQuickForm)
            return k
        }
        func run(_ k: inout QuickKeys, _ es: [QuickKeyEvent]) -> [QuickKeyAction] { es.flatMap { k.route($0) } }
        func at(_ e: QuickKeyEvent, _ t: Double) -> QuickKeyEvent { var e = e; e.at = t; return e }

        var k = machine()
        check(run(&k, [.down(R, "⌃⌥")]) == [.voiceAgain], "⌃⌥R: the last take again")
        check(run(&k, [.down(R, "⌃⌥", repeat: true)]) == [.swallow], "a held ⌃⌥R does not paste again and again")
        check(run(&k, [.down(R, "⌃"), .down(R, "")]) == [.pass, .pass], "other chords with R are the app's")
        k.againKey = nil
        check(run(&k, [.down(R, "⌃⌥")]) == [.pass], "off: the app gets it")

        // a missed release of the switcher never swallows ⌃⌥R: put first, then the take
        k = machine()
        check(run(&k, [.down(V, "⌘⇧"), .down(R, "⌃⌥")]) == [.openSwitch, .put, .voiceAgain], "missed release, then ⌃⌥R")

        // the swap: tap ⌘⇧V and let go (put), the app arms the swap, ⌘⇧V again within 2 s swaps
        k = machine()
        check(run(&k, [at(.down(V, "⌘⇧"), 100), at(.flags(""), 100.2)]) == [.openSwitch, .put], "first paste")
        k.armSwap(until: 100.2 + KeyRules.swapSeconds)
        check(run(&k, [at(.flags("⌘"), 100.8), at(.flags("⌘⇧"), 100.9), at(.down(V, "⌘⇧"), 101)]) == [.pass, .pass, .swap] && !k.switching,
              "⌘⇧V again within 2 s: swap, no switcher held")
        check(run(&k, [at(.flags(""), 101.1)]) == [.pass], "letting go after a swap puts nothing")
        k.armSwap(until: 101 + KeyRules.swapSeconds)
        check(run(&k, [at(.down(V, "⌘⇧"), 102)]) == [.swap], "each press within 2 s steps one older")
        check(run(&k, [at(.down(V, "⌘⇧", repeat: true), 102.1)]) == [.swallow], "a held V after a swap neither swaps nor opens")
        // too late: the switcher opens as usual
        k = machine()
        k.armSwap(until: 50)
        check(run(&k, [at(.down(V, "⌘⇧"), 51), at(.flags(""), 51.2)]) == [.openSwitch, .put], "after 2 s: the switcher")
        // any other key ends the window
        k = machine()
        k.armSwap(until: 50)
        check(run(&k, [at(.down(A, ""), 49), at(.down(V, "⌘⇧"), 49.5)]) == [.pass, .openSwitch], "a key between: the switcher")
        // a missed release after the swap's own press cannot hang: the swap holds nothing
        k = machine()
        k.armSwap(until: 50)
        check(run(&k, [at(.down(V, "⌘⇧"), 49), at(.down(A, ""), 49.2)]) == [.swap, .pass], "a plain letter after a swap goes to the app")
        check(!k.switching && k.swapUntil == 0, "nothing held")
        // not while the panel is open; disarm by hand (a click)
        k = machine(); k.panelOpen = true; k.armSwap(until: 50)
        check(run(&k, [at(.down(V, "⌘⇧"), 49)]) == [.pass], "panel open: no swap, no switcher")
        k = machine(); k.armSwap(until: 50); k.disarmSwap()
        check(run(&k, [at(.down(V, "⌘⇧"), 49)]) == [.openSwitch], "disarmed by a click")
    }
}

// Talk, part: live typing, voice and hands taking turns in the field. Split from app/Voice.swift on 2026-11-16;
// the run's stored state stays in Talk there (an extension holds no stored properties).
import AppKit
import Carbon

extension Talk {
    /// A take or an Enter piece starts: a fresh run. `spot` is the field read at the take's start (nil: read later).
    func startLive(_ spot: Spot? = nil, keepField: Bool = false) {
        live = Drafter.shared.settings.voiceInsert == "live" && editing == nil && !long && !toNote   // never over a selection, in a long note or into the shot strip
        if !keepField {
            runEl = spot?.el; runPid = spot?.app.processIdentifier ?? 0; runBefore = spot?.before.last
            if testing, let s = spot, !s.value.contains("⟦drafter-test⟧") { runEl = nil }
            lost = false
        }
        run = ""; doneBefore = ""; steadyText = ""; steadyWords = 0; landedWords = 0
        prevWords = []; still = 0; lastClean = ""; fixedChars = 0; lastWant = ""; lastSpotTry = .distantPast
        meter.reset(); lastHand = .distantPast; editRev = Keys.shared.editRevision
        flushTimer?.invalidate(); flushTimer = nil
        if live { flushTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] _ in self?.liveStep() } }
    }

    /// A key of his own during a take (from the event tap): voice waits until his hands stop, then goes on where he is.
    func keyDuringTake() {
        guard live else { return }
        lastHand = Date(); handsMoved()
    }

    /// His key or click: the run ends here; the next words start a new one at the caret as it is then.
    private func handsMoved() {
        editRev = Keys.shared.editRevision
        if !run.isEmpty { doneBefore += run }
        run = ""; runEl = nil
    }

    /// A new draft: the strip's steady words, then the field catches up.
    func liveDraft(_ d: String) {
        // what the strip hides (noise words) never goes in; closing words at the end ("…, okay") wait for more words
        guard live, !long, Talk.realCleaned(sendDraft, peak: peak) else { return }
        let clean = Tidy.clean(d)
        still = clean == lastClean ? still + 1 : 1
        lastClean = clean
        let words = clean.split(separator: " ")
        let n = min(LiveType.steady(prevWords, words, still: still), sendDraft.split(separator: " ").count)
        prevWords = words
        meter.saw(words: words.count, at: now)
        if n > 0 { meter.settled(words: n, at: now) }
        // a word already in the field changed in this draft: wait for drafts that agree again rather than take it out
        guard n >= landedWords, n > 0 else { return }
        steadyText = LiveType.head(clean, words: n); steadyWords = n
        liveStep()
    }

    /// What the current run should hold, from a text of the piece (steady words, or the final).
    private func runTarget(_ text: String) -> String? {
        var want = text
        if !doneBefore.isEmpty {
            guard let j = LiveType.aligned(doneBefore, in: text) else { return nil }
            want = String(text[j...])
        }
        let trimmed = String(want.drop(while: { $0 == " " }))
        return LiveType.spaced(trimmed, after: runBefore)
    }

    private static func plain(_ s: String) -> String { s.replacingOccurrences(of: "\u{A0}", with: " ") }

    /// The field is still the run's (same app, same field); the first time in a run, read the caret.
    private func fieldOK() -> Bool {
        guard let app = NSWorkspace.shared.frontmostApplication else { return false }
        if runEl == nil {
            guard run.isEmpty else { return false }
            let (s, why) = Focus.spot(skip: [])
            guard let s else {
                if !["mid-line", "selection", "no caret rect"].contains(why), runPid != 0, app.processIdentifier != runPid { leftField(why) }
                return false
            }
            if testing, !s.value.contains("⟦drafter-test⟧") { leftField("no test marker"); return false }
            if runPid != 0, s.app.processIdentifier != runPid { leftField("other app"); return false }
            runEl = s.el; runPid = s.app.processIdentifier; runBefore = s.before.last
            return true
        }
        guard app.processIdentifier == runPid else { leftField("other app"); return false }
        guard let el = Focus.focused() else { return false }
        if let r = runEl, CFEqual(el, r) { return true }
        // Chromium can hand out a new element for the same box: the same field when it still ends with the run
        if let s = Focus.spot(skip: []).0, s.app.processIdentifier == runPid, Talk.plain(s.before).hasSuffix(Talk.plain(run)) {
            runEl = s.el; return true
        }
        leftField("focus moved"); return false
    }

    private func leftField(_ why: String) {
        guard !lost else { return }
        lost = true
        log("live typing: left the field (\(why)), the rest waits for the end")
    }

    /// Settled words not yet in the field go in now, unless his hands are busy or he left the field.
    private func liveStep() {
        guard live, !lost, state == .listening, !sending else { return }
        if Keys.shared.editRevision != editRev { lastHand = Date(); handsMoved(); return }   // a click moves the caret too
        guard !handsBusy, !steadyText.isEmpty, let first = runTarget(steadyText), first != run, first != lastWant else { return }
        // a field that could not be read (caret mid-line, a selection) is asked again at most once a second
        if runEl == nil, Date().timeIntervalSince(lastSpotTry) < 1 { return }
        if runEl == nil { lastSpotTry = Date() }
        guard fieldOK(), let want = runTarget(steadyText) else { return }   // again: a run's first words read the caret just now
        let p = LiveType.plan(have: run, want: want, end: false)
        guard !p.lost, !(p.keys.isEmpty && p.append.isEmpty) else { lastWant = want; return }
        press(p.keys)
        if !p.append.isEmpty { Focus.typeText(p.append) }
        run = p.next; fixedChars += p.fixed; lastWant = ""
        if clock.field == nil { clock.field = Date() }
        landedWords = steadyWords
        meter.typed(words: steadyWords, at: now)
    }

    private func press(_ keys: [LiveType.Key]) {
        for k in keys {
            switch k {
            case .left(let n): Fields.left(n)
            case .right(let n): Fields.right(n)
            case .select(let n): Fields.left(n, shift: true)
            case .type(let s): Focus.typeText(s)
            case .erase: Focus.backspace(1)
            }
        }
    }

    enum Landed { case typed, pasted, copied }

    /// The take (or Enter piece) is over: the final reading goes in. What is in the field stays where it already says
    /// the same; what changed is fixed in place when it is small (or only marks), else the field stays as typed and the
    /// final text goes to the clipboard. Returns how it went in (a paste holds his clipboard for a moment).
    @discardableResult
    func liveFinish(_ final: String, tail: String, piece: Bool) -> Landed {
        flushTimer?.invalidate(); flushTimer = nil
        let what = piece ? "piece" : "take"
        defer { meter.reset() }
        func report(_ end: String) {
            log("live field (\(what)): \(landedWords) words in \(meter.steps) steps while talking, \(meter.summary); "
                + "fixed \(fixedChars) chars while talking; end: \(end)")
        }
        if lost {
            History.copy(final); keptNote = true
            report("field left, \(final.count) chars copied")
            return .copied
        }
        // nothing typed in this piece yet and no earlier run: a plain insert (one paste for a long text)
        if run.isEmpty, doneBefore.isEmpty {
            let (s, why) = Focus.spot(skip: [])
            if testing, !(s?.value.contains("⟦drafter-test⟧") ?? false) { report("no test field"); return .copied }
            guard let s else {
                if !testing, Focus.pasteTarget(why) { Focus.paste(final + tail, restore: false); report("pasted \(final.count) chars (\(why))"); return .pasted }
                History.copy(final); keptNote = true; report("no field (\(why)), copied"); return .copied
            }
            let text = LiveType.spaced(final, after: s.before.last) + tail
            if text.count <= 240 {   // a few words as keys: no clipboard, nothing to wait for
                Focus.typeText(text); runEl = s.el; runPid = s.app.processIdentifier; runBefore = text.last
                report("typed \(text.count) chars"); return Talk.control(text) ? .pasted : .typed
            }
            let how = Focus.insert(text, at: s)
            runEl = nil
            report("\(how) \(text.count) chars"); return how == "paste" ? .pasted : .typed
        }
        // the run must still be the end of the field: the same field with no key or click of his since it started, or
        // the field read back ending with it (Chromium's read can differ in spaces and breaks, 13-14 November)
        let s = Focus.spot(skip: []).0
        let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let same = runEl != nil && front == runPid && Keys.shared.editRevision == editRev && Focus.focused().map { CFEqual($0, runEl!) } == true
        let reads = s.map { $0.app.processIdentifier == runPid && Talk.plain($0.before).hasSuffix(Talk.plain(run)) } ?? false
        if runEl == nil, let s, reads { runBefore = s.before.last }   // a new run after his key: its first words go here
        guard same || reads, !testing || (s?.value.contains("⟦drafter-test⟧") ?? false),
              let want = runTarget(final) else {
            History.copy(final); keptNote = true; runEl = nil
            report("field changed under the run, \(final.count) chars copied")
            return .copied
        }
        // far from the final text (the cut-off fault): the whole run is replaced by the final text, the field never
        // keeps a few live words with the rest only on the clipboard
        if case .replace(let t) = LiveType.endWay(have: run, want: want) {
            let old = run, add = t + tail
            run = add; runBefore = add.last
            Focus.replace(old, with: add) { ok in
                if ok { log("live field (\(what)): end: run of \(old.count) chars replaced by the final \(add.count) chars") }
                else {
                    History.copy(final)
                    Pill.shared.copied("The field changed under the words")
                    log("live field (\(what)): end: run could not be replaced, \(final.count) chars copied")
                }
            }
            return .pasted
        }
        let p = LiveType.plan(have: run, want: want, end: true)
        press(p.keys)
        let add = p.append + tail
        if !add.isEmpty { Focus.typeText(add) }
        runBefore = add.last ?? run.last
        if !p.left.isEmpty, p.marksOnly {
            report("+\(p.append.count) chars, fixed \(p.fixed) chars (\(p.keys.count) key steps), \(LiveType.touched(p.left)) chars of marks far back left as typed")
        } else if !p.left.isEmpty {
            History.copy(final); keptNote = true
            report("+\(p.append.count) chars, fixed \(p.fixed) chars (\(p.keys.count) key steps), left \(LiveType.touched(p.left)) chars as typed, final copied")
        } else {
            report("+\(p.append.count) chars, fixed \(p.fixed) chars (\(p.keys.count) key steps)")
        }
        if p.fixed > 0 { log("live typing: \(p.fixed) characters at the end corrected") }   // the old line, for week-on-week counts
        return Talk.control(add) || p.keys.contains(where: { if case .type(let t) = $0 { return Talk.control(t) }; return false }) ? .pasted : .typed
    }

    /// Focus.typeText pastes a text with a line break or another control character.
    private static func control(_ t: String) -> Bool {
        t.unicodeScalars.contains { $0.value < 0x20 || $0.value == 0x7F || $0.value == 0x85 || $0.value == 0x2028 || $0.value == 0x2029 }
    }

    /// Into the field at the caret; with no text field, onto the clipboard.
    func put(_ text: String) {
        let (s, why) = Focus.spot(skip: [])
        if testing, !(s?.value.contains("⟦drafter-test⟧") ?? false) {   // a test never writes outside its marked field
            log("voice test: focus moved to \(Focus.lastApp?.bundleIdentifier ?? "?"), not inserted"); return
        }
        if let s {
            let how = Focus.insert(render(text, app: s.app, spot: s) + " ", at: s)
            log("voice put \(how) \(s.app.bundleIdentifier ?? "?")")
            Entities.dictated(text)                               // names in the take wait for ⌥Tab (app/Entities.swift)
        } else if !testing, Focus.pasteTarget(why) {
            Focus.paste(text + " ", restore: false)
            log("voice put paste (\(why)) \(Focus.lastApp?.bundleIdentifier ?? "?")")
        } else {
            let pb = NSPasteboard.general; pb.clearContents(); pb.setString(text, forType: .string)
            Pill.shared.flash("Copied to clipboard")
        }
    }
}

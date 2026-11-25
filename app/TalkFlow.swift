// Talk, part: the voice note's way to the field (app/VoiceFlowRules.swift): Enter pieces, the insert queue,
// the target watch. Split from app/Voice.swift on 2026-11-16.
import AppKit
import Carbon

extension Talk {
    var insertMode: VoiceMode { Drafter.shared.settings.voiceInsert == "live" ? .live : .enter }
    /// An armed draft he is speaking after: the new words add to it.
    var flowPrefix: String { if case .listening(let p) = flow.state { return p }; return "" }
    /// ↩ came while the note was finishing: the text goes in once it is read.
    var flowInsertPending: Bool { if case .finishing(_, true, _, _, _) = flow.state { return true }; return false }

    private static func stateName(_ s: FlowState) -> String {
        switch s {
        case .idle: return "idle"
        case .listening(let p): return p.isEmpty ? "listening" : "listening after a draft"
        case .finishing(_, let ins, let dr, let held, let piece): return "finishing" + (ins ? ", insert next" : "") + (dr ? ", drop" : "") + (held ? ", ↩ held" : "") + (piece ? " (piece)" : "")
        case .armed(let t): return "armed (\(t.count) chars)"
        case .kept: return "kept"
        case .inserted: return "in the field"
        case .copied: return "on the clipboard"
        case .dropped: return "dropped"
        }
    }

    /// One event into the flow; does what it says. Returns true when a key is swallowed. `tap`: from the event tap,
    /// which must return at once, so the work runs on the next turn of the main queue.
    @discardableResult
    func flowEvent(_ e: FlowEvent, tap: Bool = false) -> Bool {
        guard let (f, swallow, act) = VoiceFlowRules.step(flow, e, mode: insertMode, now: Date().timeIntervalSince1970) else { return false }
        let was = flow.state, queueBefore = flow.queue
        flow = f
        if f.state != was { log("voice flow: \(Talk.stateName(was)) -> \(Talk.stateName(f.state))") }   // lengths only, never text
        // a swallowed key always shows (round three): a Return the flow takes that showed nothing is said in the log
        if swallow, e == .ret, VoiceFlowRules.visible(f) == VoiceFlowRules.visible(VoiceFlow(state: was, at: f.at, said: f.said, queue: f.queue)), f.queue <= queueBefore {
            log("voice flow: ↩ taken without a visible change (\(Talk.stateName(was)))")
        }
        if tap { DispatchQueue.main.async { self.flowDo(act, was: was) } } else { flowDo(act, was: was) }
        if flow.state == .idle { flowTimer?.invalidate(); flowTimer = nil }
        else if flowTimer == nil {
            flowTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in self?.flowEvent(.tick) }
        }
        return swallow
    }

    /// A note that became something else (a question to the notes, an edit): the flow starts over; the note is in
    /// the journal.
    func flowReset(_ why: String) {
        guard flow.state != .idle else { return }
        log("voice flow: \(Talk.stateName(flow.state)) -> idle (\(why))")
        flow = VoiceFlow(); flowTimer?.invalidate(); flowTimer = nil
    }

    private func flowDo(_ act: FlowAct, was: FlowState) {
        switch act {
        case .none: break
        case .stopNote: clock.end = Date(); end()
        case .dropNote: cancel()
        case .arm(let t): Pill.shared.armed(armedView(t)); watchTarget()
        case .insert(let t): insertDraft(t)
        case .keep(let t): Pill.shared.kept(t); log("voice flow: draft kept (\(t.count) chars, in the journal)")
        case .drop: Pill.shared.hide(); log("voice flow: draft dropped (in the journal)")
        case .holdReturn: Pill.shared.held(); log("voice flow: ↩ held while the note finishes")
        case .willInsert: Pill.shared.finishing(insert: true)
        case .closeSegment(let p): closeSegment(p)
        case .hide: break   // the end of a note handles its own strip
        }
    }

    /// Return while he speaks (enter mode): the words so far are one segment. The engine closes it (an END frame; the
    /// audio after it starts the next Take, engine/voice.py, so no new protocol message), the microphone never stops,
    /// and the new segment starts clean in the strip. Its final text goes in once read, in order (insertNext).
    private func closeSegment(_ prefix: String) {
        let segAudio = audio, app = NSWorkspace.shared.frontmostApplication?.localizedName ?? ""
        samples = 0; peak = 0; lastDraft = ""; audio = []
        segmentsSent += 1
        Pill.shared.segment("Inserting → " + (app.isEmpty ? "this app" : app))
        let t0 = Date()
        VoiceEngine.shared.finish { heard, _ in
            let text = VoiceFlowRules.join(prefix, self.finish(heard))
            log("voice segment: \(text.count) chars, read \(Int(Date().timeIntervalSince(t0) * 1000)) ms after ↩")
            if !self.timingSaid { log("voice timing" + self.timingStart()) }
            History.take(text, audio: segAudio, app: app, loud: false, raw: heard)
            self.flowEvent(.segment(text))
            if text.isEmpty { self.segmentGone() }
        }
    }
    /// A segment that read as nothing: the band goes back to the live words; after the note, the strip goes.
    private func segmentGone() {
        if state == .listening { Pill.shared.segmentDone(ok: true, reason: "") }
        else if flow.state == .idle, flow.queue == 0, insertQueue.isEmpty, !insertBusy { Pill.shared.hide() }
    }

    /// Something the engine says is ready again: the strip stops saying "Waking".
    func engineAwake() { if state == .listening { Pill.shared.waking(false) } }

    /// True when the frontmost app has no editable text field (standalone voice capture).
    func standaloneVoiceTarget() -> Bool {
        let st = Drafter.shared.settings, front = NSWorkspace.shared.frontmostApplication
        if front?.processIdentifier == getpid() {
            return !(NSApp.keyWindow?.firstResponder is NSTextView)
        }
        if IsSecureEventInputEnabled() { return true }
        if st.skip.contains(front?.bundleIdentifier ?? "") { return true }
        let (spot, why) = Focus.spot(skip: st.skip)
        if why == "secure input" || why == "password field" || why == "skipped app" { return true }
        return spot == nil && !Focus.pasteTarget(why)
    }

    /// Captures a standalone supertagged voice take (no focused text field): saves the formatted
    /// supertag entry to History, copies the clean body, resets flow, and flashes the strip badge.
    func captureSupertag(_ match: VoiceSupertagMatch, audio takeAudio: [Float], app: String, loud: Bool, raw: String) {
        let formatted = VoiceSupertagRules.formatForJournal(match)
        History.take(formatted, audio: takeAudio, app: app, loud: loud, raw: raw)
        History.copy(match.body)
        flowReset("a voice supertag (\(match.kind.rawValue))")
        Pill.shared.flash(VoiceSupertagRules.pillSummary(match))
        log("voice supertag: \(match.kind.rawValue), \(match.body.count) chars saved to journal + body copied")
    }

    /// While a draft is armed: where Return would put it, said in the strip as the focus moves (at most 4 reads a
    /// second, off the main thread, so the event tap never waits on Accessibility). An app switch reads at once.
    func watchTarget() {
        guard case .armed = flow.state else { return }
        var last = "", busy = false
        func read() {
            guard case .armed = flow.state, !busy else { return }
            busy = true
            let skip = Drafter.shared.settings.skip, front = NSWorkspace.shared.frontmostApplication
            DispatchQueue.global(qos: .userInitiated).async {
                let (spot, why) = Focus.spot(skip: skip)
                let t = VoiceFlowRules.target(spot: spot != nil, why: IsSecureEventInputEnabled() ? "secure input" : why,
                                              canPaste: spot == nil && Focus.pasteTarget(why), ownApp: front?.processIdentifier == getpid())
                let w = VoiceFlowRules.target(t, app: front?.localizedName ?? "")
                DispatchQueue.main.async {
                    busy = false
                    guard case .armed = self.flow.state, w.place + w.button != last else { return }
                    last = w.place + w.button
                    Pill.shared.target(w.place, button: w.button)
                }
            }
        }
        read()
        let nc = NSWorkspace.shared.notificationCenter
        var token: NSObjectProtocol?
        token = nc.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { _ in read() }
        Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] t in
            guard let self, case .armed = self.flow.state else { t.invalidate(); if let token { nc.removeObserver(token) }; return }
            read()
        }
    }

    /// ↩ on an armed draft, or a closed segment's text: in at the caret of the field focused when it is ready, one at a
    /// time and in order (a later segment never lands before an earlier one), the way the Quick panel puts text in.
    /// No field, a password field, a skipped app or secure input: the clipboard, said in words. Drafter never presses
    /// Return here and never sends. The strip says "In the field" as soon as the paste is out (2026-11-14: waiting for
    /// the check held the flow 1-2 s, and his next Return, his send, was taken in that time); the check after it only
    /// reports a failure.
    private func insertDraft(_ text: String) {
        // a segment: the note is still going (or its last part is being read); the receipt then sits in the band
        let segment: Bool = { switch flow.state { case .listening, .finishing: return true; default: return false } }()
        insertQueue.append((text, segment))
        insertNext()
    }

    private func insertNext() {
        guard !insertBusy, !insertQueue.isEmpty else { return }
        let (text, segment) = insertQueue.removeFirst()
        insertBusy = true
        let front = NSWorkspace.shared.frontmostApplication, st = Drafter.shared.settings
        func done(after: Double) {
            DispatchQueue.main.asyncAfter(deadline: .now() + after) { self.insertBusy = false; self.insertNext() }
        }
        func onClipboard(_ notPut: String) {
            guard case .clipboard(let why) = PutCheckRules.outcome(notPutWhy: notPut) else { return }
            History.copy(text)
            if segment { Pill.shared.segmentDone(ok: false, reason: why) } else { flowEvent(.inserted(false)); Pill.shared.copied(why) }
            log("voice flow: \(text.count) chars to the clipboard (\(why))\(segment ? " (segment)" : "")")
        }
        let (spot, why) = Focus.spot(skip: st.skip)
        func early(_ why: String) { onClipboard(why); done(after: 0.05) }
        if IsSecureEventInputEnabled() || why == "secure input" { early("Secure input is on here"); return }
        if why == "password field" { early("A password field: not put in"); return }
        if st.skip.contains(front?.bundleIdentifier ?? "") || why == "skipped app" { early("Drafter is off in this app"); return }
        if front?.processIdentifier == getpid() { early("No text field here"); return }
        if spot == nil, !Focus.pasteTarget(why) { early("No text field here"); return }
        // shaped and styled for the app it goes into, now (a draft armed in one app may go into another)
        let clean = render(text, app: front, spot: spot)
        let lc = levelChoice(bundle: front?.bundleIdentifier ?? "")
        func go(_ out: String) {
            guard let how = Quick.shared.put(QuickItem(kind: .voice, text: out, app: front?.localizedName ?? "", at: Date().timeIntervalSince1970),
                                             out + " ", keep: true, from: front) else {
                early("No text field here"); return
            }
            Entities.dictated(text)                               // names in the note wait for ⌥Tab (app/Entities.swift)
            if segment { Pill.shared.segmentDone(ok: true, reason: "") } else { Pill.shared.inserted() }
            // the next insert waits until a paste put his clipboard back (two pastes at once would paste one text twice)
            let pasted = how.hasPrefix("paste")
            let wait = pasted ? Focus.restoreDelay + 0.1 : 0.12
            done(after: pasted ? Focus.restoreDelay + 0.05 : 0.05)
            // the check, for the log only: the paste went to a focused field, so a failed read-back shows nothing and copies
            // nothing (PutCheckRules.outcome; 17 November 2026, 81% false misses in Claude). The take stays in History.
            let was = spot?.value, web = front.map { Focus.isWeb($0) } ?? false, app = front?.bundleIdentifier ?? ""
            func check(_ second: Bool) {
                let now = Focus.spot(skip: st.skip).0
                let v = PutCheckRules.verdict(text: out, before: was, after: now?.value, web: web)
                if PutCheckRules.needsSecondCheck(v), !second {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { check(true) }
                    return
                }
                log(PutCheckRules.count(&putTally, app: app, v) + " · " + PutCheckRules.detail(text: out, before: was, after: now?.value)
                    + (second ? " · 2nd check" : ""))
                if !PutCheckRules.landed(v) { log(PutCheckRules.unsureLine(app: app)); return }
                log("voice flow: \(text.count) chars in the field (\(how), \(v.rawValue))\(segment ? " (segment)" : "")")
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + wait) { check(false) }
            if !segment { claudeAfter(out, lc, front: front) }
        }
        // Polished (research item 3): the local model rewrites it first; the queue waits, so order holds
        if lc.level == .polished, !live { polish(clean, lc, bundle: front?.bundleIdentifier ?? "") { go($0) } } else { go(clean) }
    }

    /// Claude cleanup (`voiceClaude`, engine/voice_claude.py): Parakeet's text is already in; Claude's version replaces
    /// it in place only while he has not typed since and the field still ends with it (app/VoiceClaudeRules.swift).
    /// ⌫ right after puts Parakeet's text back (Rework.takeBack). Off, offline, slow or a bad answer: nothing shows.
    func claudeAfter(_ out: String, _ c: VoiceChoice, front: NSRunningApplication?) {
        let st = Drafter.shared.settings
        guard VoiceClaudeRules.wants(on: st.voiceClaude, level: c.level.rawValue, live: live, segment: false, queued: insertQueue.count) else { return }
        let put = out + " ", rev = Keys.shared.inputRevision, t0 = Date(), bundle = front?.bundleIdentifier ?? ""
        let screen = Focus.focused().map { Keys.shared.screenText($0) } ?? ""
        let body: [String: Any] = ["text": out, "level": c.level.rawValue, "mode": c.prompt, "app": front?.localizedName ?? "",
                                   "note": WritingNotes.forApp(bundle, global: st.writingNote, perApp: st.appNotes),
                                   "context": screen, "kb": KeyLayout.language, "names": screenNames]
        Engine.shared.post("/voice/claude", body, timeout: VoiceClaudeRules.deadline) { j in
            DispatchQueue.main.async {
                let ms = Int(Date().timeIntervalSince(t0) * 1000), why = j?["why"] as? String ?? (j == nil ? "slow" : "")
                guard let new = VoiceClaudeRules.answer(j?["text"] as? String, put: out) else {
                    log("voice claude: kept Parakeet's text, \(ms) ms\(why.isEmpty ? "" : " (\(why))")"); return
                }
                guard Date().timeIntervalSince(t0) <= VoiceClaudeRules.deadline + 0.2, self.insertQueue.isEmpty,
                      VoiceClaudeRules.canSwap(revisionAt: rev, revisionNow: Keys.shared.inputRevision,
                                               before: Focus.spot(skip: st.skip).0?.before, put: put) else {
                    log("voice claude: kept Parakeet's text, \(ms) ms (he typed or the field changed)"); return
                }
                Focus.replace(put, with: new + " ") { ok in
                    guard ok, let el = Focus.focused() else { log("voice claude: swap refused by the field, \(ms) ms"); return }
                    Rework.last = Rework.Done(el: el, old: put, new: new + " ", revision: Keys.shared.inputRevision, at: Date())
                    let ch = VoiceClaudeRules.changes(old: out, new: new)
                    Pill.shared.show(VoiceClaudeRules.note(ch), seconds: VoiceClaudeRules.markSeconds, lines: 1)
                    log("voice claude: swapped, \(ms) ms, \(out.count) -> \(new.count) chars, \(ch.count) changed runs")
                }
            }
        }
    }
}

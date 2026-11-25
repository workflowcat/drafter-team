// Talk, part: long notes and calls (⇧ Right Option). The recording strip, both sides on disk, the transcript
// and the saved note. Split from app/Voice.swift on 2026-11-16; Talk itself and its stored state live there.
import AppKit

extension Talk {
    func startRecordingBar() {
        recStart = Date(); recTitle = ""; recOutline = []
        recTimer?.invalidate(); outlineTimer?.invalidate()
        recTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self, self.state == .listening, self.long else { return }
            if !self.tape.paused { self.checkSides() }
            Pill.shared.recording(call: self.isCall, seconds: self.recSeconds, title: self.recTitle, outline: self.recOutline,
                                  event: self.spool?.event ?? "", shots: self.shots?.list.count ?? 0, warning: self.tape.paused ? nil : self.warning)
            RecordLive.shared.heard(self.lastDraft)
        }
        // every 75 s the outline is rebuilt from everything said so far (title, points, to-dos)
        outlineTimer = Timer.scheduledTimer(withTimeInterval: 75, repeats: true) { [weak self] _ in
            guard let self, self.state == .listening, self.long, !self.lastDraft.isEmpty else { return }
            Engine.shared.post("/outline", ["text": self.lastDraft, "call": self.isCall], timeout: 60) { j in
                guard let j, self.state == .listening else { return }
                if let t = j["title"] as? String, !t.isEmpty { self.recTitle = t }
                let pts = (j["points"] as? [String] ?? []) + (j["todos"] as? [String] ?? []).map { "→ " + $0 }
                if !pts.isEmpty { self.recOutline = pts }
            }
        }
        if Drafter.shared.settings.recordWindow, let sp = spool {
            let meta = (try? JSONSerialization.jsonObject(with: Data(contentsOf: sp.dir.appendingPathComponent("meta.json")))) as? [String: Any]
            let ev = meta?["event"] as? [String: Any]
            let participants = ((ev?["people"] as? [String]) ?? [])
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty && !CallDoc.me.contains($0.lowercased()) }
            RecordLive.shared.start(dir: sp.dir, call: isCall, participants: participants, eventTitle: sp.event)
        }
        Pill.shared.recording(call: isCall, seconds: 0, title: "", outline: [], event: spool?.event ?? "")
        Menu.shared.refresh()
    }

    /// Seconds recorded so far, without the paused stretches.
    var recSeconds: Int { Int(max(0, tape.now().seconds)) }
    var paused: Bool { tape.paused }

    /// Pause or go on (the recording window). Both sides stop going to disk together, the live words stop, the quiet
    /// timer waits.
    func setPaused(_ on: Bool) {
        guard recording, on != tape.paused else { return }
        tape.paused = on
        screenVideo?.pauseChanged()
        lastVoice = Date()
        log("recording: \(on ? "paused" : "goes on") at \(recSeconds) s")
        Menu.shared.refresh()
    }

    /// Is each side heard? Said in the strip from the first seconds of the recording (CallHealth), logged when it
    /// changes. A microphone that gives only exact zeros is opened again once (a call app can take or mute it).
    private func checkSides() {
        let st = tape.now()
        if long, st.seconds >= 6, st.meSamples > 0, st.mePeak == 0, !micReopened {
            micReopened = true
            log("recording: the microphone gave only zeros for \(Int(st.seconds)) s, opening it again")
            mic?.stop(); MicCapture.shared?.stopNow(); MicCapture.shared = nil
            mic = MicCapture.take(sink, call: isCall)
            if mic == nil { log("recording: the microphone could not open again") }
        } else if long, micReopened, mic == nil, state == .listening {
            // nothing writes the recording while there is no microphone (the other side waits in memory): keep trying
            // each second; when it opens, what waited goes to disk (Argon 6)
            mic = MicCapture.take(sink, call: isCall)
            if mic != nil { log("recording: the microphone opened again") }
        }
        let w = CallHealth.warning(st)
        if w != warning {
            log("recording: " + (w.map { "warning: \($0)" } ?? "both sides heard again")
                + String(format: " (me %.1f s peak %.3f; them %@ %.1f s peak %.3f)", Double(st.meSamples) / 16000, st.mePeak,
                         "\(st.sysState)", Double(st.themSamples) / 16000, st.themPeak))
            warning = w
        }
    }

    func stopRecordingBar() {
        screenVideo?.stop(); screenVideo = nil
        recTimer?.invalidate(); outlineTimer?.invalidate(); recTimer = nil; outlineTimer = nil
        RecordLive.shared.stopped()
        DispatchQueue.main.async { Menu.shared.refresh() }
    }

    /// Screenshots for the recording now on disk (menu "Screenshots in long notes and calls", on by default).
    func startShots() {
        shots?.stop(); shots = nil
        guard Drafter.shared.settings.shots, let sp = spool else { return }
        let s = Shots(recording: sp.dir) { [weak sp] in Double(sp?.frames ?? 0) / 16000 }
        s.start(); shots = s
    }

    func startScreenVideo() {
        screenVideo?.stop(); screenVideo = nil
        guard isCall, Drafter.shared.settings.callScreenVideo, let sp = spool else { return }
        // The same sample clock as screenshots: pauses and mic stalls never add wall time to video.
        let video = ScreenVideoRecorder(recording: sp.dir) { [weak sp] in Double(sp?.frames ?? 0) / 16000 }
        screenVideo = video; video.start()
    }

    /// One side read again; a reading that came back empty for a side with minutes of sound (the voice engine was
    /// stopped under it) is tried once more when the engine is back.
    private func readSide(_ url: URL, names: [String], lang: String?, retry: Bool = true, _ done: @escaping ([[String: Any]]) -> Void) {
        let go = {
            VoiceEngine.shared.readFile(url.path, names: names, lang: lang) { segs in
                let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
                if segs.isEmpty, retry, size > 32000 * 20 {
                    log("recording: no text back for \(url.lastPathComponent), trying again")
                    DispatchQueue.main.asyncAfter(deadline: .now() + 4) { self.readSide(url, names: names, lang: lang, retry: false, done) }
                } else { done(segs) }
            }
        }
        if VoiceEngine.shared.running { go(); return }
        VoiceEngine.shared.preload()
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { go() }
    }

    /// A finished long note or call (or one recovered after a crash): each side read again with times (Parakeet, else
    /// Whisper), merged as "Я" / "Вони" for calls with his mic's echo of them taken out, then a note. Screenshots
    /// taken meanwhile go into brief.md beside the transcript, and the line to hand it to an agent goes on the
    /// clipboard. The live text is the fallback when the reading gives nothing.
    func transcribe(dir: URL, me: URL, them: URL?, call: Bool, live: String, done: ((Bool) -> Void)? = nil) {
        let size = (try? FileManager.default.attributesOfItem(atPath: me.path)[.size] as? Int) ?? 0
        let mins = Double(size) / 32000 / 60
        let meta = (try? JSONSerialization.jsonObject(with: Data(contentsOf: dir.appendingPathComponent("meta.json")))) as? [String: Any] ?? [:]
        let event = meta["event"] as? [String: Any]
        Pill.shared.show(String(format: call ? "Call %.0f min: transcribing both sides…" : "Note %.0f min: transcribing…", mins), seconds: 900)
        log(String(format: "%@ ended: %.1f min, other side %@, in %@", call ? "call" : "long note", mins, them == nil ? "not recorded" : "recorded", dir.lastPathComponent))
        // the people of the meeting and the speakers he named, with their nicknames and name forms (the people book)
        let named = Array(((meta["speakers"] as? [String: String]) ?? [:]).values)
        let names = screenNames + PeopleBook.load(WindowModel.bookURL).expected(((event?["people"] as? [String]) ?? []) + named)
        let lang = Transcript.language(live)
        // memory budget: with little free memory or a long recording, the text model steps aside while both sides are
        // read (the voice engine may take 3.4 GB then); typing keeps the word finisher meanwhile
        let free = Budget.free()
        let rest = (0..<Budget.low).contains(free) || mins >= 20
        if rest { Budget.rest(secs: max(120, mins * 15), why: "\(free)% free, a \(Int(mins)) min \(call ? "call" : "note") is read") }
        readSide(me, names: names, lang: lang) { a in
            let finish: ([[String: Any]]) -> Void = { b in
                if rest { Budget.wake() }
                let mine = call ? Transcript.echoless(a, b) : a
                if mine.count < a.count { log("call: \(a.count - mine.count) of my lines were the other side's echo") }
                // the other side was recorded but its reading gave nothing (17 November 2026: the voice engine passed its
                // memory cap twice): said plainly; speakers.py then places the mic's lines by voice
                if call, them != nil, b.isEmpty {   // them.wav is only kept when it had sound (Spool.wavs)
                    log("call: the other side's sound was recorded but its reading gave no lines; mic lines will be placed by voice")
                }
                // a transcribed file has one speaker label he can name on the page (no diarisation yet)
                let solo = meta["file"] != nil ? "Speaker 1" : ""
                let rows = mine.map { (call ? "Я" : solo, "me", $0) } + b.map { ("Вони", "them", $0) }
                let ordered = rows.sorted { ($0.2["start"] as? Double ?? 0) < ($1.2["start"] as? Double ?? 0) }
                // the lines with their times and track (me: his mic, them: the Mac's sound), for the Recordings view
                // (play from a line, screenshots in place) and for speakers.py
                let timed: [[String: Any]] = ordered.map { r in
                    var row: [String: Any] = ["who": r.0, "start": r.2["start"] as? Double ?? 0, "text": (r.2["text"] as? String) ?? ""]
                    if call { row["track"] = r.1 }
                    if let e = r.2["end"] as? Double { row["end"] = e }
                    return row
                }
                if !timed.isEmpty, let d = try? JSONSerialization.data(withJSONObject: timed) { try? d.write(to: dir.appendingPathComponent("lines.json")) }
                let next = { (labelled: [Brief.Row]) in
                    var transcript = labelled.map { ($0.who.isEmpty ? "" : "\($0.who): ") + $0.text }.joined(separator: call ? "\n" : " ")
                    if transcript.trimmingCharacters(in: .whitespaces).isEmpty { transcript = live }
                    try? transcript.write(to: dir.appendingPathComponent("transcript.txt"), atomically: true, encoding: .utf8)
                    Spool.markRead(dir)
                    // talk and screen together for an agent: brief.md, and the line to paste on the clipboard
                    let shots = Shot.load(dir)
                    var handoff: String?
                    if !shots.isEmpty {
                        let line = Brief.write(dir: dir, rows: labelled.isEmpty && !live.isEmpty ? [Brief.Row(who: "", start: 0, text: live)] : labelled,
                                               shots: shots, meta: meta, minutes: mins)
                        if shots.count >= 2 { handoff = line; History.copy(line) }   // one shot = a screen that never changed
                        log("brief: \(shots.count) screenshots, \(labelled.count) lines")
                    }
                    guard !transcript.isEmpty else { Pill.shared.flash(call ? "No speech found in the call" : "No speech found"); done?(false); return }
                    if let handoff {
                        Pill.shared.show("Walkthrough with \(shots.count) screenshots copied · ⌘V into Claude or Codex", seconds: 6)
                        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { self.saveNote(transcript, audio: dir.path, call: call, event: event, handoff: handoff, done: done) }
                    } else {
                        self.saveNote(transcript, audio: dir.path, call: call, event: event, done: done)
                    }
                }
                let first = ordered.map { Brief.Row(who: $0.0, start: $0.2["start"] as? Double ?? 0, text: ($0.2["text"] as? String) ?? "") }
                // a call: who said each line, placed by voice (engine/speakers.py); its lines.json then holds the labels
                if call, !timed.isEmpty {
                    Pill.shared.show("Call: placing who said what…", seconds: 120)
                    Speakers.run(dir) { ok in next(ok ? Speakers.rows(dir) : first) }
                } else { next(first) }
            }
            if let them { self.readSide(them, names: names, lang: lang, finish) } else { finish([]) }
        }
    }

    private func saveNote(_ text: String, audio: String, call: Bool = false, event: [String: Any]? = nil, handoff: String? = nil, done: ((Bool) -> Void)? = nil) {
        Pill.shared.show(call ? "Call: preparing a note…" : "Note: processing…", seconds: 90)
        var body: [String: Any] = ["text": text, "audio": audio, "call": call]
        if let event { body["event"] = event }
        Engine.shared.post("/note", body, timeout: 120) { j in
            defer { done?(true) }   // the transcript is in either way; the note is extra
            guard let j, let title = j["title"] as? String else { Pill.shared.flash("Note was not saved"); History.copy(text); return }
            let links = (j["links"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }
            let fu = (j["followups"] as? [String]) ?? []
            var lines = ["✓ \(title)"]
            if !links.isEmpty { lines.append("About: " + links.joined(separator: ", ")) }
            if !fu.isEmpty { lines.append("Follow-ups: " + fu.map { "• " + $0 }.joined(separator: " ")) }
            lines.append("Saved: " + ((j["saved"] as? [String]) ?? []).joined(separator: ", "))
            if handoff != nil { lines.append("Walkthrough for the agent: on the clipboard (also in Drafter › Recordings)") }
            Pill.shared.show(lines.joined(separator: "\n"), seconds: 6)
            log("long note: \(text.count) chars, \(links.count) links, \(fu.count) follow-ups")
            // follow-ups become a chip: Tab adds them to Aleph (each as a follow-up for the next working morning)
            if !fu.isEmpty {
                DispatchQueue.main.asyncAfter(deadline: .now() + 6) {
                    Offer.show(["Add \(fu.count) follow-up\(fu.count == 1 ? "" : "s") to Aleph?"] + fu.prefix(2).map { "• " + $0 }, kind: "Follow-ups", accept: "Add", seconds: 20) {
                        Engine.shared.post("/followups", ["items": fu], timeout: 30) { j in
                            Pill.shared.flash("Added to Aleph: \(j?["added"] as? Int ?? 0)")
                        }
                    }
                }
            }
        }
    }
}

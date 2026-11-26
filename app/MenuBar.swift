// The menu-bar item: its menu, Words to learn, and the secure-input lock.
import AppKit
import Carbon

final class Menu: NSObject, NSMenuDelegate {
    static let shared = Menu()
    var item: NSStatusItem!
    let menu = NSMenu()

    func setup() {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        menu.delegate = self
        item.menu = menu
        // a dropped audio or video file is transcribed (FileTranscribe); clicks still open the menu
        if let b = item.button { b.addSubview(StatusDrop(frame: b.bounds)) }
        refresh()
    }

    func refresh() {
        let t = Drafter.shared
        // a pen on a line = Drafter (2026-10-21, the user: the cursor icon was confusing); slashed when paused
        let name = Talk.shared.recording ? "record.circle" : SecureInput.holder != nil ? "lock" : t.active ? (Engine.shared.ready ? "pencil.line" : "hourglass") : "pencil.slash"
        item?.button?.image = NSImage(systemSymbolName: name, accessibilityDescription: "Drafter")
        item?.button?.toolTip = SecureInput.holder.map { "\($0) holds secure input: typed keys are hidden from Drafter (Enter, Tab, suggestions). Click out of its password field or reload it." }
    }

    func menuNeedsUpdate(_ m: NSMenu) {
        m.removeAllItems()
        let t = Drafter.shared
        let state = t.settings.paused ? "Paused" : t.lowBattery ? Engine.shared.info + " · battery below 20%: lighter" : Engine.shared.info
        m.addItem(withTitle: state, action: nil, keyEquivalent: "").isEnabled = false
        let liveLine = InspectorRules.menuLine(Keys.shared.liveSnapshot())
        if !liveLine.isEmpty { m.addItem(withTitle: liveLine, action: nil, keyEquivalent: "").isEnabled = false }
        // first thing in the menu (17 November 2026, app/MeetingNotes.swift): start meeting notes, with the event on now
        // or in the next 10 min; while a call or long note records, stop it and how long it ran
        m.addItem(.separator())
        let meet = m.addItem(withTitle: MeetingNotes.menuLabel, action: #selector(meetingNotes), keyEquivalent: "")
        meet.target = self
        meet.toolTip = Talk.shared.recording ? "Same as ⇧ Right Option. The transcript and the note follow."
            : "A call app on the microphone: the call, both sides. Otherwise in person, your microphone only. Also ;meet in any field."
        if !Focus.trusted() { m.addItem(withTitle: "Allow Accessibility…", action: #selector(askTrust), keyEquivalent: "").target = self }
        m.addItem(.separator())
        m.addItem(withTitle: "Open Drafter (recordings, clipboard, settings)", action: #selector(openCommand), keyEquivalent: "").target = self
        m.addItem(withTitle: "Links & Files…", action: #selector(openLinks), keyEquivalent: "").target = self
        m.addItem(withTitle: "What Drafter sees…", action: #selector(openScreen), keyEquivalent: "").target = self
        m.addItem(.separator())
        m.addItem(withTitle: t.settings.paused ? "Resume" : "Pause", action: #selector(togglePause), keyEquivalent: "p").target = self
        m.addItem(withTitle: "Snippets, quick starts, people… (Right ⌘ twice)", action: #selector(openCommands), keyEquivalent: "").target = self
        m.addItem(withTitle: "Add a word…", action: #selector(addWord), keyEquivalent: "w").target = self
        m.addItem(Learn.menu()); Learn.refresh()   // fresh for the next open
        m.addItem(History.menu(title: "Recent takes", file: History.takesFile, n: 12))
        m.addItem(History.menu(title: "Clipboard history", file: History.clipFile, n: 20))
        m.addItem(withTitle: "Open notes and call recordings", action: #selector(openNotes), keyEquivalent: "").target = self
        let tf = m.addItem(withTitle: FileTranscribe.busy ? "Transcribing a file… (stop)" : "Transcribe file…", action: #selector(transcribeFile), keyEquivalent: "")
        tf.target = self; tf.toolTip = "Audio or video (m4a, mp3, wav, mp4, mov): read like a call, with a summary. Or drop it on this icon."
        let v = m.addItem(withTitle: "Voice on Right Option",
                          action: #selector(toggleVoice), keyEquivalent: "")
        v.target = self; v.state = t.settings.voice ? .on : .off
        if let app = Focus.lastApp, let id = app.bundleIdentifier {
            let skipped = t.settings.skip.contains(id)
            let i = m.addItem(withTitle: (skipped ? "Use in " : "Skip ") + (app.localizedName ?? id), action: #selector(toggleSkip), keyEquivalent: "")
            i.target = self; i.representedObject = id
        }
        let vl = m.addItem(withTitle: "Type into the field while I talk (else ↩ inserts the note)", action: #selector(toggleLive), keyEquivalent: "")
        vl.target = self; vl.state = t.settings.voiceInsert == "live" ? .on : .off
        let km = m.addItem(withTitle: "Keep the microphone ready: first word never lost (orange dot stays on)", action: #selector(toggleKeepMic), keyEquivalent: "")
        km.target = self; km.state = t.settings.keepMic ? .on : .off
        let l = m.addItem(withTitle: "Learn from what I send (on this Mac only)", action: #selector(toggleLearn), keyEquivalent: "")
        l.target = self; l.state = t.settings.learn ? .on : .off
        let sc = m.addItem(withTitle: "Read the messages on screen (this Mac only)" + (t.settings.screenContext && !Screen.allowed ? " (needs Screen Recording)" : ""),
                           action: #selector(toggleScreen), keyEquivalent: "")
        sc.target = self; sc.state = t.settings.screenContext ? .on : .off
        let sh = m.addItem(withTitle: "Screenshots in long notes and calls (for the agent brief, on this Mac only)", action: #selector(toggleShots), keyEquivalent: "")
        sh.target = self; sh.state = t.settings.shots ? .on : .off
        m.addItem(withTitle: "Open dictionary", action: #selector(openDictionary), keyEquivalent: "").target = self
        m.addItem(.separator())
        m.addItem(withTitle: "Tab takes the next grey word or runs the chip", action: nil, keyEquivalent: "").isEnabled = false
        m.addItem(withTitle: "Quit Drafter", action: #selector(quit), keyEquivalent: "q").target = self
    }

    @objc func stopRecording() { Talk.shared.stopRecording("the menu bar") }
    @objc func meetingNotes() { MeetingNotes.toggle(from: "the menu bar") }
    @objc func askTrust() { Focus.trusted(prompt: true) }
    @objc func togglePause() { Drafter.shared.change { $0.paused.toggle() }; Drafter.shared.apply() }
    @objc func toggleSkip(_ s: NSMenuItem) {
        guard let id = s.representedObject as? String else { return }
        Drafter.shared.change { if let i = $0.skip.firstIndex(of: id) { $0.skip.remove(at: i) } else { $0.skip.append(id) } }
    }
    @objc func toggleVoice() {
        let st = Drafter.shared.change { $0.voice.toggle() }
        if st.voice { VoiceEngine.shared.preload() } else { Talk.shared.cancel(); VoiceEngine.shared.stop() }
        log("voice on Right Option: \(st.voice)")
    }
    @objc func toggleLive() { Drafter.shared.change { $0.voiceInsert = $0.voiceInsert == "live" ? "enter" : "live" } }
    @objc func toggleKeepMic() {
        let st = Drafter.shared.change { $0.keepMic.toggle() }
        MicCapture.keepReady = st.keepMic && st.voice; MicCapture.prepare()
    }
    @objc func toggleShots() {
        let st = Drafter.shared.change { $0.shots.toggle() }
        if st.shots, !CGPreflightScreenCaptureAccess() { _ = CGRequestScreenCaptureAccess() }
    }
    @objc func toggleLearn() { Drafter.shared.change { $0.learn.toggle() } }
    @objc func toggleScreen() {
        let st = Drafter.shared.change { $0.screenContext.toggle() }
        if st.screenContext, !Screen.allowed { _ = CGRequestScreenCaptureAccess() }
    }
    @objc func openDictionary() { AppWindow.shared.show(); AppWindow.shared.model.page = .dictionary }
    @objc func openLinks() { DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { AppWindow.shared.show(); AppWindow.shared.model.page = .links } }
    @objc func openScreen() { DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { AppWindow.shared.show(); AppWindow.shared.model.page = .screen } }
    @objc func openCommands() { DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { CommandCard.shared.openOwn(from: "the menu") } }
    @objc func openCommand() { DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { AppWindow.shared.show() } }
    @objc func transcribeFile() { if FileTranscribe.busy { FileTranscribe.cancel() } else { FileTranscribe.pick() } }

    @objc func openNotes() {
        for d in ["notes", "calls"] { try? FileManager.default.createDirectory(at: Home.data.appendingPathComponent(d), withIntermediateDirectories: true) }
        NSWorkspace.shared.open(Home.data.appendingPathComponent("notes")); NSWorkspace.shared.open(Home.data.appendingPathComponent("calls"))
    }
    /// Quit from the menu. A long note or call that is recording asks first (2026-10-30: the "Ulis+Bp" call stopped at
    /// 29 min with a clean exit and no line in the log; a clean exit is not restarted, so Drafter stayed off for 55 min).
    @objc func quit() {
        if Talk.shared.recording {
            let a = NSAlert()
            a.messageText = Talk.shared.isCall ? "A call is recording" : "A long note is recording"
            a.informativeText = "Stop recording keeps Drafter running and makes the transcript and the note. Quit leaves the audio to be finished on the next start."
            a.addButton(withTitle: "Stop recording"); a.addButton(withTitle: "Keep recording"); a.addButton(withTitle: "Quit anyway")
            NSApp.activate(ignoringOtherApps: true)
            switch a.runModal() {
            case .alertFirstButtonReturn: Talk.shared.stopRecording("the quit question"); return
            case .alertSecondButtonReturn: log("quit: cancelled, a recording is running"); return
            default: break
            }
        }
        log("quit: from the menu")
        Engine.shared.stop(); NSApp.terminate(nil)
    }

    @objc func addWord() {
        let seed = Focus.selectedText() ?? ""
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = "Add a word"
        a.informativeText = "A name, term or phrase, written the way it should be spelled. Typing and voice both use it."
        let f = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24)); f.stringValue = seed
        a.accessoryView = f; a.addButton(withTitle: "Add"); a.addButton(withTitle: "Cancel")
        a.window.initialFirstResponder = f
        guard a.runModal() == .alertFirstButtonReturn else { return }
        let w = f.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !w.isEmpty else { return }
        Engine.shared.post("/words", ["text": w, "kind": w.contains(" ") ? "phrase" : "term"], timeout: 30) { j in
            Ghost.shared.flash(j?["ok"] as? Bool == true ? "Added: \(w)" : "Could not add \(w)")
        }
    }
}


/// "Words to learn": words the user changed after dictating (engine/edits.py). Learn puts the pair into the shared
/// dictionary, so the same mishearing is written right next time; Ignore drops it.
final class Learn: NSObject {
    static let shared = Learn()
    static var waiting: [[String: Any]] = []

    static func refresh() {
        Engine.shared.get("/edits") { j in waiting = (j?["edits"] as? [[String: Any]]) ?? [] }
    }

    static func menu() -> NSMenuItem {
        let item = NSMenuItem(title: "Words to learn" + (waiting.isEmpty ? "" : " (\(waiting.count))"), action: nil, keyEquivalent: "")
        let sub = NSMenu()
        if waiting.isEmpty { sub.addItem(withTitle: "Nothing yet: words you change after dictating show up here", action: nil, keyEquivalent: "").isEnabled = false }
        for e in waiting.sorted(by: { ($0["count"] as? Int ?? 0) > ($1["count"] as? Int ?? 0) }).prefix(15) {
            let h = e["heard"] as? String ?? "", f = e["fixed"] as? String ?? "", n = e["count"] as? Int ?? 1
            let row = NSMenuItem(title: "«\(h)» → «\(f)»" + (n > 1 ? "  ×\(n)" : ""), action: nil, keyEquivalent: "")
            let pick = NSMenu()
            for (title, accept) in [("Learn", true), ("Ignore", false)] {
                let i = NSMenuItem(title: title, action: #selector(Learn.choose(_:)), keyEquivalent: "")
                i.target = Learn.shared; i.representedObject = ["heard": h, "fixed": f, "accept": accept]
                pick.addItem(i)
            }
            row.submenu = pick
            sub.addItem(row)
        }
        item.submenu = sub
        return item
    }

    @objc func choose(_ s: NSMenuItem) {
        guard let d = s.representedObject as? [String: Any] else { return }
        Engine.shared.post("/edits", d) { _ in Learn.refresh() }
        if d["accept"] as? Bool == true { Pill.shared.flash("Learned: \(d["fixed"] as? String ?? "")") }
    }
}


/// Secure input (2026-10-24: Dia held it for hours and Enter during dictation, Tab and suggestions all stopped without a
/// word): while any app has it on, macOS hides typed keys from Drafter's event tap; only modifier keys (Right Option)
/// still arrive. Drafter says who holds it: a lock in the menu bar, and one line in the strip when it has lasted 20 s
/// or when a take starts.
enum SecureInput {
    static var holder: String?
    private static var since: Date?, told = false

    static func check() {
        let on = IsSecureEventInputEnabled()
        if !on {
            if holder != nil { log("secure input: off"); holder = nil; since = nil; told = false; Menu.shared.refresh() }
            return
        }
        if since == nil { since = Date() }
        if holder == nil {
            holder = name() ?? "an app"
            log("secure input: on, held by \(holder!)")
            Menu.shared.refresh()
        }
        if !told, Date().timeIntervalSince(since!) > 20 { told = true; tell() }
    }

    static func tell() {
        guard let h = holder else { return }
        Pill.shared.show("\(h) is holding secure input: Enter, ⇥, and suggestions cannot see keystrokes. Click outside its password field or reload the page.", seconds: 8, lines: 3)
    }

    /// The process macOS names as the holder (ioreg's kCGSSessionSecureInputPID).
    static func name() -> String? {
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/sbin/ioreg"); p.arguments = ["-l", "-w", "0", "-d", "4", "-c", "IOConsoleUsers"]
        let out = Pipe(); p.standardOutput = out; p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        let d = out.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
        guard let s = String(data: d, encoding: .utf8),
              let r = s.range(of: #""kCGSSessionSecureInputPID"=(\d+)"#, options: .regularExpression),
              let pid = Int32(s[r].split(separator: "=").last ?? "") else { return nil }
        return NSRunningApplication(processIdentifier: pid)?.localizedName
    }
}

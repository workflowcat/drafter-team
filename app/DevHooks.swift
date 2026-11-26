// Test and bench entry points: command-line test modes, notification hooks (bench/*.sh), the test typer and the
// Accessibility probe. Nothing here runs in normal use unless a hook is posted.
import AppKit
import SwiftUI
import Carbon
import ApplicationServices
import ScreenCaptureKit

enum DevHooks {
    /// A test mode named on the command line runs instead of the app; true when one ran.
    static func runCommandLine() -> Bool {
        if let i = CommandLine.arguments.firstIndex(of: "--ui-preview"), i + 1 < CommandLine.arguments.count {
            let app = NSApplication.shared; app.setActivationPolicy(.accessory)
            do { try UIShots.run(CommandLine.arguments[i + 1], dark: CommandLine.arguments.contains("--dark")) }
            catch { fputs("Preview failed: \(error)\n", stderr); exit(1) }
            return true
        }
        if let i = CommandLine.arguments.firstIndex(of: "--record-bench"), i + 1 < CommandLine.arguments.count {
            RecordBench.run(seconds: Double(CommandLine.arguments[i + 1]) ?? 20)   // app/RecordBench.swift
            return true
        }
        if CommandLine.arguments.contains("--stream-bench") {   // app/StreamBench.swift: numbers only
            StreamBench.run(sample: CommandLine.arguments.contains("--sample"))
            return true
        }
        if let i = CommandLine.arguments.firstIndex(of: "--deck-bench"), i + 1 < CommandLine.arguments.count {
            DeckBench.run(count: Int(CommandLine.arguments[i + 1]) ?? 20, cold: CommandLine.arguments.contains("--cold"))   // app/DeckBench.swift
            return true
        }
        if let i = CommandLine.arguments.firstIndex(of: "--commands-preview"), i + 1 < CommandLine.arguments.count {
            NSApplication.shared.setActivationPolicy(.accessory)
            do { try CommandCard.previewShot(CommandLine.arguments[i + 1], dark: CommandLine.arguments.contains("--dark"), uk: CommandLine.arguments.contains("--uk")) }
            catch { fputs("Preview failed: \(error)\n", stderr); exit(1) }
            return true
        }
        if let i = CommandLine.arguments.firstIndex(of: "--mention-preview"), i + 1 < CommandLine.arguments.count {
            NSApplication.shared.setActivationPolicy(.accessory)
            do { try MentionCard.previewShot(CommandLine.arguments[i + 1], dark: CommandLine.arguments.contains("--dark")) }
            catch { fputs("Preview failed: \(error)\n", stderr); exit(1) }
            return true
        }
        if CommandLine.arguments.contains("--probe") { Focus.probeLoop(); return true }
        if CommandLine.arguments.contains("--rules-test") { Rules.selfTest(); return true }
        if CommandLine.arguments.contains("--autocorrect-test") { Autocorrect.selfTest(); exit(0) }
        if CommandLine.arguments.contains("--emoji-test") { Emoji.selfTest(); exit(0) }
        if CommandLine.arguments.contains("--snippet-test") { Snippets.selfTest(); exit(0) }
        if let i = CommandLine.arguments.firstIndex(of: "--ghost-preview"), i + 1 < CommandLine.arguments.count {
            // test: draw the suggestion panels at a fixed spot (no field, nothing typed) and save a picture of each
            let out = CommandLine.arguments[i + 1], dark = CommandLine.arguments.contains("--dark")
            let app = NSApplication.shared; app.setActivationPolicy(.accessory)
            app.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            let caret = CGRect(x: 420, y: 300, width: 1, height: 20)
            let shots: [(String, () -> Void)] = [
                ("ghost", { Ghost.shared.unsure = 7; Ghost.shared.show("the slides tonight", action: nil, at: caret) }),
                ("chip", { Ghost.shared.show("", action: ["id": "snippet", "chip": "⇥ alex@example.com"], at: caret) }),
                ("action", { Ghost.shared.show("", action: ["id": "reminder", "chip": "Нагадування · завтра 10:00 · надіслати акт Мілі"], at: caret) }),
                ("card", { Ghost.shared.showDraft([["text": "Thanks, Mila! I'll send the act tonight and we can go over the numbers on Thursday at 11 if that works for you.", "label": "thanks + act tonight"],
                                                   ["text": "b", "label": "b"], ["text": "c", "label": "c"]], field: CGRect(x: 300, y: 340, width: 520, height: 40), caret: caret) }),
            ]
            var k = 0
            func next() {
                guard k < shots.count else { exit(0) }
                let (name, draw) = shots[k]; k += 1
                draw()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: true) { c, _ in
                        guard let d = c?.displays.first else { exit(1) }
                        let cfg = SCStreamConfiguration(); cfg.sourceRect = CGRect(x: 260, y: 220, width: 620, height: 170)
                        cfg.width = 1240; cfg.height = 340
                        SCScreenshotManager.captureImage(contentFilter: SCContentFilter(display: d, excludingWindows: []), configuration: cfg) { img, _ in
                            if let img, let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: out + "-\(name).png") as CFURL, "public.png" as CFString, 1, nil) {
                                CGImageDestinationAddImage(dest, img, nil); CGImageDestinationFinalize(dest)
                            }
                            DispatchQueue.main.async { Ghost.shared.hide(); next() }
                        }
                    }
                }
            }
            DispatchQueue.main.async { next() }
            app.run()
            return true
        }
        if let i = CommandLine.arguments.firstIndex(of: "--shot"), i + 1 < CommandLine.arguments.count {
            // test: picture of the top centre of the main screen into the given file (the voice strip)
            let out = CommandLine.arguments[i + 1]
            let done = DispatchSemaphore(value: 0)
            SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: true) { c, _ in
                guard let d = c?.displays.first else { done.signal(); return }
                let cfg = SCStreamConfiguration()
                cfg.sourceRect = CGRect(x: CGFloat(d.width) / 2 - 360, y: 0, width: 720, height: 190)
                cfg.width = 1440; cfg.height = 380
                SCScreenshotManager.captureImage(contentFilter: SCContentFilter(display: d, excludingWindows: []), configuration: cfg) { img, _ in
                    if let img, let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: out) as CFURL, "public.png" as CFString, 1, nil) {
                        CGImageDestinationAddImage(dest, img, nil); CGImageDestinationFinalize(dest)
                    }
                    done.signal()
                }
            }
            _ = done.wait(timeout: .now() + 5)
            return true
        }
        if let i = CommandLine.arguments.firstIndex(of: "--ocr-app"), i + 1 < CommandLine.arguments.count,
           let app = NSRunningApplication.runningApplications(withBundleIdentifier: CommandLine.arguments[i + 1]).first {
            // test: read the lower part of that app's window from behind, as if the caret sat at its bottom
            setbuf(stdout, nil)
            let a = AXUIElementCreateApplication(app.processIdentifier)
            var w: CFTypeRef?; AXUIElementCopyAttributeValue(a, kAXFocusedWindowAttribute as CFString, &w)
            var p = CGPoint.zero, z = CGSize.zero
            if let w {
                var v: CFTypeRef?
                if AXUIElementCopyAttributeValue(w as! AXUIElement, kAXPositionAttribute as CFString, &v) == .success { AXValueGetValue(v as! AXValue, .cgPoint, &p) }
                if AXUIElementCopyAttributeValue(w as! AXUIElement, kAXSizeAttribute as CFString, &v) == .success { AXValueGetValue(v as! AXValue, .cgSize, &z) }
            }
            let caret = CGRect(x: p.x + 40, y: p.y + z.height - 30, width: 1, height: 16)
            let t = Date(); let txt = Screen.textAbove(pid: app.processIdentifier, caret: caret)
            print(String(format: "ocr %.0f ms, %d chars:", Date().timeIntervalSince(t) * 1000, txt.count), txt.suffix(400).debugDescription)
            return true
        }
        if let i = CommandLine.arguments.firstIndex(of: "--insert-check") {   // scripts/insert_check.sh, app/InsertCheck.swift
            InsertCheck.run(Array(CommandLine.arguments.dropFirst(i + 1))); return true
        }
        if let i = CommandLine.arguments.firstIndex(of: "--type"), i + 2 < CommandLine.arguments.count {
            TestTyper.run(CommandLine.arguments[i + 2], into: CommandLine.arguments[i + 1]); return true
        }
        return false
    }

    /// Distributed notifications named <bundle id>.<hook>, posted by benches and tests.
    static func install() {
        // test hook: show the voice strip for 4 s with a moving level and some words (bench/strip_shot.sh)
        for name in [Home.bundleID + ".striptest", Home.bundleID + ".rectest"] {
        DistributedNotificationCenter.default().addObserver(forName: Notification.Name(name), object: nil, queue: .main) { note in
            guard Talk.shared.state == .idle else { return }
            if note.name.rawValue.hasSuffix("rectest") {   // the recording bar of a long note / call
                var k = 0
                Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { t in
                    k += 1
                    Pill.shared.recording(call: true, seconds: 754 + k, title: "Звіти та демо",
                                          outline: ["Модуль складу в Northwind завершено, звіти ще не готові", "Міла перевірить податкову частину", "→ Сава: зробити звіти до пʼятниці"])
                    if k >= 5 { t.invalidate(); Pill.shared.hide() }
                }
                return
            }
            Pill.shared.listening()
            var i = 0
            Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { t in
                i += 1
                Pill.shared.level(Float(abs(sin(Double(i) / 3))) * 0.2)
                if i == 20 { Pill.shared.draft("хелоу як ти там можем голосом на тижні бо я хотів обговорити нашу тєму") }
                if i >= 80 { t.invalidate(); Pill.shared.hide() }
            }
        }
        }
        // the live Settings page, drawn by the running app from its own settings into a picture (never the screen, so
        // nothing else on it is caught): object "settings" or "settings-advanced"; written to the temp folder, path logged
        DistributedNotificationCenter.default().addObserver(forName: Notification.Name(Home.bundleID + ".windowshot"), object: nil, queue: .main) { n in
            let obj = n.object as? String ?? ""
            let name = ["settings-advanced", "dictionary"].contains(obj) ? obj : "settings"
            let m = AppWindow.shared.model
            m.loadStats()
            let dark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            // the Dictionary page: the live page at the window's size, numbers and layout only for the check
            DictStore.shared.redact = name == "dictionary"
            let page: AnyView = name == "dictionary" ? AnyView(DictionaryView().padding(.horizontal, 20)) : AnyView(SettingsView(advanced: name == "settings-advanced"))
            let size = name == "dictionary" ? NSSize(width: 1040, height: 760) : NSSize(width: 1152, height: 3600)
            let v = NSHostingView(rootView: page.environmentObject(m).foregroundStyle(UIInk.ink)
                .tint(UIInk.blue).background(UIInk.paper).environment(\.colorScheme, dark ? .dark : .light))
            let w = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
            w.contentView = v; v.frame = NSRect(origin: .zero, size: size)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                let path = NSTemporaryDirectory() + "drafter-windowshot-\(name).png"
                do { try UIShots.save(v, path); log("windowshot \(path)") } catch { log("windowshot failed") }
                w.contentView = nil; DictStore.shared.redact = false
            }
        }
        DistributedNotificationCenter.default().addObserver(forName: Notification.Name(Home.bundleID + ".ghostshot"), object: nil, queue: .main) { _ in Ghost.shared.shot() }
        DistributedNotificationCenter.default().addObserver(forName: Notification.Name(Home.bundleID + ".reworkshot"), object: nil, queue: .main) { _ in Rework.shared.shot() }
        // the call offer strip without a call (object: a call app's bundle id); Tab only logs
        DistributedNotificationCenter.default().addObserver(forName: Notification.Name(Home.bundleID + ".offertest"), object: nil, queue: .main) { n in
            CallWatch.offer((n.object as? String) ?? "com.tinyspeck.slackmacgap", test: true)
        }
        // the meeting-notes offer with a made-up event starting in 1 min; ↵ or its button only log, nothing records
        DistributedNotificationCenter.default().addObserver(forName: Notification.Name(Home.bundleID + ".meetoffertest"), object: nil, queue: .main) { _ in
            let now = Date()
            let m = MeetEvent(id: "test@\(Int(now.timeIntervalSince1970))", title: "Sample sync", start: now.addingTimeInterval(60),
                              end: now.addingTimeInterval(1860), video: true, others: true)
            MeetingNotes.offer(m, info: ["title": m.title], now: now, test: true)
        }
        // test hook: what an app's focused field looks like through Accessibility, from the background (read only)
        DistributedNotificationCenter.default().addObserver(forName: Notification.Name(Home.bundleID + ".axprobe"), object: nil, queue: .main) { n in
            guard let arg = n.object as? String else { return }
            if arg.hasSuffix(" wait") {   // probe once the user brings that app forward themselves (up to 2 min)
                let id = arg.replacingOccurrences(of: " wait", with: ""), t0 = Date()
                Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { t in
                    if Date().timeIntervalSince(t0) > 120 { t.invalidate(); log("axprobe \(id): not brought forward"); return }
                    guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier == id else { return }
                    t.invalidate()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                        DistributedNotificationCenter.default().postNotificationName(Notification.Name(Home.bundleID + ".axprobe"), object: id, userInfo: nil, deliverImmediately: true)
                    }
                }
                return
            }
            let front = arg.hasSuffix(" front"), id = arg.replacingOccurrences(of: " front", with: "")
            guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: id).first else { return }
            Focus.wake(app)
            if front, NSWorkspace.shared.frontmostApplication != app {   // bring it forward for a second, then back
                let prev = NSWorkspace.shared.frontmostApplication
                app.activate()
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                    DistributedNotificationCenter.default().postNotificationName(Notification.Name(Home.bundleID + ".axprobe"), object: id, userInfo: nil, deliverImmediately: true)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { prev?.activate() }
                }
                return
            }
            let a = AXUIElementCreateApplication(app.processIdentifier)
            var f: CFTypeRef?
            let own = AXUIElementCopyAttributeValue(a, kAXFocusedUIElementAttribute as CFString, &f) == .success ? f.map { $0 as! AXUIElement } : nil
            guard let el = own ?? (NSWorkspace.shared.frontmostApplication == app ? Focus.focused() : nil) else { log("axprobe \(id): no focus"); return }
            if NSWorkspace.shared.frontmostApplication == app { log("axprobe \(id): spot says \(Focus.spot(skip: []).1)") }
            AXProbe.dump(el, id: id)
        }
        // test hook: a real press with the microphone, dropped after 2.5 s (nothing is pasted): press -> strip, mic, words
        DistributedNotificationCenter.default().addObserver(forName: Notification.Name(Home.bundleID + ".presstest"), object: nil, queue: .main) { _ in
            guard Talk.shared.state == .idle else { return }
            Talk.shared.key(down: true)
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                let c = Talk.shared.clock
                log("voice timing (press test): strip \(c.ms(c.strip)) ms, mic \(c.ms(c.mic)) ms, first words \(c.ms(c.words)) ms after the press")
                Talk.shared.cancel()
            }
        }
        // test hook: screenshots as a long note takes them, 10 s into data/shots-test/<time>/ (no microphone, no note);
        // logs the count and whether a calendar event matches now. `object` "N" changes the seconds.
        DistributedNotificationCenter.default().addObserver(forName: Notification.Name(Home.bundleID + ".shotstest"), object: nil, queue: .main) { n in
            let secs = Double(n.object as? String ?? "") ?? 10
            let dir = Home.data.appendingPathComponent("shots-test/" + ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-"))
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let t0 = Date()
            let s = Shots(recording: dir) { Date().timeIntervalSince(t0) }
            s.start()
            let ev = Meeting.now()
            log("shots test: started for \(Int(secs)) s; calendar event now: " + (ev == nil ? "none" : "yes, \((ev?["people"] as? [String])?.count ?? 0) people"))
            DispatchQueue.main.asyncAfter(deadline: .now() + secs) {
                let kept = s.stop()
                Brief.write(dir: dir, rows: [Brief.Row(who: "", start: 1, text: "Shots test, no speech.")], shots: kept,
                            meta: ["call": false, "app": "test", "started": t0.timeIntervalSince1970], minutes: secs / 60)
                log("shots test: \(kept.count) kept in \(dir.lastPathComponent)")
            }
        }
        // read a saved recording again and save a new note: `object` = its folder in data/calls (same as Recordings › Read again)
        DistributedNotificationCenter.default().addObserver(forName: Notification.Name(Home.bundleID + ".reread"), object: nil, queue: .main) { n in
            guard let path = n.object as? String, path.hasPrefix(Spool.root.path) else { return }
            Spool.reread(URL(fileURLWithPath: path))
        }
        // test hook: transcribe a file as if dropped (bench/file_test.sh); only a file whose name holds "drafter-test"
        DistributedNotificationCenter.default().addObserver(forName: Notification.Name(Home.bundleID + ".filetest"), object: nil, queue: .main) { n in
            guard let path = n.object as? String, (path as NSString).lastPathComponent.contains("drafter-test") else { return }
            FileTranscribe.start([URL(fileURLWithPath: path)])
        }
        // test hook: feed a 16 kHz wav through the voice path as if it was spoken (bench/voice_test.sh)
        DistributedNotificationCenter.default().addObserver(forName: Notification.Name(Home.bundleID + ".voicetest"), object: nil, queue: .main) { n in
            guard let path = n.object as? String, path.hasPrefix(Home.root.path) else { return }
            Talk.shared.test(path)
        }
    }
}

/// `open -n -a Drafter --args --type <bundle id> "text"`: types into that app as real key events, for tests.
/// Stops at once if any other app comes to the front, or if the focused field does not contain the test marker
/// ⟦drafter-test⟧ (2026-10-18: a test without it typed into an open note).
/// \t = Tab, ↓ = down arrow, → = one word, ⎋ = Esc, ⌃ = Control+Return, ‖ = wait 1.5 s, ¶ = Return.
/// Fix marks (with data/debug): ← left arrow, ◌ mouse over the last fixed word, ◉ click its chip, ⎙ picture into data/.
/// Rework: ⇤ select to the line start, ⌥ ⌥Tab, Ⓟ picture of the rework list into data/rework-N.png.
enum TestTyper {
    static var shots = 0
    static var lastMark: [Double]?
    static func run(_ s: String, into bundle: String) {
        log("typer start \(bundle)")
        if let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundle).first { app.activate(); Focus.wake(app) }
        Thread.sleep(forTimeInterval: 1.5)
        log("typer front=\(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "?") trusted=\(Focus.trusted())")
        func front() -> Bool { NSWorkspace.shared.frontmostApplication?.bundleIdentifier == bundle }
        let src = CGEventSource(stateID: .hidSystemState)
        func key(_ code: CGKeyCode, _ flags: CGEventFlags = []) {
            for down in [true, false] {
                let e = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: down); e?.flags = flags; e?.post(tap: .cghidEventTap)
                Thread.sleep(forTimeInterval: 0.01)
            }
        }
        for ch in s {
            RunLoop.current.run(until: Date())
            guard front() else { log("typer stopped: other app in front"); flushLogs(); print("stopped: \(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "?") is in front"); exit(2) }
            guard let el = Focus.focused(), let v: String = Focus.attr(el, kAXValueAttribute), v.contains("⟦drafter-test⟧") else {
                log("typer stopped: no test marker in \(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "?") field \((Focus.focused().flatMap { Focus.attr($0, kAXRoleAttribute) as String? }) ?? "none")"); flushLogs(); exit(3)
            }
            switch ch {
            case "\t": key(48)
            case "→": key(124)
            case "⎋": key(53)
            case "⌃": key(36, .maskControl)
            case "¶": key(36)
            case "⇟": key(125, .maskCommand)   // to the end of the text
            case "Ⓐ": key(0, .maskCommand)     // select all (to clear a test draft)
            case "⇤": key(123, [.maskCommand, .maskShift])   // select to the line start
            case "⌥": key(48, .maskAlternate)                // ⌥Tab: the rework list on a selection
            case "Ⓔ": key(53, .maskShift)                    // ⇧Esc: no more call offers in that app
            case "Ⓟ": DistributedNotificationCenter.default().postNotificationName(Notification.Name(Home.bundleID + ".reworkshot"), object: nil, userInfo: nil, deliverImmediately: true)
            case "⌫": key(51)
            case "Ⓦ": key(13, .maskCommand)    // close the test tab or window
            case "‖": Thread.sleep(forTimeInterval: 1.5)
            case "←": key(123)
            case "↓": key(125)
            case "Ⓡ": log("typer value «\(v.suffix(120).replacingOccurrences(of: "\n", with: "⏎"))»")   // what the field holds now
            case "◌", "◉", "⎙":
                let j = (try? Data(contentsOf: Home.data.appendingPathComponent("fixmarks.json")))
                    .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
                let mark = (j["marks"] as? [[Double]])?.last ?? TestTyper.lastMark, chip = j["chip"] as? [Double]
                if mark != nil { TestTyper.lastMark = mark }
                if ch == "◌", let r = mark {
                    let p = CGPoint(x: r[0] + r[2] / 2, y: r[1] + r[3] / 2)
                    CGWarpMouseCursorPosition(p)
                    CGEvent(mouseEventSource: src, mouseType: .mouseMoved, mouseCursorPosition: p, mouseButton: .left)?.post(tap: .cghidEventTap)
                } else if ch == "◉", let r = chip {
                    let p = CGPoint(x: r[0] + r[2] / 2, y: r[1] + r[3] / 2)
                    for t in [CGEventType.leftMouseDown, .leftMouseUp] {
                        CGEvent(mouseEventSource: src, mouseType: t, mouseCursorPosition: p, mouseButton: .left)?.post(tap: .cghidEventTap)
                        Thread.sleep(forTimeInterval: 0.05)
                    }
                } else if ch == "⎙", let r = mark {
                    TestTyper.shots += 1
                    let out = Home.data.appendingPathComponent("fixmark-\(TestTyper.shots).png"), done = DispatchSemaphore(value: 0)
                    SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: true) { c, _ in
                        guard let d = c?.displays.first else { done.signal(); return }
                        let cfg = SCStreamConfiguration(); cfg.sourceRect = CGRect(x: r[0] - 160, y: r[1] - 50, width: 420, height: 100)
                        cfg.width = 840; cfg.height = 200
                        SCScreenshotManager.captureImage(contentFilter: SCContentFilter(display: d, excludingWindows: []), configuration: cfg) { img, _ in
                            if let img, let dest = CGImageDestinationCreateWithURL(out as CFURL, "public.png" as CFString, 1, nil) {
                                CGImageDestinationAddImage(dest, img, nil); CGImageDestinationFinalize(dest)
                            }
                            done.signal()
                        }
                    }
                    _ = done.wait(timeout: .now() + 3)
                } else { log("typer: no fix mark for \(ch)") }
            default:
                var u = Array(String(ch).utf16)
                for down in [true, false] {
                    let e = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: down)
                    e?.flags = []   // never inherit ⌘ from the key before
                    e?.keyboardSetUnicodeString(stringLength: u.count, unicodeString: &u); e?.post(tap: .cghidEventTap)
                }
            }
            Thread.sleep(forTimeInterval: 0.06)
        }
        Thread.sleep(forTimeInterval: 0.3)
        log("typer done")
        exit(0)
    }
}


/// What a field looks like through Accessibility, into data/app.log (read only): the axprobe hook, and once per app
/// per run when the caret cannot be found there (Keys.ask).
enum AXProbe {
    static var done: Set<String> = []
    static func dump(_ el: AXUIElement, id: String) {
        var names: CFArray?; AXUIElementCopyAttributeNames(el, &names)
        var out: [String] = []
        for k in (names as? [String]) ?? [] where !["AXChildren", "AXChildrenInNavigationOrder", "AXParent", "AXTopLevelUIElement", "AXWindow"].contains(k) {
            var v: CFTypeRef?; AXUIElementCopyAttributeValue(el, k as CFString, &v)
            var t = v.map { "\($0)" } ?? "nil"; if t.count > 90 { t = String(t.prefix(90)) + "…" }
            var settable: DarwinBoolean = false; AXUIElementIsAttributeSettable(el, k as CFString, &settable)
            out.append("\(k)\(settable.boolValue ? "*" : "")=\(t.replacingOccurrences(of: "\n", with: "⏎"))")
        }
        let v: String = Focus.attr(el, kAXValueAttribute) ?? ""
        let r = Focus.range(el)
        let m = Focus.markers(el)
        log("axprobe \(id): " + out.joined(separator: " | "))
        if let r, r.location > 0 {
            let b1 = Focus.bounds(el, r.location - 1, 1), b0 = Focus.bounds(el, r.location, 0), bl = Focus.bounds(el, max(0, r.location - 1), 1)
            log("axprobe \(id): bounds prev \(b1.map { "\($0)" } ?? "nil") at \(b0.map { "\($0)" } ?? "nil") \(bl == nil ? "" : "")")
        }
        log("axprobe \(id): value \(v.count) chars «\(v.suffix(60))», range \(r.map { "\($0.location),\($0.length)" } ?? "nil"), markers \(m.map { "before …\($0.0.suffix(30)) after \($0.1.prefix(30)) rect \($0.2 != nil)" } ?? "nil")")
    }
}

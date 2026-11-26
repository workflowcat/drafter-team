// The shot pack on disk and its hand-off (screenshot tool, capture side, 15 November 2026; design:
// docs/research/2026-11-15-screenshot-tool.md). data/shots/<id>/ holds shot.png (as handed off), original.png (only
// when marked), shot.json (ShotPack, app/ShotPackRules.swift) and shot.md (the agent text). Every write runs on one
// serial queue, off the main thread; shot.json is merged with what is on disk so a send or an answer is never lost.
// The targets after ⇥ in the strip (app/CaptureNote.swift) live here: clipboard, file, an app (Claude, Codex),
// Claude Code, Ask Claude here (`claude -p`, Read only), a person (a Beeper draft, never sent). Never Return anywhere.
// The log keeps "shot: sent to <target>" and counts, never the note, the read text or a chat's title.
import AppKit
import Carbon

enum ShotStore {
    static let dir = Home.data.appendingPathComponent("shots")
    static let queue = DispatchQueue(label: "drafter.shots")
    static func folder(_ id: String) -> URL { dir.appendingPathComponent(id) }
    static func pngURL(_ id: String) -> URL { folder(id).appendingPathComponent("shot.png") }
    static func mdURL(_ id: String) -> URL { folder(id).appendingPathComponent("shot.md") }
    static func jsonURL(_ id: String) -> URL { folder(id).appendingPathComponent("shot.json") }

    static func load(_ id: String) -> ShotPack? {
        (try? Data(contentsOf: jsonURL(id))).flatMap { try? JSONDecoder().decode(ShotPack.self, from: $0) }
    }

    /// The pack written (on the queue): the pictures when given, then shot.json merged with the one on disk, then shot.md.
    static func write(_ p: ShotPack, png: Data? = nil, original: Data? = nil, done: (() -> Void)? = nil) {
        queue.async {
            let f = folder(p.id)
            try? FileManager.default.createDirectory(at: f, withIntermediateDirectories: true)
            if let png { try? png.write(to: pngURL(p.id), options: .atomic) }
            if let original { try? original.write(to: f.appendingPathComponent("original.png"), options: .atomic) }
            save(p.merged(onDisk: load(p.id)))
            done?()
        }
    }
    /// A set (several pictures in one hand-off): every picture as shot.png, shot-2.png, … and its original when marked,
    /// files past the set's end taken away, then shot.json and shot.md, on the queue.
    static func writeSet(_ p: ShotPack, pngs: [Data], originals: [Data?], done: (() -> Void)? = nil) {
        queue.async {
            let f = folder(p.id), fm = FileManager.default
            try? fm.createDirectory(at: f, withIntermediateDirectories: true)
            for (i, d) in pngs.enumerated() { try? d.write(to: f.appendingPathComponent(ShotPack.pictureFile(i)), options: .atomic) }
            for (i, o) in originals.enumerated() {
                let u = f.appendingPathComponent(ShotPack.originalFile(i))
                if let o { try? o.write(to: u, options: .atomic) } else if i > 0 { try? fm.removeItem(at: u) }
            }
            for i in pngs.count..<(pngs.count + 20) {
                let u = f.appendingPathComponent(ShotPack.pictureFile(i))
                guard i > 0, fm.fileExists(atPath: u.path) else { break }
                try? fm.removeItem(at: u); try? fm.removeItem(at: f.appendingPathComponent(ShotPack.originalFile(i)))
            }
            save(p.merged(onDisk: load(p.id)))
            done?()
        }
    }
    /// A change to the pack on disk (a send, the answer), on the queue.
    static func update(_ id: String, _ change: @escaping (inout ShotPack) -> Void) {
        queue.async {
            guard var p = load(id) else { return }
            change(&p)
            save(p)
        }
    }
    private static func save(_ p: ShotPack) {
        let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let d = try? e.encode(p) { try? d.write(to: jsonURL(p.id), options: .atomic) }
        try? p.agentText(path: pngURL(p.id).path).write(to: mdURL(p.id), atomically: true, encoding: .utf8)
    }

    /// Off the main thread: the picture's text (Vision, this Mac) and the found things in it; `done` on main.
    static func read(_ png: Data, done: @escaping (String, [String]) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let t0 = Date()
            let text = CGImageSourceCreateWithData(png as CFData, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) }.map(Screen.read) ?? ""
            let found = ShotPack.foundValues(Detect.scan(String(text.prefix(Detect.cap)), written: Date()).map { (kind: $0.kind.rawValue, value: $0.value, sensitive: $0.sensitive) })
            log("shot: read \(text.count) chars, \(found.count) found, in \(Int(Date().timeIntervalSince(t0) * 1000)) ms")
            DispatchQueue.main.async { done(text, found) }
        }
    }

    /// One send: kept in shot.json, the target remembered for the list's first row, one log line without content.
    static func sent(_ id: String, _ t: ShotTarget, detail: String = "") {
        let now = Date().timeIntervalSince1970
        update(id) { $0.sent.append(ShotSent(to: t, t: now, detail: detail)) }
        if t != .field {
            Drafter.shared.change { $0.shotLast = t.rawValue }
        }
        log("shot: sent to \(t.rawValue)")
    }
}

// MARK: the targets

enum ShotSend {
    /// The folder for "File": setting `shotFolder`, else ~/Desktop.
    static var folder: URL {
        let s = Drafter.shared.settings.shotFolder.trimmingCharacters(in: .whitespaces)
        return URL(fileURLWithPath: s.isEmpty ? NSHomeDirectory() + "/Desktop" : (s as NSString).expandingTildeInPath)
    }

    /// One clipboard item: the picture and the text.
    static func clipboard(_ png: Data, text: String) {
        History.copy(text) { pb in Capture.pictureWriter(png)(pb); pb.setString(text, forType: .string) }
    }
    /// A set on the clipboard: one item per picture, the text on the first (apps that take one item get the first
    /// picture with the text).
    static func clipboard(_ pngs: [Data], text: String) {
        guard pngs.count > 1 else { if let p = pngs.first { clipboard(p, text: text) }; return }
        History.copy(text) { pb in
            let items = pngs.enumerated().map { i, d -> NSPasteboardItem in
                let it = NSPasteboardItem(); it.setData(d, forType: .png)
                if i == 0 { it.setString(text, forType: .string) }
                return it
            }
            pb.clearContents(); pb.writeObjects(items)
        }
    }

    /// shot.png copied into the folder under a macOS-like name not taken there. Returns the name, nil on failure.
    static func file(_ id: String, t: Double, count: Int = 1) -> String? {
        let f = folder
        try? FileManager.default.createDirectory(at: f, withIntermediateDirectories: true)
        let taken = Set((try? FileManager.default.contentsOfDirectory(atPath: f.path)) ?? [])
        let names = ShotPack.fileNames(t, count: count, taken: taken)
        do {
            for (i, name) in names.enumerated() {
                try FileManager.default.copyItem(at: ShotStore.folder(id).appendingPathComponent(ShotPack.pictureFile(i)), to: f.appendingPathComponent(name))
            }
            return names.count == 1 ? names[0] : "\(names[0]) and \(names.count - 1) more"
        } catch { log("shot: file copy failed"); return nil }
    }

    /// The app brought forward (launched when it is not running), then `then(true)` once it is in front, `false`
    /// after 6 s or when it is not on this Mac.
    static func bringForward(_ bundle: String, then: @escaping (Bool) -> Void) {
        func wait(_ left: Int) {
            if NSWorkspace.shared.frontmostApplication?.bundleIdentifier == bundle {
                // its box gets the focus a moment after the window comes up
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { then(true) }
                return
            }
            guard left > 0 else { then(false); return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { wait(left - 1) }
        }
        if let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundle).first {
            app.unhide(); app.activate(options: [.activateAllWindows])
            wait(60); return
        }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) else { then(false); return }
        let c = NSWorkspace.OpenConfiguration(); c.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: c) { _, err in
            DispatchQueue.main.async { if err != nil { then(false) } else { wait(60) } }
        }
    }

    // MARK: the capture deck's hand-off (round 2, docs/rounds/2026-11-17-deck.md)

    /// One picture as a clipboard item: PNG, TIFF and, when it is on disk, its file URL (apps that take files get the
    /// file; apps that take images get the image). Drafter's own mark keeps it out of the clipboard history.
    static func pictureItem(_ png: Data, url: URL?) -> NSPasteboardItem {
        let it = NSPasteboardItem()
        it.setData(png, forType: .png)
        if let t = NSBitmapImageRep(data: png)?.tiffRepresentation { it.setData(t, forType: .tiff) }
        if let url, FileManager.default.fileExists(atPath: url.path) { it.setString(url.absoluteString, forType: .fileURL) }
        return it
    }
    /// The deck's pictures on disk (shot.png, shot-2.png, …) once the shots queue wrote them.
    static func pictureURLs(_ id: String, count: Int) -> [URL] {
        ShotStore.queue.sync {}
        return (0..<count).map { ShotStore.folder(id).appendingPathComponent(ShotPack.pictureFile($0)) }
    }
    /// A deck on the clipboard: one item per picture (image, file), the text on the first.
    static func clipboard(_ pngs: [Data], urls: [URL], text: String) {
        History.copy(text) { pb in
            let items = pngs.enumerated().map { i, d -> NSPasteboardItem in
                let it = pictureItem(d, url: urls.indices.contains(i) ? urls[i] : nil)
                if i == 0, !text.isEmpty { it.setString(text, forType: .string) }
                return it
            }
            pb.clearContents(); pb.writeObjects(items)
        }
    }
    /// The deck into the front app, step by step (DeckRules.steps). His clipboard is saved once, each step goes on it
    /// and is pasted, the next one follows after DeckRules.gap, and his clipboard comes back DeckRules.pictureHold
    /// after the last ⌘V (unless something else was copied meanwhile). `pasted`: right after the last ⌘V; `done`: once
    /// his clipboard is back. No Return anywhere; secure input stops it.
    static func paste(steps: [DeckRules.Step], pngs: [Data], urls: [URL], pasted: (() -> Void)? = nil, done: (() -> Void)? = nil) {
        let pb = NSPasteboard.general
        let saved = pb.pasteboardItems?.map { item -> NSPasteboardItem in
            let c = NSPasteboardItem()
            for t in item.types { if let d = item.data(forType: t) { c.setData(d, forType: t) } }
            return c
        } ?? []
        var mine = pb.changeCount
        // insert audit 2026-11-23: the app with the keys at the first paste; a later step goes only while it still has
        // them (a switch between steps pasted the rest into the other app; InsertRules.stepMayGo)
        let startPid = Capture.keyPid()
        func give() {
            if pb.changeCount == mine {
                pb.clearContents()
                if !saved.isEmpty { pb.writeObjects(saved) }
                History.skipChange(pb.changeCount)
            }
            done?()
        }
        func run(_ i: Int) {
            guard i < steps.count else { pasted?(); DispatchQueue.main.asyncAfter(deadline: .now() + DeckRules.pictureHold) { give() }; return }
            guard InsertRules.stepMayGo(startPid: startPid, keyPid: Capture.keyPid(), ownPid: getpid(),
                                        secure: IsSecureEventInputEnabled()) else {
                log("shot: put in stopped at step \(i + 1) of \(steps.count): the keys moved or secure input"); give(); return
            }
            let s = steps[i]
            switch s {
            case .picture(let n):
                guard pngs.indices.contains(n) else { run(i + 1); return }
                pb.clearContents(); pb.writeObjects([pictureItem(pngs[n], url: urls.indices.contains(n) ? urls[n] : nil)])
            case .text(let t):
                pb.clearContents(); pb.setString(t, forType: .string)
                Focus.pasted?(t)   // the paste trail (PasteWatch.own)
            }
            pb.setString("1", forType: History.ownType)
            mine = pb.changeCount
            Focus.commandV()
            if i == steps.count - 1 { run(i + 1) }
            else { DispatchQueue.main.asyncAfter(deadline: .now() + DeckRules.gap(after: s)) { run(i + 1) } }
        }
        run(0)
    }

    /// The picture (when given), then the text after the paste gave the clipboard back, into the front app. No Return.
    /// The pictures one after another (each paste waits for the clipboard to come back), then the text.
    static func paste(pictures: [Data], text: String?, startPid: Int32? = nil) {
        guard let first = pictures.first, pictures.count > 1 else { paste(picture: pictures.first, text: text, startPid: startPid); return }
        let start = startPid ?? Capture.keyPid()
        guard mayGo(start) else { return }
        Focus.paste("", write: Capture.pictureWriter(first))
        DispatchQueue.main.asyncAfter(deadline: .now() + Focus.restoreDelay + 0.15) { paste(pictures: Array(pictures.dropFirst()), text: text, startPid: start) }
    }
    static func paste(picture png: Data?, text: String?, startPid: Int32? = nil) {
        let start = startPid ?? Capture.keyPid()
        guard mayGo(start) else { return }
        if let png { Focus.paste("", write: Capture.pictureWriter(png)) }
        guard let text, !text.isEmpty else { return }
        let gap = png == nil ? 0 : Focus.restoreDelay + 0.15
        DispatchQueue.main.asyncAfter(deadline: .now() + gap) { if mayGo(start) { Focus.paste(text) } }
    }
    /// The next paste of one put-in: the same app still has the keys, no secure input (InsertRules.stepMayGo).
    private static func mayGo(_ start: Int32?) -> Bool {
        let ok = InsertRules.stepMayGo(startPid: start, keyPid: Capture.keyPid(), ownPid: getpid(), secure: IsSecureEventInputEnabled())
        if !ok { log("shot: paste stopped, the keys moved or secure input") }
        return ok
    }

    /// The `claude` CLI: the config's path, else `claude` found on PATH through /usr/bin/env (run() puts ~/.local/bin,
    /// Homebrew and /usr/local on it). The prompt goes on stdin, never argv (tests/test_claude_argv.py).
    static var claudeBin: (bin: String, lead: [String])? {
        if let p = LocalConfig.integration("claude")["bin"] as? String, !p.isEmpty {
            let x = (p as NSString).expandingTildeInPath
            if FileManager.default.isExecutableFile(atPath: x) { return (x, []) }
        }
        return ("/usr/bin/env", ["claude"])
    }
    /// The `beeper` CLI (engine/people.py beeper_bin looks in the same places).
    static var beeperBin: String? {
        let fm = FileManager.default
        if let p = LocalConfig.integration("beeper")["bin"] as? String, !p.isEmpty, fm.isExecutableFile(atPath: (p as NSString).expandingTildeInPath) {
            return (p as NSString).expandingTildeInPath
        }
        return [NSHomeDirectory() + "/.npm-global/bin/beeper", "/opt/homebrew/bin/beeper", "/usr/local/bin/beeper", NSHomeDirectory() + "/.local/bin/beeper"]
            .first { fm.isExecutableFile(atPath: $0) }
    }

    /// Runs a tool off the main thread: stdout (nil on failure or after `timeout`), on main.
    static func run(_ bin: String, _ args: [String], stdin: String? = nil, cwd: URL? = nil, env: [String: String] = [:],
                    timeout: Double, done: @escaping (String?) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: bin); p.arguments = args
            if let cwd { p.currentDirectoryURL = cwd }
            var e = ProcessInfo.processInfo.environment
            e["PATH"] = "\(NSHomeDirectory())/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
            for (k, v) in env { e[k] = v }
            p.environment = e
            let out = Pipe(), inp = Pipe()
            p.standardOutput = out; p.standardError = FileHandle.nullDevice
            p.standardInput = stdin == nil ? FileHandle.nullDevice : inp
            do { try p.run() } catch { DispatchQueue.main.async { done(nil) }; return }
            if let stdin { inp.fileHandleForWriting.write(Data(stdin.utf8)); try? inp.fileHandleForWriting.close() }
            let killer = DispatchWorkItem { if p.isRunning { p.terminate() } }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
            let data = out.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            killer.cancel()
            let ok = p.terminationStatus == 0 && p.terminationReason == .exit
            let s = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            DispatchQueue.main.async { done(ok ? s : nil) }
        }
    }

    /// Ask Claude here: shot.md on stdin, Read only, in the shot's folder; the answer into shot.json and the strip.
    static func ask(_ id: String) {
        guard let c = claudeBin else { Pill.shared.flash("Claude Code is not on this Mac"); return }
        let md = (try? String(contentsOf: ShotStore.mdURL(id), encoding: .utf8)) ?? ""
        Pill.shared.show("Asking Claude about the screenshot…", seconds: ShotPack.askTimeout, lines: 1)
        let t0 = Date()
        run(c.bin, c.lead + ShotPack.askArgs, stdin: ShotPack.askInput(md), cwd: ShotStore.folder(id), timeout: ShotPack.askTimeout) { a in
            guard let a, !a.isEmpty else { Pill.shared.flash("Claude gave no answer"); log("shot: ask failed after \(Int(Date().timeIntervalSince(t0))) s"); return }
            ShotStore.update(id) { $0.answer = a }
            Pill.shared.show(a, seconds: max(8, min(30, Double(a.count) / 12)), lines: 4)
            log("shot: answer \(a.count) chars in \(Int(Date().timeIntervalSince(t0))) s")
        }
    }

    /// Person: the chats for a name (direct ones first), on main.
    static func chats(_ name: String, done: @escaping ([(id: String, title: String)]) -> Void) {
        guard let bin = beeperBin else { done([]); return }
        run(bin, ShotPack.beeperSearch(name), env: ["BEEPER_READONLY": "1"], timeout: 8) { out in
            done(out.map { ShotPack.chats(Data($0.utf8)) } ?? [])
        }
    }
    /// The picture and the note as a draft in that chat. Never sent.
    static func draft(chat: String, id: String, note: String, done: @escaping (Bool) -> Void) {
        guard let bin = beeperBin else { done(false); return }
        run(bin, ShotPack.beeperDraft(chat: chat, file: ShotStore.pngURL(id).path, note: note), timeout: 30) { done($0 != nil) }
    }
}

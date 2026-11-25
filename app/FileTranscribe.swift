// Transcribe a file (17 November 2026, from the tools review: MacWhisper, Transcribe): an audio or video file dropped on
// the Drafter window or the menu bar icon, or picked with "Transcribe file…", becomes a recording like a long note.
// The file is converted to 16 kHz mono (AudioImport) into data/calls/<time>/me.wav, then the call pipeline reads it
// (Talk.transcribe: Parakeet, else Whisper; names from the people book; /note writes the summary and to-dos). A file of
// 20 minutes or more also goes to the careful reading on the team server (Jobs.careful, the background-jobs rule in
// AGENTS.md). Progress shows in the notch: a ring with the percent while it converts, a turning arc while it is read.
// The source file is never changed or moved. Files go one after another.
import AppKit
import UniformTypeIdentifiers

enum FileTranscribe {
    static let carefulFrom: Double = 20 * 60          // seconds: longer files also get the careful reading
    private static var queue: [URL] = []
    private(set) static var busy = false
    private static var stop = false

    static func supported(_ urls: [URL]) -> [URL] { urls.filter { AudioImport.supported($0) } }

    /// The open panel: one or more audio or video files.
    static func pick() {
        let p = NSOpenPanel()
        p.title = "Transcribe file"; p.prompt = "Transcribe"
        p.allowsMultipleSelection = true; p.canChooseDirectories = false
        p.allowedContentTypes = AudioImport.kinds.compactMap { UTType(filenameExtension: $0) }
        NSApp.activate(ignoringOtherApps: true)
        guard p.runModal() == .OK else { return }
        start(p.urls)
    }

    /// Queue files (the ones of a kind it can read); the rest are named in the strip.
    static func start(_ urls: [URL]) {
        let ok = supported(urls)
        if ok.count < urls.count {
            Pill.shared.flash("Not audio or video: " + urls.filter { !ok.contains($0) }.map(\.lastPathComponent).prefix(3).joined(separator: ", "))
        }
        guard !ok.isEmpty else { return }
        queue += ok
        log("file: \(ok.count) queued, \(queue.count) waiting")
        next()
    }

    static func cancel() { stop = true; queue.removeAll() }

    private static func next() {
        guard !busy, !queue.isEmpty else { return }
        busy = true; stop = false
        let src = queue.removeFirst()
        let left = queue.count
        let name = src.deletingPathExtension().lastPathComponent
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let dir = Spool.root.appendingPathComponent(stamp + "-file")
        do { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
        catch { finish(nil, "Could not make a folder for \(name)"); return }
        let made = (try? src.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date()
        let meta: [String: Any] = ["call": false, "app": "File", "file": src.lastPathComponent, "title": name,
                                   "started": Date().timeIntervalSince1970, "fileDate": made.timeIntervalSince1970]
        try? JSONSerialization.data(withJSONObject: meta, options: [.sortedKeys]).write(to: dir.appendingPathComponent("meta.json"))
        RecordNotch.shared.progress(name, 0, more: left)
        let wav = dir.appendingPathComponent("me.wav")
        DispatchQueue.global(qos: .userInitiated).async {
            let access = src.startAccessingSecurityScopedResource()
            defer { if access { src.stopAccessingSecurityScopedResource() } }
            do {
                let secs = try AudioImport.convert(src, to: wav, progress: { f in
                    DispatchQueue.main.async { RecordNotch.shared.progress(name, f, more: left) }
                }, cancelled: { stop })
                DispatchQueue.main.async { read(dir, name: name, secs: secs, more: left) }
            } catch {
                let why = (error as? AudioImport.Failure).map { f -> String in
                    switch f { case .noAudioTrack: return "no sound track"; case .cancelled: return "cancelled"; case .unreadable(let s): return s }
                } ?? error.localizedDescription
                log("file: \(src.pathExtension) not converted: \(why)")
                try? FileManager.default.removeItem(at: dir)
                DispatchQueue.main.async { finish(nil, "\(name): \(why)") }
            }
        }
    }

    /// The converted file read like a long note; the page opens when the reading is in.
    private static func read(_ dir: URL, name: String, secs: Double, more: Int) {
        log(String(format: "file: converted %.1f min into %@", secs / 60, dir.lastPathComponent))
        guard secs >= 0.5 else { try? FileManager.default.removeItem(at: dir); finish(nil, "\(name): no sound in it"); return }
        RecordNotch.shared.progress(name, nil, more: more)
        Talk.shared.transcribe(dir: dir, me: dir.appendingPathComponent("me.wav"), them: nil, call: false, live: "") { ok in
            if secs >= carefulFrom {
                Jobs.careful(dir) { code in log("file: careful reading for \(dir.lastPathComponent) exited \(code)") }
            }
            finish(ok ? dir : nil, ok ? nil : "\(name): no speech found")
        }
    }

    private static func finish(_ dir: URL?, _ problem: String?) {
        busy = false
        if let problem { Pill.shared.flash(problem) }
        if queue.isEmpty {
            RecordNotch.shared.endProgress()
            if let dir {
                AppWindow.shared.show()
                let m = AppWindow.shared.model
                m.loadDocs()
                if let d = m.docs.first(where: { $0.dir.standardizedFileURL == dir.standardizedFileURL }) { m.openDoc(d) }
            }
        }
        next()
    }
}

/// The menu bar icon takes a dropped file (17 November 2026): a view over the status button that only handles drags;
/// clicks go through to the button (hitTest nil), so the menu opens as before.
final class StatusDrop: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL])
        autoresizingMask = [.width, .height]
    }
    required init?(coder: NSCoder) { fatalError() }
    override func hitTest(_ p: NSPoint) -> NSView? { nil }
    private func urls(_ s: NSDraggingInfo) -> [URL] {
        (s.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
    }
    override func draggingEntered(_ s: NSDraggingInfo) -> NSDragOperation { FileTranscribe.supported(urls(s)).isEmpty ? [] : .copy }
    override func performDragOperation(_ s: NSDraggingInfo) -> Bool {
        let u = urls(s)
        guard !FileTranscribe.supported(u).isEmpty else { return false }
        FileTranscribe.start(u); return true
    }
}

/// URLs collected from a drop's item providers, which call back on their own threads.
final class FileDropBox {
    private let lock = NSLock()
    private var all: [URL] = []
    func add(_ u: URL) { lock.lock(); all.append(u); lock.unlock() }
    var urls: [URL] { lock.lock(); defer { lock.unlock() }; return all }
}

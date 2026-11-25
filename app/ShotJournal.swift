// The screenshot tool, journal side (15 November 2026; design: docs/research/2026-11-15-screenshot-tool.md, "Journal").
// A capture's image row carries `"shot": "<id>"` (History.addPicture, the capture side); its pack is in
// data/shots/<id>/ (shot.png, original.png when marked, shot.json = ShotPack, shot.md). Here: reading shot.json
// (cached, checked by the file's date; called from the journal build's queue, never from a draw), the row's actions
// (send again, mark up again, copy for agent, show the file), and the seams the capture side fills.
// Pure rules: app/ShotJournalRules.swift.
import AppKit

enum ShotJournal {
    // MARK: the seams (the capture side sets them when it starts; until then the actions say they are not ready)

    /// ⇥ on a shot row: open the send-to list for this pack. Arguments: the pack as read from shot.json, and the pack's
    /// folder (data/shots/<id>/, holding shot.png). Called on the main thread.
    static var sendAgain: ((ShotPack, URL) -> Void)? = { CaptureNote.shared.reopen($0, folder: $1, markup: false) }
    /// ⌘E on a shot row: open markup over original.png (else shot.png) with the kept marks; same arguments.
    static var markAgain: ((ShotPack, URL) -> Void)? = { CaptureNote.shared.reopen($0, folder: $1, markup: true) }

    // MARK: files

    /// data/shots (the preview points it at a folder of made-up shots).
    static var root: URL = Home.data.appendingPathComponent("shots")
    static func dir(_ id: String) -> URL { root.appendingPathComponent(id, isDirectory: true) }
    static func png(_ id: String) -> URL { dir(id).appendingPathComponent("shot.png") }

    private static let lock = NSLock()
    private static var cache: [String: (date: Date, pack: ShotPack)] = [:]

    /// The pack for a shot id, or nil (an unsafe id, no shot.json yet, a file that does not read). Read once and kept
    /// until shot.json changes (a send, an answer, a new markup): one stat per call. A miss is not kept, so a pack
    /// written after its history row shows at the next build. Any thread; the journal calls it off the main thread.
    static func pack(_ id: String) -> ShotPack? {
        guard ShotJournalRules.validId(id) else { return nil }
        let u = dir(id).appendingPathComponent("shot.json")
        guard let date = (try? FileManager.default.attributesOfItem(atPath: u.path))?[.modificationDate] as? Date else { return nil }
        lock.lock()
        if let c = cache[id], c.date == date { lock.unlock(); return c.pack }
        lock.unlock()
        guard let data = try? Data(contentsOf: u), var p = try? JSONDecoder().decode(ShotPack.self, from: data) else { return nil }
        if p.answer == nil, let a = try? String(contentsOf: dir(id).appendingPathComponent("answer.md"), encoding: .utf8),
           !a.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { p.answer = a }
        p.id = id   // the folder decides
        lock.lock()
        if cache.count > 2000 { cache.removeAll() }
        cache[id] = (date, p)
        lock.unlock()
        return p
    }

    private static let thumbCache: NSCache<NSString, NSImage> = {
        let c = NSCache<NSString, NSImage>(); c.countLimit = 180; return c
    }()
    private static let thumbQueue: OperationQueue = {
        let q = OperationQueue()
        q.name = "drafter.shot-thumb"
        q.qualityOfService = .userInitiated
        q.maxConcurrentOperationCount = 1   // serial: one decode at a time
        return q
    }()
    private static let thumbLock = NSLock()
    private static var thumbInFlight: [String: [() -> Void]] = [:]
    private static var thumbFailed: Set<String> = []

    private static func decodeThumb(_ url: URL, px: Int) -> NSImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                                                   kCGImageSourceThumbnailMaxPixelSize: px,
                                                                   kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }

    /// shot.png scaled for a card, kept per file date (synchronous: used by previews). nil when the file is gone.
    static func thumb(_ id: String, px: Int = 720) -> NSImage? {
        let u = png(id)
        guard let date = (try? FileManager.default.attributesOfItem(atPath: u.path))?[.modificationDate] as? Date else { return nil }
        let key = "\(id)@\(date.timeIntervalSince1970)@\(px)"
        let k = key as NSString
        if let i = thumbCache.object(forKey: k) { return i }
        thumbLock.lock()
        let failed = thumbFailed.contains(key)
        thumbLock.unlock()
        if failed { return nil }
        guard let i = decodeThumb(u, px: px) else {
            thumbLock.lock()
            if thumbFailed.count > 500 { thumbFailed.removeAll() }
            thumbFailed.insert(key)
            thumbLock.unlock()
            return nil
        }
        thumbCache.setObject(i, forKey: k)
        return i
    }

    /// Non-blocking thumbnail lookup for live scrolling: returns cached image immediately, else decodes off the main
    /// thread on a bounded queue and calls `onReady` on main once cached (deduplicated per key, negative-cached on failure).
    static func thumbAsync(_ id: String, px: Int = 720, onReady: @escaping () -> Void) -> NSImage? {
        let u = png(id)
        guard let date = (try? FileManager.default.attributesOfItem(atPath: u.path))?[.modificationDate] as? Date else { return nil }
        let key = "\(id)@\(date.timeIntervalSince1970)@\(px)"
        let nsKey = key as NSString
        if let i = thumbCache.object(forKey: nsKey) { return i }
        thumbLock.lock()
        if thumbFailed.contains(key) { thumbLock.unlock(); return nil }
        if thumbInFlight[key] != nil {
            thumbInFlight[key]?.append(onReady)
            thumbLock.unlock()
            return nil
        }
        thumbInFlight[key] = [onReady]
        thumbLock.unlock()
        thumbQueue.addOperation {
            let img = decodeThumb(u, px: px)
            if let img { thumbCache.setObject(img, forKey: nsKey) }
            thumbLock.lock()
            if img == nil {
                if thumbFailed.count > 500 { thumbFailed.removeAll() }
                thumbFailed.insert(key)
            }
            let callbacks = thumbInFlight.removeValue(forKey: key) ?? []
            thumbLock.unlock()
            guard img != nil else { return }
            DispatchQueue.main.async { callbacks.forEach { $0() } }
        }
        return nil
    }
}

extension WindowModel {
    /// The chosen item's shot pack, when it is a shot.
    var currentShot: ShotPack? { current?.shot }

    /// A shot row's actions (ShotJournalRules.actions) bound to what they do here.
    func shotActions(_ it: TapeItem) -> [RowAction] {
        ShotJournalRules.actions(pinned: it.pinned).map { s in
            RowAction(key: s.key, word: s.word, tip: s.tip) { [weak self] in
                guard let self else { return }
                self.choose(it.id)
                switch s.act {
                case .send: self.sendShot()
                case .insert: self.insert()
                case .copyAgent: self.copyShotForAgent()
                case .markUp: self.markShot()
                case .showFile: self.showShotFile()
                case .pin: self.pin()
                case .delete: self.delete()
                }
            }
        }
    }

    /// ⇥: the send-to list again (the capture side's list, through `ShotJournal.sendAgain`).
    func sendShot() {
        guard let p = currentShot else { return }
        guard !preview else { status = "Send to…"; return }
        guard let f = ShotJournal.sendAgain else { status = "Send to… is not ready yet"; return }
        f(p, ShotJournal.dir(p.id))
    }

    /// ⌘E: mark up again (the capture side's markup, through `ShotJournal.markAgain`).
    func markShot() {
        guard let p = currentShot else { return }
        guard !preview else { status = "Mark up again"; return }
        guard let f = ShotJournal.markAgain else { status = "Mark up again is not ready yet"; return }
        f(p, ShotJournal.dir(p.id))
    }

    /// ⌘C: one clipboard item with the picture and the text an agent reads (with shot.png's path, for a terminal).
    func copyShotForAgent() {
        guard let p = currentShot else { return }
        let u = ShotJournal.png(p.id)
        let text = p.agentText(path: u.path, screenText: false)
        guard !preview else { status = "On the clipboard · picture and \(text.count) characters"; return }
        guard let png = try? Data(contentsOf: u) else {
            History.copy(text); status = "On the clipboard · text only, shot.png is gone"; return
        }
        History.copy(text) { pb in Capture.pictureWriter(png)(pb); pb.setString(text, forType: .string) }
        status = "On the clipboard · picture and \(text.count) characters"
    }

    /// ⌘O: shot.png in Finder.
    func showShotFile() {
        guard let p = currentShot else { return }
        let u = ShotJournal.png(p.id)
        guard FileManager.default.fileExists(atPath: u.path) else { status = "shot.png is gone"; return }
        guard !preview else { status = "In Finder"; return }
        NSWorkspace.shared.activateFileViewerSelecting([u])
    }
}

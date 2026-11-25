// Drafter as a proper app (2026-10-21, Andrii: "make it like a proper app; things are overlapping and confusing"):
// one window, opened from the Dock or the menu. Since the look round "Tape" (14 November 2026) it is one tape: what he
// copied, typed and said, and his calls and long notes, newest first, with the big field on top that searches it and,
// after ⌘K, takes a command (engine /command). Shortcuts, Settings and Help open as pages in the same window, Esc goes
// back. The tape itself is drawn in TapeWindow.swift. The app shows in the Dock and ⌘-Tab only while the window is
// open; closing it leaves Drafter running in the menu bar as before.
import AppKit
import SwiftUI
import AVFoundation
import EventKit

final class AppWindow: NSObject, NSWindowDelegate {
    static let shared = AppWindow()
    private var window: NSWindow?
    private var tick: Timer?
    private var keyMonitor: Any?
    private var pinchMonitor: Any?
    let model = WindowModel()

    func show() {
        if window == nil {
            // no toolbar: the field is the first thing in the window; the title bar is transparent over the content
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1040, height: 760),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
            w.title = "Drafter"; w.titleVisibility = .hidden; w.titlebarAppearsTransparent = true; w.isReleasedWhenClosed = false
            w.backgroundColor = Native.paper; w.titlebarSeparatorStyle = .none
            w.minSize = NSSize(width: JournalLayout.minWindow.w, height: JournalLayout.minWindow.h)
            w.contentViewController = NSHostingController(rootView: WindowView().environmentObject(model))
            w.center(); w.setFrameAutosaveName("DrafterWindow"); w.delegate = self
            // the frame kept per screen (soft round): a screen of another size gets its own
            if let v = w.screen?.visibleFrame, let f = UserDefaults.standard.string(forKey: "window.frame." + JournalLayout.screenKey(v)) {
                w.setFrame(JournalLayout.restore(NSRectFromString(f), visible: v), display: false)
            }
            window = w
            // the journal's keys (StreamKeys.route): before the field or the editor sees them
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
                guard let self, let w = self.window, e.window === w else { return e }
                return self.model.key(e) ? nil : e
            }
            // a pinch on the journal steps the semantic zoom (StreamZoomRules)
            pinchMonitor = NSEvent.addLocalMonitorForEvents(matching: .magnify) { [weak self] e in
                guard let self, e.window === self.window, self.model.page == .tape else { return e }
                if e.phase == .began { self.model.stream.pinch = StreamZoomRules.Pinch() }
                self.model.pinchZoom(Double(e.magnification))
                return nil
            }
        }
        // the app he came from: Insert puts the text there
        if let front = PutBack.remember() { model.origin = front }
        model.reload()
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        model.focusField += 1
        // engine state and a recording that is still going are kept fresh while the window is open
        var n = 0
        tick?.invalidate()
        tick = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] t in
            // closed: the tick stops (show() starts it again) instead of waking the app every 3 s for good;
            // minimised it waits, as before
            guard let self, let w = self.window, w.isVisible || w.isMiniaturized else { t.invalidate(); self?.tick = nil; return }
            guard w.isVisible else { return }
            self.model.setEngine(Engine.shared.ready ? "" : Engine.shared.info)
            n += 1
            if self.model.docs.contains(where: \.live) || (self.model.page == .doc && n % 3 == 0) || n % 10 == 0 { self.model.loadDocs() }
        }
        model.setEngine(Engine.shared.ready ? "" : Engine.shared.info)
        log("window: opened")
        // the window as it was drawn on this pass (the rows it had; fresh ones follow from reload)
        let t0 = Date()
        model.openedAt = t0; model.firstAnswer = nil
        DispatchQueue.main.async { log("window: first draw \(Int(Date().timeIntervalSince(t0) * 1000)) ms, \(self.model.rows.count) rows") }
    }

    func toggle() { (window?.isVisible ?? false) && NSApp.isActive ? window?.performClose(nil) : show() }
    var isVisible: Bool { window?.isVisible ?? false }
    func isOwnWindow(_ obj: Any?) -> Bool { guard let w = window, let o = obj as? NSWindow else { return false }; return o === w }

    func windowDidEndLiveResize(_ n: Notification) { keepFrame() }
    func windowDidMove(_ n: Notification) { keepFrame() }
    private func keepFrame() {
        guard let w = window, let v = w.screen?.visibleFrame else { return }
        UserDefaults.standard.set(NSStringFromRect(w.frame), forKey: "window.frame." + JournalLayout.screenKey(v))
    }

    func windowWillClose(_ n: Notification) {
        model.player?.stop(); model.stopPlaying(); tick?.invalidate(); tick = nil
        // the Screen and Links pages poll every second while shown: closing the window leaves them (review 2026-11-22)
        if model.page == .screen || model.page == .links { model.page = .tape }
        DispatchQueue.main.async { NSApp.setActivationPolicy(.accessory) }
    }
}

final class WindowModel: ObservableObject {
    /// Where the window is: the tape, or a page over it (Esc goes back).
    enum Page { case tape, doc, names, links, screen, dictionary, shortcuts, settings, help }
    var preview = false
    @Published var page: Page = .tape
    // calls and long notes as documents (Recordings.swift)
    @Published var docs: [CallDoc] = []
    @Published var doc: CallDoc?
    @Published var playing: String?
    /// The line being played (changes once per line, not on every tick of the playhead).
    @Published var playTurn: Int?
    /// The playhead lives in `live`: its 0.4 s tick redraws the Play button's time, not the whole window.
    var playhead: Double { get { live.playhead } set { live.playhead = newValue } }
    /// What changes often and only a small view shows: the status line and the playhead (native round, 16 November
    /// 2026: each status change and each playhead tick rebuilt the whole window, 55 and 180 ms).
    let live = LiveLine()
    @Published var engine = ""
    @Published var focusField = 0
    var players: [AVAudioPlayer] = []
    var playTimer: Timer?
    /// The search text lives in a small object of its own (window2 round, 16 November 2026): a key redraws the field,
    /// not the window. The window redraws when the answer lands (the list, the counts publish then). On other pages
    /// (a recording, the settings) a key still redraws the page, as before.
    let queryBox = QueryBox()
    /// Direction C: the journal as one stream (app/Stream.swift).
    let stream = StreamState()
    var query: String {
        get { queryBox.text }
        set {
            guard newValue != queryBox.text else { return }
            if page != .tape { objectWillChange.send() }
            queryBox.text = newValue
            if open != nil { open = nil }
            queryChanged()
        }
    }
    // the journal (TapeWindow.swift, JournalModel.swift, StreamModel.swift, Stream.swift)
    @Published var rows: [TapeItem] = [] { didSet { facetCache = nil; rowColsCache = nil; rowsGen &+= 1; TagPrefs.shared.count(rows) } }   // every item, built (newest first)
    /// Changes whenever `rows` does (caches over the rows key on it).
    private(set) var rowsGen = 0
    /// The few row fields a search key reads, one array each, made once per change of the rows (window2 round,
    /// 16 November 2026: reading `rows[i].id` copied the whole item, and that copy per row per key was most of a key).
    struct RowCols { var ids: [String] = []; var rec: [Bool] = []; var kind: [String] = []; var chunk: [String] = [] }
    private var rowColsCache: RowCols?
    var rowCols: RowCols {
        if let c = rowColsCache { return c }
        var c = RowCols()
        c.ids.reserveCapacity(rows.count); c.rec.reserveCapacity(rows.count); c.kind.reserveCapacity(rows.count); c.chunk.reserveCapacity(rows.count)
        rows.withUnsafeBufferPointer { b in
            for i in b.indices { c.ids.append(b[i].id); c.rec.append(b[i].doc != nil); c.kind.append(b[i].kind.word); c.chunk.append(b[i].chunk) }
        }
        rowColsCache = c
        return c
    }
    /// Each row's facet, made once per change of the rows (a place or a key made all of them again).
    var facetCache: [TapeFacet]?
    var facets: [TapeFacet] {
        if let f = facetCache { return f }
        let p = TagPrefs.shared
        let f = rows.map { r -> TapeFacet in var f = r.facet; f.tags = p.shown(f.tags); return f }   // hidden tags filter nothing
        facetCache = f; return f
    }
    @Published var lines: [JLine] = []            // the outline as shown: only what is unfolded
    @Published var chosen: String?                // the chosen line (an item, a header, a session)
    @Published var open: String?                  // the item open in place (the reader closed)
    @Published var picked: [String] = []          // items picked with ⇧↑ ⇧↓ (Combine)
    @Published var commandMode = false
    @Published var tapeTick = 0                   // a redraw without new items (a pin, playback)
    @Published var buildTick = 0
    @Published var width: CGFloat = 1040
    @Published var nav = StreamKeys.State()
    @Published var results = 0
    @Published var editing: String?               // the item in the editor; "new": a Combine draft
    @Published var draft = ""
    @Published var showOriginal = false
    // the stream: Go to (⌘T), back and forward (app/StreamModel.swift)
    @Published var palette: String?               // Go to (⌘T) is open with this text
    @Published var paletteIndex = 0
    /// Wire round: the reader's focus on a thing found in the chosen text (⌥↓ ⌥↑), its actions list (↵), for which
    /// item; the things found in the text the reader shows (app/JournalFound.swift).
    @Published var foundFocus = FoundFocus()
    var foundFocusId: String?
    var foundCache: (id: String, sig: Int, found: [Found])?
    var history = JournalLayout.History()
    var historyMuted = false
    var previewPastes: [PasteTrail.Paste] = []      // the preview's made-up paste trail
    var journal = JournalBuild()
    lazy var journalStore = JournalStore(url: preview ? nil : Home.data.appendingPathComponent("journal.json"))
    var origin: NSRunningApplication?             // the app he came from (Insert puts the text there)
    var now = Date().timeIntervalSince1970
    var tapeSeq = 0
    var gone: (item: TapeItem, until: DispatchWorkItem)?
    @Published var goneIds: Set<String> = []
    var undos: [(name: String, run: () -> Void)] = []
    var firstPaint: Double?
    var previewPins: Set<String> = []
    var previewTagFile: URL?        // the preview's tags on disk (a temporary file)
    var previewDefer = false        // the preview measures the real path: tags after the first paint
    var fillMs = 0.0                // how long the last fill of missing tags took
    var combineSources: [String] = []
    @Published var takes: [Entry] = []
    @Published var clips: [Entry] = []
    @Published var typed: [Entry] = []
    @Published var today: [String: Int] = [:]
    /// What each typing feature earned in the last 7 days, and today's voice takes ("takes"), from data/app.log;
    /// nil until the first read is done (off the main thread, `loadStats`).
    @Published var stats: [String: LogStats.Count]?
    /// Side warnings a recording logged while it ran, by recording, for Calls & notes (`loadWarnings`).
    @Published var warnings: [String: [String]] = [:]
    /// Recordings sent to Read again from this window, until their transcript shows.
    @Published var rereading: [String: Date] = [:]
    @Published var settings = Drafter.shared.settings
    /// The status line. It clears itself after a few seconds, unless it says something still running: playback (until
    /// it ends), a line ending in "…", or the command options it sits under (13 November: "Playing · 6 s" stayed for
    /// minutes after the clip ended).
    var status: String {
        get { live.status }
        set { guard newValue != live.status else { return }; live.status = newValue; settleStatus() }
    }
    private var statusSeq = 0
    // the line at the top
    @Published var command = "" { didSet { seq += 1; options = []; thinking = false } }
    @Published var options: [[String: Any]] = []
    @Published var thinking = false
    var player: AVAudioPlayer?
    private var seq = 0

    // The history files as the window reads them, followed (QuickRead.swift): an open reads only what was appended
    // since the last one. Touched only on `readQueue`.
    private static let readQueue = DispatchQueue(label: "drafter.window-read", qos: .userInitiated)
    private static let follow = (takes: JSONLFollow(History.takesFile, keep: 500), clips: JSONLFollow(History.clipFile, keep: 300),
                                 typed: JSONLFollow(History.typedFile, keep: 600), drafts: JSONLFollow(History.draftsFile, keep: 600))
    private static let journalDB = JournalDBRead(Home.data.appendingPathComponent("journal.sqlite"))
    private var reloadSeq = 0
    /// The engine line, written only when it changes (the 3 s tick wrote the same line and redrew the window).
    func setEngine(_ s: String) { if engine != s { engine = s } }
    /// Window opened: when (for the first-draw and first-answer lines in the log).
    var openedAt: Date?
    var firstAnswer: (from: Date, query: String)?

    /// The history and the recordings, read off the main thread (speed round, 15 November 2026: every open read the
    /// three files whole and every recording on the main thread); the window shows what it had meanwhile.
    func reload() {
        settings = Drafter.shared.settings
        reloadSeq += 1
        let mine = reloadSeq, t0 = Date(), useDB = !preview && settings.journalDB
        Self.readQueue.async {
            let f = Self.follow
            f.drafts.refresh()
            // typed, takes and clipboard from data/journal.sqlite with `journalDB` on, each file from JSONL whenever
            // the database is behind it (app/JournalDB.swift); drafts.jsonl stays JSONL (not in phase 1)
            var fromDB: [String] = []
            func rows(_ store: String, _ fl: JSONLFollow, _ n: Int) -> [[String: Any]] {
                let r = JournalDBRules.pick(on: useDB, db: { Self.journalDB.newest(store, file: fl.url, n: n) },
                                            jsonl: { fl.refresh(); return fl.newest(n) })
                if r.fromDB { fromDB.append(store) }
                return r.rows
            }
            let hidden = DraftHide.load(History.hiddenFile)
            let takes = rows("takes", f.takes, 500).compactMap { Entry.voice($0) }
            let clips = rows("clipboard", f.clips, 300).enumerated().compactMap { i, r in Entry.clip(r, id: "c\(i)") }
            // what he typed: one row per message, its drafts folded into it (TypedList); the files stay as they are
            let typed = TypedList.build(sent: DraftHide.drop(rows("typed", f.typed, 600), kind: "sent", hidden: hidden),
                                        drafts: DraftHide.drop(f.drafts.newest(600), kind: "draft", hidden: hidden))
            let docs = WindowModel.readDocs()
            let ms = Int(Date().timeIntervalSince(t0) * 1000)
            DispatchQueue.main.async {
                guard mine == self.reloadSeq else { return }
                // a reopen with nothing new: no new lists, no build, no redraw (it rebuilt the journal every time)
                let same = takes == self.takes && clips == self.clips && typed == self.typed
                if !same { self.takes = takes; self.clips = clips; self.typed = typed }
                let today = ["typed": typed.filter { $0.title.isEmpty && Calendar.current.isDateInToday($0.when) }.count]
                if today != self.today { self.today = today }
                self.loadStats()
                self.applyDocs(docs, rebuild: !same)
                log("window: reload \(ms) ms off the main thread\(same ? ", nothing new" : "")\(fromDB.isEmpty ? "" : ", journal db: " + fromDB.joined(separator: " "))")
            }
        }
    }

    // MARK: numbers from the log, off the main thread

    private static var statsCache: (at: Date, value: [String: LogStats.Count])?
    private static var statsBusy = false
    /// Reads data/app.log on a utility queue at most every 5 minutes; the window shows the last numbers meanwhile.
    func loadStats() {
        guard !preview else { return }
        if let c = Self.statsCache { stats = c.value; if Date().timeIntervalSince(c.at) < 300 { return } }
        guard !Self.statsBusy else { return }
        Self.statsBusy = true
        DispatchQueue.global(qos: .utility).async {
            let now = Date()
            let lines = WindowModel.logTail()
            let value = LogStats.count(lines, since: LogStats.stamp(now.addingTimeInterval(-7 * 86_400)), today: String(LogStats.stamp(now).prefix(10)))
            DispatchQueue.main.async {
                Self.statsCache = (now, value); Self.statsBusy = false
                self.stats = value
            }
        }
    }

    /// The end of data/app.log as lines (the last 12 MB: more than a week).
    static func logTail() -> [Substring] {
        guard let h = FileHandle(forReadingAtPath: Home.data.appendingPathComponent("app.log").path) else { return [] }
        let size = (try? h.seekToEnd()) ?? 0
        try? h.seek(toOffset: size > 12_000_000 ? size - 12_000_000 : 0)
        let text = String(decoding: h.readDataToEndOfFile(), as: UTF8.self); try? h.close()
        return text.split(separator: "\n")
    }

    /// The side warnings logged while a recording ran, read once per recording off the main thread.
    func loadWarnings(_ d: CallDoc) {
        guard !preview, warnings[d.id] == nil, !d.live else { return }
        warnings[d.id] = []
        let from = LogStats.stamp(d.started), to = LogStats.stamp(d.started.addingTimeInterval(max(d.secs, 60) + 120))
        DispatchQueue.global(qos: .utility).async {
            let w = LogStats.warnings(WindowModel.logTail(), from: from, to: to)
            DispatchQueue.main.async { self.warnings[d.id] = w }
        }
    }

    private func settleStatus() {
        statusSeq += 1
        let mine = statusSeq
        guard !status.isEmpty, !preview else { return }
        func check() {
            guard mine == statusSeq, !status.isEmpty else { return }
            if status.hasPrefix("▶") {
                if player?.isPlaying == true { DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: check) } else { status = "" }
                return
            }
            if status.hasSuffix("…") || thinking || !options.isEmpty { DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: check); return }
            status = ""
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + (status.hasPrefix("▶") ? 0.5 : 5), execute: check)
    }

    func copy(_ e: Entry) { History.copy(e.text); status = "On the clipboard · \(e.text.count) characters" }

    func play(_ e: Entry) {
        player?.stop()
        let url = e.audio.hasSuffix(".wav") ? URL(fileURLWithPath: e.audio) : URL(fileURLWithPath: e.audio).appendingPathComponent("me.wav")
        guard FileManager.default.fileExists(atPath: url.path), let p = try? AVAudioPlayer(contentsOf: url) else { status = "Audio is no longer available (voice clips are kept for 14 days)"; return }
        player = p; p.play(); status = "▶ Playing · \(Int(p.duration)) s"; tapeTick += 1
    }

    func reread(_ e: Entry) {
        guard !preview else { return }
        Spool.reread(URL(fileURLWithPath: e.audio))
        rereading[e.audio] = Date()
        status = "Reading the recording again · a new note follows (the old transcript is kept beside it)"
    }

    func reveal(_ e: Entry) {
        let path = e.audio.isEmpty ? Home.data.path : e.audio
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    func save(_ change: (inout Settings) -> Void) {
        let st = Drafter.shared.change(change); settings = st
        MicCapture.keepReady = st.keepMic && st.voice; MicCapture.prepare()
        Drafter.shared.apply(); Menu.shared.refresh()
    }

    // MARK: the line at the top

    func plan() {
        let t = command.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { seq += 1; options = []; thinking = false; return }
        seq += 1; let mine = seq; thinking = true; status = ""; options = []
        Engine.shared.post("/command", ["text": t], timeout: t.hasPrefix(";accounts") ? 60 : 30) { j in
            guard mine == self.seq else { return }
            self.thinking = false
            self.options = (j?["options"] as? [[String: Any]]) ?? []
            self.status = self.options.isEmpty ? "No suggestions. Try rephrasing." : "\((j?["by"] as? String) == "haiku" ? "Haiku" : "on this Mac") · click to run"
            if LookupQuery.parse(t) != nil || (j?["by"] as? String) == "lookup" {
                if j == nil { self.status = "Search service is unavailable. Press Return to retry."; return }
                self.status = (j?["error"] as? String) ?? ((j?["source"] as? String ?? "") + " · " + (self.options.isEmpty ? (j?["status"] as? String ?? "No matches") : "choose a result to copy"))
            }
        }
    }

    func run(_ a: [String: Any]) {
        guard let r = a["run"] as? [String: Any], let kind = r["kind"] as? String else { return }
        let report: (String, Bool) -> Void = { text, ok in DispatchQueue.main.async { self.status = (ok ? "✓ " : "") + text; if ok { self.options = [] } } }
        switch kind {
        case "copy", "insert", "lookup.insert": History.copy(r["text"] as? String ?? ""); report("Copied · ⌘V to paste", true)
        case "snippet.save": Engine.shared.post("/snippet", ["key": r["key"] ?? "", "text": r["text"] ?? ""]) { j in report((j?["done"] as? String) ?? "Not saved", j != nil) }
        case "eventkit.event": Actions.event(r, report)
        case "eventkit.reminder": Actions.reminder(r, report)
        case "eventkit.free":
            Actions.freeSlots(r) { slots, err in
                guard let slots else { report(err ?? "Cannot check the calendar", false); return }
                if slots.isEmpty { report("No free slots", false); return }
                self.options = slots.map { ["chip": $0.chip, "run": ["kind": "eventkit.event", "title": r["title"] as? String ?? "Meeting",
                                                                    "start": $0.start, "minutes": r["minutes"] as? Int ?? 30] as [String: Any]] }
                self.status = "from your calendars · click to book"
            }
        case "none": status = a["chip"] as? String ?? ""
        default:
            status = "Working…"
            Engine.shared.post("/act", ["id": a["id"] ?? "", "fields": a["fields"] ?? [:]], timeout: 30) { j in
                report((j?["done"] as? String) ?? (j?["error"] as? String) ?? "Could not complete this", j?["done"] != nil)
            }
        }
    }
}

struct WindowView: View {
    @EnvironmentObject var m: WindowModel
    var titlebar = false   // the preview draws the window's three dots (a borderless window has none)
    @State private var fileOver = false   // a file dragged over the window
    var body: some View {
        GeometryReader { g in
            VStack(spacing: 0) {
                StreamBar(title: pageTitle)   // direction C: one bar, the pages in its menu (TopBar unused)
                Group {
                    switch m.page {
                    case .tape:
                        StreamView(q: m.queryBox, st: m.stream)
                    case .doc:
                        if let d = m.doc { DocView(d: d).id(d.id) } else { Color.clear }
                    case .settings: SettingsView()
                    case .help: HelpView()
                    case .names: NamesView()
                    case .links: LinksView()
                    case .screen: InspectorView()
                    case .dictionary: DictionaryView()
                    case .shortcuts: ShortcutsView()
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(width: g.size.width, height: g.size.height)
            .onAppear { m.width = g.size.width }
            .onChange(of: g.size.width) { _, w in m.width = w }
        }
        .overlay(alignment: .topLeading) {
            if titlebar {
                HStack(spacing: 8) { ForEach(0..<3, id: \.self) { _ in Circle().fill(UIInk.rule).frame(width: 12, height: 12) } }.padding(.leading, 14).padding(.top, 14)
            }
        }
        .background { WindowKeys() }
        // an audio or video file dropped anywhere on the window is transcribed (FileTranscribe)
        .onDrop(of: [.fileURL], isTargeted: $fileOver) { items in
            let box = FileDropBox(), g = DispatchGroup()
            for p in items {
                g.enter()
                _ = p.loadObject(ofClass: URL.self) { u, _ in if let u { box.add(u) }; g.leave() }
            }
            g.notify(queue: .main) { FileTranscribe.start(box.urls) }
            return true
        }
        .overlay {
            if fileOver {
                RoundedRectangle(cornerRadius: 12).strokeBorder(UIInk.blue, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                    .background(RoundedRectangle(cornerRadius: 12).fill(UIInk.paper.opacity(0.85)))
                    .overlay { Label("Drop to transcribe", systemImage: "waveform").font(NativeFont.text(15)).foregroundStyle(UIInk.ink) }
                    .padding(10).allowsHitTesting(false)
            }
        }
        .font(NativeFont.text(13)).foregroundStyle(UIInk.ink).tint(UIInk.blue)
        .background(UIInk.paper)
    }
    var pageTitle: String {
        switch m.page { case .doc: return m.doc?.title ?? ""; case .settings: return "Settings"; case .help: return "Help"; case .names: return "Names"; case .links: return "Links & Files"; case .screen: return "Screen"; case .dictionary: return "Dictionary"; case .shortcuts: return "Shortcuts"; case .tape: return "" }
    }
}

/// The keys of the window that work from anywhere in it, as hidden buttons. The journal's own keys (arrows, Return,
/// Esc, Tab, ⌘C, ⌘P, ⌘⌫, ⌘Z, ⌘T, ⌘[ ⌘], ⌘1-9) go through WindowModel.key and StreamKeys.route (JournalModel.swift).
struct WindowKeys: View {
    @EnvironmentObject var m: WindowModel
    func k(_ key: KeyEquivalent, _ mods: EventModifiers = .command, enabled: Bool = true, _ act: @escaping () -> Void) -> some View {
        Button("", action: act).keyboardShortcut(key, modifiers: mods).disabled(!enabled).opacity(0).frame(width: 0, height: 0).accessibilityHidden(true)
    }
    var body: some View {
        let it = m.current, tape = m.page == .tape
        ZStack {
            k("k") { m.startCommand() }
            k("f") { m.page = .tape; m.commandMode = false; m.nav.region = .search; m.focusField += 1 }
            k("n", [.command, .shift]) { m.show(.names) }; k("l", [.command, .shift]) { m.show(.links) }; k("i", [.command, .shift]) { m.show(.screen) }; k("d", [.command, .shift]) { m.show(.dictionary) }; k("j") { m.show(.shortcuts) }; k(",") { m.show(.settings) }; k("/") { m.show(.help) }
            k(.escape, [], enabled: !tape) { m.back() }
            k("l", enabled: (tape && it.map(m.hasAudio) == true) || (m.page == .doc && m.doc?.hasAudio == true)) {
                if m.page == .doc, let d = m.doc { m.playing == d.id ? m.stopPlaying() : m.play(d, from: 0) }
                else if let it { m.open = it.id; m.playPause(it) }
            }
            k("a", [.command, .shift], enabled: tape && it != nil) { m.copyForAgent() }
        }
    }
}

/// What the command line offers, under the field; a click runs one, or its number.
struct CommandOptions: View {
    @EnvironmentObject var m: WindowModel
    var body: some View {
        if !m.options.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(m.options.enumerated()), id: \.offset) { i, o in
                    Button { m.run(o) } label: {
                        HStack(spacing: 10) {
                            Text("\(i + 1)").font(NativeFont.mono(12)).foregroundStyle(UIInk.faint)
                            Text(o["chip"] as? String ?? "").font(NativeFont.text(15)).lineLimit(1)
                            Spacer()
                        }.padding(.horizontal, 16).padding(.vertical, 10).contentShape(Rectangle())
                    }.buttonStyle(.plain)
                    if i < m.options.count - 1 { Rectangle().fill(UIInk.line).frame(height: 1) }
                }
                HStack {
                    StatusText(live: m.live, font: NativeFont.mono(11), color: UIInk.faint)
                    Spacer()
                    Button("Close") { m.options = [] }.buttonStyle(.plain).font(NativeFont.text(12)).foregroundStyle(UIInk.muted)
                }.padding(.horizontal, 16).padding(.vertical, 8).background(UIInk.soft)
            }
            .background(.regularMaterial).clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(UIInk.line, lineWidth: 0.5) }
            .shadow(color: .black.opacity(0.12), radius: 12, y: 6)
        }
    }
}

struct KeyChip: View {
    let k: String
    init(_ k: String) { self.k = k }
    var body: some View {
        // the keycap: the key's face over a darker bottom edge, the tape's 6 pt corners
        let r = TapeDraw.keyRadius
        Text(k).font(NativeFont.mono(11, .medium)).foregroundStyle(UIInk.muted)
            .padding(.horizontal, 6).padding(.top, 2).padding(.bottom, 4)
            .background {
                ZStack(alignment: .top) {
                    RoundedRectangle(cornerRadius: r).fill(UIInk.keyEdge)
                    RoundedRectangle(cornerRadius: r).fill(UIInk.key).padding(.bottom, 2)
                }
            }
    }
}

/// The window's fast-changing words (native round): its own object, so only the views that show them redraw.
final class QueryBox: ObservableObject {
    @Published var text = ""
}

final class ChunkLine: ObservableObject {
    @Published var title = ""
    @Published var sub = ""
    @Published var id = ""
}

final class LiveLine: ObservableObject {
    @Published var status = ""
    @Published var playhead: Double = 0
}

/// The status text: redraws on its own when the status changes.
struct StatusText: View {
    @ObservedObject var live: LiveLine
    var font: Font
    var color: Color
    var fallback = ""
    var body: some View {
        Text(live.status.isEmpty ? fallback : live.status).font(font).foregroundStyle(color).lineLimit(1)
    }
}

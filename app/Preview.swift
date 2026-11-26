// Native rendering checks with synthetic data. Never launches the app delegate or either engine.
import AppKit
import SwiftUI

enum UIShots {
    static func save(_ view: NSView, _ path: String) throws {
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw NSError(domain: "Preview", code: 1) }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else { throw NSError(domain: "Preview", code: 2) }
        try data.write(to: URL(fileURLWithPath: path))
    }
    static func run(_ folder: String, dark: Bool) throws {
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        NSApp.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        // PREVIEW_ONLY=quick (or window, settings, strip): one surface, for a quick look while working on it
        let only = ProcessInfo.processInfo.environment["PREVIEW_ONLY"] ?? ""
        if only == "shotjournal" { try shotJournalShots(folder, dark: dark); return }   // the screenshot tool's journal cards
        if only == "knowledge" { try EntityPreview.run(folder); return }   // the entity card, the mark and the context preview
        if only == "names" { try namesShots(folder, dark: dark); return }
        if only == "markup" { try markupShots(folder); return }   // the markup editor with pen strokes (PreviewMarkup.swift)   // the Names page (made-up names)
        if only == "window" { try windowShots(folder, dark: dark); return }
        if only == "stream" { try streamShots(folder, dark: dark); return }   // the journal stream (PreviewStream.swift)
        // the strip style in use for these renders (never read from the settings file): STRIP_STYLE, default composer
        if Pill.shared.forced == nil { Pill.shared.forced = StripStyle.of(ProcessInfo.processInfo.environment["STRIP_STYLE"]) }
        if only == "pick" { try PickPanel.shared.preview(folder); return }   // Pick parts (made-up texts)
        if only == "strip" { try Pill.shared.preview(folder); return }
        if only == "record" { try RecordPreview.run(folder, dark: dark); return }   // the recording window and the small notch
        if only == "record-window" { try RecordPreview.run(folder, dark: dark, windowOnly: true); return }   // the recording window alone
        if only == "strips" { try stripStyles(folder); return }   // every style, both themes, and the two contact sheets
        if only == "quick" { try Quick.shared.preview(folder); return }
        try Pill.shared.preview(folder)
        try Command.shared.preview(folder)
        try Quick.shared.preview(folder)
        try PickPanel.shared.preview(folder)
        try EntityPreview.run(folder)
        try onScreen(folder)
        try windowShots(folder, dark: dark)
        try shotJournalShots(folder, dark: dark)
        print("Native UI previews passed: " + folder)
    }

    /// Made-up rows for the journal (never his): one morning today in detail (clips, drafts, voice notes, a chat
    /// export, a web page with its navigation, three repeats), then older days in sessions back `days` days.
    static func sampleTape(_ m: WindowModel, now: Double, days: Int = 420, perDay: Int = 6) {
        let cal = TapeBuild.cal
        let today = cal.startOfDay(for: Date(timeIntervalSince1970: now))
        func at(_ h: Int, _ min: Int, back: Int = 0, s: Int = 14) -> Date {
            cal.date(byAdding: .second, value: (h * 60 + min) * 60 + s, to: cal.date(byAdding: .day, value: -back, to: today)!)!
        }
        func e(_ id: String, _ h: Int, _ mi: Int, _ app: String, _ text: String, secs: Double = 0, back: Int = 0) -> Entry {
            Entry(id: id, when: at(h, mi, back: back), app: app, text: text, audio: "", secs: secs)
        }
        var clips = [e("c1", 12, 38, "Safari", "https://example.org/station/review-14#plan"),
                     e("c5", 12, 30, "Preview", "Image · 640 × 400"), e("c6", 12, 27, "Finder", NSHomeDirectory() + "/Desktop/station-drawings-final.pdf"),
                     e("c2", 12, 4, "Mail", "Room 4.12, second floor, the door on the left"),
                     e("c3", 11, 9, "Xcode", "let share = taken / shown"),
                     e("c4", 10, 31, "Mail", "Mila Synthetic, +380 00 000 00 00, Tuesday after 14:00"),
                     e("c7", 10, 2, "Telegram", "[14.11.26, 10:01] Sava Synthetic: Lantern build is green, can you look at the order form today?"),
                     e("c8", 9, 41, "Safari", "Skip to content\nHome\nProducts\nPricing\nBlog\nSign in\nThe station map shows every platform, lift and exit in one view, updated each night.\nMore text."),
                     e("c9", 9, 33, "Figma", "Lantern order form, step 2"), e("c10", 9, 32, "Figma", "Lantern order form, step 2"),
                     e("c11", 9, 31, "Figma", "Lantern order form, step 2")]
        clips[0].clip = .link; clips[0].clipTitle = "Station review 14"
        if let p = try? Quick.samplePicture() { clips[1].clip = .image; clips[1].picture = p.name; clips[1].bytes = p.bytes; clips[1].ocr = p.ocr }
        clips[2].clip = .file; clips[2].bytes = 482_113
        clips[7].clipTitle = "Station map · Example Transit"
        var typed = [e("t1", 12, 41, "Telegram", "Could you send the final drawings by three? I will look before the call."),
                     e("t2", 12, 20, "Claude", "Rewrite this paragraph in plain English, at most 40 words, keep it warm"),
                     e("t3", 11, 22, "Terminal", "git commit -m \"journal: sessions under chunks of time\""),
                     e("t4", 11, 2, "Messages", "See you at the station at nine, I will bring the drawings."),
                     e("t5", 10, 15, "Claude", "Can you check the contrast of the grey text in both themes? Mila asked for it."),
                     e("t6", 9, 52, "Slack", "Warm, but not formal - we write the way people talk"),
                     e("t7", 9, 36, "Telegram", "Привіт, Саво! Форму Lantern подивлюсь до обіду, напишу що не так.")]
        typed[3].drafts = ["See you at the", "See you at the station at ten", "See you at the station at nine"]
        typed[0].started = typed[0].when.addingTimeInterval(-74); typed[1].started = typed[1].when.addingTimeInterval(-41)
        typed[3].started = typed[3].when.addingTimeInterval(-128); typed[6].started = typed[6].when.addingTimeInterval(-63)
        var takes = [e("v1", 12, 31, "Notes", "Note after the review: we keep the journal and drop the three panes. Button words should be simpler. Mila does the second round by Tuesday.", secs: 18),
                     e("v2", 11, 36, "Calendar", "Remind me on Monday to send the invoice to the studio", secs: 6),
                     e("v3", 10, 47, "Notes", "Idea: show the grey text only after half a second of pause, not on every letter", secs: 9)]
        takes[0] = Entry(id: "v1", when: takes[0].when, app: "Notes", text: takes[0].text, audio: "/sample/take.wav", secs: 18)
        takes[0].raw = "Note after the review: well, we keep the journal and, um, drop the three panes. Button words should be simpler. Mila does the second round by Tuesday."
        // older days: sessions of made-up lines, back `days` days
        let lines: [(String, String)] = [
            ("Telegram", "Ok, I will send the drawings tonight"), ("Telegram", "Завтра о десятій на станції, беру ноутбук"),
            ("Claude", "Summarise the Lantern order notes in five bullets"), ("Claude", "Write a short reply to Mila, warm and clear"),
            ("Mail", "Thanks, the invoice is attached. Payment within 14 days."), ("Mail", "Зустріч переносимо на четвер, 15:00"),
            ("Figma", "Order form, empty state"), ("Safari", "https://example.org/docs/lantern-gate"), ("Notes", "Plan for the week: form, map, invoice"),
            ("Slack", "Can someone review the station map before Friday?"), ("Notes", "Ідея: показувати сесії, а не години"),
            ("Terminal", "npm run test -- lantern"), ("Mail", "Sava Synthetic, design review notes"), ("Claude", "Check this paragraph for tone")]
        var r: UInt64 = 7
        func next(_ n: Int) -> Int { r = r &* 6364136223846793005 &+ 1442695040888963407; return Int((r >> 33) % UInt64(max(1, n))) }
        var k = 0
        for back in 1...max(1, days) {
            let n = back <= 14 ? perDay : next(perDay + 1)
            guard n > 0 else { continue }
            var h = 8 + next(3), mi = next(50)
            for j in 0..<n {
                let (app, text) = lines[next(lines.count)]
                if j > 0 { if next(3) == 0 { h += 1 + next(3); mi = next(40) } else { mi += 2 + next(7) } }
                if h > 22 { break }
                if mi >= 60 { h += 1; mi -= 60 }
                var x = e("o\(k)", h, mi, app, text + (back % 7 == 0 && j == 0 ? "" : ""), secs: 0, back: back); k += 1
                switch next(4) {
                case 0: if app == "Safari" { x.clip = .link }; clips.append(x)
                case 1: x = Entry(id: x.id, when: x.when, app: app, text: text, audio: "", secs: Double(4 + next(30))); takes.append(x)
                default: x.started = x.when.addingTimeInterval(-Double(20 + next(200))); typed.append(x)
                }
            }
        }
        m.clips = clips.sorted { $0.when > $1.when }; m.typed = typed.sorted { $0.when > $1.when }; m.takes = takes.sorted { $0.when > $1.when }
    }

    /// A made-up entity store for the preview: people, a studio, a project and its Worker (a twin: shows as the
    /// project), relations with reasons; "Mark" points to two people and the store's flags leave it undecided (no tag).
    static func sampleEntities() -> EntityStore {
        func e(_ id: String, _ kind: String, _ name: String, _ who: String) -> Entity { var x = Entity(id: id, kind: kind, name: name); x.who = who; return x }
        var mila = e("p:mila", "person", "Mila Synthetic", "designer on the station project")
        mila.relations = [EntityRelation(id: "o:studio", why: "works at", w: 0.9), EntityRelation(id: "x:lantern", why: "similar topics: order form, drawings", w: 0.5)]
        var sava = e("p:sava", "person", "Sava Synthetic", "builds the Lantern order form")
        sava.relations = [EntityRelation(id: "x:lantern", why: "works on", w: 0.95), EntityRelation(id: "p:mila", why: "often together in chats", w: 0.6)]
        var lantern = e("x:lantern", "project", "Lantern", "ordering tool for a made-up studio")
        lantern.relations = [EntityRelation(id: "o:studio", why: "part of", w: 0.9), EntityRelation(id: "p:sava", why: "built by", w: 0.8)]
        lantern.twins = ["t:gate"]
        var gate = e("t:gate", "tool", "lantern-gate", "the Worker behind Lantern"); gate.twin_of = "x:lantern"
        let recs = [mila, sava, lantern, gate, e("p:mark1", "person", "Mark Sample", ""), e("p:mark2", "person", "Mark Other", ""),
                    e("o:studio", "org", "Example Studio", "a made-up design studio")]
        func h(_ i: Int, _ how: String = "name") -> [EntityHit] { [EntityHit(index: i, how: how)] }
        return EntityStore(records: recs, surfaces: ["mila synthetic": h(0), "mila": h(0, "first"), "sava synthetic": h(1), "sava": h(1, "first"), "саво": h(1, "first"),
                                                     "lantern": h(2), "lantern-gate": h(3), "mark": h(4, "first") + h(5, "first")],
                           flags: ["mark": EntitySurfaceFlags(needs_context: true, shared: true)])
    }

    /// The journal: three panes, chunks of time, sessions; the reader, the editor, a search, Group by, both
    /// densities, the sidebar shut, a narrow window, a long scroll; the pages. Counts lines per screen.
    /// The Names page on made-up names: the list, a search, a spelling being fixed, a merge being picked, after a hide
    /// with its undo, the hidden ones, a narrow window.
    static func namesShots(_ folder: String, dark: Bool) throws {
        let model = WindowModel(); model.preview = true
        let s = NamesStore.shared; s.preview = true; s.use(NamesPreview.sample())
        let host = NSHostingView(rootView: WindowView(titlebar: true).environmentObject(model).environment(\.colorScheme, dark ? .dark : .light))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 760), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host; host.frame = NSRect(x: 0, y: 0, width: 1280, height: 760); model.width = 1280
        func shot(_ name: String, wait: Double = 0.25) throws { RunLoop.current.run(until: Date().addingTimeInterval(wait)); try save(host, folder + "/" + name + ".png") }
        model.show(.names); try shot("names")
        s.query = "ган"; try shot("names-search")
        s.query = ""; s.chosen = "p2"; s.editing = "p2"; try shot("names-edit")
        s.editing = nil; s.chosen = "p1"; s.merging = "p4"; s.kind = ""; try shot("names-merge")
        s.merging = nil; s.hide("p3"); try shot("names-hidden-notice")
        s.kind = "hidden"; try shot("names-hidden")
        s.undo(); s.kind = ""
        host.frame = NSRect(x: 0, y: 0, width: 1280, height: 760); model.width = 1280
        // the Dictionary page on made-up words: the list, a search, a word being edited, after a removal with its undo
        let d = DictStore.shared; d.preview = true; d.use(DictPreview.file, waiting: DictPreview.waiting)
        model.show(.dictionary); d.chosen = d.rows.first?.id; try shot("dictionary")
        d.query = "glimmer"; try shot("dictionary-search")
        d.query = ""; d.chosen = "word:bramblix"; d.editing = "word:bramblix"; try shot("dictionary-edit")
        d.editing = nil; d.remove("word:orest"); try shot("dictionary-removed")
        d.undo()
        host.frame = NSRect(x: 0, y: 0, width: 760, height: 760); model.width = 760; try shot("names-narrow")
        s.notice = ""
    }

    static func windowShots(_ folder: String, dark: Bool, short: Bool = false) throws {
        let cal = TapeBuild.cal
        let now = cal.date(from: DateComponents(year: 2026, month: 11, day: 14, hour: 12, minute: 45))!.timeIntervalSince1970
        Entities.previewStore = sampleEntities()
        defer { Entities.previewStore = nil }
        TapeBuild.tagCache = [:]
        let model = WindowModel(); model.preview = true; model.now = now
        // made-up numbers for Settings (the real ones come from data/app.log)
        model.stats = [LogStats.suggest: .init(shown: 8400, taken: 410), LogStats.next: .init(shown: 140, taken: 12),
                       LogStats.rework: .init(shown: 5, taken: 4), LogStats.typo: .init(shown: 380, taken: 130),
                       LogStats.fixWord: .init(shown: 680, taken: 28), LogStats.layout: .init(shown: 18, taken: 18), "takes": .init(shown: 7, taken: 0)]
        sampleTape(model, now: now, days: 420, perDay: 5)
        var docs = try sampleDocs()
        docs[0].started = cal.date(bySettingHour: 11, minute: 48, second: 0, of: Date(timeIntervalSince1970: now))!
        docs[0].secs = 92 * 60 / 10
        docs[1].started = Date(timeIntervalSince1970: now - 86400 + 3600); docs[1].secs = 4 * 60 + 10
        docs[2].started = Date(timeIntervalSince1970: now - 3 * 86400)
        model.docs = docs
        model.previewPins = ["t:t6"]
        model.journalStore.change("v:v3", to: "Idea: show the grey text only after half a second of pause, never on every letter.", original: model.takes.first { $0.id == "v3" }?.text ?? "")
        model.rebuildTape()
        let host = NSHostingView(rootView: WindowView(titlebar: true).environmentObject(model).environment(\.colorScheme, dark ? .dark : .light))
        let window = PreviewKeyWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 1000), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        host.frame = NSRect(x: 0, y: 0, width: 1280, height: 1000)
        model.width = 1280
        func shot(_ name: String, wait: Double = 0.15) throws {
            RunLoop.current.run(until: Date().addingTimeInterval(wait)); try save(host, folder + "/" + name + ".png")
        }
        // the journal as one stream (stream round, 23 November 2026): PreviewStream.swift
        try streamScenes(model, host: host) { n, w in try shot(n, wait: w) }
        try shot("window", wait: 0.3)
        if short { model.show(.settings); try shot("settings"); return }
        // 12 a narrow window: the reader closed by itself
        model.startCommand(); model.command = "book 30 min with Mila tomorrow"
        model.options = [["chip": "Book «Design review» tomorrow 10:00-10:30"], ["chip": "Find a free 30 min slot tomorrow"]]
        model.status = "Haiku · click to run"
        try shot("command-options")
        model.commandMode = false; model.command = ""; model.options = []; model.status = ""
        // the pages: a call, its search, a long note, a call with no words
        model.openDoc(model.docs[0]); try shot("recordings", wait: 0.3)
        // the same call with its details and a named speaker (17 November 2026)
        var named = model.docs[0]
        named.app = "Microsoft Teams"; named.place = "Room 4"; named.project = "Atlas"; named.calendar = "Work"
        named.eventStart = named.started.timeIntervalSince1970; named.eventEnd = named.started.timeIntervalSince1970 + 1800
        named.speakers = ["Вони": "Mila Synthetic"]
        model.openDoc(named); try shot("recordings-details", wait: 0.3)
        model.openDoc(model.docs[0])
        model.query = "схем"; try shot("recordings-search", wait: 0.3)
        model.query = ""; model.openDoc(model.docs[1]); try shot("recordings-note", wait: 0.2)
        model.warnings[model.docs[2].id] = ["Your microphone gives only silence (muted or taken by another app?)"]
        model.openDoc(model.docs[2]); try shot("recordings-empty", wait: 0.3)
        NamesStore.shared.preview = true; NamesStore.shared.use(NamesPreview.sample())
        model.show(.names); try shot("names", wait: 0.3)
        // Wave 1 & Wave 2 pages: Links & Files Hub, Live Screen Inspector, Unified Entity Workspace, Dictionary, Gallery
        model.show(.links); try shot("links", wait: 0.4)
        model.show(.screen); try shot("screen", wait: 0.3)
        let dictStore = DictStore.shared; dictStore.preview = true; dictStore.use(DictPreview.file, waiting: DictPreview.waiting)
        model.show(.dictionary); dictStore.chosen = dictStore.rows.first?.id; try shot("dictionary", wait: 0.3)
        let sampleWorkspace: NameRules.Entry = [
            "id": "p:mila", "kind": "person", "uk": "Міла", "latin": "Mila Synthetic",
            "short": ["Mila"], "forms": ["Міли", "Мілі"], "heard": [String](),
            "phones": ["+380 00 000 00 00"], "emails": ["mila@example.test"], "links": [String](),
            "sources": ["sample"], "context": ["lines": 84, "chats": 5, "last_seen": "2026-11-14"],
            "weight": 99.0, "hidden": false, "card": false
        ]
        let wsHost = NSHostingView(rootView: EntityWorkspaceView(entry: sampleWorkspace)
            .environmentObject(model).foregroundStyle(UIInk.ink).tint(UIInk.blue)
            .background(UIInk.paper).environment(\.colorScheme, dark ? .dark : .light))
        let wsWin = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 880, height: 640), styleMask: [.borderless], backing: .buffered, defer: false)
        wsWin.contentView = wsHost; wsHost.frame = NSRect(x: 0, y: 0, width: 880, height: 640)
        RunLoop.current.run(until: Date().addingTimeInterval(0.45))
        try save(wsHost, folder + "/entity-workspace.png")
        model.show(.shortcuts); try shot("shortcuts")
        model.show(.settings); try shot("settings")
        let tall = NSHostingView(rootView: SettingsView().environmentObject(model).foregroundStyle(UIInk.ink).tint(UIInk.blue)
            .background(UIInk.paper).environment(\.colorScheme, dark ? .dark : .light))
        let tallWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1152, height: 2300), styleMask: [.borderless], backing: .buffered, defer: false)
        tallWindow.contentView = tall; tall.frame = NSRect(x: 0, y: 0, width: 1152, height: 2300)
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        try save(tall, folder + "/settings-all.png")
        // the same page with Advanced open (settings round, 17 November 2026)
        let open = NSHostingView(rootView: SettingsView(advanced: true).environmentObject(model).foregroundStyle(UIInk.ink).tint(UIInk.blue)
            .background(UIInk.paper).environment(\.colorScheme, dark ? .dark : .light))
        let openWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1152, height: 3200), styleMask: [.borderless], backing: .buffered, defer: false)
        openWindow.contentView = open; open.frame = NSRect(x: 0, y: 0, width: 1152, height: 3200)
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        try save(open, folder + "/settings-advanced.png")
        model.show(.help); try shot("help")
        let helpTall = NSHostingView(rootView: HelpView().environmentObject(model).foregroundStyle(UIInk.ink).background(UIInk.paper).environment(\.colorScheme, dark ? .dark : .light))
        let helpWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 2000), styleMask: [.borderless], backing: .buffered, defer: false)
        helpWindow.contentView = helpTall; helpTall.frame = NSRect(x: 0, y: 0, width: 760, height: 2000)
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        try save(helpTall, folder + "/help-all.png")
        model.back(); model.query = "no matching item"
        host.frame = NSRect(x: 0, y: 0, width: 760, height: 520); model.width = 760
        try shot("window-small-empty")
        model.query = ""
        // speed: a year and more of made-up rows: the build, then every key timed on its own through the journal's
        // search (the core) and the stream's lines. A key over 30 ms in the core, or a detector run while typing, fails.
        let big = WindowModel(); big.preview = true; big.now = now
        sampleTape(big, now: now, days: 730, perDay: 30)
        big.docs = docs
        TapeBuild.tagCache = [:]
        let t0 = Date(); big.rebuildTape()
        let buildMs = Date().timeIntervalSince(t0) * 1000
        let marksBefore = SearchMarkStore.shared.computed
        let tb = Date(); big.query = "zq"
        let indexMs = Date().timeIntervalSince(tb) * 1000, marked = SearchMarkStore.shared.computed - marksBefore
        big.query = ""
        var keys: [Double] = [], cores: [Double] = []
        let marksKeys = SearchMarkStore.shared.computed
        for q in ["s", "st", "sta", "stat", "stati", "station has:date", "has:money", "mentions:friday", "plan mentions:friday", "lantern", "links lantern", "@mila station"] {
            let t1 = Date(); big.query = q; keys.append(Date().timeIntervalSince(t1) * 1000); cores.append(big.searchSide.view.ms)
        }
        big.query = ""
        print("journal search keys: " + keys.map { String(format: "%.1f", $0) }.joined(separator: " ") + " · core " + cores.map { String(format: "%.1f", $0) }.joined(separator: " "))
        print(String(format: "journal speed: %d items · build %.0f ms · index with marks %.0f ms (%d rows read by the detector) · search per key avg %.1f ms, worst %.1f ms (core worst %.1f ms) · detector runs while typing %d",
                     big.rows.count, buildMs, indexMs, marked, keys.reduce(0, +) / Double(keys.count), keys.max() ?? 0, cores.max() ?? 0,
                     SearchMarkStore.shared.computed - marksKeys))
        if (cores.max() ?? 0) > 30 || SearchMarkStore.shared.computed != marksKeys {
            throw NSError(domain: "Preview", code: 30, userInfo: [NSLocalizedDescriptionKey: "journal search over 30 ms a key in the core, or the detector ran while typing"])
        }
    }

    /// Two fictional recordings in a temporary folder: a call with timed lines, both sides, audio and screenshots, and
    /// a long note without times. Their summaries come in as notes would (no data/notes file is read or written).
    static func sampleDocs() throws -> [CallDoc] {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("drafter-preview-calls")
        try? FileManager.default.removeItem(at: root)
        let call = root.appendingPathComponent("2026-10-30T09-00-00Z"), note = root.appendingPathComponent("2026-10-29T15-10-00Z")
        for d in [call, note] { try FileManager.default.createDirectory(at: d.appendingPathComponent("shots"), withIntermediateDirectories: true) }
        let now = Date().timeIntervalSince1970
        func json(_ o: Any, _ url: URL) throws { try JSONSerialization.data(withJSONObject: o).write(to: url) }
        try json(["call": true, "app": "Zoom", "started": now - 3 * 3600, "event": ["title": "Design review: voice strip", "people": ["mila"]]], call.appendingPathComponent("meta.json"))
        try json(["call": false, "app": "Figma", "started": now - 26 * 3600], note.appendingPathComponent("meta.json"))
        let rows: [(String, Double, String)] = [
            ("Я", 2, "Привіт! Покажу нову схему стрічки, вона вже в макеті."), ("Вони", 9, "Бачу. А де тут видно, що запис іде з обох боків?"),
            ("Я", 15, "Ось дві позначки рівня: я і вони. Якщо їхня мовчить хвилину, це видно одразу."), ("Вони", 31, "Добре. Тоді прибери слово Processing, коли текст уже вставлено."),
            ("Я", 44, "Так, там буде галочка замість мікрофона."), ("Вони", 58, "І таймер на пропозиції записати дзвінок, тонка лінія знизу."),
            ("Я", 71, "Домовились. Надішлю оновлену схему ввечері."), ("Вони", 80, "Супер, тоді в четвер подивимось разом.")]
        try json(rows.map { ["who": $0.0, "start": $0.1, "text": $0.2] }, call.appendingPathComponent("lines.json"))
        try "Я думаю, що головна сторінка має бути спокійнішою. Перше: менше рамок. Друге: пошук по всіх розмовах одразу, щоб за хвилину знайти, хто що сказав. Третє: одна кнопка, яка віддає все агенту разом зі скріншотами. Решту можна сховати в меню."
            .write(to: note.appendingPathComponent("transcript.txt"), atomically: true, encoding: .utf8)
        // 80 seconds of silence on each side, so Play shows as it does for a real call
        var wav = Data("RIFF".utf8); wav.append(contentsOf: withUnsafeBytes(of: UInt32(36 + 32000 * 80).littleEndian, Array.init))
        wav.append(Data("WAVEfmt ".utf8)); wav.append(contentsOf: [16, 0, 0, 0, 1, 0, 1, 0, 0x80, 0x3e, 0, 0, 0, 0x7d, 0, 0, 2, 0, 16, 0])
        wav.append(Data("data".utf8)); wav.append(contentsOf: withUnsafeBytes(of: UInt32(32000 * 80).littleEndian, Array.init)); wav.append(Data(count: 32000 * 80))
        for n in ["me.wav", "them.wav"] { try wav.write(to: call.appendingPathComponent(n)) }
        // three screens: drawn boxes with a label, as JPEG like Shots writes them
        var shots: [[String: Any]] = []
        for (i, (t, label)) in [(12.0, "Strip · levels"), (40.0, "Strip · done"), (60.0, "Offer · countdown")].enumerated() {
            let img = NSImage(size: NSSize(width: 640, height: 400), flipped: false) { r in
                NSColor(srgbRed: 0.93, green: 0.93, blue: 0.92, alpha: 1).setFill(); r.fill()
                NSColor.black.setFill(); NSRect(x: 170, y: 330, width: 300, height: 46).fill()
                Native.blue.setFill(); NSRect(x: 40, y: 40 + CGFloat(i) * 60, width: 220, height: 120).fill()
                (label as NSString).draw(at: NSPoint(x: 300, y: 120), withAttributes: [.font: NSFont.systemFont(ofSize: 30, weight: .semibold), .foregroundColor: NSColor.darkGray])
                return true
            }
            let file = String(format: "shots/%03d-00m%02ds.jpg", i + 1, Int(t))
            if let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff), let jpg = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.8]) {
                try jpg.write(to: call.appendingPathComponent(file))
            }
            shots.append(["t": t, "file": file, "app": "Figma", "title": "Drafter strip · " + label])
        }
        try json(shots, call.appendingPathComponent("shots.json"))
        let notes = [call.path: NoteFile(path: "/sample/notes/design-review.md", title: "Design review: voice strip", people: ["Mila Synthetic", "Sava Synthetic"],
                                         points: ["The strip shows both sides' sound while a call records", "A check replaces the microphone once text is in",
                                                  "The call offer gets a thin 30-second line"],
                                         followups: ["Alex: send the updated strip tonight", "Both: look at it together on Thursday"]),
                     note.path: NoteFile(path: "/sample/notes/home.md", title: "Calmer home screen", people: [], points: [], followups: ["Hide the rest in a menu"])]
        // a call that was never read: 2 s of microphone, 5 minutes of the other side
        let unread = root.appendingPathComponent("2026-10-28T14-04-00Z")
        try FileManager.default.createDirectory(at: unread, withIntermediateDirectories: true)
        try json(["call": true, "app": "Zoom", "started": now - 50 * 3600, "event": ["title": "Sync", "people": [String]()]], unread.appendingPathComponent("meta.json"))
        func silence(_ secs: Int) -> Data {
            var w = Data("RIFF".utf8); w.append(contentsOf: withUnsafeBytes(of: UInt32(36 + 32000 * secs).littleEndian, Array.init))
            w.append(Data("WAVEfmt ".utf8)); w.append(contentsOf: [16, 0, 0, 0, 1, 0, 1, 0, 0x80, 0x3e, 0, 0, 0, 0x7d, 0, 0, 2, 0, 16, 0])
            w.append(Data("data".utf8)); w.append(contentsOf: withUnsafeBytes(of: UInt32(32000 * secs).littleEndian, Array.init)); w.append(Data(count: 32000 * secs))
            return w
        }
        try silence(2).write(to: unread.appendingPathComponent("me.wav")); try silence(300).write(to: unread.appendingPathComponent("them.wav"))
        return [CallDoc.load(call, notes: notes), CallDoc.load(note, notes: notes), CallDoc.load(unread, notes: notes)]
    }
}

// MARK: the strip styles side by side (14 November 2026)

extension UIShots {
    /// The states the owner's words are about, in order (made-up text only).
    static let stripStates: [(String, String)] = [
        ("listening-1", "Listening · 1 line"), ("listening-2", "Listening · 2 lines"), ("listening-4", "Listening · 4 lines, scrolling"),
        ("finishing", "Finishing"), ("finishing-latched", "Finishing · ↩ latched"), ("armed", "Draft ready → a field"), ("armed-copy", "Draft ready · no field"), ("kept", "In the journal"), ("inserted", "In the field"),
        ("copied", "On the clipboard · no field"), ("waking", "Waking · audio kept"), ("segment", "↩ while speaking · inserting"),
        ("segment-done", "↩ while speaking · in the field"), ("live", "Live mode · words in the field"), ("held", "Live mode · ↩ held"),
        ("call", "A call"), ("warning", "A call · a side not heard"), ("offer", "An offer"), ("undo", "A receipt with Undo")]

    /// Every state of both strip styles in light and dark, on a made-up screen top with the camera housing and on a
    /// made-up external display: <root>/<style>/<theme>/<state>-<notch|display>.png, then one contact sheet per style
    /// and theme (<root>/sheet-<style>-<theme>.png). Made-up text only.
    static func stripStyles(_ root: String) throws {
        let fm = FileManager.default
        let only = (ProcessInfo.processInfo.environment["STRIP_ONLY"] ?? "").split(separator: ",").map(String.init)
        for theme in ["dark", "light"] {
            NSApp.appearance = NSAppearance(named: theme == "dark" ? .darkAqua : .aqua)
            for s in StripStyle.allCases where only.isEmpty || only.contains(s.rawValue) {
                let dir = root + "/\(s.rawValue)/\(theme)"
                try? fm.removeItem(atPath: dir)
                try fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
                Pill.shared.forced = s
                for (screen, notch) in [("notch", CGFloat(200)), ("display", CGFloat(0))] {
                    try stripRun(s, notch: notch) { name in dir + "/\(name)-\(screen).png" }
                }
                try stripSheet(root, style: s, theme: theme)
            }
        }
        print("Strip styles: " + root)
    }

    /// Drives one style through the states with the calls Voice makes, shooting each.
    static func stripRun(_ s: StripStyle, notch: CGFloat, path: (String) -> String) throws {
        let bar: CGFloat = { if let sc = NSScreen.main, sc.safeAreaInsets.top > 0 { return sc.safeAreaInsets.top }; return 32 }()
        let comp = ComposerStrip.shared, classic = ClassicStrip.shared
        let face = Pill.face(s)
        func start(live: Bool = false) {
            if s == .composer { comp.previewStart(notch: notch, bar: notch > 0 ? bar : 24, live: live) } else { classic.previewOn(notch: notch) }
        }
        func levels(_ n: Int) { if s == .composer { comp.previewLevels(n) } else { classic.previewLevels(n) } }
        func shot(_ name: String) throws {
            if s == .composer { try composerScene(comp, path(name)) } else { try classic.previewShot(path(name)) }
        }
        let w1 = "Let's move the review to Friday"
        let w2 = w1 + " and keep the first half for the made-up launch plan"
        let w4 = w2 + ", then the budget sheet, the two drafts from Mila, and whatever is left from the call about the strip and the notch on the new laptops."
            + " After that we look at the made-up numbers for the second week and decide who writes the short note to the team"
        start()
        face.listening(); face.draft(w1); levels(30); try shot("listening-1")
        face.draft(w2); levels(10); try shot("listening-2")
        face.draft(w4); levels(10); try shot("listening-4")
        face.finishing(insert: false); try shot("finishing")
        face.finishing(insert: true); try shot("finishing-latched")
        face.armed(w2 + "."); face.target("→ Claude", button: "Insert"); try shot("armed")
        face.target("No text field in Finder", button: "Copy"); try shot("armed-copy")
        face.kept(w2 + "."); try shot("kept")
        face.listening(); face.draft(w1); face.inserted(); try shot("inserted")
        face.copied("No text field here"); try shot("copied")
        face.listening(); face.waking(true); levels(30); try shot("waking")
        face.waking(false); face.draft(w2); face.segment("Inserting → Claude"); face.draft("And the room for the demo"); levels(10); try shot("segment")
        face.segmentDone(ok: true, reason: ""); try shot("segment-done")
        start(live: true)
        face.listening(); face.draft(w2); levels(30); try shot("live")
        face.held(); try shot("held")
        start()
        face.recording(call: true, seconds: 83, title: "", outline: ["Agree on the strip and how it opens under the notch"], event: "Design review: voice strip", shots: 2, warning: nil)
        if s == .composer { comp.previewSet { $0.me = 0.62; $0.them = 0.34 } }
        try shot("call")
        face.recording(call: true, seconds: 95, title: "", outline: [], event: "Design review: voice strip", shots: 0, warning: "Not hearing the other side yet")
        if s == .composer { comp.previewSet { $0.me = 0.5; $0.them = 0 } }
        try shot("warning")
        face.hide(after: 0)
        face.offer(["Record this call?", "Design review: voice strip · Mila Synthetic, Sava Synthetic"], kind: "Call", side: "Zoom",
                   controls: [StripButton("Record", key: "tab", style: .primary) {}, StripButton("Dismiss", key: "esc") {}], seconds: 30)
        try shot("offer")
        face.flash("Offers off in Slack", button: StripButton("Undo", key: "", style: .primary) {})
        try shot("undo")
        if s == .composer { comp.previewStart(notch: 200, bar: bar) }
    }

    static func stripSheet(_ root: String, style s: StripStyle, theme: String) throws {
        func load(_ path: String) -> NSBitmapImageRep? {
            guard let d = FileManager.default.contents(atPath: path), let r = NSBitmapImageRep(data: d) else { return nil }
            r.size = NSSize(width: CGFloat(r.pixelsWide) / 2, height: CGFloat(r.pixelsHigh) / 2); return r
        }
        let cols = [("notch", "MacBook screen, camera housing"), ("display", "External display")]
        let cap: CGFloat = 200, gap: CGFloat = 14, head: CGFloat = 54
        var rows: [(String, [NSBitmapImageRep?], CGFloat)] = []
        for (name, label) in stripStates {
            let imgs = cols.map { load(root + "/\(s.rawValue)/\(theme)/\(name)-\($0.0).png") }
            rows.append((label, imgs, imgs.compactMap { $0?.size.height }.max() ?? 80))
        }
        let cell = rows.flatMap { $0.1.compactMap { $0?.size.width } }.max() ?? 820
        let w = cap + CGFloat(cols.count) * (cell + gap) + gap
        let h = head + rows.reduce(0) { $0 + $1.2 + gap } + gap
        try picture(NSSize(width: w, height: h), root + "/sheet-\(s.rawValue)-\(theme).png") { r in
            Native.paper.setFill(); r.fill()
            (("\(s.name) · \(theme)") as NSString).draw(at: NSPoint(x: 20, y: h - 34), withAttributes: [.font: Native.display(20), .foregroundColor: Native.ink])
            let label: [NSAttributedString.Key: Any] = [.font: Native.text(14), .foregroundColor: Native.muted]
            for (i, c) in cols.enumerated() { (c.1 as NSString).draw(at: NSPoint(x: cap + gap + CGFloat(i) * (cell + gap), y: h - 34), withAttributes: label) }
            var y = h - head
            for (label, imgs, rh) in rows {
                y -= rh + gap
                (label as NSString).draw(with: NSRect(x: 20, y: y, width: cap - 30, height: rh - 8), options: [.usesLineFragmentOrigin],
                                         attributes: [.font: Native.text(14), .foregroundColor: Native.ink])
                for (i, img) in imgs.enumerated() {
                    guard let img else { continue }
                    let x = cap + gap + CGFloat(i) * (cell + gap)
                    NSGraphicsContext.saveGraphicsState()
                    NSRect(x: x, y: y, width: cell, height: rh).clip()
                    img.over(NSRect(x: x + (cell - img.size.width) / 2, y: y + rh - img.size.height, width: img.size.width, height: img.size.height))
                    NSGraphicsContext.restoreGraphicsState()
                }
            }
        }
    }
}

// MARK: what shows over other apps (look round, 14 November 2026)

extension UIShots {
    /// A view as it draws now, at the screen's scale (offscreen: nothing is put on the screen).
    static func bitmap(_ view: NSView) -> NSBitmapImageRep? {
        view.layoutSubtreeIfNeeded()
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        guard view.bounds.width >= 1, view.bounds.height >= 1,
              let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(ceil(view.bounds.width * scale)), pixelsHigh: Int(ceil(view.bounds.height * scale)),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        rep.size = view.bounds.size
        guard let ctx = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        // the views alone, over nothing (a panel's clear ground stays clear)
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = ctx
        NSColor.clear.set(); view.bounds.fill(using: .copy)
        NSGraphicsContext.restoreGraphicsState()
        // a layer's own ground (the strip's buttons): drawn first, with its corners
        if let bg = view.layer?.backgroundColor, let c = NSColor(cgColor: bg) {
            NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = ctx
            let r = view.layer?.cornerRadius ?? 0
            c.setFill(); NSBezierPath(roundedRect: view.bounds, xRadius: r, yRadius: r).fill()
            NSGraphicsContext.restoreGraphicsState()
        }
        // a view with children: its own drawing, then each child put on it one by one
        if !(view is NSTextField), !view.subviews.isEmpty {
            NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = ctx
            view.effectiveAppearance.performAsCurrentDrawingAppearance { view.draw(view.bounds) }
            for sub in view.subviews where !sub.isHidden { bitmap(sub)?.over(sub.frame) }
            NSGraphicsContext.restoreGraphicsState()
            return rep
        }
        // a label draws through its cell (drawn whole, it took the clear window's ground as grey)
        if let tf = view as? NSTextField, let cell = tf.cell {
            NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = ctx
            view.effectiveAppearance.performAsCurrentDrawingAppearance { cell.draw(withFrame: tf.bounds, in: tf) }
            NSGraphicsContext.restoreGraphicsState()
            return rep
        }
        view.effectiveAppearance.performAsCurrentDrawingAppearance { view.displayIgnoringOpacity(view.bounds, in: ctx) }
        return rep
    }

    /// A picture drawn in code at 2x, in the app's appearance.
    static func picture(_ size: NSSize, _ path: String, _ draw: (NSRect) -> Void) throws {
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { throw NSError(domain: "Preview", code: 3) }
        rep.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSApp.effectiveAppearance.performAsCurrentDrawingAppearance { draw(NSRect(origin: .zero, size: size)) }
        NSGraphicsContext.restoreGraphicsState()
        guard let data = rep.representation(using: .png, properties: [:]) else { throw NSError(domain: "Preview", code: 2) }
        try data.write(to: URL(fileURLWithPath: path))
    }

    /// The strip as it hangs from the notch (or floats under the menu bar): a made-up menu bar behind it.
    static func strip(_ box: NSView, _ path: String, notch: CGFloat, bar: CGFloat) throws {
        guard let img = bitmap(box) else { return }
        let w = max(760, box.bounds.width + 200), h = max(box.bounds.height + 28, bar + 40)
        try picture(NSSize(width: w, height: h), path) { r in
            let dark = Native.dark
            NSColor.underPageBackgroundColor.setFill(); r.fill()   // the desktop
            NSColor.windowBackgroundColor.withAlphaComponent(0.92).setFill()     // the menu bar
            NSRect(x: 0, y: h - bar, width: w, height: bar).fill()
            let menu: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 13, weight: .regular), .foregroundColor: dark ? NSColor.white : NSColor.black]
            ("  Notes    File    Edit    View" as NSString).draw(at: NSPoint(x: 8, y: h - bar + (bar - 16) / 2), withAttributes: menu)
            ("12:40" as NSString).draw(at: NSPoint(x: w - 52, y: h - bar + (bar - 16) / 2), withAttributes: menu)
            if notch > 0 {
                NSColor.black.setFill()
                NSBezierPath(roundedRect: NSRect(x: (w - notch) / 2, y: h - bar, width: notch, height: bar + 8), xRadius: 8, yRadius: 8).fill()
                NSRect(x: (w - notch) / 2, y: h - 8, width: notch, height: 8).fill()
            }
            img.over(NSRect(x: (w - box.bounds.width) / 2, y: h - box.bounds.height - (notch > 0 ? 0 : bar + 6),
                                width: box.bounds.width, height: box.bounds.height))
        }
    }

    /// One made-up field with what Drafter shows at its caret. The caret sits far above every screen, so the real
    /// panels are laid out as they would be and never appear.
    static func field(_ path: String, typed: String, caret: CGRect, panel: NSPanel, size: NSSize = NSSize(width: 720, height: 150),
                      font: NSFont? = nil, box: CGRect? = nil, placeholder: String = "", extra: ((NSPoint) -> Void)? = nil) throws {
        guard let content = panel.contentView, let img = bitmap(content) else { return }
        let c = Ghost.shared.cocoa(caret)
        let f = font ?? NSFont.systemFont(ofSize: max(11, min(26, c.height * 0.78)))
        // the picture holds the field, the caret and the panel, with room around them
        let around = (box.map { Ghost.shared.cocoa($0) } ?? c).union(panel.frame).union(c).insetBy(dx: -40, dy: -34)
        let size = NSSize(width: max(size.width, around.width), height: max(size.height, around.height))
        var o = NSPoint(x: c.minX - size.width * 0.46, y: c.midY - size.height * 0.55)
        o.x = min(max(o.x, around.maxX - size.width), around.minX); o.y = min(max(o.y, around.maxY - size.height), around.minY)
        try picture(size, path) { r in
            NSColor.windowBackgroundColor.setFill(); r.fill()
            let fieldRect = box.map { Ghost.shared.cocoa($0) }.map { NSRect(x: $0.minX - o.x, y: $0.minY - o.y, width: $0.width, height: $0.height) }
                ?? NSRect(x: 24, y: c.minY - o.y - 10, width: size.width - 48, height: c.height + 20)
            NSColor.textBackgroundColor.setFill()
            let fp = NSBezierPath(roundedRect: fieldRect, xRadius: 8, yRadius: 8); fp.fill()
            NSColor.separatorColor.setStroke(); fp.lineWidth = 1; fp.stroke()
            let a: [NSAttributedString.Key: Any] = [.font: f, .foregroundColor: NSColor.labelColor]
            let t = typed as NSString, tw = t.size(withAttributes: a).width
            let lineH = ceil(f.ascender - f.descender + f.leading)
            t.draw(at: NSPoint(x: c.minX - o.x - tw, y: c.minY - o.y + (c.height - lineH) / 2), withAttributes: a)
            if typed.isEmpty, !placeholder.isEmpty {
                (placeholder as NSString).draw(at: NSPoint(x: fieldRect.minX + 12, y: fieldRect.midY - lineH / 2),
                                               withAttributes: [.font: f, .foregroundColor: NSColor.placeholderTextColor])
            }
            NSColor.labelColor.setFill(); NSRect(x: c.minX - o.x, y: c.minY - o.y, width: 1.5, height: c.height).fill()
            extra?(o)
            let p = panel.frame
            img.over(NSRect(x: p.minX - o.x, y: p.minY - o.y, width: content.bounds.width, height: content.bounds.height))
        }
    }

    static func onScreen(_ folder: String) throws {
        let g = Ghost.shared
        let caret = CGRect(x: 600, y: -2600, width: 1, height: 20)   // AX, top-left: above every screen
        func chip(_ name: String, _ typed: String, _ action: [String: Any]) throws {
            g.unsure = 0; g.show("", action: action, at: caret)
            try field(folder + "/chip-\(name).png", typed: typed, caret: caret, panel: g.panel)
            g.hide()
        }
        g.unsure = 7; g.show("the slides tonight", action: nil, at: caret)
        try field(folder + "/ghost.png", typed: "Thanks, Mila. I will send you ", caret: caret, panel: g.panel)
        g.extend(" before nine", unsure: 11)
        try field(folder + "/ghost-two-step.png", typed: "Thanks, Mila. I will send you ", caret: caret, panel: g.panel)
        g.hide()
        g.unsure = 0; g.show("receive", action: nil, at: caret, replace: "recie")
        try field(folder + "/ghost-fix.png", typed: "I did not recie", caret: caret, panel: g.panel)
        g.hide()
        try chip("snippet", "my mail is au", ["id": "snippet", "chip": "⇥ alex@example.com"])
        try chip("action", "нагадай завтра о 10 надіслати акт Мілі", ["id": "reminder", "chip": "Нагадування · завтра 10:00 · надіслати акт Мілі"])
        try chip("proofread", "I recieve it tommorow", ["id": "proofread", "chip": "⇥ Fix 2 · recieve → receive, tommorow → tomorrow"])
        try chip("person", "Mila's number is ", ["id": "person", "chip": "Mila Synthetic · phone · +380 00 000 0000"])
        try chip("lookup", ";docs project notes", ["id": "lookup", "chip": "Search Google Drive · project notes"])
        // the next message: a card above an empty box
        let fieldBox = CGRect(x: 300, y: -2580, width: 520, height: 40)
        let caretBox = CGRect(x: 312, y: -2570, width: 1, height: 20)
        g.showDraft([["text": "Thanks, Mila! I'll send the act tonight and we can go over the numbers on Thursday at 11 if that works for you.", "label": "thanks + act tonight"],
                     ["text": "b", "label": "b"], ["text": "c", "label": "c"]], field: fieldBox, caret: caretBox)
        try field(folder + "/card.png", typed: "", caret: caretBox, panel: g.panel, size: NSSize(width: 720, height: 190), box: fieldBox, placeholder: "Message")
        g.expand(true)
        try field(folder + "/card-open.png", typed: "", caret: caretBox, panel: g.panel, size: NSSize(width: 720, height: 230), box: fieldBox, placeholder: "Message")
        g.hide()
        // a word Drafter fixed: dots under it, his own word in a chip above
        let word = CGRect(x: 560, y: -2600, width: 58, height: 20)
        let typedFont = NSFont.systemFont(ofSize: 15.6)
        let fixed = FixMarks.shared.previewChip(old: "recieve", word: word)
        try field(folder + "/fixmark.png", typed: "I did not receive", caret: CGRect(x: word.maxX, y: word.minY, width: 1, height: 20), panel: fixed,
                  font: typedFont) { o in
            let c = Ghost.shared.cocoa(word)
            let dots = Dots(frame: NSRect(x: 0, y: 0, width: c.width, height: 2))
            if let d = bitmap(dots) { d.over(NSRect(x: c.minX - o.x, y: c.minY - o.y - 1, width: c.width, height: 2)) }
        }
        FixMarks.shared.hideChip()
    }
}

extension NSImageRep {
    /// Drawn over what is there (`draw(in:)` copies, so a clear pixel cut a hole).
    func over(_ r: NSRect) { draw(in: r, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil) }
}

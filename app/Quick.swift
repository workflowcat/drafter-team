// The Quick panel (14 November 2026; the user: "a quicker interaction over the last typed words… a clipboard history…
// have Drafter read it and rewrite it… so that you can quickly copy stuff where it needs to go"). ⌃⌥V (setting
// `quickKey`; ⌃⌥Space and ⌘Space are reserved) opens a small panel on the caret's screen, centred in the upper third,
// over any app. It lists what the user copied, typed (TypedList: one row per message) and said (voice takes), newest first,
// pins on top. The panel never becomes key: the app the user is in stays in front with its caret, and the event tap hands
// the panel its keys while it is open (Keys.handle calls `tap`), as the ⌥Tab rework list does.
//
// Keys: type to narrow (ranked by match, freshness and what the user put in before: QuickRules.score, data/quick-stats.json)
// · ↑ ↓ · ⏎ put it at the user's caret and close · ⌘⏎ put it and stay · ⌘C copy · esc close · ⌘1 all ⌘2 copied ⌘3 typed
// ⌘4 voice · ⌘P pin / unpin · ⌘⌫ remove from history (⌘Z brings it back while the line says so) · ⇥ rewrite: three
// instant ones on this Mac (plain text, one line, as a quote) and the rework list (engine /rework: Claude only when the user
// picks one and `rework` is on, else the local model). The result shows below; ⏎ puts it, ⌫ goes back to the user's text.
// One tape (look round "Tape", 14 November): the chosen row unfolds in place to its text and its keys; rewrite unfolds
// under it. Drawing in QuickView below and app/TapeDraw.swift.
// ⌘⇧V held opens the same picker in its quick form (the extension "the quick form" below): the newest copies, hold
// and tap, let go to put; a letter turns it into the full form (picker round, 15 November 2026: one window for both,
// drawn in app/QuickView.swift).
//
// Putting text: AX insert or paste through Focus (the paste puts the user's clipboard back and is never kept as a copy).
// Never into skipped apps, password fields or under secure input: there the text goes to the clipboard instead.
// Rows live in memory, read once off the main thread at start and again when a history file changed.
import AppKit
import Carbon

final class Quick {
    static let shared = Quick()
    enum Mode { case list, rework }
    /// full: ⌃⌥V, search, list and actions; quick: ⌘⇧V held, the newest copies and the held-chord step-through.
    enum Look { case full, quick }
    enum Run { case menu, working, result, failed }
    struct Cmd { let id: String; let name: String; var hint: String; let cloud: Bool }

    static let visibleRows = 8

    // rows
    private(set) var items: [QuickItem] = []      // merged: pins, then newest first
    private(set) var shown: [Int] = []            // indices into items after the query and the kind
    private var raw: [QuickItem] = []             // from the files
    private var drafts: [String: [String]] = [:]  // typed row text -> the drafts folded into it (removed with it)
    private var pins: [QuickPin] = []
    private(set) var uses = QuickUses()           // data/quick-stats.json: when the user put which item in (ids and times)
    private var stamps: [String] = []
    private let search = QuickSearch()            // the search core over the items (QuickSearch.swift)
    private var loading = false, reloadAgain = false
    private var gone: (item: QuickItem, until: DispatchWorkItem)?   // removed, still undoable

    // what the user sees
    private(set) var isOpen = false
    var held = false                              // turned full from the quick form while ⌘⇧ are still down
    var look = Look.full
    /// The quick form's last put (row, text, app) and its rows then, for ⌘⇧V again within 2 s (switchSwap).
    var lastPut: (row: Int, text: String, pid: pid_t)?
    var swapRows: [QuickItem] = []
    var query = ""
    var kind: QuickKind?
    var sel = 0, top = 0
    var mode = Mode.list
    var notice = ""
    // rewrite
    var cmds: [Cmd] = []
    var rsel = 0
    var custom = ""
    var run = Run.menu
    var result = "", resultName = "", resultBy = "", ms = 0
    var seq = 0
    var origin: NSRunningApplication?
    var now = Date().timeIntervalSince1970

    let panel: NSPanel
    let view = QuickView()

    init() {
        panel = NSPanel(contentRect: NSRect(origin: .zero, size: QuickView.fullFrame), styleMask: [.nonactivatingPanel, .borderless],
                        backing: .buffered, defer: false)
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = false   // the view draws the one float shadow
        panel.level = .popUpMenu; panel.ignoresMouseEvents = true; panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        view.frame = NSRect(origin: .zero, size: QuickView.fullFrame)
        view.model = self
        panel.contentView = view
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] _ in
            self?.close("app changed")
        }
    }

    var current: QuickItem? { sel < shown.count ? items[shown[sel]] : nil }

    // MARK: the chosen clip's written forms (wire round, 15 November 2026)

    /// A text clip that IS one thing (a date, an amount, an IBAN...) has written forms for where it goes
    /// (FoundRules.quickForms); ← and → step through them on the chosen row, ↵ and ⌘C take the form shown.
    /// 0 is the text as copied. Kept per chosen row: another row starts again (on a stored rule's form, if any).
    private(set) var formIx = 0
    var formsFor: (id: String, at: Double, kind: String, forms: [FormatVariant])?
    func forms(_ it: QuickItem) -> (kind: String, forms: [FormatVariant]) {
        if let f = formsFor, f.id == it.id, f.at == it.at { return (f.kind, f.forms) }
        var r: (kind: String, forms: [FormatVariant], ruled: Bool) = ("", [], false)
        if it.clip == .text, !it.image, it.text.count <= 200, it.shape == nil || it.shape == .rich {   // a table, code or colour has no written forms
            let b = origin?.bundleIdentifier ?? ""
            let kind = AppKind.of(b, title: "", ai: Keys.aiApps, chats: Keys.chatApps, browsers: Keys.browsers, aiTitle: Keys.aiTitle)
            r = FoundRules.quickForms(it.text, written: Date(timeIntervalSince1970: it.at), dest: FoundRules.dest(bundle: b, kind: kind), memory: ClipForms.memory)
        }
        // key map verdict F2/F3 (17 November 2026): a copy kept with its formatting shows it first ("With formatting"),
        // and "Text" (the same characters, no formatting) is its first ← → form; ↵ puts the form shown.
        let lead = formatted(it) ? [FormatVariant(id: Self.textForm, name: "Text", text: it.text)] : []
        formsFor = (it.id, it.at, r.kind, lead + r.forms); formIx = r.ruled ? 1 + lead.count : 0
        return (r.kind, lead + r.forms)
    }
    static let textForm = "text"
    /// The chosen row shows "Text" on a formatted copy: it goes in without its formatting.
    func plainForm(_ it: QuickItem) -> Bool { formatted(it) && shownForm(it)?.id == Self.textForm }
    /// The name of form 0 on a row.
    func firstFormName(_ it: QuickItem) -> String { formatted(it) ? "With formatting" : "As copied" }
    /// The form on the chosen row: nil = the text as copied.
    func shownForm(_ it: QuickItem) -> FormatVariant? {
        let f = forms(it).forms
        return formIx > 0 && formIx <= f.count ? f[formIx - 1] : nil
    }
    /// What ↵ and ⌘C take from the chosen row.
    func chosenText(_ it: QuickItem) -> String { shownForm(it)?.text ?? it.text }
    private func stepForm(_ d: Int) {
        guard mode == .list, let it = current else { return }
        let n = forms(it).forms.count
        guard n > 0 else { return }
        formIx = QuickRules.stepForm(formIx, by: d, forms: n)
        view.needsDisplay = true
    }

    // MARK: the event tap

    /// Both keys as one state (QuickRules.QuickKeys, tested with made-up event sequences).
    var keys = QuickKeys()
    private var keyNames = ("", "", "")
    private var captureNames: [String] = ["\u{0}"], captureKeys: [QuickHotkey] = []
    private var pickName = "\u{0}", pickKey: QuickHotkey?

    /// From Keys.handle, for every event before anything else looks at it. true = swallowed.
    func tap(_ type: CGEventType, _ event: CGEvent) -> Bool {
        let st = Drafter.shared.settings
        if keyNames != (st.quickKey, st.switchKey, st.againKey) {
            keyNames = (st.quickKey, st.switchKey, st.againKey)
            keys.panelKey = QuickRules.hotkey(st.quickKey); keys.switchKey = QuickRules.hotkey(st.switchKey)
            // never the same chord as another of Drafter's keys
            let again = QuickRules.hotkey(st.againKey)
            let taken = [keys.panelKey, keys.switchKey] + Capture.keys.map { QuickRules.hotkey($0) }
            keys.againKey = (again != nil && taken.contains(again)) ? nil : again
        }
        if type == .leftMouseDown || type == .rightMouseDown { keys.disarmSwap() }   // a click: the caret may have moved
        keys.panelOpen = isOpen
        keys.quickForm = st.switchQuickForm
        keys.forms = isOpen && mode == .list ? (current.map { forms($0).forms.count } ?? 0) : 0
        // quick capture (app/Capture.swift): its key, and every key while the screen is dimmed
        // markup, then the capture deck; while the screen is dimmed for the deck's next shot, the keys are the capture's
        // a scrolling capture (app/ScrollShot.swift): ↵ ends it, esc drops it, every other key scrolls the app below
        if type == .keyDown, ScrollShot.shared.isOn {
            if ScrollShot.shared.key(Int(event.getIntegerValueField(.keyboardEventKeycode))) { return true }
        }
        // round 4: the deck never takes the user's keys; a mouse down outside it ends a card's caption take (CaptureNote.clicked)
        if type == .leftMouseDown || type == .rightMouseDown, CaptureNote.shared.isOpen {
            DispatchQueue.main.async { CaptureNote.shared.clicked(at: NSEvent.mouseLocation) }
        }
        if type == .keyDown, MarkupEditor.shared.isOpen, !Capture.shared.isOpen, !ScrollShot.shared.isOn {
            let code = Int(event.getIntegerValueField(.keyboardEventKeycode)), fl = event.flags
            var n = 0; var u = [UniChar](repeating: 0, count: 4)
            event.keyboardGetUnicodeString(maxStringLength: 4, actualStringLength: &n, unicodeString: &u)
            let ch = String(utf16CodeUnits: u, count: n), cmd = fl.contains(.maskCommand), shift = fl.contains(.maskShift)
            DispatchQueue.main.async { if MarkupEditor.shared.isOpen { MarkupEditor.shared.key(code, ch, cmd: cmd, shift: shift) } }
            return true
        }
        if type == .keyDown, Capture.shared.isOpen {
            let code = Int(event.getIntegerValueField(.keyboardEventKeycode))
            DispatchQueue.main.async { Capture.shared.key(code) }
            return true
        }
        if type == .keyDown {
            let names = Capture.keys   // ⌘⇧5 once macOS lets it go, the fallback key, ⌘⇧S if on (ShotRules.keys)
            if captureNames != names { captureNames = names; captureKeys = names.compactMap { QuickRules.hotkey($0) } }
            let f = event.flags
            var c = QuickKeyEvent(kind: .down); c.code = Int(event.getIntegerValueField(.keyboardEventKeycode))
            c.ctrl = f.contains(.maskControl); c.alt = f.contains(.maskAlternate); c.cmd = f.contains(.maskCommand); c.shift = f.contains(.maskShift)
            if captureKeys.contains(where: { QuickKeys.exact(c, $0) }) {
                if event.getIntegerValueField(.keyboardEventAutorepeat) == 0 { DispatchQueue.main.async { Capture.shared.open() } }
                return true
            }
            // keys round three, row 11: Pick parts' chord is the setting `pickKey` (⌃⌥P), never another of Drafter's global chords
            let pk = st.pickKey + "|" + st.quickKey + "|" + st.switchKey + "|" + st.againKey + "|" + names.joined(separator: ",")
            if pickName != pk {
                pickName = pk
                pickKey = KeyRules.ownChord(st.pickKey, others: [st.quickKey, st.switchKey, st.againKey] + names).flatMap { QuickRules.hotkey($0) }
            }
            // keys round three, row 1: ⌘⇧V in a skipped app (a terminal, VS Code, Xcode, a password manager) is the app's
            if !isOpen, !keys.switching, QuickKeys.exact(c, keys.switchKey),
               KeyRules.skippedAppKeeps(front: NSWorkspace.shared.frontmostApplication?.bundleIdentifier, skip: st.skip, own: Home.bundleID) {
                return false
            }
            if QuickKeys.exact(c, pickKey) {      // ⌃⌥P (pickKey): Pick parts on what is on the clipboard
                if event.getIntegerValueField(.keyboardEventAutorepeat) == 0 { DispatchQueue.main.async { PickPanel.openClipboard() } }
                return true
            }
        }
        keys.panelOpen = isOpen && look == .full   // the quick form is the held chord's: route reads it while switching
        if held, type == .flagsChanged, !event.flags.contains(.maskCommand) { held = false }
        let f = event.flags
        var e = QuickKeyEvent(kind: type == .keyDown ? .down : type == .flagsChanged ? .flags : .up)
        e.code = Int(event.getIntegerValueField(.keyboardEventKeycode))
        e.ctrl = f.contains(.maskControl); e.alt = f.contains(.maskAlternate); e.cmd = f.contains(.maskCommand); e.shift = f.contains(.maskShift)
        e.autorepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
        e.at = Date().timeIntervalSince1970
        if type == .keyDown || type == .flagsChanged {
            var swallowed = false, passOn = false
            for a in keys.route(e) {
                switch a {
                case .pass: passOn = true
                case .swallow: swallowed = true
                case .togglePanel: swallowed = true; DispatchQueue.main.async { self.toggle() }
                case .openSwitch: swallowed = true; DispatchQueue.main.async { self.openQuick() }
                case .step(let n): swallowed = true; DispatchQueue.main.async { self.stepQuick(n) }
                case .put: DispatchQueue.main.async { self.finishQuick() }
                case .cancel: swallowed = true; DispatchQueue.main.async { if self.look == .quick { self.close("esc") } }
                case .voiceAgain: swallowed = true; DispatchQueue.main.async { self.voiceAgain() }
                case .swap: swallowed = true; DispatchQueue.main.async { self.swap() }
                case .openFull: swallowed = true; DispatchQueue.main.async { self.openFromSwitch() }
                case .next: swallowed = true; DispatchQueue.main.async { if self.isOpen, self.look == .full { self.move(1); self.view.needsDisplay = true } }
                case .form(let d): swallowed = true; DispatchQueue.main.async { self.stepForm(d) }
                case .toPanel(let code):
                    swallowed = true
                    var n = 0; var u = [UniChar](repeating: 0, count: 4)
                    event.keyboardGetUnicodeString(maxStringLength: 4, actualStringLength: &n, unicodeString: &u)
                    var ch = String(utf16CodeUnits: u, count: n).lowercased()
                    if ch.unicodeScalars.first.map({ CharacterSet.controlCharacters.contains($0) }) ?? true {
                        ch = QuickRules.codes.first { $0.value == code }?.key.lowercased() ?? ""
                    }
                    if code == QuickKeys.space { ch = "" }   // Space: the full picker with an empty search
                    DispatchQueue.main.async { self.intoFull(ch) }
                }
            }
            if swallowed && !passOn { return true }
            if type == .flagsChanged { return false }
        }
        guard isOpen else { return false }
        if type == .leftMouseDown || type == .rightMouseDown {
            if look == .quick { keys.cancelSwitch() }   // a click while holding: nothing goes in on the release
            DispatchQueue.main.async { self.close("click") }; return false
        }
        // the quick form takes keys only through route (while held); a key after a missed release goes to the app
        guard look == .full, type == .keyDown else { return false }
        var n = 0; var u = [UniChar](repeating: 0, count: 4)
        event.keyboardGetUnicodeString(maxStringLength: 4, actualStringLength: &n, unicodeString: &u)
        let mods = event.flags.intersection([.maskCommand, .maskControl, .maskAlternate, .maskShift])
        return key(event.getIntegerValueField(.keyboardEventKeycode), String(utf16CodeUnits: u, count: n), mods)
    }

    // MARK: open and close

    func toggle() { isOpen ? close("key") : open() }

    func open(typed: String = "", held: Bool = false, choose: QuickItem? = nil, near: NSRect? = nil) {
        guard !isOpen else { return }
        self.held = held; look = .full
        if IsSecureEventInputEnabled() { Pill.shared.flash("Quick panel is off while secure input is on"); return }
        let t0 = Date()
        origin = PutBack.remember()
        query = typed; kind = nil; sel = 0; top = 0; mode = .list; notice = ""; custom = ""; run = .menu; seq += 1; formsFor = nil
        now = Date().timeIntervalSince1970
        refilter()
        if let c = choose, let i = shown.firstIndex(where: { items[$0].same(c) }) { sel = i }
        Ghost.shared.hide(); Rework.shared.close("quick")
        place(near: near)
        view.needsDisplay = true
        panel.orderFrontRegardless()
        isOpen = true
        refresh()
        log("quick: open, \(items.count) rows, \(Int(Date().timeIntervalSince(t0) * 1000)) ms")
        // the next main-queue pass, close to the first frame (docs/rounds/2026-11-15-speed.md)
        DispatchQueue.main.async { log("quick: first draw \(Int(Date().timeIntervalSince(t0) * 1000)) ms") }
    }

    func close(_ why: String) {
        guard isOpen else { return }
        isOpen = false; seq += 1
        panel.orderOut(nil)
        commitGone()
        log("quick: closed (\(why))")
    }

    /// The caret's screen (the focused element's, else the mouse's), centred, in the upper third. near: the quick
    /// form's card, which the full form grows from (the same top-left corner, kept on its screen).
    func place(near: NSRect? = nil) {
        let p = QuickView.pad
        if let near, let scr = NSScreen.screens.first(where: { $0.frame.intersects(near) }) {
            let vis = scr.visibleFrame, size = QuickView.frameSize(self)
            let x = min(max(near.minX - p, vis.minX + 8 - p), vis.maxX - size.width - 8 + p)
            let y = min(max(near.maxY + p - size.height, vis.minY + 8 - p), vis.maxY - size.height - 8 + p)
            panel.setFrame(NSRect(x: x, y: y, width: size.width, height: size.height), display: true)
            return
        }
        var scr: NSScreen?
        if let app = origin, app.processIdentifier != getpid(), let el = Focus.focused() {
            AXUIElementSetMessagingTimeout(el, 0.08)
            if let r = Focus.frame(el) {
                let h = NSScreen.screens.first?.frame.height ?? 0
                let p = NSPoint(x: r.midX, y: h - r.midY)
                scr = NSScreen.screens.first { $0.frame.contains(p) }
            }
        }
        let mouse = NSEvent.mouseLocation
        let s = scr ?? NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        let vis = s?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let size = QuickView.frameSize(self)
        let midY = vis.maxY - vis.height / 3
        let y = min(max(midY - size.height / 2, vis.minY + 8 - p), vis.maxY - size.height - 8 + p)
        panel.setFrame(NSRect(x: vis.midX - size.width / 2, y: y, width: size.width, height: size.height), display: false)
    }

    // MARK: rows

    /// At start: pins and rows, off the main thread.
    func warm() {
        DispatchQueue.global(qos: .utility).async {
            let p = Self.loadPins()
            let u = (try? Data(contentsOf: Self.statsFile)).flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] }.map(QuickUses.init) ?? QuickUses()
            DispatchQueue.main.async { self.pins = p; self.uses = u; self.refresh() }
        }
    }

    private static let pinsFile = Home.data.appendingPathComponent("quick-pins.json")
    private static let statsFile = Home.data.appendingPathComponent("quick-stats.json")
    /// The user put `it` in: counted for the ranking (item and app ids, times; never the text).
    func used(_ it: QuickItem) {
        QuickRules.used(&uses, it, at: Date().timeIntervalSince1970)
        guard stamps != ["preview"] else { return }
        let j = uses.json
        DispatchQueue.global(qos: .utility).async {
            if let d = try? JSONSerialization.data(withJSONObject: j) { try? d.write(to: Self.statsFile, options: .atomic) }
        }
    }
    private static func loadPins() -> [QuickPin] {
        guard let d = try? Data(contentsOf: pinsFile), let a = (try? JSONSerialization.jsonObject(with: d)) as? [[String: Any]] else { return [] }
        return a.compactMap(QuickPin.init)
    }
    private func savePins() {
        let rows = pins.map(\.json)
        DispatchQueue.global(qos: .utility).async {
            if let d = try? JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted]) { try? d.write(to: Self.pinsFile, options: .atomic) }
        }
    }

    /// Reads the history files again when one changed (size, time); the panel keeps showing the rows it has meanwhile.
    func refresh() {
        if let k = search.takeKeyStats() { log(String(format: "quick: keys %d, p50 %.1f ms, max %.1f ms (filter, since the last open)", k.n, k.p50, k.max)) }
        if loading { reloadAgain = true; return }
        loading = true
        let st = Drafter.shared.settings
        let have = stamps
        DispatchQueue.global(qos: .utility).async {
            let t0 = Date()
            let fresh = Self.sources.map { files in files.map { u -> String in
                guard let a = try? FileManager.default.attributesOfItem(atPath: u.path) else { return "-" }
                return "\(a[.modificationDate] ?? "")/\(a[.size] ?? "")"
            }.joined(separator: "|") }
            var changed: [Int] = []
            for i in fresh.indices where have.count != fresh.count || have[i] != fresh[i] {
                self.reader.read(i, max: st.quickMax, days: st.quickDays, secrets: QuickRules.secretRules(st.quickSecret))
                changed.append(i)
            }
            let rows = self.reader.parts.flatMap { $0 }, folded = self.reader.folded
            if !changed.isEmpty {
                log("quick: read \(changed.map { ["copied", "typed", "voice"][$0] }.joined(separator: "+")), \(rows.count) rows in \(Int(Date().timeIntervalSince(t0) * 1000)) ms")
            }
            DispatchQueue.main.async {
                self.loading = false
                if !changed.isEmpty {
                    let t1 = Date()
                    self.raw = rows; self.drafts = folded; self.stamps = fresh; self.rebuild()
                    log("quick: rebuild \(Int(Date().timeIntervalSince(t1) * 1000)) ms, \(self.items.count) rows\(self.isOpen ? ", open" : "")")
                }
                if self.reloadAgain { self.reloadAgain = false; self.refresh() }
            }
        }
    }

    // Touched only on the loading queue (one read at a time): each source's rows (QuickRead.swift: only the bytes
    // appended since the last read are read; rows already built are kept).
    private static let sources = [[History.clipFile, History.clipsDir], [History.typedFile, History.draftsFile], [History.takesFile]]
    private let reader = QuickReader(.init(clip: History.clipFile, typed: History.typedFile, drafts: History.draftsFile,
                                           takes: History.takesFile, hidden: History.hiddenFile), clipText: History.clipText,
                                           clipLabels: History.clipLabels)

    /// A new copy (its clipboard.jsonl row), straight from History.watchClipboard: on the list at once, no file read.
    func copied(_ row: [String: Any]) {
        guard stamps != ["preview"] else { return }
        let r = row
        raw.insert(QuickItem(kind: .copied, text: r["text"] as? String ?? "", app: r["app"] as? String ?? "", at: r["t"] as? Double ?? 0,
                             image: r["image"] != nil, clip: (r["kind"] as? String).flatMap(ClipKind.init(rawValue:)),
                             title: r["title"] as? String ?? "", bytes: r["bytes"] as? Int ?? 0, picture: r["clip"] as? String ?? "",
                             rich: r["rich"] as? Bool ?? false, shape: ClipRules.shape(r), data: r["data"] as? String ?? "",
                             note: ClipRules.note(r)), at: 0)
        rebuild()
    }

    /// A title the user copied before with the same address (a local cache: the rows in memory). "" when none.
    func knownTitle(_ url: String) -> String {
        raw.first { $0.clip == .link && $0.text == url && !$0.title.isEmpty }?.title ?? ""
    }

    /// Made-up rows (previews and the speed check): never the user's.
    func load(_ rows: [QuickItem], pins: [QuickPin] = []) { raw = rows; self.pins = pins; stamps = ["preview"]; rebuild() }

    private func rebuild() {
        let keep = current
        var rows = raw
        if let g = gone?.item { rows.removeAll { $0.same(g) } }
        items = QuickRules.merge(rows, pins: pins.filter { p in gone.map { !($0.item.kind == p.kind && $0.item.text == p.text) } ?? true })
        // the index for these rows, off the main thread (previews: at once); a query typed meanwhile gets its order then
        search.inline = stamps == ["preview"]
        search.rebuild(items, uses: uses, now: Date().timeIntervalSince1970) { [weak self] in
            guard let self, self.isOpen, !self.query.isEmpty, !self.search.inline else { return }
            self.refilter(keep: self.current)
        }
        refilter(keep: keep)
    }

    func refilter(keep: QuickItem? = nil) {
        shown = look == .quick ? QuickRules.quickRows(items, count: Self.quickCount)
            : search.filter(items, query: query, kind: kind, uses: uses, now: Date().timeIntervalSince1970)
        if look == .quick, isOpen, stamps != ["preview"] {   // a copy came in while held: the card grows, its top stays
            let size = QuickView.frameSize(self), f = panel.frame
            if f.size != size { panel.setFrame(NSRect(x: f.minX, y: f.maxY - size.height, width: size.width, height: size.height), display: true) }
        }
        if let keep, let i = shown.firstIndex(where: { items[$0].same(keep) }) { sel = i } else { sel = min(sel, max(0, shown.count - 1)) }
        if keep == nil { sel = 0 }
        scroll()
        if isOpen { view.needsDisplay = true }
    }

    /// The rows in view: the chosen row (it unfolds in place) stays whole in view, the rest stay put when they can.
    private func scroll() { top = view.fitTop(self) }

    // MARK: keys

    /// A key while the panel is open (on the tap). true = swallowed; false = it goes on to the app (the panel closed).
    func key(_ code: Int64, _ ch: String, _ mods0: CGEventFlags) -> Bool {
        // opened from the paste switcher with ⌘⇧ still held: those keys are typing until the user lets go
        let mods = held ? mods0.subtracting([.maskCommand, .maskShift]) : mods0
        let cmd = mods.contains(.maskCommand), plain = mods.subtracting(.maskShift).isEmpty
        if cmd, code == 14, mode == .list, let it = current { DispatchQueue.main.async { self.close("pick"); PickPanel.open(it) }; return true }   // ⌘E: Pick parts
        // round three: the chosen row's own keys (⌘O open, ⌘M markdown, ⌘T no tracking / copy text, ⌘R reveal, ⌘S save;
        // a file: ⌘C copies the file, ⌥⌘C its path), matched with exact modifiers (keys round three, ClipRules.rowAction)
        if cmd, mode == .list, let it = current,
           let a = ClipRules.rowAction(actions(it), code: Int(code), cmd: cmd, alt: mods.contains(.maskAlternate),
                                       ctrl: mods.contains(.maskControl), shift: mods.contains(.maskShift)) {
            DispatchQueue.main.async { self.act(a.id, it) }
            return true
        }
        if mods.contains(.maskControl) || (cmd && ![36, 76, 8, 6, 35, 51, 18, 19, 20, 21].contains(code)) {
            DispatchQueue.main.async { self.close("shortcut") }; return false
        }
        if mode == .rework { reworkKey(code, ch, cmd: cmd, plain: plain); scroll(); view.needsDisplay = true; return true }
        // "@name" or "context for name": ⏎ puts the entity's context in, ⌘C copies it (app/Entities.swift)
        if [36, 76].contains(code) || (code == 8 && cmd), !query.isEmpty, let d = Entities.door(query) {
            let put = code != 8
            DispatchQueue.main.async { self.close("context"); Entities.doorTake(d.text, what: d.what, put: put) }
            return true
        }
        switch code {
        case 53: DispatchQueue.main.async { self.close("esc") }
        case 126: move(-1)
        case 125: move(1)
        case 116: move(-Self.visibleRows)
        case 121: move(Self.visibleRows)
        // (a `where` binds only the last pattern of a case: before the picker round ↵ fell into this case on every row
        // and the digits 1 2 3 picked a kind instead of being typed)
        case 36 where mods.contains(.maskShift) && current?.clip == .image, 76 where mods.contains(.maskShift) && current?.clip == .image:   // ⇧↵ a picture with its read text
            if let it = current { DispatchQueue.main.async { self.act("withText", it) } }
        case 36, 76:
            if let it = current {
                let keep = cmd, t = chosenText(it), row = sel, rows = shown.map { items[$0] }, from = origin, bare = plainForm(it)
                DispatchQueue.main.async {
                    let how = self.put(it, t, keep: keep, plain: bare)
                    // ⌘⇧V again within 2 s: the next row's copy replaces this one (as after the quick form)
                    self.lastPut = nil; self.swapRows = rows
                    if !keep, how != nil { self.arm(row, t, pid: from?.processIdentifier) }
                }
            }
        case 48: if plain, let it = current { openRework(it) }
        case 51:
            if cmd { remove() }
            else if mods.contains(.maskAlternate) { dropWord() }
            else if !query.isEmpty { query.removeLast(); refilter() }
        case 6 where cmd: undo()
        case 8 where cmd: if let it = current { copy(it, chosenText(it), plain: plainForm(it)) }
        case 35 where cmd: pin()
        case 18 where cmd, 19 where cmd, 20 where cmd, 21 where cmd:
            kind = [nil, .copied, .typed, .voice][Int(code - 18)]; sel = 0; top = 0; refilter()
        case 123, 124, 115, 119: break
        default:
            if !cmd, let c = ch.unicodeScalars.first, !CharacterSet.controlCharacters.contains(c), query.count < 200 {
                query += ch; sel = 0; top = 0; refilter()
                if let h = Entities.doorHint(query) { notice = h }
            }
        }
        view.needsDisplay = true
        return true
    }

    private func move(_ by: Int) {
        guard !shown.isEmpty else { return }
        sel = max(0, min(shown.count - 1, sel + by)); scroll()
    }

    private func dropWord() {
        while query.last == " " { query.removeLast() }
        while let l = query.last, l != " " { query.removeLast() }
        refilter()
    }

    // MARK: kinds (round three: links, files, pictures)

    /// What the row points at: itself, or the first link or path in a text.
    func target(_ it: QuickItem) -> (kind: ClipKind, value: String)? {
        switch it.clip {
        case .text: return ClipRules.firstTarget(in: it.text)
        case .image: return it.picture.isEmpty ? nil : (.image, History.clipURL(it.picture).path)
        default: return (it.clip, it.text)
        }
    }
    func actions(_ it: QuickItem) -> [ClipRules.Action] {
        if it.clip == .image && it.picture.isEmpty { return [] }
        return it.clip == .text ? ClipRules.actions(.text, target: target(it)?.kind) : ClipRules.actions(it.clip)
    }
    private func fileURL(_ v: String) -> URL { URL(fileURLWithPath: (v as NSString).expandingTildeInPath) }

    /// A text copy kept with its formatting (RTF, RTFD, HTML in data/clips/): ↵ pastes the form shown ("With formatting" or "Text").
    func formatted(_ it: QuickItem) -> Bool { (it.clip == .text || it.clip == .link) && !it.data.isEmpty }

    /// The pasteboard writer for a file, a picture, PDF data, formatting or a colour (nil: the row goes in as text).
    /// A picture goes back in the type it came in (old rows: PNG), with TIFF beside it for apps that take only TIFF.
    func writer(_ it: QuickItem) -> ((NSPasteboard) -> Void)? {
        switch it.clip {
        case .file:
            let paths = it.text.split(separator: "\n").map { fileURL(String($0)) } as [NSURL]
            return { pb in pb.writeObjects(paths) }
        case .image where it.shape == .pdf && !it.data.isEmpty:
            guard let d = try? Data(contentsOf: History.clipURL(it.data)) else { return nil }
            let png = it.picture.isEmpty ? nil : try? Data(contentsOf: History.clipURL(it.picture))
            return { pb in
                pb.setData(d, forType: .pdf)
                if let png { pb.setData(png, forType: .png) }   // apps that take no PDF get its first page
            }
        case .image where !it.picture.isEmpty:
            let u = History.clipURL(it.picture)
            guard let d = try? Data(contentsOf: u) else { return nil }
            let type = ClipKindRules.type(forName: it.picture) ?? "public.png"
            return { pb in
                pb.setData(d, forType: NSPasteboard.PasteboardType(type))
                if type != "public.tiff", let rep = NSBitmapImageRep(data: d), let t = rep.tiffRepresentation { pb.setData(t, forType: .tiff) }
            }
        case .text, .link:
            if it.shape == .color, let c = ClipKindRules.color(it.text) {
                let text = it.text, color = NSColor(srgbRed: c.r, green: c.g, blue: c.b, alpha: c.a)
                return { pb in pb.setString(text, forType: .string); pb.writeObjects([color]) }
            }
            guard formatted(it), let types = History.formattedTypes(it.data) else { return nil }
            let text = it.text
            return { pb in
                for (t, d) in types where t != "public.utf8-plain-text" { pb.setData(d, forType: NSPasteboard.PasteboardType(t)) }
                pb.setString(text, forType: .string)
            }
        default: return nil
        }
    }

    func act(_ id: String, _ it: QuickItem) {
        guard let (k, v) = target(it) else { return }
        func copied(_ s: String, _ what: String) { close("copy"); History.copy(s); Pill.shared.flash("\(what) copied · ⌘V to paste") }
        switch id {
        case "open":
            close("open")
            if k == .link, let u = URL(string: v) { NSWorkspace.shared.open(u) } else { NSWorkspace.shared.open(fileURL(v)) }
        case "markdown": copied(ClipRules.markdown(v, title: it.clip == .link ? it.title : ""), "Markdown link")
        case "untracked": copied(ClipRules.untracked(v), "Link without tracking")
        case "reveal": close("reveal"); NSWorkspace.shared.activateFileViewerSelecting([fileURL(v)])
        case "path": copied(v, "Path")
        case "copyFile": copy(it, it.text)   // the file itself on the clipboard (pasteboard file URLs, as `writer` does)
        case "text":
            let t = it.ocr.isEmpty ? History.clipText(it.picture) : it.ocr
            if t.isEmpty { notice = "No text read in this picture yet"; view.needsDisplay = true } else { copied(t, "Text") }
        case "withText":
            let t = it.ocr.isEmpty ? History.clipText(it.picture) : it.ocr
            let from = origin
            put(it, it.text, keep: false)
            if !t.isEmpty { DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(350)) { Capture.put(text: t, origin: from) } }
        case "save":
            let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
            // the file as it was kept: a picture in its own type, PDF data as a PDF
            let src = it.shape == .pdf && !it.data.isEmpty ? History.clipURL(it.data) : fileURL(v)
            let to = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop/Drafter \(f.string(from: Date(timeIntervalSince1970: it.at))).\(src.pathExtension.isEmpty ? "png" : src.pathExtension)")
            do { try FileManager.default.copyItem(at: src, to: to); close("save"); Pill.shared.flash("Saved to Desktop") }
            catch { notice = "Could not save to Desktop"; view.needsDisplay = true }
        default: break
        }
        log("quick: \(id) on a \(it.clip.rawValue) row")
    }

    // MARK: actions

    /// Puts `text` where the user's caret was. keep: the panel stays for the next one (the panel never took the focus, so the
    /// paste reaches the user's app either way).
    /// asIs (the switcher keeping formatting): the app gets a plain ⌘V of what is on the clipboard already.
    /// Returns how it went in; nil: it went to the clipboard instead (or nowhere).
    @discardableResult
    /// plain: a formatted copy goes in as its "Text" form (← →); any other written form always goes in as text.
    func put(_ it: QuickItem, _ text: String, keep: Bool, from: NSRunningApplication? = nil, asIs: Bool = false, plain: Bool = false) -> String? {
        if it.image && it.picture.isEmpty && it.data.isEmpty { notice = "Only the size of this image was kept"; view.needsDisplay = true; return nil }
        let object = plain || ((it.clip == .text || it.clip == .link) && text != it.text) ? nil : writer(it)
        if !keep { close("put") }
        let st = Drafter.shared.settings
        guard let front = Capture.keyApp(), front.processIdentifier == (from ?? origin)?.processIdentifier,
              front.processIdentifier != getpid(), !st.skip.contains(front.bundleIdentifier ?? ""), !IsSecureEventInputEnabled() else {
            copy(it, text, plain: plain); return nil
        }
        let before = PutBack.before(front)
        let (spot, why) = Focus.spot(skip: st.skip)
        let how: String
        if let object, spot != nil || Focus.pasteTarget(why) { Focus.paste("", write: object); how = "paste \(it.shape.map { "\(it.clip.rawValue) \($0.rawValue)" } ?? it.clip.rawValue)" }
        else if object != nil { copy(it, text, plain: plain); return nil }
        else if asIs, spot != nil || Focus.pasteTarget(why) { Self.commandV(); how = "⌘V" }
        else if let spot { how = Focus.insert(text, at: spot) }
        else if Focus.pasteTarget(why) { Focus.paste(text); how = "paste" }
        else { copy(it, text, plain: plain); return nil }
        used(it)
        PutBack.check(front, windowsBefore: before, who: "quick", clip: { History.copy(text, write: object) })   // PutRules 3
        if keep, isOpen { notice = "Put in · \(text.count) characters"; view.needsDisplay = true }
        log("quick: put \(it.kind.rawValue), \(text.count) chars, \(how) in \(front.bundleIdentifier ?? "?")")
        return how
    }

    /// A double tap of Right Option (`againTap`, keys round two) or the `againKey` chord: the newest voice take goes in again at the caret, through `put` (never
    /// into skipped apps, password fields or under secure input: there it goes to the clipboard).
    func voiceAgain() {
        let from = PutBack.remember()
        DispatchQueue.global(qos: .userInitiated).async {
            let rows = History.read(History.takesFile, last: 20).map { (text: $0["text"] as? String ?? "", outcome: $0["outcome"] as? String ?? "") }
            let text = KeyRules.lastTake(rows)
            DispatchQueue.main.async {
                guard let text else { Pill.shared.flash("No voice take yet"); log("voice again: no take"); return }
                let how = self.put(QuickItem(kind: .voice, text: text, app: "", at: 0), text, keep: true, from: from)
                log("voice again: \(text.count) chars, \(how ?? "copied")")
            }
        }
    }

    /// ⌘V into the front app, marked as Drafter's own so the tap lets it through.
    static func commandV() { Focus.commandV() }   // counted for the draft budget (DraftCaptureRules)

    private func copy(_ it: QuickItem, _ text: String, plain: Bool = false) {
        if it.image && it.picture.isEmpty && it.data.isEmpty { notice = "Only the size of this image was kept"; view.needsDisplay = true; return }
        close("copy")
        History.copy(text, write: plain || ((it.clip == .text || it.clip == .link) && text != it.text) ? nil : writer(it))
        Pill.shared.flash("Copied · ⌘V to paste")
        log("quick: copied \(it.kind.rawValue), \(text.count) chars")
    }

    private func pin() {
        guard let it = current else { return }
        if it.pinned { pins.removeAll { $0.kind == it.kind && $0.text == it.text }; notice = "Unpinned" }
        else { pins.insert(QuickPin(kind: it.kind, text: it.text, app: it.app, at: it.at), at: 0); notice = "Pinned" }
        savePins(); rebuild()
    }

    /// The window's ⌘P on a row (Window.swift): the same pins as the panel's.
    func isPinned(_ kind: QuickKind, _ text: String) -> Bool { pins.contains { $0.kind == kind && $0.text == text } }
    func togglePin(_ kind: QuickKind, _ text: String, app: String, at: Double) {
        if isPinned(kind, text) { pins.removeAll { $0.kind == kind && $0.text == text } }
        else { pins.insert(QuickPin(kind: kind, text: text, app: app, at: at), at: 0) }
        if stamps != ["preview"] { savePins() }
        rebuild()
    }

    /// ⌘⌫: off the list at once; out of the files when the undo line is gone (8 s, the next removal, or the panel closing).
    private func remove() {
        guard let it = current else { return }
        commitGone()
        let w = DispatchWorkItem { [weak self] in self?.commitGone(); self?.notice = ""; self?.view.needsDisplay = true }
        gone = (it, w)
        DispatchQueue.main.asyncAfter(deadline: .now() + 8, execute: w)
        notice = "Removed from history · ⌘Z brings it back"
        rebuild()
    }

    private func undo() {
        guard let g = gone else { return }
        g.until.cancel(); gone = nil
        notice = "Back"
        rebuild()
        if let i = shown.firstIndex(where: { items[$0].same(g.item) }) { sel = i; scroll() }
    }

    private func commitGone() {
        guard let g = gone else { return }
        g.until.cancel(); gone = nil
        let it = g.item
        if pins.contains(where: { $0.kind == it.kind && $0.text == it.text }) { pins.removeAll { $0.kind == it.kind && $0.text == it.text }; savePins() }
        raw.removeAll { $0.same(it) }
        if stamps != ["preview"] { History.forget(it.kind, it.text, drafts: it.kind == .typed ? drafts[it.text] ?? [] : [], picture: it.picture) }
        rebuild()
        log("quick: removed a \(it.kind.rawValue) row")
    }

    // MARK: rewrite

    static let localCmds = [Cmd(id: "plain", name: "Plain text", hint: "no formatting, links without tracking", cloud: false),
                            Cmd(id: "oneline", name: "One line", hint: "the lines joined", cloud: false),
                            Cmd(id: "quote", name: "As a quote", hint: "> before each line", cloud: false)]

    private(set) var source: QuickItem?

    func openRework(_ it: QuickItem) {
        guard !it.image else { notice = "Only the size of an image is kept"; return }
        let cloud = Drafter.shared.settings.rework
        source = it
        cmds = Self.localCmds + Rework.shared.cmds.map { Cmd(id: $0.id, name: $0.name, hint: $0.hint, cloud: cloud) }
        if let i = cmds.firstIndex(where: { $0.id == "translate" }) {
            cmds[i].hint = Rework.lang(it.text, share: 0.6) == "uk" ? "→ English" : "→ Українська"
        }
        mode = .rework; rsel = 0; custom = ""; run = .menu; result = ""
        if cloud { Engine.shared.post("/rework", ["warm": true, "from": "quick"]) }
    }

    /// Too long for the rework list (engine/rework.py MAX_CHARS): only the instant ones.
    func usable(_ c: Cmd) -> Bool { QuickRules.local(c.id, "") != nil || (source?.text.count ?? 0) <= 3000 }

    private func reworkKey(_ code: Int64, _ ch: String, cmd: Bool, plain: Bool) {
        // 1-9, 0: that verb at once (while the user's own words are empty)
        if !cmd, custom.isEmpty, run != .working, ch.count == 1, let d = Int(ch), d < cmds.count + 1 || d == 0 {
            let i = d == 0 ? 9 : d - 1
            if i < cmds.count, usable(cmds[i]) { rsel = i; start(cmds[i].id) }
            return
        }
        switch code {
        case 53: mode = .list; seq += 1
        case 126, 123: rsel = max(0, rsel - 1)
        case 125, 124: rsel = min(cmds.count - 1, rsel + 1)
        case 115, 119, 116, 121: break
        case 36, 76, 48:
            if run == .result, code != 48, let it = source { let text = result, keep = cmd; DispatchQueue.main.async { self.put(it, text, keep: keep) } }
            else if run != .result, !custom.trimmingCharacters(in: .whitespaces).isEmpty { start("custom") }
            else if run != .result, rsel < cmds.count, usable(cmds[rsel]) { start(cmds[rsel].id) }
        case 51:
            if run != .menu { run = .menu; result = ""; seq += 1 }
            else if !custom.isEmpty { custom.removeLast() }
        case 8 where cmd: if run == .result, let it = source { copy(it, result) }
        default:
            if !cmd, run != .working, let c = ch.unicodeScalars.first, !CharacterSet.controlCharacters.contains(c), custom.count < 200 {
                custom += ch; if run == .result || run == .failed { run = .menu; result = "" }
            }
        }
    }

    private func start(_ id: String) {
        guard let it = source else { return }
        let name = id == "custom" ? "Your words" : cmds.first { $0.id == id }?.name ?? id
        resultName = name; seq += 1
        if let out = QuickRules.local(id, it.text) {
            result = out; resultBy = "this Mac"; ms = 0; run = out == it.text ? .failed : .result
            log("quick: rewrite \(id) local, \(it.text.count) → \(out.count) chars")
            return
        }
        run = .working
        let mine = seq, t0 = Date()
        // the text leaves the Mac only here, after the user picked; engine: Claude through claude_on("rework"), else local
        // writing instructions: the global one (a clipboard row knows the app's name, not its bundle id)
        let notes = WritingNotes.forApp("", global: Drafter.shared.settings.writingNote, perApp: [:])
        Engine.shared.post("/rework", ["text": it.text, "cmd": id, "custom": id == "custom" ? custom : "", "app": it.app, "from": "quick", "notes": notes, "kb": KeyLayout.language], timeout: 45) { j in
            guard mine == self.seq, self.isOpen, self.mode == .rework else { return }
            let out = (j?["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            self.ms = Int(Date().timeIntervalSince(t0) * 1000)
            self.resultBy = (j?["by"] as? String).map { $0 == "local" ? "this Mac" : $0 } ?? ""
            if out.isEmpty { self.run = .failed } else { self.result = out; self.run = .result }
            log("quick: rewrite \(id) \(self.ms)ms by \(j?["by"] as? String ?? "-") " + (out.isEmpty ? "none" : "\(it.text.count) → \(out.count) chars"))
            self.view.needsDisplay = true
        }
    }
}

// MARK: the quick form (picker round, 15 November 2026)

/// ⌘⇧V (setting `switchKey`), like ⌘Tab for the clipboard, is the same picker in its quick form: the first tap opens it
/// under the caret with the five newest copies, the newest chosen; each further V (⌘⇧ still down) or → moves on
/// (wrapping), ← goes back (with written forms on the chosen copy, ← → step through them instead); letting go of ⌘ puts
/// the chosen one in, as plain text (QuickRules.plain, so a tap-and-release does what the apps' own ⌘⇧V "paste and match
/// style" did; setting `switchFormat` keeps the newest copy's formatting by sending the app a plain ⌘V). Esc, still
/// holding, puts nothing in. Any other letter turns the picker into its full form with that letter in search, where it
/// stands. Plain ⌘V is never touched. Copies only: typed and voice rows wait in the full form.
/// ⌘⇧V again within 2 s of a put (setting `switchSwap`) swaps it for the next older text copy.
extension Quick {
    static let quickCount = 5

    func openQuick() {
        guard !isOpen else { keys.cancelSwitch(); return }
        let t0 = Date()
        if IsSecureEventInputEnabled() { keys.cancelSwitch(); return }
        guard !QuickRules.quickRows(items, count: Self.quickCount).isEmpty else { keys.cancelSwitch(); Pill.shared.flash("Nothing copied yet"); return }
        origin = PutBack.remember()
        look = .quick; held = false
        query = ""; kind = nil; sel = 0; top = 0; mode = .list; notice = ""; custom = ""; run = .menu; seq += 1; formsFor = nil
        now = Date().timeIntervalSince1970
        refilter()
        Ghost.shared.hide(); Rework.shared.close("quick")
        placeQuick()
        view.needsDisplay = true
        panel.orderFrontRegardless()
        isOpen = true
        log("switch: open, \(shown.count) copies, \(Int(Date().timeIntervalSince(t0) * 1000)) ms")
    }

    /// ⌘⇧V (keys round two, 17 November 2026): the full picker at once, ⌘⇧ still down count as nothing until let go.
    func openFromSwitch() {
        if isOpen { return }
        if IsSecureEventInputEnabled() { Pill.shared.flash("Quick panel is off while secure input is on"); return }
        open(held: true)
        log("switch: full picker")
    }

    func stepQuick(_ by: Int) {
        guard isOpen, look == .quick, !shown.isEmpty else { return }
        sel = QuickRules.wrap(sel, by: by, count: shown.count)
        view.needsDisplay = true
    }

    /// The user typed a letter while holding: the full form with it in search, the same copy chosen when it still matches,
    /// grown from where the quick form stands.
    func intoFull(_ ch: String) {
        guard isOpen, look == .quick else { open(typed: ch, held: true); return }
        let it = current, card = panel.frame.insetBy(dx: QuickView.pad, dy: QuickView.pad)
        look = .full; held = true; query = ch; sel = 0; top = 0
        refilter()
        if let it, let i = shown.firstIndex(where: { items[$0].same(it) }) { sel = i; refilter(keep: it) }
        place(near: card)
        view.needsDisplay = true
        log("switch: into the full form")
    }

    /// ⌘ let go: the chosen copy goes in (the written form shown, if the user stepped to one).
    func finishQuick() {
        guard isOpen, look == .quick, let it = current else { close("empty"); return }
        let row = sel, rows = shown.map { items[$0] }, formed = shownForm(it)?.text, from = origin, bare = plainForm(it)
        close("put")
        let keepFormat = formed == nil && Drafter.shared.settings.switchFormat && row == 0
            && NSPasteboard.general.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines) == it.text
        let text = formed ?? (keepFormat ? it.text : QuickRules.plain(it.text))
        let how = put(it, text, keep: true, from: from, asIs: keepFormat, plain: bare)
        lastPut = nil; swapRows = rows
        if how != nil { arm(row, text, pid: from?.processIdentifier) }
    }

    /// Rows the swap may paste over (as plain text): texts and links, not files or pictures.
    private var textRows: [Bool] { swapRows.map { ($0.clip == .text || $0.clip == .link) && !$0.image } }

    private func arm(_ row: Int, _ text: String, pid: pid_t?) {
        guard Drafter.shared.settings.switchSwap, let pid, !text.isEmpty,
              KeyRules.swapNext(textRows, after: row) != nil else { keys.disarmSwap(); return }
        lastPut = (row, text, pid)
        keys.armSwap(until: Date().timeIntervalSince1970 + KeyRules.swapSeconds)
    }

    /// The text just put is selected back (the caret is right after it) and the next older copy is pasted over it.
    /// Only when the field still ends with that text, in the same app, never in skipped apps, password fields or
    /// under secure input.
    func swap() {
        keys.disarmSwap()
        guard let p = lastPut, let i = KeyRules.swapNext(textRows, after: p.row) else { lastPut = nil; return }
        lastPut = nil
        let st = Drafter.shared.settings
        guard let front = Capture.keyApp(), front.processIdentifier == p.pid,
              !st.skip.contains(front.bundleIdentifier ?? ""), !IsSecureEventInputEnabled() else { log("switch: swap skipped, app changed"); return }
        let (spot, why) = Focus.spot(skip: st.skip)
        guard spot != nil || Focus.pasteTarget(why), let el = Focus.focused(),
              KeyRules.stillEnds(before: spot?.before ?? Focus.before(el) ?? "", piece: p.text) else {
            log("switch: swap skipped, text changed"); return
        }
        let it = swapRows[i], text = QuickRules.plain(it.text)
        let before = PutBack.before(front)
        Fields.left(p.text.count, shift: true)
        Focus.paste(text)
        PutBack.check(front, windowsBefore: before, who: "switch", clip: { History.copy(text) })   // PutRules 3
        used(it)
        log("switch: swap to copy \(i + 1), \(p.text.count) → \(text.count) chars in \(front.bundleIdentifier ?? "?")")
        arm(i, text, pid: p.pid)
    }

    /// Under the caret (or the focused field), else in the upper third of the mouse's screen. The card sits 6 pt under
    /// the caret line, or above it near the bottom; the panel round it holds the shadow's room.
    private func placeQuick() {
        let h = NSScreen.screens.first?.frame.height ?? 0, p = QuickView.pad
        let size = QuickView.frameSize(self)
        var anchor: CGRect?
        if let app = origin, app.processIdentifier != getpid(), let el = Focus.focused() {
            AXUIElementSetMessagingTimeout(el, 0.08)
            anchor = Focus.selectionRect(el) ?? Focus.frame(el)
        }
        if let a = anchor, let scr = NSScreen.screens.first(where: { $0.frame.contains(NSPoint(x: a.midX, y: h - a.midY)) }) {
            let vis = scr.visibleFrame
            var y = h - a.maxY - 6 - size.height + p
            if y + p < vis.minY + 4 { y = h - a.minY + 6 - p }
            let x = min(max(a.minX - p, vis.minX - p + 4), vis.maxX - size.width + p - 4)
            panel.setFrame(NSRect(x: x, y: min(max(y, vis.minY - p + 4), vis.maxY - size.height + p - 4), width: size.width, height: size.height), display: false)
            return
        }
        let mouse = NSEvent.mouseLocation
        let vis = (NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        panel.setFrame(NSRect(x: vis.midX - size.width / 2, y: vis.maxY - vis.height / 3 - size.height / 2, width: size.width, height: size.height), display: false)
    }
}

// MARK: previews and the speed check (made-up rows only; nothing is put on screen)

extension Quick {
    /// Round three: link, file and picture rows (made-up; the picture is drawn here and read by Vision like a real one).
    /// A made-up picture in data/clips/ of the scratch home (previews only), read by Vision like a real copy.
    static func samplePicture() throws -> (name: String, bytes: Int, ocr: String) {
        let name = "c-preview.png", u = History.clipURL(name)
        try FileManager.default.createDirectory(at: History.clipsDir, withIntermediateDirectories: true)
        let img = NSImage(size: NSSize(width: 640, height: 400), flipped: true) { r in
            NSColor.white.setFill(); r.fill()
            NSColor(white: 0.93, alpha: 1).setFill(); NSRect(x: 0, y: 0, width: 640, height: 56).fill()
            let big: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 30, weight: .semibold), .foregroundColor: NSColor.black]
            let body: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 22), .foregroundColor: NSColor.darkGray]
            ("Invoice 0042" as NSString).draw(at: NSPoint(x: 32, y: 10), withAttributes: big)
            ("Station redesign, drawings" as NSString).draw(at: NSPoint(x: 32, y: 100), withAttributes: body)
            ("Total due: 1 250 EUR by Friday" as NSString).draw(at: NSPoint(x: 32, y: 150), withAttributes: body)
            NSColor.systemBlue.setFill(); NSRect(x: 32, y: 230, width: 220, height: 56).fill()
            return true
        }
        if let t = img.tiffRepresentation, let rep = NSBitmapImageRep(data: t), let png = rep.representation(using: .png, properties: [:]) {
            try png.write(to: u)
        }
        let t0 = Date()
        let ocr = CGImageSourceCreateWithURL(u as CFURL, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) }.map(Screen.read) ?? ""
        try ocr.write(to: History.clipURL(name + ".txt"), atomically: true, encoding: .utf8)
        print("kinds: picture read in \(Int(Date().timeIntervalSince(t0) * 1000)) ms: \(ocr.split(whereSeparator: \.isNewline).count) lines")
        return (name, (try? Data(contentsOf: u).count) ?? 0, ocr)
    }

    /// Round three: link, file and picture rows (made-up; the picture is drawn here and read by Vision like a real one).
    func kindsPreview(now: Double, shot: (String) throws -> Void, reset: () -> Void) throws {
        let (name, bytes, ocr) = try Self.samplePicture()
        let rows = [
            QuickItem(kind: .copied, text: "https://example.com/projects/station-redesign/drawings?utm_source=newsletter&id=48213", app: "Safari", at: now - 40,
                      clip: .link, title: "Station redesign · drawings"),
            QuickItem(kind: .copied, text: "Image · 640 × 400", app: "Preview", at: now - 3 * 60, image: true, clip: .image, bytes: bytes, picture: name, ocr: ocr),
            QuickItem(kind: .copied, text: "~/Desktop/station-drawings-final.pdf", app: "Finder", at: now - 9 * 60, clip: .file, bytes: 482_113),
            QuickItem(kind: .copied, text: "The plan is at https://example.com/plans/station, see the second page", app: "Mail", at: now - 20 * 60),
            QuickItem(kind: .typed, text: "See you at the station at nine, I will bring the drawings.", app: "Messages", at: now - 30 * 60),
            QuickItem(kind: .copied, text: "Room 4.12, second floor, the door on the left", app: "Mail", at: now - 50 * 60, rich: true),
        ]
        load(rows); reset(); refilter()
        try shot("kinds-link")
        sel = 1; try shot("kinds-image")
        sel = 2; try shot("kinds-file")
        sel = 3; try shot("kinds-text-link")
        reset(); query = "1 250"; refilter()
        print("kinds: search \"1 250\" finds \(shown.count) row(s), first \(shown.first.map { items[$0].clip.rawValue } ?? "-")")
        try shot("kinds-ocr-search")
        reset(); query = "desktop"; refilter()
        print("kinds: search \"desktop\" finds \(shown.first.map { items[$0].clip.rawValue } ?? "-")")
    }

    static func sampleRows(_ n: Int, now: Double) -> [QuickItem] {
        let hand: [QuickItem] = [
            QuickItem(kind: .copied, text: "https://example.com/projects/station-redesign/drawings/final-review?utm_source=newsletter&utm_medium=email&id=48213", app: "Safari", at: now - 40),
            QuickItem(kind: .typed, text: "See you at the station at nine, I will bring the drawings.", app: "Messages", at: now - 4 * 60),
            QuickItem(kind: .voice, text: "Нагадати про зустріч у четвер о десятій і взяти з собою креслення.\nПотім обговорити бюджет.", app: "Notes", at: now - 22 * 60),
            QuickItem(kind: .copied, text: "Room 4.12, second floor, the door on the left", app: "Mail", at: now - 50 * 60),
            QuickItem(kind: .copied, text: "Image · 1280 × 800", app: "Preview", at: now - 2 * 3600, image: true),
            QuickItem(kind: .typed, text: "Дякую! Надішлю акт сьогодні ввечері, а в четвер пройдемось по цифрах.", app: "Telegram", at: now - 3 * 3600),
            QuickItem(kind: .voice, text: "Draft for the newsletter: three short points, the launch date, and a thank-you to the team.", app: "Notes", at: now - 26 * 3600),
            QuickItem(kind: .copied, text: "**Agenda**\n- budget\n- drawings\n- next steps", app: "Notion", at: now - 2 * 86400),
            QuickItem(kind: .typed, text: "Could you send the updated plan by Friday?", app: "Slack", at: now - 3 * 86400),
            QuickItem(kind: .copied, text: "Kyiv, Khreshchatyk 22", app: "Maps", at: now - 5 * 86400),
        ]
        let words = ["plan", "station", "drawings", "budget", "зустріч", "четвер", "кава", "report", "звіт", "invoice", "notes", "draft"]
        let apps = ["Notes", "Safari", "Mail", "Telegram", "Slack"]
        var filler: [QuickItem] = []
        for i in 0..<max(0, n - hand.count) {
            var w: [String] = []
            for k in 0..<(6 + i % 30) { w.append(words[(k * 7 + i) % words.count]) }
            let at: Double = now - 6 * 86400 - Double(i) * 1500
            w.append("\(i)")
            filler.append(QuickItem(kind: QuickKind.allCases[i % 3], text: w.joined(separator: " "), app: apps[i % apps.count], at: at))
        }
        return hand + filler
    }

    func preview(_ folder: String) throws {
        // a fixed time of day, so the tape's hours read the same in every render
        let now = Calendar.current.date(bySettingHour: 12, minute: 45, second: 0, of: Date())!.timeIntervalSince1970
        self.now = now
        let dark = Native.dark ? "-dark" : ""
        func shot(_ name: String) throws {
            view.frame = NSRect(origin: .zero, size: QuickView.frameSize(self))
            view.needsDisplay = true
            guard let rep = UIShots.bitmap(view), let d = rep.representation(using: .png, properties: [:]) else { throw NSError(domain: "Quick", code: 1) }
            try d.write(to: URL(fileURLWithPath: folder + "/quick-\(name)\(dark).png"))
        }
        func reset() { look = .full; query = ""; kind = nil; sel = 0; top = 0; mode = .list; notice = ""; custom = ""; run = .menu; formIx = 0; formsFor = nil }
        let rows = Self.sampleRows(1000, now: now)
        load(rows, pins: [QuickPin(kind: .copied, text: "Room 4.12, second floor, the door on the left", app: "Mail", at: now - 50 * 60)])
        isOpen = true
        // speed: what the key does before the panel shows (state, filter, one full draw), with 1,000 rows in memory
        var opens: [Double] = []
        for _ in 0..<5 {
            let t0 = Date()
            reset(); refilter(); _ = UIShots.bitmap(view)
            opens.append(Date().timeIntervalSince(t0) * 1000)
        }
        var keys: [Double] = []
        for ch in "зустріч четв" { let t0 = Date(); query.append(ch); refilter(); keys.append(Date().timeIntervalSince(t0) * 1000) }
        print(String(format: "quick speed: %d rows · open (filter + draw) first %.1f ms, then %.1f ms · filter per key avg %.2f ms, worst %.2f ms",
                     items.count, opens[0], opens.dropFirst().reduce(0, +) / 4, keys.reduce(0, +) / Double(keys.count), keys.max() ?? 0))
        reset(); refilter(); try shot("list")
        print("quick rows in view: \(view.drawnRows) at \(Int(QuickView.H)) pt, head \(Int(QuickView.headH)) pt, row \(Int(QuickView.rowH)) pt")
        sel = 3; try shot("preview")
        reset(); query = "station"; refilter(); try shot("filtered")
        reset(); kind = .voice; refilter(); try shot("voice")
        reset(); refilter(); sel = 2; openRework(items[shown[2]]); rsel = 6; try shot("rework")
        run = .result; resultName = "Warmer"; resultBy = "sonnet"; ms = 1400
        result = "See you at the station at nine! I'll bring the drawings with me."
        try shot("rework-result")
        reset(); refilter(); sel = 2; remove(); try shot("removed"); undo()
        reset(); query = "nothing like this"; refilter(); try shot("no-match")
        try kindsPreview(now: now, shot: shot, reset: reset)
        try Capture.preview(folder, dark: dark)
        load(rows, pins: [QuickPin(kind: .copied, text: "Room 4.12, second floor, the door on the left", app: "Mail", at: now - 50 * 60)])
        // the quick form (⌘⇧V held): just opened, the third chosen, then turned full by typing "r"
        reset(); look = .quick; refilter(); try shot("switch-open")
        sel = 2; try shot("switch-third")
        look = .full; held = true; query = "r"; refilter(); try shot("from-switch")
        held = false
        // written forms (← →) on a copy that is one thing: full and quick
        let formRows = [QuickItem(kind: .copied, text: "20.11.2026", app: "Mail", at: now - 30),
                        QuickItem(kind: .copied, text: "1 250,50 EUR", app: "Notes", at: now - 4 * 60),
                        QuickItem(kind: .copied, text: "Room 4.12, second floor, the door on the left", app: "Mail", at: now - 50 * 60)]
        load(formRows); reset(); refilter()
        print("quick forms: \"\(formRows[0].text)\" has \(forms(items[shown[0]]).forms.count), \"\(formRows[1].text)\" has \(forms(items[shown[1]]).forms.count)")
        formsFor = nil; _ = forms(items[shown[0]]); formIx = 0; try shot("forms")
        stepForm(1); try shot("forms-next")
        stepForm(1); try shot("forms-third")
        look = .quick; refilter(); sel = 0; formsFor = nil; _ = forms(items[shown[0]]); formIx = 0; stepForm(1); try shot("switch-forms")
        load([]); reset(); refilter(); try shot("empty")
        isOpen = false; raw = []; items = []; shown = []; stamps = []
    }
}

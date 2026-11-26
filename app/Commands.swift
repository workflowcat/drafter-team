// The one `;` picker (rules: app/CommandRules.swift). Right ⌘ twice or the menu opens it with an empty query and it
// takes the keys the user types; `;` + 2 letters in a field opens it with what the user typed, and the keys go on to the field.
// One list, a label on each row: snippets, quick starts, lookups (shown "off" until Google is set up), people, other
// cards. ↑↓ choose, ⇥ (and ↵ when it holds the query) puts in or opens, 1-6 on a person a field (as the `;ana` list), esc closes. Text goes in through
// Snippets.expand and Entities.replace (Focus.spot: never a password field, a skipped app or under secure input).
// Local only: a pick sends nothing; a lookup row only types its trigger, and the lookup asks before it searches.
import AppKit
import Carbon

final class CommandCard {
    static let shared = CommandCard()
    let panel = FixMarks.overlay()
    let view = CommandView()
    fileprivate(set) var rows: [CommandItem] = []
    fileprivate(set) var query = ""
    fileprivate(set) var own = false     // opened by Right ⌘ or the menu: the panel holds the query
    fileprivate(set) var uk = false
    var sel = 0
    private var old = ""                 // what a pick takes out of the field
    private var spot: Spot?
    var isOpen: Bool { panel.isVisible }

    init() { panel.contentView = view; view.card = self }

    // MARK: sources

    /// Every row the picker can show for `q`, in source order (CommandRules.filter ranks them).
    static func items(_ q: String, uk: Bool = false) -> [CommandItem] {
        var out: [CommandItem] = []
        // meeting notes first (17 November 2026): `;meet`, `;notes` (an alias), with the event on now or in 10 min
        let meet = MeetingRules.pickRow(event: MeetingNotes.current()?.0, recording: Talk.shared.recording)
        out.append(CommandItem(kind: .action, key: MeetingRules.keys[0], title: meet.title, detail: meet.detail, ref: "meeting-notes"))
        for (k, v) in Snippets.all.sorted(by: { $0.key < $1.key }) {
            out.append(CommandItem(kind: .snippet, key: k, title: CommandRules.short(v), ref: k))
        }
        for p in Presets.all {
            guard let k = p.keys.first else { continue }
            out.append(CommandItem(kind: .preset, key: k, title: p.title, detail: URL(string: p.url)?.host ?? "", ref: p.url))
        }
        let gam = LocalConfig.available("gam")
        for k in LookupQuery.reserved.sorted() {
            let l = LookupQuery(trigger: k, kind: String(k.dropFirst()), query: "")
            out.append(CommandItem(kind: .lookup, key: k, title: l.label, on: gam, ref: k))
        }
        out += CommandRules.freeRows(q, uk: uk, on: gam)   // ;free with a day set
        // voice modes last (research item 3): found by ;mode or "voice", never in the way of snippets
        let vc = Talk.shared.levelChoice()
        out += CommandRules.voiceModeRows(modes: Array(Drafter.shared.settings.voiceModes.keys), current: vc.mode.isEmpty ? vc.level.label : vc.mode, uk: uk)
        let bare = q.hasPrefix(";") ? String(q.dropFirst()) : q
        if bare.count >= 2 {
            let st = Entities.store
            let people = MentionRules.people(bare, in: st)
            for i in people {
                let e = st.records[i]
                out.append(CommandItem(kind: .person, key: "", title: e.name, detail: MentionRules.company(e) ?? e.whoLine, ref: "\(i)"))
            }
            for i in EntityRules.find(bare, in: st, limit: 6) where !people.contains(i) {
                let e = st.records[i]
                guard e.kind != "person", !e.isPrivate else { continue }
                out.append(CommandItem(kind: .card, key: "", title: e.name, detail: e.whoLine, ref: "\(i)"))
            }
        }
        return out
    }

    static func ukrainian(_ line: String) -> Bool {
        if let src = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
           let p = TISGetInputSourceProperty(src, kTISPropertyInputSourceID) {
            let id = Unmanaged<CFString>.fromOpaque(p).takeUnretainedValue() as String
            if KeyLayout.ukIDs.contains(id) { return true }
        }
        return CommandRules.cyrillic(line)
    }

    // MARK: open

    /// Keys.ask: `;` + 2 letters before the caret. true = the list shows.
    func offer(_ s: Spot) -> Bool {
        guard let t = CommandRules.typed(s.before), let rect = s.rect else { if !own { hide() }; return false }
        let ukLine = Self.ukrainian(s.before.components(separatedBy: "\n").last ?? "")
        let found = CommandRules.filter(Self.items(t.query, uk: ukLine), t.query)
        guard !found.isEmpty else { hide(); return false }
        if t.query != query { sel = 0 }
        own = false; query = t.query; old = t.old; spot = s; rows = found
        uk = ukLine
        show(at: rect)
        return true
    }

    /// Right ⌘ twice, or the menu: an empty query at the caret (or the screen's top third without one).
    func openOwn(from: String) {
        let s = Focus.spot(skip: Drafter.shared.settings.skip).0
        own = true; query = ""; old = ""; spot = s; sel = 0
        uk = Self.ukrainian(s?.before.components(separatedBy: "\n").last ?? "")
        rows = CommandRules.filter(Self.items(""), "")
        show(at: s?.rect)
        log("commands opened from \(from)")
    }

    private func refilter() {
        rows = CommandRules.filter(Self.items(query, uk: uk), query)
        sel = min(sel, max(0, rows.count - 1))
        show(at: spot?.rect)
    }

    func show(at caret: CGRect?) {
        let size = view.fit()
        let scr = (caret.map { c in NSScreen.screens.first { $0.frame.contains(Ghost.shared.cocoa(c).origin) } } ?? nil) ?? NSScreen.main
        var o: NSPoint
        if let caret {
            let c = Ghost.shared.cocoa(caret)
            o = NSPoint(x: c.minX - 8, y: c.minY - size.height - 6)
            if let v = scr?.visibleFrame, o.y < v.minY { o.y = c.maxY + 6 }
        } else if let v = scr?.visibleFrame {
            o = NSPoint(x: v.midX - size.width / 2, y: v.maxY - v.height / 3 - size.height / 2)
        } else { o = .zero }
        if let v = scr?.visibleFrame { o.x = min(max(o.x, v.minX + 4), v.maxX - size.width - 4) }
        panel.setFrame(NSRect(origin: o, size: size), display: true)
        view.frame = NSRect(origin: .zero, size: size)
        view.needsDisplay = true
        panel.orderFrontRegardless()
    }

    func hide() { if panel.isVisible { panel.orderOut(nil) }; rows = []; query = ""; own = false; sel = 0 }

    // MARK: keys (on the tap; true = swallowed)

    func key(_ code: Int64, _ mods: CGEventFlags, _ ch: String) -> Bool {
        guard isOpen else { return false }
        let plain = mods.isEmpty || mods == .maskNumericPad
        switch code {
        case 125, 126 where plain:
            if !rows.isEmpty { sel = EntityRules.wrap(sel + (code == 125 ? 1 : -1), rows.count); view.needsDisplay = true }
            return true
        case 53 where mods.isEmpty:
            DispatchQueue.main.async { self.hide() }; return true
        case 48 where mods.isEmpty:
            DispatchQueue.main.async { self.pick(field: nil) }; return true
        case 36, 76 where mods.isEmpty || mods == .maskNumericPad:
            // in a field ↵ stays the app's (a chat sends): only ⇥ picks there; the picker's own query takes ↵
            guard own else { DispatchQueue.main.async { self.hide() }; return false }
            DispatchQueue.main.async { self.pick(field: nil) }; return true
        case 51 where own && mods.isEmpty:
            DispatchQueue.main.async { if self.query.isEmpty { self.hide() } else { self.query.removeLast(); self.refilter() } }
            return true
        default:
            if plain, let d = Int(ch), (1...MentionRules.labels.count).contains(d), sel < rows.count, rows[sel].kind == .person {
                DispatchQueue.main.async { self.pick(field: d) }; return true
            }
            guard own else { return false }   // a `;` query in a field: the key goes to the field, ask re-offers
            if !mods.subtracting([.maskShift, .maskAlphaShift, .maskNumericPad]).isEmpty { DispatchQueue.main.async { self.hide() }; return false }
            let c = ch.filter { !$0.isNewline && $0 != "\t" && !$0.isASCII || $0.isLetter || $0.isNumber || " ;'’._-".contains($0) }
            if c.isEmpty { return true }
            DispatchQueue.main.async { self.query += c; self.refilter() }
            return true
        }
    }

    /// A click anywhere but the panel closes it.
    func click(_ p: CGPoint) {
        guard isOpen else { return }
        let flipped = NSPoint(x: p.x, y: (NSScreen.screens.first?.frame.maxY ?? 0) - p.y)
        if !panel.frame.contains(flipped) { DispatchQueue.main.async { self.hide() } }
    }

    // MARK: pick

    private func pick(field: Int?) {
        guard sel < rows.count else { hide(); return }
        let it = rows[sel], was = old, s = spot
        hide()
        let now = Focus.spot(skip: Drafter.shared.settings.skip).0
        func needField() -> Spot? {
            guard let now, s.map({ CFEqual($0.el, now.el) }) ?? true else { Pill.shared.flash(uk ? "Тут немає поля для тексту" : "No text field here"); return nil }
            return now
        }
        switch it.kind {
        case .preset:
            Presets.open(["url": it.ref, "old": was], expected: now)
        case .action:
            // the typed trigger leaves the field, then notes start (or stop) as from the menu bar, or the voice mode is set
            if !was.isEmpty, let now, now.before.hasSuffix(was), s.map({ CFEqual($0.el, now.el) }) ?? true { Focus.backspace(was.count) }
            if it.ref.hasPrefix("voice-mode:") { Talk.shared.pickMode(String(it.ref.dropFirst("voice-mode:".count)), from: "the ; picker") }
            else { MeetingNotes.toggle(from: "the ; picker") }
        case .snippet:
            guard let f = needField(), let text = Snippets.all[it.ref] else { return }
            Snippets.expand(old: was, new: text, key: it.ref, expected: f)
        case .lookup:
            guard it.on else { Pill.shared.flash(uk ? "Пошук вимкнено: потрібен Google (Settings)" : "Lookups are off: set up Google in Settings"); return }
            guard let f = needField() else { return }
            _ = Entities.replace(old: was, new: it.key + " ", expected: f)   // the lookup chip takes it from here
        case .person, .card:
            guard let f = needField(), let i = Int(it.ref), i < Entities.store.records.count else { return }
            let e = Entities.store.records[i], k = field ?? 1
            guard let text = it.kind == .person ? MentionRules.text(e, key: k) : e.name else {
                Pill.shared.flash("\(e.name): no \(MentionRules.labels[k - 1])"); return
            }
            guard Entities.replace(old: was, new: MentionRules.oneLine(text), expected: f) else { return }
        }
        log("commands: \(it.kind.rawValue) in \(now.map(Entities.dest) ?? "no field")")
    }
}

final class CommandView: NSView {
    weak var card: CommandCard?
    override var isFlipped: Bool { true }
    // caret-cozy round: the panels' style (app/Panel.swift): 12 pt in, 32 pt rows like the journal, key caps at the foot
    static let width: CGFloat = 460, row: CGFloat = Panel.rowH, head: CGFloat = 40, foot: CGFloat = 36
    func fit() -> NSSize {
        let n = CGFloat(max(1, card?.rows.count ?? 1))
        return NSSize(width: Self.width, height: (card?.own == true ? Self.head : 8) + n * Self.row + Self.foot + 4)
    }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }
    override func draw(_ dirty: NSRect) {
        guard let c = card else { return }
        CommandDraw.list(bounds, rows: c.rows, sel: c.sel, query: c.own ? c.query : nil, uk: c.uk)
    }
}

enum CommandDraw {
    /// A row's kind as a symbol and its colour (Kind in Look.swift): items blue, actions purple.
    static func mark(_ k: CommandKind) -> (String, NSColor) {
        switch k {
        case .snippet: return (Kind.snippet.mark, Kind.snippet.color)
        case .preset: return (Kind.link.mark, Kind.link.color)
        case .lookup: return (Kind.lookup.mark, Kind.lookup.color)
        case .person: return (Kind.person.mark, Kind.person.color)
        case .card: return ("doc.text", Native.blue)
        case .action: return (Kind.action.mark, Kind.action.color)
        }
    }
    static func list(_ b: NSRect, rows: [CommandItem], sel: Int, query: String?, uk: Bool) {
        TapeDraw.surface(b)
        let pad = Panel.pad
        var y: CGFloat = 8
        if let q = query {
            let f = Native.text(15)
            TapeDraw.glyph("search", NSRect(x: pad + 8, y: 20 - 8, width: 16, height: 16), color: Native.muted)
            TapeDraw.line(";" + q, NSRect(x: pad + 34, y: TapeDraw.lineTop(f, mid: 20), width: b.width - pad * 2 - 40, height: 22), TapeDraw.at(f, Native.ink))
            let qx = pad + 34 + min(b.width - pad * 2 - 40, TapeDraw.width(";" + q, TapeDraw.at(f, Native.ink)) + 1)
            Native.blue.setFill(); NSRect(x: qx, y: 11, width: 2, height: 18).fill()
            Panel.divider(x0: 0, x1: b.width, y: CommandView.head - 4)
            y = CommandView.head
        }
        if rows.isEmpty {
            TapeDraw.line(CommandRules.emptyWord(uk: uk), NSRect(x: pad + 10, y: TapeDraw.lineTop(Panel.font, mid: y + CommandView.row / 2), width: b.width - 2 * pad - 20, height: 18),
                          TapeDraw.at(Panel.font, Native.muted))
        }
        for (i, it) in rows.enumerated() {
            let r = NSRect(x: 6, y: y + CGFloat(i) * CommandView.row, width: b.width - 12, height: CommandView.row)
            let (m, tint) = mark(it.kind)
            let tail = it.on ? it.detail : CommandRules.offWord(uk: uk)
            let words = it.key.isEmpty ? it.title : it.key + "  " + it.title
            Panel.row(r, symbol: m, tint: it.on ? tint : Native.faint, text: words, app: String(tail.prefix(40)), time: CommandRules.label(it.kind, uk: uk),
                      chosen: i == sel, font: Native.text(13, i == sel ? .medium : .regular), ink: it.on ? Native.ink : Native.muted)
        }
        let fy = y + CGFloat(max(1, rows.count)) * CommandView.row + 4
        Panel.divider(x0: 0, x1: b.width, y: fy)
        let person = sel < rows.count && rows[sel].kind == .person
        var keys: [(key: String, word: String)] = [("↵", uk ? "вставити" : "put in")]
        if person { keys.append(("1-6", uk ? "поле" : "a field")) }
        keys.append(("esc", uk ? "закрити" : "close"))
        Panel.hints(keys, x: pad + 4, mid: fy + CommandView.foot / 2)
    }
}

extension CommandCard {
    /// `--commands-preview <png> [--dark] [--uk]`: the picker over made-up rows, saved as a picture. Never the files.
    static func previewShot(_ path: String, dark: Bool, uk: Bool) throws {
        let card = CommandCard.shared
        card.rows = [
            CommandItem(kind: .action, key: ";meet", title: "Notes for Sample sync", detail: "14:00"),
            CommandItem(kind: .preset, key: ";gmeet", title: "New Google Meet", detail: "meet.google.com"),
            CommandItem(kind: .snippet, key: ";sig", title: "Best regards, Sample Person"),
            CommandItem(kind: .lookup, key: ";meetings", title: "Find a meeting link", on: false),
            CommandItem(kind: .person, key: "", title: "Ana Example", detail: "Sample Studio"),
            CommandItem(kind: .card, key: "", title: "Meetup Sample", detail: "event"),
        ]
        card.own = true; card.query = "me"; card.sel = 0; card.uk = uk
        NSApplication.shared.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        card.view.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        card.view.frame = NSRect(origin: .zero, size: card.view.fit())
        try UIShots.save(card.view, path)
    }
}

// The command panel (Dock click or the menu, 2026-10-21): one line typed anywhere - "забукай 30 хв з Савою завтра після обіду", "find a
// free hour on Thursday", "нагадай скинути акт Мілі в пʼятницю", ";sig" - becomes up to three options (engine
// /command: Claude Haiku online, the local triggers and model offline). Nothing runs before the user picks: ↑↓ choose,
// Enter or Tab runs the chosen one, Esc closes. Calendar and reminders are made here with EventKit and can be undone
// with ⌘Z while the receipt shows. Free slots come from the user's real calendars only; with no
// calendar access it says so and never makes slots up. Fixed size (Codex review 2026-10-21: switching options changes
// words, never the shape), the shared card surface.
import AppKit
import EventKit

final class CommandPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// The panel's solid surface (drawn, so nothing behind shows through): the panels' one ground (app/Panel.swift).
final class CardView: NSView {
    var appearanceChanged: (() -> Void)?
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true; appearanceChanged?() }
    override func draw(_ r: NSRect) { Panel.ground(bounds) }
}

final class Command: NSObject, NSTextFieldDelegate {
    static let shared = Command()
    private var panel: CommandPanel?
    private let input = NSTextField()
    private var rows: [NSTextField] = []
    private let status = NSTextField(labelWithString: "")
    private var options: [[String: Any]] = []
    private var chosen = 0
    private var planned = ""             // the text the options belong to
    private var seq = 0
    private var timer: Timer?
    private var origin: Spot?            // the field the user was in, for snippets and inserts
    private var lookupTrigger: String?
    private var undo: (() -> Bool)?
    var isOpen: Bool { panel?.isVisible ?? false }


    private func make() -> CommandPanel {
        let p = CommandPanel(contentRect: NSRect(x: 0, y: 0, width: 620, height: 166),
                             styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: false)
        p.isOpaque = false; p.backgroundColor = .clear; p.hasShadow = false
        p.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.hidesOnDeactivate = false
        let v = CardView(frame: NSRect(x: 0, y: 0, width: 620, height: 166))
        p.contentView = v
        v.appearanceChanged = { [weak self] in self?.draw() }
        input.frame = NSRect(x: 18, y: 166 - 44, width: 584, height: 28)
        input.isBordered = false; input.drawsBackground = false; input.focusRingType = .exterior
        input.font = .systemFont(ofSize: 17); input.textColor = Native.ink
        input.placeholderAttributedString = NSAttributedString(string: "What would you like to do? Book…  find a free slot…  task…  ;snippet",
            attributes: [.foregroundColor: Native.muted, .font: NSFont.systemFont(ofSize: 17)])
        input.delegate = self
        v.addSubview(input)
        for i in 0..<3 {
            let r = NSTextField(labelWithString: "")
            r.frame = NSRect(x: 12, y: 166 - 82 - CGFloat(i) * 30, width: 596, height: 26)
            r.font = Panel.font; r.lineBreakMode = .byTruncatingTail
            r.wantsLayer = true; r.layer?.cornerRadius = Panel.control - 2
            v.addSubview(r); rows.append(r)
        }
        status.frame = NSRect(x: 18, y: 8, width: 584, height: 16)
        status.font = Panel.hint; status.textColor = Native.muted
        v.addSubview(status)
        return p
    }

    func preview(_ folder: String) throws {
        if panel == nil { panel = make() }
        input.stringValue = "Find the recording about the interface"
        options = [["chip": "Sample · Voice panel design discussion"], ["chip": "Sample · Color notes"], ["chip": "Sample · Light appearance check"]]
        chosen = 0; status.stringValue = "↑↓ choose · ⏎ copy · esc close"
        draw()
        if let view = panel?.contentView { try UIShots.save(view, folder + "/command.png") }
        input.stringValue = ";free 30 next week"
        options = [["chip": "Insert all 3 available times"], ["chip": "Mon 26 Oct 2026, 09:00–09:30 (Europe/Kyiv)"], ["chip": "Mon 26 Oct 2026, 10:30–11:00 (Europe/Kyiv)"]]
        status.stringValue = "Primary calendar only · Europe/Kyiv · ↑↓ choose · ⏎ insert"
        draw()
        if let view = panel?.contentView { try UIShots.save(view, folder + "/lookup.png") }

    }

    func toggle() { isOpen ? close() : open() }

    func open() {
        if panel == nil { panel = make() }
        origin = Focus.spot(skip: Drafter.shared.settings.skip).0
        lookupTrigger = nil
        Ghost.shared.hide()
        input.stringValue = ""; planned = ""; chosen = 0; undo = nil; top = 0
        chosenMoved = false
        options = recent("")
        status.stringValue = options.isEmpty ? "↑↓ choose · ⏎ or ⇥ run · esc close"
            : "recent recordings · ↑↓ choose · ⏎ copy · or type a request"
        draw()
        if let s = NSScreen.main, let p = panel {
            p.setFrameOrigin(NSPoint(x: s.frame.midX - 310, y: s.visibleFrame.maxY - 130 - 166))   // below the voice strip, never under it
        }
        panel?.makeKeyAndOrderFront(nil)
        panel?.makeFirstResponder(input)
        log("command: opened")
    }

    func lookup(_ trigger: String, expected: Spot?) {
        guard let expected, let current = Focus.spot(skip: Drafter.shared.settings.skip).0,
              CFEqual(expected.el, current.el), expected.app.processIdentifier == current.app.processIdentifier,
              LookupQuery.unchanged(before: current.before, value: current.value, caret: current.caret,
                                    expectedBefore: expected.before, expectedValue: expected.value, expectedCaret: expected.caret,
                                    trigger: trigger) else { Ghost.shared.flash("Text changed; search cancelled"); return }
        open()
        origin = expected; lookupTrigger = trigger; input.stringValue = trigger
        options = []; planned = ""; draw(); plan()
    }

    func close() {
        timer?.invalidate(); seq += 1
        panel?.orderOut(nil)
    }

    // MARK: typing

    /// Recent voice takes and recordings (newest first), as options that copy the text. With a query: only the ones
    /// whose text holds every word of it. Shown at once, before (and under) what the engine plans.
    private func recent(_ q: String) -> [[String: Any]] {
        let words = q.lowercased().split(separator: " ").map(String.init).filter { $0.count > 1 }
        let f = DateFormatter(); f.dateFormat = "d.MM HH:mm"
        var out: [[String: Any]] = []
        // long notes and calls first when they match: their transcript or live text
        let calls = ((try? FileManager.default.contentsOfDirectory(at: Spool.root, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [])
            .sorted { $0.lastPathComponent > $1.lastPathComponent }.prefix(20)
        for d in calls {
            let t = (try? String(contentsOf: d.appendingPathComponent("transcript.txt"), encoding: .utf8))
                ?? (try? String(contentsOf: d.appendingPathComponent("live.txt"), encoding: .utf8)) ?? ""
            guard !t.isEmpty, words.allSatisfy({ t.lowercased().contains($0) }) else { continue }
            let one = t.replacingOccurrences(of: "\n", with: " ")
            out.append(["chip": "Recording \(d.lastPathComponent.prefix(16).replacingOccurrences(of: "T", with: " ")) · \(t.count) chars · \(one.prefix(90))",
                        "run": ["kind": "copy", "text": t] as [String: Any]])
            if out.count >= 3 { break }
        }
        for r in History.read(History.takesFile, last: 400) {
            guard let t = r["text"] as? String, t.count > 3, words.allSatisfy({ t.lowercased().contains($0) }) else { continue }
            let when = f.string(from: Date(timeIntervalSince1970: r["t"] as? Double ?? 0))
            out.append(["chip": "\(when) · \(r["app"] as? String ?? "") · \(t.replacingOccurrences(of: "\n", with: " ").prefix(110))",
                        "run": ["kind": "copy", "text": t] as [String: Any]])
            if out.count >= 9 { break }
        }
        return out
    }

    func controlTextDidChange(_ n: Notification) {
        seq += 1; chosenMoved = false
        undo = nil
        let q = input.stringValue.trimmingCharacters(in: .whitespaces)
        options = LookupQuery.parse(q) != nil ? [] : recent(q).prefix(q.isEmpty ? 9 : 3).map { $0 }; chosen = 0; top = 0; planned = ""
        draw()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.8, repeats: false) { [weak self] _ in self?.plan() }
    }

    func control(_ c: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        switch sel {
        case #selector(NSResponder.cancelOperation(_:)): close(); return true
        case #selector(NSResponder.moveUp(_:)): pick(-1); return true
        case #selector(NSResponder.moveDown(_:)): pick(1); return true
        case #selector(NSResponder.insertTab(_:)), #selector(NSResponder.insertNewline(_:)):
            let t = input.stringValue.trimmingCharacters(in: .whitespaces)
            // Enter on a chosen row runs it; Enter on fresh text plans it first (a recording row is chosen by moving to it)
            if (t == planned || chosenMoved || t.isEmpty), !options.isEmpty { runChosen() } else { timer?.invalidate(); plan() }
            return true
        default: return false
        }
    }

    /// ⌘Z while a receipt shows (the text field would otherwise take it as text undo).
    func keyUndo() -> Bool { guard isOpen, undo != nil else { return false }; doUndo(); return true }

    private func doUndo() {
        let ok = undo?() ?? false
        undo = nil
        status.stringValue = ok ? "↩ Undone" : "Could not undo"
        log("command: undo " + (ok ? "done" : "failed"))
    }

    private var top = 0                  // first option shown in the three rows
    private var chosenMoved = false
    private func pick(_ by: Int) {
        guard !options.isEmpty else { return }
        chosen = (chosen + by + options.count) % options.count
        chosenMoved = true
        if chosen < top { top = chosen } else if chosen > top + 2 { top = chosen - 2 }
        draw()
    }

    private func plan() {
        let t = input.stringValue.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty, t != planned else { return }
        seq += 1; let mine = seq; chosenMoved = false
        let isLookup = LookupQuery.parse(t) != nil
        status.toolTip = nil
        status.stringValue = isLookup ? "Searching…" : "Thinking…"
        let started = Date()
        Engine.shared.post("/command", ["text": t], timeout: t.hasPrefix(";accounts") ? 60 : 30) { j in
            guard mine == self.seq else { return }
            self.planned = t; self.chosen = 0
            let lookup = isLookup || (j?["by"] as? String) == "lookup"
            self.options = ((j?["options"] as? [[String: Any]]) ?? []) + (lookup ? [] : Array(self.recent(t).prefix(3)))
            // ;free: plain words in the field's language, links, refine rows (app/Availability.swift)
            if let j, let rows = Availability.pickerRows(j, query: t, context: self.origin.map { Keys.shared.contextFor($0, refresh: false) } ?? "") { self.options = rows }
            self.top = 0
            let by = (j?["by"] as? String) == "haiku" ? "Haiku" : (j?["by"] as? String) == "snippet" ? "snippet" : "on this Mac"
            self.status.stringValue = self.options.isEmpty ? "No suggestions. Try rephrasing."
                : "\(by) · " + String(format: "%.1f s", Date().timeIntervalSince(started)) + " · ↑↓ choose · ⏎ run"
            if lookup {
                let action = self.lookupTrigger == nil ? "↑↓ choose · ⏎ copy" : "↑↓ choose · ⏎ insert"
                self.status.stringValue = (j?["error"] as? String) ?? (j == nil ? "Search service is unavailable. Press Return to retry." : ((j?["source"] as? String ?? "") + " · " + (self.options.isEmpty ? (j?["status"] as? String ?? "No matches") : action)))
                if j == nil || j?["error"] != nil { self.planned = "" }
                self.status.toolTip = self.status.stringValue
            }
            self.draw()
            log("command: \(self.options.count) options by \(j?["by"] as? String ?? "?") in \(j?["ms"] as? Int ?? 0) ms")
        }
    }

    private func draw() {
        if chosen < top || chosen > top + 2 { top = max(0, min(chosen, options.count - 3)) }
        for (k, r) in rows.enumerated() {
            let i = top + k
            guard i < options.count, let chip = options[i]["chip"] as? String else {
                r.stringValue = ""; r.layer?.backgroundColor = .clear; continue
            }
            let on = i == chosen
            r.stringValue = "  " + (on ? "⏎  " : "     ") + chip
            r.textColor = on ? Native.ink : Native.muted
            r.layer?.backgroundColor = on ? Native.pick.cgColor : NSColor.clear.cgColor
        }
    }

    // MARK: running

    private func runChosen() {
        guard chosen < options.count, let run = options[chosen]["run"] as? [String: Any], let kind = run["kind"] as? String else { return }
        let a = options[chosen]
        log("command: run \(kind)")
        switch kind {
        case "lookup.insert":
            let text = run["text"] as? String ?? ""
            guard !text.isEmpty else { return }
            let expected = origin, trigger = lookupTrigger
            close()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                guard let trigger else { History.copy(text); Pill.shared.flash("Copied · ⌘V to paste"); return }
                guard let expected,
                      let current = Focus.spot(skip: Drafter.shared.settings.skip).0,
                      CFEqual(expected.el, current.el), expected.app.processIdentifier == current.app.processIdentifier,
                      LookupQuery.unchanged(before: current.before, value: current.value, caret: current.caret,
                                            expectedBefore: expected.before, expectedValue: expected.value, expectedCaret: expected.caret,
                                            trigger: trigger) else {
                    History.copy(text); Pill.shared.flash("Copied · original field changed or unavailable"); return
                }
                Snippets.expand(old: trigger, new: text, key: "lookup", expected: current)
            }
        case "lookup.refine":   // a ;free refine row: the query with one choice changed, planned again
            input.stringValue = run["query"] as? String ?? input.stringValue; planned = ""; plan()
        case "insert":
            let text = run["text"] as? String ?? ""
            close()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                if let s = Focus.spot(skip: Drafter.shared.settings.skip).0 { _ = Focus.insert(text, at: s) } else { History.copy(text); Pill.shared.flash("Copied · ⌘V to paste") }
            }
        case "copy":
            History.copy(run["text"] as? String ?? ""); done("Copied · ⌘V to paste")
        case "snippet.save":
            Engine.shared.post("/snippet", ["key": run["key"] ?? "", "text": run["text"] ?? ""]) { j in self.done((j?["done"] as? String) ?? "Not saved") }
        case "eventkit.event": event(run)
        case "eventkit.reminder": reminder(run)
        case "eventkit.free": free(run)
        case "none": status.stringValue = a["chip"] as? String ?? ""
        default:
            status.stringValue = "Working…"
            Engine.shared.post("/act", ["id": a["id"] ?? "", "fields": a["fields"] ?? [:]], timeout: 30) { j in
                self.done((j?["done"] as? String) ?? (j?["error"] as? String) ?? "Could not complete this")
            }
        }
    }

    /// The result stays in the line for a while (it can be undone there), then the panel goes.
    private func done(_ text: String, undo: (() -> Bool)? = nil) {
        self.undo = undo
        status.stringValue = "✓ " + text + (undo != nil ? " · ⌘Z undo" : "")
        options = []; planned = input.stringValue; draw()
        let mine = seq
        DispatchQueue.main.asyncAfter(deadline: .now() + (undo != nil ? 6 : 2.5)) { if mine == self.seq { self.close() } }
    }

    private var store: EKEventStore { Actions.store }

    private func event(_ r: [String: Any]) {
        store.requestFullAccessToEvents { ok, _ in
            DispatchQueue.main.async {
                guard ok else { self.status.stringValue = "Calendar access needed in System Settings › Privacy › Calendars"; return }
                guard let start = Actions.date(r["start"]) else { self.status.stringValue = "No time specified"; return }
                let e = EKEvent(eventStore: self.store)
                e.title = r["title"] as? String ?? "Meeting"; e.startDate = start
                e.endDate = start.addingTimeInterval(Double(r["minutes"] as? Int ?? 30) * 60)
                e.notes = "Drafter"; e.calendar = self.store.defaultCalendarForNewEvents
                do {
                    try self.store.save(e, span: .thisEvent)
                    let id = e.eventIdentifier
                    log("command: event saved \(start)")
                    self.done("Event «\(e.title ?? "")» in calendar \(e.calendar?.title ?? "")") {
                        guard let id, let x = self.store.event(withIdentifier: id) else { return false }
                        return (try? self.store.remove(x, span: .thisEvent)) != nil
                    }
                } catch { self.status.stringValue = "Failed: \(error.localizedDescription)" }
            }
        }
    }

    private func reminder(_ r: [String: Any]) {
        store.requestFullAccessToReminders { ok, _ in
            DispatchQueue.main.async {
                guard ok else { self.status.stringValue = "Reminders access needed in System Settings › Privacy › Reminders"; return }
                let x = EKReminder(eventStore: self.store)
                x.title = r["title"] as? String ?? "Reminder"
                x.calendar = self.store.defaultCalendarForNewReminders()
                if let d = Actions.date(r["due"]) {
                    x.dueDateComponents = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: d)
                    x.addAlarm(EKAlarm(absoluteDate: d))
                }
                do {
                    try self.store.save(x, commit: true)
                    let id = x.calendarItemIdentifier
                    self.done("Reminder «\(x.title ?? "")»") {
                        guard let y = self.store.calendarItem(withIdentifier: id) as? EKReminder else { return false }
                        return (try? self.store.remove(y, commit: true)) != nil
                    }
                } catch { self.status.stringValue = "Failed: \(error.localizedDescription)" }
            }
        }
    }

    /// Free time from the user's own calendars as options that book that slot (Actions.freeSlots). Nothing is invented
    /// when the calendar cannot be read.
    private func free(_ r: [String: Any]) {
        Actions.freeSlots(r) { slots, err in
            guard let slots else { self.status.stringValue = err ?? "Cannot check the calendar"; return }
            let minutes = r["minutes"] as? Int ?? 30
            guard !slots.isEmpty else { self.status.stringValue = "No \(minutes)-minute slots in this period"; return }
            self.options = slots.map { ["chip": $0.chip, "run": ["kind": "eventkit.event", "title": r["title"] as? String ?? "Meeting",
                                                                 "start": $0.start, "minutes": minutes] as [String: Any]] }
            self.chosen = 0; self.top = 0; self.planned = self.input.stringValue
            self.status.stringValue = "from your calendars · ⏎ book selected slot"
            self.draw()
        }
    }
}

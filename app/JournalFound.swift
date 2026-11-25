// Things inside the chosen text, in the journal (wire round, 15 November 2026): the detector's marks in the reader,
// "In this text" in Details, the reader's keys for a found thing (⌥↓ ⌥↑ walk them, ↵ its actions, the action keys,
// esc), and "Copy as…" / "Insert as…" (the written forms of the item or of the thing in focus, and a text clip's
// clean-ups; ⌥ on an entry keeps it as a new clip). Rules: app/FoundRules.swift (pure, tested); the detector:
// app/DetectRules.swift; its actions: app/DetectActions.swift. Nothing here logs a found value.
import AppKit

extension WindowModel {
    // MARK: what the chosen text holds

    /// The things in the text the reader shows (his change, or the original while he looks at it). Sensitive things
    /// never show. A recording has none here (its transcript is long; search marks it instead).
    func found(_ it: TapeItem) -> [Found] {
        guard it.doc == nil else { return [] }
        let text = showOriginal ? it.text : it.current
        var h = Hasher(); h.combine(text); h.combine(it.id); let sig = h.finalize()
        if let c = foundCache, c.id == it.id, c.sig == sig { return c.found }
        let f = Detect.scan(text, written: Date(timeIntervalSince1970: it.at)).filter { !$0.sensitive }
        foundCache = (it.id, sig, f)
        return f
    }
    /// The thing in focus in the chosen item (nil: none).
    func focusedThing(_ it: TapeItem) -> Found? {
        guard foundFocusId == it.id, let i = foundFocus.index else { return nil }
        let f = found(it)
        return i < f.count ? f[i] : nil
    }
    func thingActions(_ it: TapeItem, _ f: Found) -> [DetectAction] {
        DetectActions.actions(for: f, context: DetectContext(text: it.current, title: it.entry?.title ?? ""))
    }

    // MARK: the reader's keys for found things

    /// One key while an item is chosen. nil: not ours, the window goes on with it.
    func foundKey(code: Int, mods: NSEvent.ModifierFlags, chars: String?) -> Bool? {
        guard let it = current, it.doc == nil, it.shot == nil, editing == nil else { return nil }
        if foundFocusId != it.id { foundFocus = FoundFocus(); foundFocusId = it.id }
        let k: FoundRules.FoundKey
        switch (code, mods) {
        case (125, [.option]): k = .next
        case (126, [.option]): k = .prev
        default:
            guard foundFocus.index != nil else { return nil }
            switch (code, mods) {
            case (36, []), (76, []): k = .ret
            case (53, []): k = .esc
            case (125, []): k = .down
            case (126, []): k = .up
            default:
                if let c = chars?.uppercased(), c.count == 1, let ch = c.first, ch.isLetter, mods.subtracting(.shift).isEmpty {
                    k = .key((mods.contains(.shift) ? "⇧" : "") + c)
                } else { k = .other }
            }
        }
        let fs = found(it)
        let f = foundFocus.index.flatMap { $0 < fs.count ? fs[$0] : nil }
        let acts = f.map { thingActions(it, $0) } ?? []
        let (s, eff) = FoundRules.route(foundFocus, k, count: fs.count, keys: acts.map(\.key), built: acts.map(\.built))
        foundFocus = s
        switch eff {
        case .pass:
            if k == .next || k == .prev { status = "Nothing found in this text"; return true }
            return nil
        case .none, .openMenu, .closeMenu: return true
        case .clear: status = ""; return true
        case .focus(let i):
            if open != it.id { open = it.id }   // the stream opens the row in place
            let t = fs[i]
            status = "\(FoundRules.one(t.words, 40)) · \(i + 1) of \(fs.count) · ↵ what to do · esc"
            return true
        case .run(let n):
            guard let t = f, n < acts.count else { return true }
            runThing(acts[n], t, it)
            return true
        }
    }

    func runThing(_ a: DetectAction, _ f: Found, _ it: TapeItem) {
        let ctx = DetectContext(text: it.current, title: it.entry?.title ?? "")
        if let t = DetectActions.copyText(a.id, f, context: ctx) {   // marked as Drafter's own: not kept as a new copy
            guard !preview else { status = "\(a.name) · on the clipboard"; return }
            History.copy(t); status = "On the clipboard · \(FoundRules.one(t, 40))"
            log("window: thing \(f.kind.rawValue) \(a.id)")
            return
        }
        guard !preview else { status = a.name; return }
        let ok = DetectActions.run(a, on: f, context: ctx)
        status = ok ? a.name + " · done" : "Could not " + a.name.lowercased()
        log("window: thing \(f.kind.rawValue) \(a.id) \(ok ? "ok" : "failed")")
    }

    // MARK: "Copy as…" and "Insert as…"

    /// The entries for the chosen item: the thing in focus, or the whole item when it is one thing, plus a text
    /// clip's clean-ups. Insert reads the destination from the app he came from.
    func formEntries(_ it: TapeItem, insert: Bool) -> [FormEntry] {
        guard it.doc == nil, it.shot == nil, (it.entry?.clip ?? .text) == .text else { return [] }
        var dest = FormatDest.other
        if insert, let o = origin {
            let b = o.bundleIdentifier ?? ""
            dest = FoundRules.dest(bundle: b, kind: AppKind.of(b, title: "", ai: Keys.aiApps, chats: Keys.chatApps, browsers: Keys.browsers, aiTitle: Keys.aiTitle))
        }
        return FoundRules.forms(text: it.current, focused: focusedThing(it), written: Date(timeIntervalSince1970: it.at), dest: dest,
                                clip: it.kind == .copied, memory: ClipForms.memory, title: it.entry?.title ?? "")
    }

    /// A menu at the mouse (↑ ↓ ↵ esc work in it as in any menu); ⌥ turns each entry into "keep as a new clip".
    func showForms(insert: Bool) {
        guard let it = current else { return }
        let es = formEntries(it, insert: insert)
        guard !es.isEmpty else { status = "No other forms for this text"; return }
        if preview { status = (insert ? "Insert as: " : "Copy as: ") + es.map(\.name).joined(separator: ", "); return }
        let menu = NSMenu(title: insert ? "Insert as" : "Copy as")
        menu.autoenablesItems = false
        let head = NSMenuItem(title: insert ? "Insert as" : "Copy as", action: nil, keyEquivalent: ""); head.isEnabled = false
        menu.addItem(head)
        let focused = focusedThing(it)
        for (i, e) in es.enumerated() {
            let item = FormMenuItem(title: e.name + "  ·  " + e.preview) { [weak self] in self?.applyForm(e, insert: insert, keep: false, it: it, focused: focused) }
            item.toolTip = e.text.count > 400 ? String(e.text.prefix(400)) + "…" : e.text
            if i < 9 { item.keyEquivalent = "\(i + 1)"; item.keyEquivalentModifierMask = [] }
            menu.addItem(item)
            let keep = FormMenuItem(title: "Keep as a new clip: " + e.name) { [weak self] in self?.applyForm(e, insert: insert, keep: true, it: it, focused: focused) }
            keep.isAlternate = true; keep.keyEquivalentModifierMask = [.option]
            if i < 9 { keep.keyEquivalent = "\(i + 1)" }
            menu.addItem(keep)
        }
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }

    func applyForm(_ e: FormEntry, insert: Bool, keep: Bool, it: TapeItem, focused: Found?) {
        let dest: FormatDest? = nil
        _ = FormatLearn.picked(e.kind, dest: dest, form: e.id, in: &ClipForms.memory)   // counted; the copy chip asks "Always?"
        ClipForms.save()
        if keep {
            let ns = it.current as NSString
            let rec = PickRecord(text: e.text, from: PickRules.sourceId(kind: it.quick?.rawValue ?? "copied", text: it.text),
                                 picked: [focused?.range ?? NSRange(location: 0, length: ns.length)], at: Date().timeIntervalSince1970,
                                 level: .things, rest: false, mine: it.kind != .copied)
            History.keepPick(rec, app: it.app)
            History.copy(e.text)
            status = "\(e.name) is a new clip · on the clipboard"
        } else if insert {
            guard let o = origin, !o.isTerminated else { History.copy(e.text); status = "On the clipboard · no app to insert into"; return }
            guard PutBack.raise(o, "window") else { History.copy(e.text); status = "On the clipboard · \(o.localizedName ?? "the app") is not in front"; return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { _ = Capture.put(text: e.text, origin: o) }
            status = "In the field · \(e.name.lowercased())"
        } else {
            History.copy(e.text)
            status = "On the clipboard · \(e.name.lowercased())"
        }
        log("window: form \(e.kind) \(e.id) \(keep ? "kept" : insert ? "inserted" : "copied")")
    }
}

/// A menu entry that runs a closure.
final class FormMenuItem: NSMenuItem {
    private let run: () -> Void
    init(title: String, _ run: @escaping () -> Void) {
        self.run = run
        super.init(title: title, action: #selector(go), keyEquivalent: "")
        target = self
    }
    required init(coder: NSCoder) { fatalError() }
    @objc private func go() { run() }
}

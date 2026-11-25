// The `;` mention list (rules and keys: app/MentionRules.swift). `;ana` shows up to 5
// people from data/entities.json under the caret; ↑↓ picks the person, 1-6 puts in a field (1 name, 2 phone, 3 email,
// 4 address, 5 company, 6 card), Tab the name, Esc closes. `;ana 2` typed straight through puts in the phone with no
// list. The text goes in through Entities.replace (Focus.spot: never a password field, a skipped app or under secure
// input). Local only.
import AppKit

final class MentionCard {
    static let shared = MentionCard()
    let panel = FixMarks.overlay()
    let view = MentionView()
    fileprivate(set) var people: [Int] = []
    var sel = 0
    private var typed: MentionTyped?
    private var spot: Spot?
    var isOpen: Bool { panel.isVisible }

    init() { panel.contentView = view; view.card = self }

    var current: Entity? { sel < people.count ? Entities.store.records[people[sel]] : nil }
    var list: [Entity] { people.map { Entities.store.records[$0] } }

    /// Keys.ask: the line before the caret ends in a mention. true = handled (the list shows, or a field went in).
    func offer(_ s: Spot, reserved: Set<String>) -> Bool {
        guard let t = MentionRules.parse(s.before, reserved: reserved),
              t.pick != nil || !MentionRules.cardFirst(Entities.dest(s)) else { hide(); return false }
        let found = MentionRules.people(t.query, in: Entities.store)
        guard !found.isEmpty else { hide(); return false }
        people = found; typed = t; spot = s
        if sel >= found.count { sel = 0 }
        if let k = t.pick { DispatchQueue.main.async { self.put(k) }; return true }
        guard let rect = s.rect else { hide(); return false }
        show(at: rect)
        return true
    }

    func show(at caret: CGRect) {
        let size = view.fit()
        let c = Ghost.shared.cocoa(caret)
        var o = NSPoint(x: c.minX - 8, y: c.minY - size.height - 6)
        if let scr = NSScreen.screens.first(where: { $0.frame.contains(NSPoint(x: c.midX, y: c.midY)) }) ?? NSScreen.main {
            if o.y < scr.visibleFrame.minY { o.y = c.maxY + 6 }
            o.x = min(max(o.x, scr.visibleFrame.minX + 4), scr.visibleFrame.maxX - size.width - 4)
        }
        panel.setFrame(NSRect(origin: o, size: size), display: true)
        view.frame = NSRect(origin: .zero, size: size)
        view.needsDisplay = true
        panel.orderFrontRegardless()
    }

    func hide() { if panel.isVisible { panel.orderOut(nil) }; people = []; typed = nil; sel = 0 }

    /// A key while the list shows (on the tap). true = swallowed.
    func key(_ code: Int64, _ mods: CGEventFlags, _ ch: String) -> Bool {
        guard isOpen, !people.isEmpty else { return false }
        switch code {
        case 48 where mods.isEmpty:
            DispatchQueue.main.async { self.put(1) }; return true
        case 125, 126 where mods.isEmpty:
            sel = EntityRules.wrap(sel + (code == 125 ? 1 : -1), people.count); view.needsDisplay = true; return true
        case 53 where mods.isEmpty:
            DispatchQueue.main.async { self.hide() }; return true
        default:
            if mods.isEmpty || mods == .maskNumericPad, let d = Int(ch), (1...MentionRules.labels.count).contains(d) {
                DispatchQueue.main.async { self.put(d) }; return true
            }
            return false
        }
    }

    /// Field `k` of the chosen person replaces what he typed (`;ana`, `;ana `, `;ana 2`).
    private func put(_ k: Int) {
        guard let e = current, let t = typed, let s = spot else { hide(); return }
        guard let text = MentionRules.text(e, key: k) else {
            Pill.shared.flash("\(e.name): no \(MentionRules.labels[k - 1])"); return
        }
        // the list may have shown for `;ana ` and the digit was swallowed: the field still holds `@ana `
        let now = Focus.spot(skip: Drafter.shared.settings.skip).0?.before.replacingOccurrences(of: "\u{A0}", with: " ") ?? ""
        let old = now.hasSuffix(t.old) ? t.old : (now.hasSuffix(t.old + " ") ? t.old + " " : t.old)
        hide()
        guard Entities.replace(old: old, new: MentionRules.oneLine(text), expected: s) else { return }
        log("mention: \(MentionRules.labels[k - 1]) in \(Entities.dest(s))")
    }
}

final class MentionView: NSView {
    weak var card: MentionCard?
    override var isFlipped: Bool { true }
    static let width: CGFloat = 420, row: CGFloat = Panel.rowH, field: CGFloat = 26
    func fit() -> NSSize {
        let n = CGFloat(card?.people.count ?? 1)
        return NSSize(width: Self.width, height: 6 + n * Self.row + 8 + CGFloat(MentionRules.labels.count) * Self.field + 10)
    }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }
    override func draw(_ dirty: NSRect) {
        guard let c = card, let e = c.current else { return }
        MentionDraw.list(bounds, people: c.list, sel: c.sel, slots: MentionRules.slots(e))
    }
}

enum MentionDraw {
    /// The list: also drawn by --ui-preview from made-up people.
    static func list(_ b: NSRect, people: [Entity], sel: Int, slots: [MentionSlot]) {
        TapeDraw.surface(b)
        let rowH = MentionView.row
        for (i, e) in people.enumerated() {
            // the journal's row (app/Panel.swift): the person symbol, the name, their company at the right
            let r = NSRect(x: 6, y: 6 + CGFloat(i) * rowH, width: b.width - 12, height: rowH)
            Panel.row(r, symbol: Kind.person.mark, tint: i == sel ? Kind.person.color : Native.muted, text: e.name,
                      app: MentionRules.company(e) ?? e.whoLine, chosen: i == sel, font: Native.text(13, i == sel ? .medium : .regular))
        }
        var y = 6 + CGFloat(people.count) * rowH + 8
        Panel.divider(x0: 0, x1: b.width, y: y - 4)
        let valA = TapeDraw.at(Native.mono(12), Native.ink, cut: .byTruncatingMiddle), noneA = TapeDraw.at(Native.mono(12), Native.muted)
        for s in slots {
            let kx = TapeDraw.keyWord("\(s.key)", s.label, x: 12, y: y, color: s.text == nil ? Native.muted : Native.ink, gap: 10)
            let vx = max(kx, 120)
            TapeDraw.line(s.text.map(MentionRules.oneLine) ?? "-", NSRect(x: vx, y: TapeDraw.lineTop(Native.mono(12), mid: y + TapeDraw.capH / 2), width: b.width - vx - 14, height: 18), s.text == nil ? noneA : valA)
            y += MentionView.field
        }
    }
}

extension MentionCard {
    /// `--mention-preview <png> [--dark]`: the list for `;an` over made-up people, saved as a picture. Never the file.
    static func previewShot(_ path: String, dark: Bool) throws {
        func ent(_ id: String, _ name: String, _ who: String, _ h: [String: [String]], org: String? = nil) -> Entity {
            var e = Entity(id: id, kind: "person", name: name); e.who = who; e.handles = h; e.org = org; e.heat = 3; return e
        }
        Entities.previewStore = EntityStore(records: [
            ent("p:1", "Ana Example", "designer, at Sample Studio", ["phone": ["+380 44 555 0100"], "email": ["ana@example.test"], "address": ["Sample st 1, Kyiv"]], org: "Sample Studio"),
            ent("p:2", "Anatoliy Demo", "finance lead", ["email": ["tolik@example.test"]]),
            ent("p:3", "Анна Зразок", "lawyer, at Made-up Legal", ["phone": ["+380 67 000 0000"]]),
        ])
        defer { Entities.previewStore = nil }
        let card = MentionCard.shared
        card.people = [0, 1, 2]; card.sel = 0
        NSApplication.shared.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        card.view.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        card.view.frame = NSRect(origin: .zero, size: card.view.fit())
        try UIShots.save(card.view, path)
    }
}

/// No trigger: "Ana's number" -> a chip with her phone; Tab puts it after the words (Keys runs "expand").
enum MentionAsk {
    static func offer(_ before: String) -> [String: Any]? {
        let st = Entities.store
        guard let (i, key, text) = MentionRules.ask(before, in: st) else { return nil }
        let e = st.records[i], line = before.components(separatedBy: "\n").last ?? ""
        let prefix = line.last?.isWhitespace == true ? "" : " "
        return ["id": "person", "chip": "\(e.name) · \(MentionRules.labels[key - 1]) · \(text)",
                "run": ["kind": "expand", "old": "", "new": prefix + text, "key": "mention"]]
    }
}

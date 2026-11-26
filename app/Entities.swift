// Entities in the app (14 November 2026, docs/reviews/2026-11-14-entities.md, steps 1 and 2).
//
// Step 1, the `;` card for any entity: `;лан` shows one tape row at the caret (kind glyph, name, what Tab puts in).
// Tab puts the reference for this app (Obsidian: [[path|name]]; mail: the name, → for "Name <address>"; elsewhere the
// name), ⇧Tab the plain name, ← → the other forms (address, Telegram, link), ↓ ↑ the next entity, a digit fixes the
// kind (1 person · 2 org · 3 project · 4 tool · 5 doc · 6 place · 0 not a thing), Esc leaves what he typed.
// `;ctx lan`: the "context for" brief (the entity and its related ones). Snippet keys keep their prefixes.
//
// Step 2, context for agents, only in AI apps (AppKind "ai") and coding agents (RefRules.agent): at a word end the
// last 1-3 words are looked up in the prebuilt map (EntityRules.mention, about 10-60 µs, never the engine); a name
// that resolves gets a quiet dotted mark for 8 s. ⌥Tab with no selection attaches the packs of the names in this
// message (typed or dictated) to a tray and opens the preview (ContextPanel): the exact text that will go in, ← →
// level (name, one line, full), ↑ ↓ entity, ⌫ remove, ⏎ put the block at the end of the message, ⌘C copy, Esc keeps
// the tray; nothing goes in without the preview. Backspace right after takes the block (or a card's
// insert) out again. Nothing is sent: the block is text in his box until he sends it.
//
// Files (local, untracked): data/entities.json (read), data/entity-overrides.json (kind fixes), data/entity-picks.json
// (which one of two, per place, 30 days), data/context-levels.json (his last level per entity, 30 days).
import AppKit
import Carbon

enum Entities {
    // MARK: the store

    private static let snap = LocalSnapshot<EntityStore>([Home.data.appendingPathComponent("entities.json"), Home.settings, Home.data.appendingPathComponent("sources.json")]) { files in
        guard let d = files[0] else { return EntityStore() }
        var s = try JSONDecoder().decode(EntityStore.self, from: d)
        let vault = files[1].flatMap(Settings.decode)?.obsidianVault ?? ""
        let sources = files[2].flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        let vaultOn = (sources?["obsidian"] as? [String: Any])?["enabled"] as? Bool ?? true
        s.records = s.records.map { record in
            var record = record
            if !vaultOn || vault.isEmpty || record.pack?.obsidianVault != vault {
                record.pack?.pointers.removeAll { $0.value.hasPrefix("obsidian://") }
                record.pack?.facts.removeAll { $0.source == "Obsidian" }
                let newest = record.pack?.facts.map(\.date).max()
                record.pack?.newest = newest
            }
            return record
        }
        let fixed = kindFixes
        if !fixed.isEmpty { s.records = s.records.map { r in var r = r; if let k = fixed[r.id] { if k == "none" { r.cards_only = true } else { r.kind = k } }; return r } }
        return s
    }
    /// The last complete snapshot (never read on the tap; the first call starts the read off the main thread).
    static var store: EntityStore { previewStore ?? snap.read() ?? EntityStore() }
    static var previewStore: EntityStore?   // --ui-preview: made-up entities, never the file
    static func warm() { _ = snap.read() }

    // kind fixes made in this run, laid over the file until the nightly build writes them in (read off the main thread)
    private static let fixLock = NSLock()
    private static var _fixes: [String: String] = [:]
    private static var kindFixes: [String: String] { fixLock.lock(); defer { fixLock.unlock() }; return _fixes }

    /// The one-key kind fix: data/entity-overrides.json (the build reads it; his answer wins on every rebuild).
    static func setKind(_ id: String, key: Character) -> String? {
        guard let kind = EntityRules.kindKeys[key] else { return nil }
        let url = Home.data.appendingPathComponent("entity-overrides.json")
        var all = (try? JSONSerialization.jsonObject(with: Data(contentsOf: url))) as? [String: Any] ?? [:]
        all[id] = ["kind": kind, "by": "me", "at": EntityRules.today()]
        if let d = try? JSONSerialization.data(withJSONObject: all, options: [.prettyPrinted, .sortedKeys]) { try? d.write(to: url, options: .atomic) }
        fixLock.lock(); _fixes[id] = kind; fixLock.unlock()
        var s = store
        s.records = s.records.map { r in var r = r; if r.id == id { if kind == "none" { r.cards_only = true } else { r.kind = kind } }; return r }
        snap.publish(s)
        log("entity kind set by key \(key)")
        return kind
    }

    // MARK: where he is

    static func kind(_ s: Spot) -> String {
        AppKind.of(s.app.bundleIdentifier ?? "", title: s.title, ai: Keys.aiApps, chats: Keys.chatApps, browsers: Keys.browsers, aiTitle: Keys.aiTitle)
    }
    static func dest(_ s: Spot) -> String { RefRules.dest(id: s.app.bundleIdentifier ?? "", title: s.title, kind: kind(s)) }
    static func defaultLevel(_ dest: String) -> Int {
        let st = Drafter.shared.settings
        return RefRules.level(dest, ai: st.contextLevelAI, agent: st.contextLevelAgent)
    }
    /// The place a pick is remembered for: the app and the window title (a chat, a document, a thread).
    static func place(_ s: Spot) -> String { (s.app.bundleIdentifier ?? "") + "|" + s.title }

    // MARK: putting text in, and taking it back

    struct Done { let el: AXUIElement; let old: String; let new: String; let revision: Int; let at: Date }
    static var last: Done?

    /// The typed `old` (right before the caret) becomes `new`. false: the field changed under us.
    @discardableResult
    static func replace(old: String, new: String, expected: Spot) -> Bool {
        guard let s = Focus.spot(skip: Drafter.shared.settings.skip).0, CFEqual(expected.el, s.el),
              expected.app.processIdentifier == s.app.processIdentifier,
              s.before.replacingOccurrences(of: "\u{A0}", with: " ").hasSuffix(old) else { Pill.shared.flash("Text has changed"); return false }
        Keys.shared.cancel()
        Focus.backspace(old.count)
        Focus.typeText(new)
        last = Done(el: s.el, old: old, new: new, revision: Keys.shared.inputRevision, at: Date())
        return true
    }

    /// The block goes at the end of the message (⌘↓ moves the caret there), after a blank line; the caret stays there.
    static func append(_ block: String, el: AXUIElement) {
        guard !block.isEmpty, !IsSecureEventInputEnabled() else { return }
        Keys.shared.cancel()
        let src = CGEventSource(stateID: .hidSystemState)
        for down in [true, false] {
            let e = CGEvent(keyboardEventSource: src, virtualKey: 125, keyDown: down)
            e?.flags = .maskCommand; e?.setIntegerValueField(.eventSourceUserData, value: Focus.mark); e?.post(tap: .cghidEventTap)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            let before = Focus.spot(skip: Drafter.shared.settings.skip).0?.before ?? ""
            let gap = before.isEmpty ? "" : before.hasSuffix("\n\n") ? "" : before.hasSuffix("\n") ? "\n" : "\n\n"
            let text = gap + block
            Focus.paste(text)
            last = Done(el: el, old: "", new: text, revision: Keys.shared.inputRevision, at: Date())
        }
    }

    /// Backspace as the very next key after a card's insert or a context block: it comes out again.
    static func takeBack() -> Bool {
        guard let d = last, Keys.shared.inputRevision == d.revision + 1, Date().timeIntervalSince(d.at) < 60 else { last = nil; return false }
        last = nil
        DispatchQueue.main.async {
            guard let s = Focus.spot(skip: Drafter.shared.settings.skip).0, CFEqual(s.el, d.el),
                  s.before.replacingOccurrences(of: "\u{A0}", with: " ").hasSuffix(d.new.replacingOccurrences(of: "\u{A0}", with: " ")) else { return }
            Fields.left(d.new.count, shift: true)
            if d.old.isEmpty { Focus.backspace(1) } else { Focus.typeText(d.old) }
            log("entity insert taken back, \(d.new.count) chars")
        }
        return true
    }

    // MARK: step 2: names in this message, the tray

    struct Pending { let index: Int; let id: String; let text: String; let candidates: [String]; let resolved: Bool; let typed: Bool }
    struct TrayItem { let id: String; var level: Int; var mentions: Int }
    private(set) static var pending: [Pending] = []
    static var tray: [TrayItem] = []
    private static var field: AXUIElement?, fieldPid: pid_t = 0, fieldDest = "", fieldPlace = ""
    private static var costs: [Double] = []

    /// A new field or app: the names and the tray belong to the message being written there.
    private static func same(_ s: Spot) -> Bool {
        if let f = field, CFEqual(f, s.el), fieldPid == s.app.processIdentifier { return true }
        field = s.el; fieldPid = s.app.processIdentifier; pending = []; tray = []; EntityMark.shared.hide()
        return false
    }

    /// Keys.ask, after the debounce, with the field just read. Only in AI apps and coding agents, only right after a
    /// word ended. Cheap: a few dictionary lookups on the prebuilt map.
    static func wordEnd(_ s: Spot) {
        guard Drafter.shared.settings.contextPacks, let last = s.before.last, !last.isLetter, last != "'", last != "’", last != "-" else { return }
        let d = dest(s)
        guard d == "ai" || d == "agent" else { return }
        let st = store
        guard !st.records.isEmpty else { return }
        _ = same(s); fieldDest = d; fieldPlace = place(s)
        let t0 = DispatchTime.now().uptimeNanoseconds
        let ctx = EntityRules.fold(String(s.before.suffix(400)) + " " + s.title)
        let m = EntityRules.mention(before: s.before, store: st, context: ctx, picks: picks(for: fieldPlace), expect: EntityRules.expect(dest: d))
        cost(Double(DispatchTime.now().uptimeNanoseconds - t0) / 1000)
        guard let m, m.how != "part" || m.resolved else { return }
        let r = st.records[m.index]
        if pending.contains(where: { $0.id == r.id }) || tray.contains(where: { $0.id == r.id }) {
            if let i = tray.firstIndex(where: { $0.id == r.id }) { tray[i].mentions += 1 }
            return
        }
        // a lone first name or surname that matches one record: still a mark, since he sees the preview before anything goes in
        pending.append(Pending(index: m.index, id: r.id, text: m.text, candidates: m.candidates.map { st.records[$0].id }, resolved: m.resolved, typed: true))
        EntityMark.shared.show(m, in: s, ambiguous: !m.resolved)
    }

    /// A dictated take was put in (app/Voice.swift, once its text is final): its names wait for ⌥Tab, one quiet line says so.
    static func dictated(_ text: String) {
        guard Drafter.shared.settings.contextPacks, let s = Focus.spot(skip: Drafter.shared.settings.skip).0 else { return }
        let d = dest(s)
        guard d == "ai" || d == "agent" else { return }
        let st = store
        guard !st.records.isEmpty else { return }
        _ = same(s); fieldDest = d; fieldPlace = place(s)
        let found = EntityRules.mentions(in: text, store: st, expect: EntityRules.expect(dest: d)).filter { i in !pending.contains { $0.id == st.records[i].id } && !tray.contains { $0.id == st.records[i].id } }
        guard !found.isEmpty else { return }
        for i in found { pending.append(Pending(index: i, id: st.records[i].id, text: st.records[i].name, candidates: [st.records[i].id], resolved: true, typed: false)) }
        Pill.shared.flash("⌥Tab context: " + found.prefix(3).map { st.records[$0].name }.joined(separator: ", ") + (found.count > 3 ? " +\(found.count - 3)" : ""))
        log("entity: take with \(found.count) names")
    }

    /// ⌥Tab with nothing selected may be ours: there are names waiting or a tray (read on the tap: no AX, no files).
    static func mayAttach() -> Bool { Drafter.shared.settings.contextPacks && (!pending.isEmpty || !tray.isEmpty) }

    /// ⌥Tab, off the tap: the waiting names join the tray and the preview opens. false: nothing here, the key goes on.
    static func optionTab() -> Bool {
        guard Drafter.shared.settings.contextPacks, let s = Focus.spot(skip: Drafter.shared.settings.skip).0, same(s) else { return false }
        let st = store
        EntityMark.shared.hide()
        var ask: Pending?
        for p in pending {
            if !p.resolved { ask = ask ?? p; continue }
            add(p.id, mentions: 1)
        }
        pending.removeAll { $0.resolved }
        if let a = ask {
            pending.removeAll { $0.id == a.id }
            let idx = a.candidates.compactMap { st.byId[$0] }
            ContextPanel.shared.choose(idx, name: a.text, spot: s)
            return true
        }
        guard !tray.isEmpty else { return false }
        ContextPanel.shared.open(spot: s)
        return true
    }

    static func add(_ id: String, mentions: Int) {
        if let i = tray.firstIndex(where: { $0.id == id }) { tray[i].mentions += mentions; return }
        tray.append(TrayItem(id: id, level: level(for: id) ?? defaultLevel(fieldDest.isEmpty ? "ai" : fieldDest), mentions: mentions))
    }

    /// He picked one of two for this name here: remembered for the place (30 days).
    static func picked(_ id: String, name: String, spot: Spot) {
        var all = readJSON("entity-picks.json")
        all[place(spot) + "|" + EntityRules.fold(name)] = ["id": id, "at": Date().timeIntervalSince1970]
        writeJSON("entity-picks.json", all)
        _ = same(spot); fieldPlace = place(spot); fieldDest = dest(spot)
        add(id, mentions: 1)
    }
    private static func picks(for place: String) -> [String: String] {
        let now = Date().timeIntervalSince1970
        var out: [String: String] = [:]
        for (k, v) in readJSONCached("entity-picks.json") {
            guard k.hasPrefix(place + "|"), let d = v as? [String: Any], let id = d["id"] as? String,
                  now - (d["at"] as? Double ?? 0) < 30 * 86400 else { continue }
            out[String(k.dropFirst(place.count + 1))] = id
        }
        return out
    }
    static func level(for id: String) -> Int? {
        guard let d = readJSONCached("context-levels.json")[id] as? [String: Any], let l = d["level"] as? Int,
              Date().timeIntervalSince1970 - (d["at"] as? Double ?? 0) < 30 * 86400 else { return nil }
        return l
    }
    static func remember(level: Int, for id: String) {
        var all = readJSON("context-levels.json")
        all[id] = ["level": level, "at": Date().timeIntervalSince1970]
        writeJSON("context-levels.json", all)
    }

    /// The block for the tray as it stands.
    static func trayBlock() -> String {
        let st = store, ids = st.byId
        let items = tray.compactMap { t in ids[t.id].map { EntityRules.Item(entity: st.records[$0], level: t.level, mentions: t.mentions) } }
        return EntityRules.block(items, today: EntityRules.today())
    }

    /// ⏎ in the preview: the block goes in, the tray empties.
    static func insertTray(el: AXUIElement) {
        let b = trayBlock()
        let n = tray.filter { $0.level >= 2 }.count
        tray = []; pending = []
        guard !b.isEmpty else { return }
        append(b, el: el)
        log("context block put in: \(n) entities, \(b.count) chars")
    }

    /// Enter in a field with a tray he never put in: the tray goes, the log counts it (proposal 5.5).
    static func sent() {
        if !tray.isEmpty { log("context tray dropped at send: \(tray.count)") }
        tray = []; pending = []; EntityMark.shared.hide()
    }

    private static func cost(_ us: Double) {
        costs.append(us)
        guard costs.count >= 200 else { return }
        let s = costs.sorted()
        log(String(format: "entity word ends: %d, p50 %.0f µs, p99 %.0f µs", s.count, s[s.count / 2], s[Int(Double(s.count) * 0.99)]))
        costs = []
    }

    // MARK: the cheap doors

    /// The Quick panel: `@lan` copies its full pack, "context for lan" (or "ctx lan") the brief with related ones.
    static func door(_ query: String) -> (text: String, what: String)? {
        let q = query.trimmingCharacters(in: .whitespaces)
        let st = store
        guard !st.records.isEmpty else { return nil }
        for p in ["context for ", "ctx "] where q.lowercased().hasPrefix(p) {
            guard let i = EntityRules.find(String(q.dropFirst(p.count)), in: st).first(where: { !st.records[$0].cardOnly }) else { return nil }
            return (EntityRules.brief(st.records[i], store: st, today: EntityRules.today()), "context for " + st.records[i].name)
        }
        guard q.hasPrefix("@"), let i = EntityRules.find(q, in: st).first(where: { !st.records[$0].cardOnly }) else { return nil }
        return (EntityRules.block([.init(entity: st.records[i], level: 3, mentions: 1)], today: EntityRules.today()), st.records[i].name)
    }
    static func doorHint(_ query: String) -> String? { door(query).map { "⏎ puts in, ⌘C copies " + $0.what } }

    /// A door's text, after the Quick panel closed: into the field he was in, else onto the clipboard.
    static func doorTake(_ text: String, what: String, put: Bool) {
        let st = Drafter.shared.settings
        if put, !IsSecureEventInputEnabled(), let s = Focus.spot(skip: st.skip).0 {
            append(text, el: s.el)                               // at the end of the message, as the ⌥Tab block
            log("context door: put in, \(text.count) chars")
            return
        }
        History.copy(text)
        Pill.shared.flash("Copied " + what + " · ⌘V to paste")
        log("context door: copied, \(text.count) chars")
    }

    /// His correction from a card ("Not related", "Not this one", "Same", "Not the same"): data/entity-fixes.json,
    /// applied by the next build (engine/entities.py). No card calls it yet.
    @discardableResult
    static func fix(_ what: String, _ a: String, _ b: String, why: String = "") -> Bool {
        guard let all = EntityRules.addFix(readJSON("entity-fixes.json"), what: what, a: a, b: b, why: why) else { return false }
        writeJSON("entity-fixes.json", all)
        log("entity fix: \(what)")
        return true
    }

    // MARK: small files

    private static var jsonCache: [String: (Date, [String: Any])] = [:]
    private static func readJSON(_ name: String) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data(contentsOf: Home.data.appendingPathComponent(name)))) as? [String: Any] ?? [:]
    }
    private static func readJSONCached(_ name: String) -> [String: Any] {
        let url = Home.data.appendingPathComponent(name)
        let m = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date ?? .distantPast
        if let c = jsonCache[name], c.0 == m { return c.1 }
        let v = readJSON(name); jsonCache[name] = (m, v); return v
    }
    private static func writeJSON(_ name: String, _ v: [String: Any]) {
        if let d = try? JSONSerialization.data(withJSONObject: v, options: [.sortedKeys]) { try? d.write(to: Home.data.appendingPathComponent(name), options: .atomic) }
        jsonCache[name] = nil
    }
}

// MARK: - the `;` card

final class EntityCard {
    static let shared = EntityCard()
    let panel = FixMarks.overlay()
    let view = EntityCardView()
    private(set) var choices: [Int] = []
    func choicesForPreview(_ c: [Int]) { choices = c }
    var sel = 0, form = 0
    var old = "", dest = "plain", brief = false
    private var spot: Spot?
    var isOpen: Bool { panel.isVisible }

    init() { panel.contentView = view; view.card = self }

    var current: Entity? { sel < choices.count ? Entities.store.records[choices[sel]] : nil }
    var forms: [RefRules.Form] {
        guard let e = current else { return [] }
        if brief { return [RefRules.Form(label: "context for", text: EntityRules.brief(e, store: Entities.store, today: EntityRules.today()))] }
        return RefRules.forms(e, dest: dest)
    }

    /// Keys.ask: the line ends in `;query` (2+ letters) or `;ctx query`. true = the card shows (nothing else is offered).
    func offer(_ s: Spot, reserved: Set<String>) -> Bool {
        let line = s.before.components(separatedBy: "\n").last ?? ""
        var typed = "", isBrief = false
        if let r = line.range(of: #";ctx [\p{L}'’ʼ -]{2,40}$"#, options: .regularExpression) { typed = String(line[r]); isBrief = true }
        else if let w = line.split(whereSeparator: { $0.isWhitespace }).last, w.hasPrefix(";"), line.hasSuffix(w) { typed = String(w) }
        guard typed.count >= 3, let rect = s.rect else { hide(); return false }
        if !isBrief, reserved.contains(where: { $0.lowercased().hasPrefix(typed.lowercased()) }) { hide(); return false }
        let q = isBrief ? String(typed.dropFirst(5)) : String(typed.dropFirst())
        // 3+ letters: ;en / ;uk stay the translate keys, ;ctx waits for its name
        guard isBrief || (q.count >= 3 && q.lowercased() != "ctx" && q.allSatisfy({ $0.isLetter || "'’ʼ-".contains($0) })) else { hide(); return false }
        let st = Entities.store
        let found = EntityRules.find(q, in: st).filter { !isBrief || !st.records[$0].cardOnly }
        guard !found.isEmpty else { hide(); return false }
        choices = found; sel = 0; form = 0; old = typed; brief = isBrief; spot = s
        dest = Entities.dest(s)
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
    func hide() { if panel.isVisible { panel.orderOut(nil) }; choices = []; brief = false }

    /// A key while the card shows (on the tap). true = swallowed.
    func key(_ code: Int64, _ mods: CGEventFlags, _ typed: String) -> Bool {
        guard isOpen, !choices.isEmpty else { return false }
        switch code {
        case 48 where mods.isEmpty || mods == .maskShift:
            let plain = mods == .maskShift
            DispatchQueue.main.async { self.take(plain: plain) }; return true
        case 125, 126 where mods.isEmpty:
            sel = EntityRules.wrap(sel + (code == 125 ? 1 : -1), choices.count); form = 0; view.needsDisplay = true; refit(); return true
        case 123, 124 where mods.isEmpty:
            form = EntityRules.wrap(form + (code == 124 ? 1 : -1), max(1, forms.count)); view.needsDisplay = true; refit(); return true
        case 53 where mods.isEmpty:
            DispatchQueue.main.async { self.hide() }; return true
        default:
            if mods.isEmpty, let ch = typed.first, typed.count == 1, EntityRules.kindKeys[ch] != nil, let e = current {
                DispatchQueue.main.async {
                    if let k = Entities.setKind(e.id, key: ch) { Pill.shared.flash(k == "none" ? "\(e.name): not a thing" : "\(e.name): \(EntityRules.kindWord[k] ?? k)") }
                    self.view.needsDisplay = true
                }
                return true
            }
            return false
        }
    }
    private func refit() { if let r = spot?.rect { show(at: r) } }

    private func take(plain: Bool) {
        guard let e = current, let s = spot else { return }
        let fs = forms
        let f = plain ? RefRules.Form(label: "name", text: e.name) : (fs.isEmpty ? RefRules.Form(label: "name", text: e.name) : fs[EntityRules.wrap(form, fs.count)])
        hide()
        let ai = dest == "ai" || dest == "agent"
        // in an AI app the reference is the name; its pack joins the tray (⌥Tab shows it)
        let text = brief ? f.text : (ai && f.label == "context" ? e.name : f.text)
        guard Entities.replace(old: old, new: text, expected: s) else { return }
        if ai && !brief && !plain && f.label == "context" {
            Entities.picked(e.id, name: e.name, spot: s)
            Pill.shared.flash("Context · \(Entities.tray.count) · ⌥Tab to see")
        }
        log("entity card: \(brief ? "brief" : f.label) \(e.kind) in \(dest)")
    }
}

extension EntityRules {
    static func wrap(_ i: Int, _ n: Int) -> Int { n == 0 ? 0 : (i % n + n) % n }
}

/// One tape row (app/TapeDraw.swift): the kind's glyph in the gutter, the name and its line, what Tab puts in below,
/// and the keys. The chosen look of the Quick panel, at the caret.
final class EntityCardView: NSView {
    weak var card: EntityCard?
    override var isFlipped: Bool { true }
    static let width: CGFloat = 440, gutter: CGFloat = 44
    func fit() -> NSSize { NSSize(width: Self.width, height: 96) }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }
    override func draw(_ dirty: NSRect) {
        guard let c = card, let e = c.current else { return }
        EntityDraw.card(bounds, entity: e, forms: c.forms, form: c.form, index: c.sel, count: c.choices.count, brief: c.brief)
    }
}

enum EntityDraw {
    /// The `;` card: also drawn by --ui-preview from made-up entities.
    static func card(_ b: NSRect, entity e: Entity, forms: [RefRules.Form], form: Int, index: Int, count: Int, brief: Bool) {
        TapeDraw.surface(b)
        // caret-cozy round: the panels' style (app/Panel.swift): the kind's symbol, the name, the kind quietly after it,
        // who on the second line; a hairline; the key cap and what Tab puts in
        let row = NSRect(x: 0, y: 0, width: b.width, height: 58)
        Native.drawMark(EntityRules.glyph(e.kind), in: NSRect(x: 16, y: 12, width: 18, height: 18), tint: Native.blue)
        let x: CGFloat = 46, w = b.width - x - 14
        let nameA = TapeDraw.at(Native.text(14, .semibold), Native.ink)
        let nw = min(w * 0.6, TapeDraw.width(e.name, nameA))
        TapeDraw.line(e.name, NSRect(x: x, y: TapeDraw.lineTop(Native.text(14), mid: 21), width: nw, height: 20), nameA)
        let meta = e.kindWord + (e.isPrivate ? " · private, allowed by you" : "") + (count > 1 ? "  \(index + 1)/\(count)" : "")
        TapeDraw.line(meta, NSRect(x: x + nw + 8, y: TapeDraw.lineTop(Panel.hint, mid: 21), width: max(0, w - nw - 8), height: 18), TapeDraw.at(Panel.hint, Native.faint))
        TapeDraw.line(e.whoLine.isEmpty ? (e.cardOnly ? "contact card" : "no notes yet") : e.whoLine,
                      NSRect(x: x, y: TapeDraw.lineTop(Panel.font, mid: 41), width: w, height: 18), TapeDraw.at(Panel.font, Native.muted))
        Panel.divider(x0: 0, x1: b.width, y: row.maxY + 2)
        // what goes in
        let f = forms.isEmpty ? RefRules.Form(label: "name", text: e.name) : forms[EntityRules.wrap(form, forms.count)]
        let y = row.maxY + 8
        let kx = TapeDraw.keyWord("⇥", brief ? "context for" : f.label, x: 14, y: y, gap: 10)
        let shown = brief ? "\(f.text.count) characters, \(1 + (e.related?.count ?? 0)) entities" : f.text.replacingOccurrences(of: "\n", with: " ")
        let tA = TapeDraw.at(Native.mono(12), Native.ink, cut: .byTruncatingMiddle)
        let right = forms.count > 1 && !brief ? "← → \(EntityRules.wrap(form, forms.count) + 1)/\(forms.count)" : ""
        let rw = right.isEmpty ? 0 : TapeDraw.width(right, TapeDraw.at(Native.mono(11), Native.muted)) + 12
        TapeDraw.line(shown, NSRect(x: kx, y: TapeDraw.lineTop(Native.mono(12), mid: y + TapeDraw.capH / 2), width: b.width - kx - 14 - rw, height: 18), tA)
        if !right.isEmpty { TapeDraw.line(right, NSRect(x: b.width - 14 - rw + 12, y: y + 5, width: rw, height: 16), TapeDraw.at(Native.mono(11), Native.muted)) }
    }
}

// MARK: - the quiet mark under a name

final class EntityMark {
    static let shared = EntityMark()
    private let panel = FixMarks.overlay()
    private let line = EntityDots()
    private var timer: Timer?
    init() { panel.contentView = line }

    /// A thin dotted line under the name for 8 s (a small "2" after it when two things share the name). Never moves the
    /// caret, never changes text.
    func show(_ m: EntityMention, in s: Spot, ambiguous: Bool) {
        var r: CGRect?
        if !s.viaMarkers, s.caret - m.back >= 0 { r = Focus.bounds(s.el, s.caret - m.back, m.length) }
        if r == nil, let caret = FixMarks.shared.caretMarker(s.el) {
            var walk = [caret]
            for _ in 0..<(m.back + 2) { guard let p = FixMarks.shared.prev(s.el, walk.last!) else { break }; walk.append(p) }
            if walk.count > m.back { r = FixMarks.shared.box(s.el, walk[m.back], walk[m.back - m.length]) }
        }
        guard let rect = r, rect.width > 2 else { return }
        draw(Ghost.shared.cocoa(rect), ambiguous: ambiguous)
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 8, repeats: false) { [weak self] _ in self?.hide() }
    }
    func draw(_ c: CGRect, ambiguous: Bool) {
        line.ambiguous = ambiguous
        panel.setFrame(NSRect(x: c.minX, y: c.minY - 3, width: c.width + (ambiguous ? 10 : 0), height: ambiguous ? 9 : 2), display: true)
        line.needsDisplay = true
        panel.orderFrontRegardless()
    }
    func hide() { timer?.invalidate(); panel.orderOut(nil) }
    /// Preview: the mark's view alone, for a made-up word.
    static func preview(width: CGFloat, ambiguous: Bool) -> NSView {
        let v = EntityDots(frame: NSRect(x: 0, y: 0, width: width + (ambiguous ? 10 : 0), height: ambiguous ? 9 : 2)); v.ambiguous = ambiguous; return v
    }
}

/// Dots in the muted ink, one on, two off: quieter than a fix mark (warn, two on two off).
final class EntityDots: NSView {
    var ambiguous = false
    override func draw(_ r: NSRect) {
        let y: CGFloat = ambiguous ? bounds.height - 2 : 0
        Native.muted.setFill()
        var x: CGFloat = 0
        let end = bounds.width - (ambiguous ? 10 : 0)
        while x < end { NSRect(x: x, y: y, width: 1.5, height: 1.5).fill(); x += 4 }
        if ambiguous {
            ("2" as NSString).draw(at: NSPoint(x: end + 3, y: -1), withAttributes: [.font: Native.mono(8, .medium), .foregroundColor: Native.muted])
        }
    }
}

// MARK: - the preview: what will go in, before it goes in

final class ContextPanel {
    static let shared = ContextPanel()
    enum Mode { case tray, choose }
    let panel: NSPanel
    let view = ContextView()
    var mode = Mode.tray
    var sel = 0
    var options: [Int] = []          // choose mode: record indices
    var name = ""
    private var spot: Spot?
    var isOpen: Bool { panel.isVisible }

    init() {
        panel = NSPanel(contentRect: .zero, styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: true)
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true
        panel.level = .popUpMenu; panel.ignoresMouseEvents = true; panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.contentView = view; view.model = self
    }

    func open(spot s: Spot) { mode = .tray; spot = s; sel = min(sel, max(0, Entities.tray.count - 1)); place() }
    func choose(_ idx: [Int], name n: String, spot s: Spot) { mode = .choose; options = idx; name = n; sel = 0; spot = s; place() }
    func close() { panel.orderOut(nil) }

    private func place() {
        let size = view.fit()
        var scr: NSScreen? = NSScreen.main
        if let r = spot?.rect { let p = Ghost.shared.cocoa(r).origin; scr = NSScreen.screens.first { $0.frame.contains(p) } ?? scr }
        guard let f = scr?.visibleFrame else { return }
        // centred in the upper third, as the Quick panel
        panel.setFrame(NSRect(x: f.midX - size.width / 2, y: f.maxY - f.height / 3 - size.height / 2, width: size.width, height: size.height), display: true)
        view.frame = NSRect(origin: .zero, size: size)
        view.needsDisplay = true
        panel.orderFrontRegardless()
    }

    /// Keys while it is open (on the tap). Everything is swallowed but ⌘/⌃ shortcuts, which close it.
    func key(_ code: Int64, _ mods: CGEventFlags, _ typed: String) -> Bool {
        let cmd = mods.contains(.maskCommand)
        if mods.contains(.maskControl) || (cmd && code != 8) { DispatchQueue.main.async { self.close() }; return false }
        DispatchQueue.main.async { self.handle(code, cmd: cmd, typed: typed) }
        return true
    }

    private func handle(_ code: Int64, cmd: Bool, typed: String) {
        let st = Entities.store, ids = st.byId
        let n = mode == .tray ? Entities.tray.count : options.count
        switch code {
        case 53: close(); return
        case 126: sel = EntityRules.wrap(sel - 1, n)
        case 125: sel = EntityRules.wrap(sel + 1, n)
        case 123, 124 where mode == .tray && sel < Entities.tray.count:
            let l = min(3, max(1, Entities.tray[sel].level + (code == 124 ? 1 : -1)))
            Entities.tray[sel].level = l
            Entities.remember(level: l, for: Entities.tray[sel].id)
        case 51 where mode == .tray && sel < Entities.tray.count:
            Entities.tray.remove(at: sel); sel = min(sel, max(0, Entities.tray.count - 1))
            log("context: entity removed in preview")
            if Entities.tray.isEmpty { close(); return }
        case 36, 76:
            if mode == .choose {
                guard sel < options.count, let s = spot else { return }
                Entities.picked(st.records[options[sel]].id, name: name, spot: s)
                open(spot: s); return
            }
            close()
            if let s = spot { Entities.insertTray(el: s.el) }
            return
        case 8 where cmd && mode == .tray:
            History.copy(Entities.trayBlock()); Pill.shared.flash("Context copied · ⌘V to paste"); close(); return
        default:
            if let ch = typed.first, typed.count == 1, EntityRules.kindKeys[ch] != nil {
                let id: String? = mode == .tray ? (sel < Entities.tray.count ? Entities.tray[sel].id : nil) : (sel < options.count ? st.records[options[sel]].id : nil)
                if let id, let k = Entities.setKind(id, key: ch) {
                    let nm = ids[id].map { st.records[$0].name } ?? ""
                    Pill.shared.flash(k == "none" ? "\(nm): not a thing" : "\(nm): \(EntityRules.kindWord[k] ?? k)")
                }
            }
        }
        place()
    }
}

/// The tray as tape rows: one per entity, the chosen one unfolded to the exact text; the block's size at the foot.
final class ContextView: NSView {
    weak var model: ContextPanel?
    override var isFlipped: Bool { true }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }
    func fit() -> NSSize {
        guard let m = model else { return NSSize(width: 560, height: 120) }
        let st = Entities.store, ids = st.byId
        if m.mode == .choose { return NSSize(width: 560, height: ContextDraw.chooseHeight(m.options.count)) }
        let items = Entities.tray.compactMap { t in ids[t.id].map { (st.records[$0], t.level) } }
        return NSSize(width: 560, height: ContextDraw.height(items, sel: m.sel, today: EntityRules.today()))
    }
    override func draw(_ dirty: NSRect) {
        guard let m = model else { return }
        let st = Entities.store, ids = st.byId
        if m.mode == .choose {
            ContextDraw.choose(bounds, name: m.name, options: m.options.map { st.records[$0] }, sel: m.sel)
        } else {
            let items = Entities.tray.compactMap { t in ids[t.id].map { (st.records[$0], t.level) } }
            ContextDraw.tray(bounds, items: items, sel: m.sel, block: Entities.trayBlock(), built: st.built_day ?? "", today: EntityRules.today())
        }
    }
}

enum ContextDraw {
    static let rowH: CGFloat = 40, gutter: CGFloat = 36, pad: CGFloat = 14, footH: CGFloat = 46, headH: CGFloat = 34
    static let levelWord = [1: "name", 2: "one line", 3: "full"]
    static func textFor(_ e: Entity, _ level: Int, today: String) -> String {
        level <= 1 ? "Only the name, as written." : EntityRules.render(e, level: level, today: today)
    }
    static func unfold(_ e: Entity, _ level: Int, today: String, width: CGFloat) -> CGFloat {
        let n = TapeDraw.lines(textFor(e, level, today: today), width: width, font: Native.mono(12), lh: 18, max: 12)
        return CGFloat(n) * 18 + 14
    }
    static func height(_ items: [(Entity, Int)], sel: Int, today: String) -> CGFloat {
        var h = headH + footH
        for (i, it) in items.enumerated() { h += rowH + (i == sel ? unfold(it.0, it.1, today: today, width: 560 - gutter - 12 - pad) : 0) }
        return h
    }
    static func chooseHeight(_ n: Int) -> CGFloat { headH + CGFloat(n) * rowH + footH }

    private static func head(_ b: NSRect, _ left: String, _ right: String) {
        TapeDraw.line(left, NSRect(x: pad, y: 10, width: b.width * 0.6, height: 18), TapeDraw.at(Native.text(13, .medium), Native.ink))
        let a = TapeDraw.at(Native.mono(11), Native.muted)
        let w = TapeDraw.width(right, a)
        TapeDraw.line(right, NSRect(x: b.width - pad - w, y: 12, width: w, height: 16), a)
        Panel.divider(x0: 0, x1: b.width, y: headH - 1)
    }

    static func tray(_ b: NSRect, items: [(Entity, Int)], sel: Int, block: String, built: String, today: String) {
        TapeDraw.surface(b)
        head(b, "Context · \(items.count)", "\(block.count) / \(EntityRules.blockMax)" + (built.isEmpty ? "" : " · built \(built)"))
        var y = headH
        for (i, (e, level)) in items.enumerated() {
            let on = i == sel
            let h = rowH + (on ? unfold(e, level, today: today, width: b.width - gutter - 12 - pad) : 0)
            let r = NSRect(x: 0, y: y, width: b.width, height: h)
            if on { Native.pick.setFill(); NSBezierPath(roundedRect: r.insetBy(dx: 6, dy: 2), xRadius: Panel.control, yRadius: Panel.control).fill() }
            Native.drawMark(EntityRules.glyph(e.kind), in: NSRect(x: 18, y: y + (rowH - 16) / 2, width: 16, height: 16), tint: on ? Native.blue : Native.muted)
            let x = gutter + 12, w = b.width - x - pad
            let nameA = TapeDraw.at(Native.text(14, on ? .medium : .regular), Native.ink)
            let nw = min(w * 0.55, TapeDraw.width(e.name, nameA))
            TapeDraw.line(e.name, NSRect(x: x, y: y + 10, width: nw, height: 20), nameA)
            let meta = (levelWord[level] ?? "") + (e.isPrivate ? " · private, allowed by you" : "")
            TapeDraw.line(meta, NSRect(x: x + nw + 10, y: y + 12, width: w - nw - 10, height: 16), TapeDraw.at(Native.mono(11), Native.muted))
            if on {
                TapeDraw.block(textFor(e, level, today: today), x: x, y: y + rowH - 2, width: w, font: Native.mono(12), color: level <= 1 ? Native.muted : Native.ink, lh: 18, max: 12)
            }
            y += h
        }
        foot(b, [("←→", "level"), ("⌫", "remove"), ("↵", "put in"), ("⌘C", "copy"), ("esc", "keep")])
    }

    static func choose(_ b: NSRect, name: String, options: [Entity], sel: Int) {
        TapeDraw.surface(b)
        head(b, "\(name): which one?", "\(options.count)")
        var y = headH
        for (i, e) in options.enumerated() {
            let on = i == sel, r = NSRect(x: 0, y: y, width: b.width, height: rowH)
            if on { Native.pick.setFill(); NSBezierPath(roundedRect: r.insetBy(dx: 6, dy: 2), xRadius: Panel.control, yRadius: Panel.control).fill() }
            Native.drawMark(EntityRules.glyph(e.kind), in: NSRect(x: 18, y: y + (rowH - 16) / 2, width: 16, height: 16), tint: on ? Native.blue : Native.muted)
            let x = gutter + 12, w = b.width - x - pad
            let nameA = TapeDraw.at(Native.text(14, on ? .medium : .regular), Native.ink)
            let nw = min(w * 0.45, TapeDraw.width(e.name, nameA))
            TapeDraw.line(e.name, NSRect(x: x, y: y + 10, width: nw, height: 20), nameA)
            TapeDraw.line(e.whoLine, NSRect(x: x + nw + 10, y: y + 12, width: w - nw - 10, height: 16), TapeDraw.at(Native.text(12), Native.muted))
            y += rowH
        }
        foot(b, [("↑↓", "choose"), ("↵", "this one"), ("1-6", "kind"), ("esc", "plain")])
    }

    private static func foot(_ b: NSRect, _ keys: [(String, String)]) {
        Panel.divider(x0: 0, x1: b.width, y: b.height - footH)
        var x = pad
        for (k, w) in keys { x = TapeDraw.keyWord(k, w, x: x, y: b.height - footH + 11, gap: 14) }
    }
}

// MARK: - --ui-preview (made-up entities only)

enum EntityPreview {
    static func sample() -> EntityStore {
        let v = "/Volumes/sample/Notes Vault/"
        func e(_ id: String, _ kind: String, _ name: String, _ who: String, facts: [EntityFact], ptrs: [EntityPointer], targets: [String: String] = [:],
               handles: [String: [String]] = [:], related: [String] = [], newest: String = "2026-11-11", priv: Bool = false) -> Entity {
            Entity(id: id, kind: kind, name: name, aliases: [], who: who, targets: targets, handles: handles, related: related,
                   pack: EntityPack(facts: facts, pointers: ptrs, newest: newest), heat: 3, cards_only: nil, private: priv)
        }
        return EntityStore(records: [
            e("p:hanna", "person", "Ганна Ткач", "finance lead, at Lantern Labs",
              facts: [EntityFact(text: "writes in Ukrainian, prefers short messages", source: "vault", date: "2026-11-02", quote: false),
                      EntityFact(text: "works on Lantern", source: "vault", date: "2026-11-10", quote: false),
                      EntityFact(text: "email hanna@example.com", source: "vault", date: "", quote: false)],
              ptrs: [EntityPointer(label: "Note", value: v + "Entities/People/Hanna Tkach.md", path: true)],
              targets: ["obsidian": "Entities/People/Hanna Tkach", "mail": "hanna@example.com"],
              handles: ["email": ["hanna@example.com"], "tg": ["hanna_example"]], related: ["x:lantern"]),
            e("x:lantern", "project", "Lantern", "ordering tool for Lantern Labs",
              facts: [EntityFact(text: "status: active", source: "vault", date: "2026-11-11", quote: false),
                      EntityFact(text: "next: invoice export", source: "vault", date: "2026-11-11", quote: true)],
              ptrs: [EntityPointer(label: "Repo", value: "/Volumes/sample/Codius/lantern", path: true),
                     EntityPointer(label: "Story", value: v + "Stories/Lantern.md", path: true)],
              targets: ["obsidian": "Stories/Lantern"], related: ["p:hanna", "t:gate"]),
            e("t:gate", "tool", "lantern-gate", "Cloudflare Worker that holds Lantern storage", facts: [],
              ptrs: [EntityPointer(label: "Code", value: "/Volumes/sample/Codius/lantern-gate", path: true),
                     EntityPointer(label: "URL", value: "https://lantern-gate.example.workers.dev", path: false)], related: ["x:lantern"], newest: ""),
            e("p:hanna2", "person", "Ганна Інша", "designer at a made-up studio", facts: [], ptrs: [], newest: ""),
        ])
    }

    static func shot(_ v: NSView, _ path: String) throws {
        guard let rep = UIShots.bitmap(v), let d = rep.representation(using: .png, properties: [:]) else { throw NSError(domain: "Preview", code: 4) }
        try d.write(to: URL(fileURLWithPath: path))
    }

    static func run(_ folder: String) throws {
        Entities.previewStore = sample()
        defer { Entities.previewStore = nil }
        let caret = CGRect(x: 600, y: -2600, width: 1, height: 20)
        // the `;` card for a person, a project and a tool (an Obsidian note, a mail box, a terminal)
        let card = EntityCard.shared
        for (name, typed, i, dest) in [("person", ";ган", 0, "mail"), ("project", ";lant", 1, "obsidian"), ("tool", ";lantern-g", 2, "agent")] {
            card.preview(choices: i == 0 ? [0, 3] : [i], dest: dest, typed: typed)
            try UIShots.field(folder + "/card-\(name).png", typed: "see " + typed, caret: caret, panel: card.panel)
            card.hide()
        }
        // the mark under a name, and under a name two things share
        for (name, typed, word, two) in [("mark", "Ask Ганна Ткач ", "Ганна Ткач", false), ("mark-two", "Ask about Ганні ", "Ганні", true)] {
            let font = NSFont.systemFont(ofSize: 15.6)
            let full = (typed as NSString).size(withAttributes: [.font: font]).width
            let w = (word as NSString).size(withAttributes: [.font: font]).width
            let space = (" " as NSString).size(withAttributes: [.font: font]).width
            let r = CGRect(x: caret.minX - space - w, y: caret.minY, width: w, height: 20)
            _ = full
            let empty = FixMarks.overlay(); empty.setFrame(NSRect(x: Ghost.shared.cocoa(caret).minX, y: Ghost.shared.cocoa(caret).minY, width: 1, height: 1), display: false)
            empty.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 1, height: 1))
            try UIShots.field(folder + "/\(name).png", typed: typed, caret: caret, panel: empty, font: font) { o in
                let c = Ghost.shared.cocoa(r)
                let v = EntityMark.preview(width: c.width, ambiguous: two)
                if let d = UIShots.bitmap(v) { d.over(NSRect(x: c.minX - o.x, y: c.minY - o.y - 3 - (two ? 7 : 0), width: v.frame.width, height: v.frame.height)) }
            }
        }
        // the preview at each level: the person chosen and unfolded, the project at one line
        let view = ContextPanel.shared.view
        for level in 1...3 {
            Entities.tray = [.init(id: "p:hanna", level: level, mentions: 2), .init(id: "x:lantern", level: 2, mentions: 1), .init(id: "t:gate", level: 3, mentions: 1)]
            ContextPanel.shared.mode = .tray; ContextPanel.shared.sel = 0
            view.frame = NSRect(origin: .zero, size: view.fit())
            try shot(view, folder + "/context-level-\(level).png")
        }
        ContextPanel.shared.sel = 1
        view.frame = NSRect(origin: .zero, size: view.fit())
        try shot(view, folder + "/context-project.png")
        ContextPanel.shared.mode = .choose; ContextPanel.shared.options = [0, 3]; ContextPanel.shared.name = "Ганні"; ContextPanel.shared.sel = 0
        view.frame = NSRect(origin: .zero, size: view.fit())
        try shot(view, folder + "/context-choose.png")
        Entities.tray = []; ContextPanel.shared.mode = .tray
    }
}

extension EntityCard {
    /// --ui-preview: lay the card out for made-up choices, never on screen.
    func preview(choices c: [Int], dest d: String, typed: String) {
        choicesForPreview(c); dest = d; old = typed; sel = 0; form = 0; brief = false
        let size = view.fit()
        let o = Ghost.shared.cocoa(CGRect(x: 600, y: -2600, width: 1, height: 20))
        panel.setFrame(NSRect(x: o.minX - 8, y: o.minY - size.height - 6, width: size.width, height: size.height), display: false)
        view.frame = NSRect(origin: .zero, size: size)
    }
}

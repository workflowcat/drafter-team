// What he just copied, offered where it fits (1 November 2026; Raycast and Pretype do it). A link or a short text he
// copied in another app in the last 3 minutes shows as a chip when the line asks for it: a link after "link", "here",
// "лінк", "посилання", "ось", "тримай"… or a colon; a short text (one line, ≤120 characters) after a colon. Tab types
// it in. Offered once per copy, never Drafter's own pastes or concealed items (History.watchClipboard decides that).
import AppKit

enum Clip {
    private static var last: (text: String, app: String, at: Date, used: Bool)?
    static let cues: Set<String> = ["link", "links", "url", "here", "here's", "heres", "лінк", "лінка", "лінку", "посилання",
                                    "ось", "от", "тут", "тримай", "тримайте", "лови", "ловіть", "глянь", "гляньте", "дивись"]

    static func copied(_ text: String, from app: String) {
        last = (text, app, Date(), false)
        ClipForms.copied(text, app: app)
    }
    static func used() { last?.used = true }

    /// Clipboard context (parity round, setting `clipContext`): the fresh copy for the ghost's prompt, or nil
    /// (ClipContext.pick). Logged once per copy, numbers and a reason word only.
    private static var logged: Date?
    static func forPrompt(_ before: String) -> String? {
        let st = Drafter.shared.settings
        let r = ClipContext.pick(last?.text, copiedAt: last?.at, from: last?.app ?? "", now: Date(), on: st.clipContext, skip: st.skip,
                                 secret: last.map { QuickRules.isSecret($0.text, History.secretRules()) } ?? false, before: before)
        if let at = last?.at, logged != at, r.why != .stale, r.why != .off, r.why != .pasted {
            logged = at
            log(r.text.map { "clip context: \($0.count) chars" } ?? "clip context: left out (\(r.why?.rawValue ?? "?"))")
        }
        return r.text
    }
    /// The copy chip put another form on the clipboard (or back the original): the caret chip offers that text.
    static func replaced(_ text: String) { last?.text = text }

    static func offer(_ s: Spot) -> [String: Any]? {
        guard let c = last, !c.used, Date().timeIntervalSince(c.at) < 180, c.app != (s.app.bundleIdentifier ?? "") else { return nil }
        let line = (s.before.components(separatedBy: "\n").last ?? "").replacingOccurrences(of: "\u{A0}", with: " ")
        let t = c.text
        let isLink = t.range(of: #"^https?://\S+$"#, options: .regularExpression) != nil
        guard isLink || (t.count <= 120 && !t.contains("\n")) else { return nil }
        // the line must end with a space or a colon, after a cue word or a colon
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard line.last == " " || line.last == ":", !trimmed.isEmpty else { return nil }
        let colon = trimmed.hasSuffix(":")
        let lastWord = trimmed.split(separator: " ").last.map { String($0).lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ":,.-—")) } ?? ""
        guard colon || (isLink && cues.contains(lastWord)) else { return nil }
        let new = (line.last == " " ? "" : " ") + t
        var short = isLink ? t.replacingOccurrences(of: #"^https?://(www\.)?"#, with: "", options: .regularExpression) : t
        if short.count > 46 { short = String(short.prefix(45)) + "…" }
        return ["id": "snippet", "chip": "⇥ \(isLink ? "Copied link" : "Copied") · \(short)",
                "run": ["kind": "expand", "old": "", "new": new, "key": "clip"]]
    }
}

/// The copy chip (format round, 15 November 2026; Andrii: "a bunch of autoformatting on copy for dates, numbers, IBAN
/// account"). When the copied text IS one thing (a date, number, amount, IBAN, phone, ЄДРПОУ, link with tracking, path,
/// colour), the strip offers its top form on Tab, ⇧Tab shows the next form (keys round three; digits stay the app's); Esc or typing on dismisses it, ⌘V pastes the
/// original. A picked form goes to the clipboard and "Copied as: …" keeps Undo for 5 s; the original row stays in the
/// journal (the replaced clipboard is never logged as a new copy). After the same pick three times it asks once
/// "Always?"; a rule he confirms then applies at once, with Undo. Never for sensitive things, concealed or secret
/// copies (History.watchClipboard stops those before Clip.copied), skipped apps, or while the strip is busy.
/// Rules: app/FormatRules.swift (CopyChip.plan), data/format-rules.json.
enum ClipForms {
    static let file = Home.data.appendingPathComponent("format-rules.json")
    static var memory: FormatMemory = FormatLearn.load(file)

    static func copied(_ text: String, app: String) {
        guard !Drafter.shared.settings.skip.contains(app), Talk.shared.state == .idle, Spool.active == nil, !Offer.active else { return }
        let original = text
        switch CopyChip.plan(text, memory: memory) {
        case .nothing: return
        case .note(let n): Pill.shared.flash(n)
        case .apply(let kind, let v):
            put(v.text)
            Pill.shared.flash("Copied as: \(v.name.lowercased())", button: StripButton("Undo", key: "", style: .primary) { put(original) })
            log("clip form: rule \(kind) \(v.id)")
        case .offer(let kind, let vs):
            guard !vs.isEmpty else { return }
            present(kind, vs, 0, original: original)
            log("clip form: offered \(kind)")
        }
    }

    /// The copy chip on form `i`: Tab takes it, ⇧Tab shows the next one (keys round three: digits stay the app's).
    static func present(_ kind: String, _ vs: [FormatVariant], _ i: Int, original: String) {
        let v = vs[i]
        Offer.clear()
        Offer.until = Date().addingTimeInterval(8); Offer.forms = vs.count
        Offer.action = { choose(kind, v, original: original) }
        if vs.count > 1 { Offer.step = { present(kind, vs, CopyChip.step(i, forms: vs.count), original: original) } }
        var keys = [StripButton(v.name, key: "tab", style: .primary) { Offer.accept() }]
        if vs.count > 1 { keys.append(StripButton("Next form", key: "⇧tab") { Offer.next() }) }
        keys.append(StripButton("Dismiss", key: "esc") { Offer.dismiss("click") })
        Pill.shared.offer(["Copy \(CopyChip.names[kind] ?? kind) as", "\(v.name): \(CopyChip.preview(v.text))"], kind: "Copy", controls: keys, seconds: 8)
    }

    /// He picked a form: it goes to the clipboard; the third same pick asks once "Always?".
    static func choose(_ kind: String, _ v: FormatVariant, original: String) {
        put(v.text)
        log("clip form: picked \(kind) \(v.id)")
        if FormatLearn.picked(kind, dest: nil, form: v.id, in: &memory) {
            FormatLearn.answer(kind, dest: nil, form: v.id, yes: false, in: &memory)   // asked once, whatever he answers
            save()
            Offer.clear(); Offer.until = Date().addingTimeInterval(8)
            Offer.action = { always(kind, v) }
            Pill.shared.offer(["Copied as: \(v.name.lowercased())", "Always copy \(CopyChip.names[kind] ?? kind) this way?"], kind: "Copy",
                              controls: [StripButton("Always", key: "tab", style: .primary) { Offer.accept() },
                                         StripButton("Undo", key: "") { Offer.dismiss("undo"); put(original) },
                                         StripButton("Not now", key: "esc") { Offer.dismiss("click") }], seconds: 8)
        } else {
            save()
            Pill.shared.flash("Copied as: \(v.name.lowercased())", button: StripButton("Undo", key: "", style: .primary) { put(original) })
        }
    }

    static func always(_ kind: String, _ v: FormatVariant) {
        let prev = FormatLearn.answer(kind, dest: nil, form: v.id, yes: true, in: &memory) ?? nil
        save()
        log("clip form: rule stored \(kind) \(v.id)")
        Pill.shared.flash("Always \(v.name.lowercased()) for \(CopyChip.names[kind] ?? kind)", button: StripButton("Undo", key: "", style: .primary) {
            FormatLearn.undo(kind, dest: nil, previous: prev, in: &memory); save()
            log("clip form: rule undone \(kind)")
        })
    }

    /// The clipboard holds `text`; History skips this change, so the journal keeps the original copy only.
    static func put(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        History.skipChange(pb.changeCount)
        Clip.replaced(text)
    }
    static func save() { FormatLearn.save(memory, to: file) }
}

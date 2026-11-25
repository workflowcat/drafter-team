// Things inside a text, in the views (wire round, 15 November 2026): the detector (app/DetectRules.swift) and the
// written forms (app/FormatRules.swift) connected to the journal, the Quick panel and Pick parts. Pure: Foundation
// only; the views draw and run what these rules say. Tested in tests/found_rules.swift with made-up text.
// - the reader's keys for found things (⌥↓ ⌥↑ to the next or previous one, ↵ its actions, the action keys);
// - "In this text" in Details: each thing with its words and what it resolved to;
// - "Copy as…" and "Insert as…": the forms of one thing and the clean-ups of a text, with a preview each;
// - where a text goes (`FormatDest`) from the front app;
// - Pick parts' "things" level from the real detector.
import Foundation

/// One entry of "Copy as…" / "Insert as…": a written form of the item or of the thing in focus, or a clean-up.
struct FormEntry: Equatable {
    let id: String          // the form's id (FormatVariant.id)
    let name: String        // "ISO date", "Joined lines"
    let preview: String     // one line: the changed part of the result
    let text: String        // the whole result
    let kind: String        // what FormatLearn counts it under: "date", "money"... or "text" for a clean-up
}

/// The reader's focus on a found thing and its actions list.
struct FoundFocus: Equatable {
    var index: Int? = nil   // the thing in focus (in text order)
    var menu = false        // its actions are open
    var row = 0             // the action the keys are on
}

/// "Copy as…" or "Insert as…" open on an item.
struct FormsMenu: Equatable {
    enum Use: Equatable { case copy, insert }
    var use: Use
    var entries: [FormEntry]
    var row = 0
}

enum FoundRules {
    // MARK: Pick parts: the "things" level from the detector

    /// Pick parts' kinds: link, date, amount, email (its quick picks L, D, ⇧4, E), and the rest by their own names.
    static func pickKind(_ k: DetectKind) -> String {
        switch k {
        case .date, .dateRange: return "date"
        case .money: return "amount"
        default: return k.rawValue
        }
    }
    /// The detector as Pick parts' finder: every thing but the sensitive ones, resolved against `written`.
    static func pickThings(written: Date, hints: DetectHints = DetectHints()) -> (String) -> [(range: NSRange, kind: String, label: String)] {
        { text in
            Detect.scan(text, written: written, hints: hints).filter { !$0.sensitive }.map { ($0.range, pickKind($0.kind), $0.words) }
        }
    }

    // MARK: "In this text"

    /// Details' lines: the glyph kind, the words as written and what they resolved to (a date: the day it means; a
    /// link: its address; money: the amount and currency). Sensitive things never show. At most `max` lines.
    static func inThisText(_ found: [Found], max: Int = 12) -> [(kind: String, words: String, value: String)] {
        var out: [(String, String, String)] = []
        var seen = Set<String>()
        for f in found where !f.sensitive {
            guard seen.insert(f.kind.rawValue + "\u{1}" + f.value).inserted else { continue }
            let w = one(f.words, 48)
            var v: String
            switch f.kind {
            case .date, .dateRange: v = f.display
            case .link, .email, .phone, .path, .iban, .money: v = f.value
            default: v = f.display
            }
            v = one(v, 60)
            if fold(v) == fold(w) { v = "" }
            out.append((f.kind.rawValue, w, v))
            if out.count >= max { break }
        }
        return out
    }
    static func one(_ s: String, _ n: Int) -> String {
        let t = s.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\u{00A0}", with: " ").trimmingCharacters(in: .whitespaces)
        return t.count <= n ? t : String(t.prefix(n - 1)) + "…"
    }
    static func fold(_ s: String) -> String { s.lowercased().filter { !$0.isWhitespace } }

    // MARK: the reader's keys for found things

    enum FoundKey: Equatable { case next, prev, ret, esc, up, down, key(String), other }
    enum FoundEffect: Equatable { case pass, none, focus(Int), openMenu, closeMenu, run(Int), clear }

    /// One key. `count`: things in the text; `keys`: the focused thing's action keys ("↵", "C", "⇧C", "K"...) in
    /// order, `built`: which of them run. ⌥↓ / ⌥↑ walk the things (wrapping); ↵ opens the actions, ↵ again runs the
    /// one the keys are on; an action's own key runs it while the list is open; esc closes the list, then the focus.
    /// Any other key passes (the window's own keys go on working while a thing has the focus).
    static func route(_ s0: FoundFocus, _ k: FoundKey, count: Int, keys: [String], built: [Bool]) -> (FoundFocus, FoundEffect) {
        var s = s0
        switch k {
        case .next, .prev:
            guard count > 0 else { return (s, .pass) }
            let d = k == .next ? 1 : -1
            s.index = s.index.map { (($0 + d) % count + count) % count } ?? (d > 0 ? 0 : count - 1)
            s.menu = false; s.row = 0
            return (s, .focus(s.index!))
        case .ret:
            guard let i = s.index, i < count else { return (s, .pass) }
            if !s.menu {
                s.menu = true; s.row = built.firstIndex(of: true) ?? 0
                return (s, .openMenu)
            }
            guard s.row < built.count, built[s.row] else { return (s, .none) }
            s.menu = false
            return (s, .run(s.row))
        case .up, .down:
            guard s.menu, !keys.isEmpty else { return (s, .pass) }
            s.row = max(0, min(keys.count - 1, s.row + (k == .down ? 1 : -1)))
            return (s, .none)
        case .esc:
            if s.menu { s.menu = false; return (s, .closeMenu) }
            if s.index != nil { s.index = nil; return (s, .clear) }
            return (s, .pass)
        case .key(let key):
            guard s.menu else { return (s, .pass) }
            guard let i = keys.firstIndex(of: key) else { return (s, .none) }
            guard i < built.count, built[i] else { return (s, .none) }
            s.menu = false
            return (s, .run(i))
        case .other:
            return (s, s.menu ? .none : .pass)
        }
    }

    // MARK: "Copy as…" and "Insert as…"

    /// The entries: the forms of the thing in focus (or of the whole item when it is one thing), then the clean-ups
    /// of a text clip. A stored rule's form for this kind and destination comes first in its group. Entries that do
    /// not change the text are left out.
    static func forms(text: String, focused: Found?, written: Date, dest: FormatDest = .other, clip: Bool, memory: FormatMemory = FormatMemory(),
                      title: String = "", hints: DetectHints = DetectHints()) -> [FormEntry] {
        var out: [FormEntry] = []
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var kind = "", vs: [FormatVariant] = [], base = t
        if let f = focused, !f.sensitive {
            vs = Format.variants(for: f, dest: dest, title: title, hints: hints); kind = learnKind(f.kind); base = f.words
        } else if let one = Format.whole(t, written: written, hints: hints, dest: dest), !one.sensitive {
            vs = one.variants; kind = one.kind
        }
        vs = vs.filter { $0.text != base }
        if let r = FormatLearn.rule(kind, dest: dest == .other ? nil : dest, in: memory), let i = vs.firstIndex(where: { $0.id == r.form }) {
            vs.insert(vs.remove(at: i), at: 0)
        }
        out += vs.map { FormEntry(id: $0.id, name: $0.name, preview: preview(base, $0.text), text: $0.text, kind: kind) }
        if clip, focused == nil {
            var cs = Format.cleanups(text)
            if let r = FormatLearn.rule("text", dest: dest == .other ? nil : dest, in: memory), let i = cs.firstIndex(where: { $0.id == r.form }) {
                cs.insert(cs.remove(at: i), at: 0)
            }
            out += cs.map { FormEntry(id: $0.id, name: $0.name, preview: preview(text, $0.text), text: $0.text, kind: "text") }
        }
        return out
    }
    static func learnKind(_ k: DetectKind) -> String {
        switch k { case .date, .dateRange: return "date"; default: return k.rawValue }
    }

    /// One line that shows what a form changes: the result from a little before the first change, one line, at most
    /// `n` characters (invisible characters shown as ·).
    static func preview(_ original: String, _ result: String, n: Int = 56) -> String {
        let a = Array(original), b = Array(result)
        var i = 0
        while i < a.count, i < b.count, a[i] == b[i] { i += 1 }
        let from = i < 20 ? 0 : i - 16
        var s = String(b[from...]).replacingOccurrences(of: "\n", with: " ⏎ ").replacingOccurrences(of: "\u{00A0}", with: "·")
        s = String(s.replacingOccurrences(of: "\t", with: " ").filter { !Format.invisible.contains($0) })
        if s.count > n { s = String(s.prefix(n - 1)) + "…" }
        return (from > 0 ? "…" : "") + s
    }

    enum MenuKey: Equatable { case up, down, ret, keep, esc, other }
    enum MenuEffect: Equatable { case none, apply(Int), keep(Int), close }
    /// ↑ ↓ move, ↵ applies the form (copy or insert), ⌥↵ keeps it as a new clip, esc closes.
    static func route(_ m0: FormsMenu, _ k: MenuKey) -> (FormsMenu, MenuEffect) {
        var m = m0
        switch k {
        case .up: m.row = max(0, m.row - 1); return (m, .none)
        case .down: m.row = min(max(0, m.entries.count - 1), m.row + 1); return (m, .none)
        case .ret: return m.entries.isEmpty ? (m, .close) : (m, .apply(m.row))
        case .keep: return m.entries.isEmpty ? (m, .close) : (m, .keep(m.row))
        case .esc: return (m, .close)
        case .other: return (m, .none)
        }
    }

    // MARK: where the text goes

    static let terminals: Set<String> = ["com.apple.Terminal", "com.googlecode.iterm2", "dev.warp.Warp-Stable", "com.mitchellh.ghostty",
                                         "net.kovidgoyal.kitty", "io.alacritty", "co.zeit.hyper", "org.tabby"]
    static let editors: Set<String> = ["com.apple.dt.Xcode", "com.microsoft.VSCode", "com.todesktop.230313mzl4w4u92", "dev.zed.Zed",
                                       "com.sublimetext.4", "com.panic.Nova", "com.barebones.bbedit", "com.vscodium"]
    /// The destination kind from the front app: terminals and editors by bundle id (JetBrains apps too), chats and
    /// mail from AppKind's kind ("chat", "mail"; "ai" boxes read like chats), else other.
    static func dest(bundle: String, kind: String) -> FormatDest {
        if terminals.contains(bundle) { return .terminal }
        if editors.contains(bundle) || bundle.hasPrefix("com.jetbrains.") { return .code }
        switch kind { case "chat", "ai": return .chat; case "mail": return .mail; default: return .other }
    }

    // MARK: search: what a text holds

    /// The search's marks for one text (wire round): `SearchHas` bits for has:date/money/phone/email/path/code/iban/link
    /// and the start of each day it mentions (for mentions:). Only the first `cap` characters are read (a long
    /// transcript: its summary plus the start). Sensitive things never count. Bits as in SearchHas.bit.
    static func searchMarks(_ text: String, written: Date, hints: DetectHints = DetectHints(), cap: Int = 4000) -> (bits: UInt16, days: [Double]) {
        guard !text.isEmpty else { return (0, []) }
        let ns = text as NSString
        let window = ns.length > cap ? NSRange(location: 0, length: cap) : nil
        let f = Detect.flags(Detect.scan(text, written: written, hints: hints, window: window), timeZone: hints.timeZone)
        var b: UInt16 = 0
        if f.link { b |= 8 }
        if f.date { b |= 32 }
        if f.money { b |= 64 }
        if f.phone { b |= 128 }
        if f.email { b |= 256 }
        if f.path { b |= 512 }
        if f.code { b |= 1024 }
        if f.iban { b |= 2048 }
        var cal = Calendar(identifier: .gregorian); cal.timeZone = hints.timeZone
        let days: [Double] = f.days.compactMap { k in
            let p = k.split(separator: "-").compactMap { Int($0) }
            guard p.count == 3, let d = cal.date(from: DateComponents(year: p[0], month: p[1], day: p[2])) else { return nil }
            return d.timeIntervalSince1970
        }
        return (b, days)
    }

    // MARK: the Quick panel: the forms of a clip

    /// A clip that IS one thing: its forms for the destination, each changing the text; a destination rule (or a
    /// general one) first. Empty for anything else (the row behaves as before).
    /// `ruled`: a stored rule names the first form, so the row starts on it (not on the text as copied).
    static func quickForms(_ text: String, written: Date, dest: FormatDest, memory: FormatMemory = FormatMemory()) -> (kind: String, forms: [FormatVariant], ruled: Bool) {
        guard let one = Format.whole(text, written: written, dest: dest), !one.sensitive else { return ("", [], false) }
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var v = one.variants.filter { $0.text != t }
        var ruled = false
        if let r = FormatLearn.rule(one.kind, dest: dest == .other ? nil : dest, in: memory), let i = v.firstIndex(where: { $0.id == r.form }) {
            v.insert(v.remove(at: i), at: 0); ruled = true
        }
        return (one.kind, v, ruled)
    }
}

/// Each row's detector marks for the search, computed once per row id and text (the index build fills it, off the
/// main thread); a row is read again only when its text changed. The per-key search only reads it: the detector never
/// runs while he types. Thread-safe (the build queue writes, the main thread's plain fallback reads).
final class SearchMarkStore {
    static let shared = SearchMarkStore()
    struct Marks: Equatable { let sig: Int; let bits: UInt16; let days: [Double] }
    private var byId: [String: Marks] = [:]
    private let lock = NSLock()
    private(set) var computed = 0          // detector runs (tests and the preview's measure)

    static func sig(_ text: String, written: Double) -> Int { var h = Hasher(); h.combine(text); h.combine(written); return h.finalize() }

    /// The marks for a row: stored ones when its text is the same, else the detector once.
    func marks(id: String, text: String, written: Double, hints: DetectHints = DetectHints()) -> Marks {
        let s = Self.sig(text, written: written)
        lock.lock(); let have = byId[id]; lock.unlock()
        if let have, have.sig == s { return have }
        let m = FoundRules.searchMarks(text, written: Date(timeIntervalSince1970: written), hints: hints)
        let out = Marks(sig: s, bits: m.bits, days: m.days)
        lock.lock(); byId[id] = out; computed += 1; lock.unlock()
        return out
    }
    /// Stored marks only (nil: not read yet). Never runs the detector.
    func stored(id: String) -> Marks? { lock.lock(); defer { lock.unlock() }; return byId[id] }
    func forget(id: String) { lock.lock(); byId[id] = nil; lock.unlock() }
    var count: Int { lock.lock(); defer { lock.unlock() }; return byId.count }
}

// What a journal item is related to: ONE boundary (`JournalTags.tags`), so the entity store's own work on relation
// quality (ranking, reasons, ambiguous names) can change what is behind it without touching the views. Today: the
// entity matcher's surface forms (people, projects, tools), a link's site or a file's folder, the app.
// Ambiguous name forms: a store with `surface_flags` decides itself (EntityRules.mentions with the kinds expected in
// the item's app, `EntityRules.decide`); an older store without flags keeps the first rule (a form that points to more
// than one record, or an ordinary dictionary word of 4 letters or fewer, gives no tag). A twin (a project's repo) shows
// as its main record. `links`: the reasons the store keeps between records ("works at", "part of"), for the reader.
// `TagDisk`: tags kept on disk by row, so a second open does not work them out again (data/journal-tags.json).
// Pure (Foundation): tests/journal_tags.swift with a made-up store and a temporary folder.
import Foundation

enum JournalTags {
    /// Lower-case words of 4 letters or fewer from the system word list (/usr/share/dict/words), read once.
    static let common: Set<String> = {
        guard let s = try? String(contentsOfFile: "/usr/share/dict/words", encoding: .utf8) else { return [] }
        var out = Set<String>()
        for w in s.split(separator: "\n") where w.count <= 4 && w.first?.isLowercase == true { out.insert(String(w)) }
        return out
    }()

    /// The older store's rule (no `surface_flags`): may this name form stand as a tag? `records`: how many records it
    /// points to.
    static func fits(form: String, records: Int, common: Set<String>) -> Bool {
        if records > 1 { return false }
        let f = EntityRules.fold(form)
        if f.count <= 4, !f.contains(" "), common.contains(f) { return false }
        return true
    }

    /// What he names in an app, by the app's name (the journal keeps names, not bundle ids): the destination words of
    /// RefRules.dest, for `EntityRules.expect(dest:)`.
    static func dest(app: String) -> String {
        let a = app.lowercased()
        if ["telegram", "whatsapp", "signal", "messages", "slack", "discord", "beeper", "viber", "messenger", "teams"].contains(a) { return "chat" }
        if ["mail", "spark", "outlook", "superhuman", "mimestream", "gmail"].contains(a) { return "mail" }
        if ["claude", "chatgpt", "perplexity", "gemini"].contains(a) { return "ai" }
        if ["terminal", "iterm2", "iterm", "ghostty", "warp", "codex"].contains(a) { return "agent" }
        return "plain"
    }

    /// A record as the journal shows it: a twin as its main record.
    static func main(_ i: Int, store: EntityStore) -> Int {
        guard i < store.records.count, let m = store.records[i].twin_of, let j = store.byId[m] else { return i }
        return j
    }

    /// The names found in a text that may stand as tags, first seen first, one per record (twins as their main).
    /// Kinds outside person, project and tool are left out by `TapeRules.tags`.
    static func found(in text: String, store: EntityStore, common: Set<String>, app: String = "") -> [(name: String, kind: String)] {
        var idx: [Int] = []
        if !store.surfaceFlags.isEmpty {
            // the store decides ambiguous forms itself, with the kinds expected in this app
            idx = EntityRules.mentions(in: text, store: store, expect: EntityRules.expect(dest: dest(app: app)))
        } else {
            var prefix = ""
            func isWord(_ c: Character) -> Bool { c.isLetter || c == "'" || c == "’" || c == "ʼ" || c == "-" }
            func look() {
                guard let m = EntityRules.mention(before: prefix, store: store), m.resolved, m.index < store.records.count else { return }
                let records = Set((store.surfaces[EntityRules.fold(m.text)] ?? []).map(\.index)).count
                guard fits(form: m.text, records: records, common: common) else { return }
                idx.append(m.index)
            }
            for ch in text {
                if !isWord(ch), let last = prefix.last, isWord(last) { look() }
                prefix.append(ch)
            }
            if let last = prefix.last, isWord(last) { look() }
        }
        var out: [(name: String, kind: String)] = [], seen = Set<Int>()
        for i in idx where i < store.records.count {
            let j = main(i, store: store)
            guard seen.insert(j).inserted, !store.records[j].cardOnly else { continue }
            out.append((store.records[j].name, store.records[j].kind))
        }
        return out
    }

    /// THE boundary: an item's tags, at most 2, most telling first (the window shows one).
    static func tags(text: String, clip: String, app: String, chat: String?, people: [String] = [], store: EntityStore, common: Set<String> = common) -> [TapeTag] {
        var names = people.isEmpty ? found(in: String(text.prefix(400)), store: store, common: common, app: app) : people.map { ($0, "person") }
        // a chat named after a person in the store is that person (TapeRules.tags then keeps one person tag)
        if let chat, let r = store.records.first(where: { $0.kind == "person" && $0.name.lowercased() == chat.lowercased() }),
           !names.contains(where: { $0.name.lowercased() == r.name.lowercased() }) { names.insert((r.name, r.kind), at: 0) }
        return TapeRules.tags(text: text, clip: clip, app: app, chat: chat, found: names)
    }

    /// The record behind a tag (its main record when it is a twin).
    static func record(_ t: TapeTag, store: EntityStore) -> Int? {
        guard ["person", "chat", "project", "tool", "org"].contains(t.kind) else { return nil }
        let n = t.name.lowercased()
        guard let i = store.records.firstIndex(where: { $0.name.lowercased() == n }) else { return nil }
        return main(i, store: store)
    }

    /// A short reason a tag is there, when the store has one: the record's own line (who or what it is).
    static func reason(_ t: TapeTag, store: EntityStore) -> String? {
        guard let i = record(t, store: store), !store.records[i].whoLine.isEmpty else { return nil }
        return EntityRules.cut(store.records[i].whoLine, 80)
    }

    /// One kept relation, said: its reason and the other thing.
    struct Link: Equatable { let why: String; let name: String; let kind: String }

    /// What the store says a tag's record is related to, strongest first: the reason as the store words it ("works
    /// at", "part of", "similar topics: …") and the other record. The item's other tags come first (that is why they
    /// stand together); private records and contact-only cards are left out.
    static func links(_ t: TapeTag, others: [TapeTag] = [], store: EntityStore, max: Int = 3) -> [Link] {
        guard let i = record(t, store: store) else { return [] }
        let near = Set(others.compactMap { record($0, store: store) })
        var out: [(Link, Bool, Double)] = [], seen = Set<Int>()
        for r in store.records[i].relations ?? [] {
            guard let j0 = store.byId[r.id] else { continue }
            let j = main(j0, store: store)
            let o = store.records[j]
            guard j != i, !o.isPrivate, !o.cardOnly, !r.why.isEmpty, seen.insert(j).inserted else { continue }
            out.append((Link(why: EntityRules.cut(r.why, 60), name: o.name, kind: o.kind), near.contains(j), r.w))
        }
        out.sort { $0.1 != $1.1 ? $0.1 : $0.2 > $1.2 }
        return out.prefix(max).map(\.0)
    }
}

/// Tags kept on disk by row (data/journal-tags.json, never in git): one line of text per tag ("kind\tname"). The file
/// holds the store it was made with (`sign`): a new store (the nightly build) starts it again.
final class TagDisk {
    struct File: Codable { var sign = ""; var tags: [String: [String]] = [:] }
    let url: URL?
    private(set) var file = File()
    private(set) var dirty = false
    init(url: URL?, sign: String) {
        self.url = url
        if let url, let d = try? Data(contentsOf: url), let f = try? JSONDecoder().decode(File.self, from: d), f.sign == sign { file = f }
        file.sign = sign
    }
    /// What changes when the store is built again.
    static func sign(_ s: EntityStore) -> String { "\(s.built_day ?? "")|\(s.records.count)|\(s.surfaces.count)|\(s.surfaceFlags.count)" }

    func get(_ key: String) -> [TapeTag]? {
        file.tags[key].map { $0.compactMap { l in
            let p = l.split(separator: "\t", maxSplits: 1).map(String.init)
            return p.count == 2 ? TapeTag(name: p[1], kind: p[0]) : nil
        } }
    }
    func put(_ key: String, _ t: [TapeTag]) {
        let v = t.map { $0.kind + "\t" + $0.name }
        if file.tags[key] != v { file.tags[key] = v; dirty = true }
    }
    /// Only the rows still shown stay (a row he deleted goes).
    func keep(_ keys: Set<String>) {
        let before = file.tags.count
        file.tags = file.tags.filter { keys.contains($0.key) }
        if file.tags.count != before { dirty = true }
    }
    func save() {
        guard dirty, let url else { return }
        guard let d = try? JSONEncoder().encode(file) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if (try? d.write(to: url, options: .atomic)) != nil { dirty = false }
    }
}

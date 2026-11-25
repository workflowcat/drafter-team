// The journal's own store (14 November 2026): changes he makes to an item's text, and drafts he makes by combining
// items. The history files are never written: a change lives here, by item id, beside the original, and goes away on
// Revert. Items are general (kind "draft" today) so another kind, a quick note for one, can be added later.
// data/journal.json; tests use a temporary folder. Pure Foundation: tests/journal_store.swift.
import Foundation

final class JournalStore {
    struct Change: Codable, Equatable { var text: String; var at: Double }
    struct Item: Codable, Equatable { var id: String; var kind: String; var text: String; var at: Double; var sources: [String] = []; var pinned = false }
    struct File: Codable, Equatable {
        var changes: [String: Change] = [:]
        var items: [Item] = []
        var hidden: Set<String> = []

        init() {}
        private enum CodingKeys: String, CodingKey { case changes, items, hidden }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            changes = try c.decodeIfPresent([String: Change].self, forKey: .changes) ?? [:]
            items = try c.decodeIfPresent([Item].self, forKey: .items) ?? []
            hidden = try c.decodeIfPresent(Set<String>.self, forKey: .hidden) ?? []
        }
        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(changes, forKey: .changes)
            try c.encode(items, forKey: .items)
            try c.encode(hidden.sorted(), forKey: .hidden)
        }
    }

    let url: URL?            // nil: in memory only (the preview)
    private(set) var file = File()
    init(url: URL?) {
        self.url = url
        if let url, let d = try? Data(contentsOf: url), let f = try? JSONDecoder().decode(File.self, from: d) { file = f }
    }

    /// Journal-view-only soft archive of full row IDs (including the `j:` prefix for this store's own drafts).
    /// Reversible at any time via Tidy → Archived (`unhide`); never deletes underlying history files or affects
    /// search/MCP archives. Since 23 November 2026 engine/journal_db.py mirrors this list into data/journal.sqlite, and
    /// the engine's search over journal rows there (engine/ask.py's takes) leaves these rows out too.
    var hidden: Set<String> { file.hidden }
    var hiddenCount: Int { file.hidden.count }
    func isHidden(_ id: String) -> Bool { file.hidden.contains(id) }

    /// Soft archive only. The returned delta lets Undo preserve earlier archives.
    @discardableResult
    func hide(_ ids: [String]) -> [String] {
        var added: [String] = []
        for id in ids where !id.isEmpty {
            if file.hidden.insert(id).inserted { added.append(id) }
        }
        if !added.isEmpty { save() }
        return added
    }
    func unhide(_ ids: [String]) {
        let before = file.hidden.count
        file.hidden.subtract(ids)
        if before != file.hidden.count { save() }
    }

    func changed(_ id: String) -> String? { file.changes[id]?.text }
    var changes: [String: String] { file.changes.mapValues(\.text) }

    /// A change to an item's text. Back to the original: the change goes. Returns the change it replaced (for undo).
    @discardableResult
    func change(_ id: String, to text: String, original: String, at: Double = Date().timeIntervalSince1970) -> Change? {
        let before = file.changes[id]
        if text == original { file.changes[id] = nil } else { file.changes[id] = Change(text: text, at: at) }
        if before != file.changes[id] { save() }
        return before
    }
    /// Revert: the original again. Returns the change, so Undo can put it back.
    @discardableResult
    func revert(_ id: String) -> Change? {
        guard let c = file.changes.removeValue(forKey: id) else { return nil }
        save(); return c
    }
    func restore(_ id: String, _ c: Change) { file.changes[id] = c; save() }

    /// A new item (a draft from Combine); kept with where it came from.
    @discardableResult
    func add(kind: String, text: String, sources: [String], pinned: Bool, at: Double = Date().timeIntervalSince1970) -> Item {
        let it = Item(id: kind + "-" + UUID().uuidString.prefix(8).lowercased(), kind: kind, text: text, at: at, sources: sources, pinned: pinned)
        file.items.append(it); save()
        return it
    }
    func update(_ id: String, text: String) {
        guard let i = file.items.firstIndex(where: { $0.id == id }), file.items[i].text != text else { return }
        file.items[i].text = text; save()
    }

    func pin(_ id: String, _ on: Bool) {
        guard let i = file.items.firstIndex(where: { $0.id == id }), file.items[i].pinned != on else { return }
        file.items[i].pinned = on; save()
    }
    /// Takes a draft out; returns it, so Undo can put it back (`put`).
    @discardableResult
    func remove(_ id: String) -> Item? {
        guard let i = file.items.firstIndex(where: { $0.id == id }) else { return nil }
        let it = file.items.remove(at: i); save(); return it
    }
    func put(_ it: Item) { file.items.removeAll { $0.id == it.id }; file.items.append(it); save() }

    /// Texts joined in time order, oldest first, a blank line between them.
    static func combine(_ parts: [(at: Double, text: String)]) -> String {
        parts.sorted { $0.at < $1.at }.map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }.joined(separator: "\n\n")
    }

    private func save() {
        guard let url else { return }
        let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let d = try? e.encode(file) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? d.write(to: url, options: .atomic)
    }
}

// Quick starts (2026-10-31, Andrii: "presets of starting new docs like doc.new or a quick google meet start"):
// ";doc" then Tab opens a new Google Doc in the browser, ";meet" starts a Google Meet, and so on; the trigger is
// taken out of the field. Shared list: dictionary/presets.json; his own (same shape, checked first): data/presets.json.
// Opening a page is all it does: it sends nothing and creates nothing on its own.
import AppKit

struct Preset: Decodable { let keys: [String]; let title: String; let url: String }

enum Presets {
    private static var cache: (at: Date, list: [Preset]) = (.distantPast, [])
    static var all: [Preset] {
        if Date().timeIntervalSince(cache.at) < 30 { return cache.list }
        func read(_ u: URL) -> [Preset] { (try? JSONDecoder().decode([Preset].self, from: Data(contentsOf: u))) ?? [] }
        let list = read(Home.data.appendingPathComponent("presets.json")) + read(Home.root.appendingPathComponent("dictionary/presets.json"))
        cache = (Date(), list)
        return list
    }

    /// The preset for the trigger being typed: an exact key, else the one key that starts with it (3+ characters).
    static func match(_ typed: String, in list: [Preset]) -> Preset? {
        let t = typed.lowercased()
        guard t.hasPrefix(";"), t.count >= 3 else { return nil }
        if let p = list.first(where: { $0.keys.contains { $0.lowercased() == t } }) { return p }
        let hits = list.filter { $0.keys.contains { $0.lowercased().hasPrefix(t) } }
        return hits.count == 1 ? hits[0] : nil
    }

    static func offer(_ before: String) -> [String: Any]? {
        let line = before.components(separatedBy: "\n").last ?? ""
        let typed = SnippetRules.word(line)
        guard !typed.isEmpty, line.hasSuffix(typed), let p = match(typed, in: all) else { return nil }
        return ["id": "preset", "chip": "⇥ \(p.title) · \(URL(string: p.url)?.host ?? p.url)",
                "run": ["kind": "open", "url": p.url, "old": typed]]
    }

    static func open(_ r: [String: Any], expected: Spot?) {
        guard let s = r["url"] as? String, let url = URL(string: s), ["https", "http"].contains(url.scheme ?? "") else { return }
        if let old = r["old"] as? String, !old.isEmpty, let now = Focus.spot(skip: Drafter.shared.settings.skip).0,
           now.before.hasSuffix(old), expected.map({ CFEqual($0.el, now.el) }) ?? true {
            Focus.backspace(old.count)
        }
        NSWorkspace.shared.open(url)
        log("preset opened \(url.host ?? "?")")
    }
}

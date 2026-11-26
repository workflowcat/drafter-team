// The Dictionary page's rules (17 November 2026, research item 2: docs/research/2026-11-17-what-people-love.md), pure:
// the rows of data/words.json (engine/dictionary.py) and the words waiting to be learned (engine/edits.py), in three
// groups: Words to learn on top, then heard -> meant pairs, then plain words. Search, the heard-forms field and each
// row's key. Tests: tests/dict_rules.swift.
import Foundation

enum DictRules {
    enum Group: Int, CaseIterable { case learn, pair, word }

    struct Row: Equatable {
        var group: Group
        var text: String          // the word, or what he meant
        var heard: [String] = []  // what voice heard for it
        var count = 0             // Words to learn: how often he made this change
        var source = ""           // where the word came from (menu, edits, typing, dictionary)
        var loose = false         // a heard -> meant pair with no word of its own

        /// One key per row: the page's chosen row, SwiftUI's row id.
        var id: String {
            switch group {
            case .learn: return "learn:" + (heard.first ?? "") + "→" + text
            case .pair: return loose ? "loose:" + (heard.first ?? "") : "word:" + text.lowercased()
            case .word: return "word:" + text.lowercased()
            }
        }
    }

    static func title(_ g: Group) -> String {
        switch g { case .learn: return "Words to learn"; case .pair: return "Heard → meant"; case .word: return "Words" }
    }

    /// The rows from the dictionary file's JSON and the waiting edits (GET /edits), each group in its order: Words to
    /// learn by how often, the rest alphabetically.
    static func rows(_ file: [String: Any], waiting: [[String: Any]]) -> [Row] {
        var out: [Row] = []
        for e in waiting {
            let h = e["heard"] as? String ?? "", f = e["fixed"] as? String ?? ""
            guard !h.isEmpty, !f.isEmpty else { continue }
            out.append(Row(group: .learn, text: f, heard: [h], count: e["count"] as? Int ?? 1))
        }
        out.sort { $0.count != $1.count ? $0.count > $1.count : order($0.text, $1.text) }
        var rest: [Row] = [], seen = Set<String>()
        for w in file["words"] as? [[String: Any]] ?? [] {
            let t = (w["text"] as? String ?? "").trimmingCharacters(in: .whitespaces)
            guard !t.isEmpty, seen.insert(t.lowercased()).inserted else { continue }
            let h = w["heard"] as? [String] ?? []
            rest.append(Row(group: h.isEmpty ? .word : .pair, text: t, heard: h, source: w["source"] as? String ?? ""))
        }
        for (h, m) in file["loose_heard"] as? [String: String] ?? [:] where !h.isEmpty && !m.isEmpty {
            rest.append(Row(group: .pair, text: m, heard: [h], loose: true))
        }
        rest.sort { $0.group != $1.group ? $0.group.rawValue < $1.group.rawValue : order($0.text, $1.text) }
        return out + rest
    }

    static func order(_ a: String, _ b: String) -> Bool { a.localizedCaseInsensitiveCompare(b) == .orderedAscending }

    /// Text folded for search: no case, no accents, one apostrophe.
    static func fold(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .replacingOccurrences(of: "’", with: "'").replacingOccurrences(of: "ʼ", with: "'")
    }

    /// The rows shown for a search: every word of the query is in the word or one of its heard forms.
    static func filter(_ rows: [Row], query: String) -> [Int] {
        let q = fold(query).split(separator: " ").map(String.init)
        guard !q.isEmpty else { return Array(rows.indices) }
        return rows.indices.filter { i in
            let hay = fold(([rows[i].text] + rows[i].heard).joined(separator: " "))
            return q.allSatisfy { hay.contains($0) }
        }
    }

    /// The heard field as he typed it ("brum blocks, brumbl") into the dictionary's list: lower case, trimmed, once
    /// each, never the word itself.
    static func heard(_ field: String, word: String) -> [String] {
        var out: [String] = []
        for p in field.split(whereSeparator: { $0 == "," || $0 == ";" }) {
            let h = p.split(whereSeparator: \.isWhitespace).joined(separator: " ").lowercased()
            if !h.isEmpty, h != word.lowercased(), h.count <= 60, !out.contains(h) { out.append(h) }
        }
        return out
    }

    /// A word the page may save: 1 to 60 characters once trimmed.
    static func valid(_ s: String) -> Bool { let t = s.trimmingCharacters(in: .whitespaces); return !t.isEmpty && t.count <= 60 }

    /// Rows per group, for the group heads.
    static func counts(_ rows: [Row], _ shown: [Int]) -> [Group: Int] {
        var c: [Group: Int] = [:]
        for i in shown { c[rows[i].group, default: 0] += 1 }
        return c
    }
}

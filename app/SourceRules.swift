// Settings > Sources (17 November 2026): what the engine reads from (mail, beeper, drive, ...), served by GET /sources.
// The list from its JSON and one row's detail text. Pure, for a test (tests/source_rules.swift).
import Foundation

struct SourceRow: Equatable {
    var name: String
    var label: String
    var enabled: Bool
    var count: Int
    var updated: Double   // unix seconds, 0 = never
    var error: String
    var running: Bool
    var note: String
}

enum SourceRules {
    /// The rows of a /sources answer ({"sources": [...]}), in the engine's order; a row without a name is dropped.
    static func rows(_ j: [String: Any]) -> [SourceRow] {
        (j["sources"] as? [[String: Any]] ?? []).compactMap { s in
            guard let name = s["name"] as? String, !name.isEmpty else { return nil }
            return SourceRow(name: name, label: s["label"] as? String ?? name, enabled: s["enabled"] as? Bool ?? false,
                             count: (s["count"] as? NSNumber)?.intValue ?? 0, updated: (s["updated"] as? NSNumber)?.doubleValue ?? 0,
                             error: s["error"] as? String ?? "", running: s["running"] as? Bool ?? false,
                             note: s["note"] as? String ?? "")
        }
    }

    static func rows(data: Data) -> [SourceRow] {
        (try? JSONSerialization.jsonObject(with: data) as? [String: Any]).map { rows($0) } ?? []
    }

    /// Poll again while any row is still updating.
    static func anyRunning(_ rows: [SourceRow]) -> Bool { rows.contains { $0.running } }

    /// "1,234 items · updated 2 h ago"; "updating…" while it runs; the error when there is one; "never updated".
    static func detail(_ r: SourceRow, now: Double) -> String {
        if r.running { return "updating…" }
        let e = r.error.trimmingCharacters(in: .whitespacesAndNewlines)
        if !e.isEmpty { return e }
        if r.updated <= 0 { return "never updated" }
        return "\(thousands(r.count)) \(r.count == 1 ? "item" : "items") · updated \(ago(now - r.updated))"
    }

    /// "just now", "5 min ago", "2 h ago", "3 d ago".
    static func ago(_ secs: Double) -> String {
        let s = Int(secs)
        if s < 60 { return "just now" }
        if s < 3600 { return "\(s / 60) min ago" }
        if s < 86400 { return "\(s / 3600) h ago" }
        return "\(s / 86400) d ago"
    }

    /// 1234 -> "1,234", whatever the Mac's locale.
    static func thousands(_ n: Int) -> String {
        let digits = String(abs(n))
        var out = ""
        for (i, ch) in digits.enumerated() {
            if i > 0, (digits.count - i) % 3 == 0 { out.append(",") }
            out.append(ch)
        }
        return (n < 0 ? "-" : "") + out
    }
}

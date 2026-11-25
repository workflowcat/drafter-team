// Where a clip went (gallery round, 14 November 2026; Andrii: "icons from sources, where something came from and where
// it's placed"). Each paste he or Drafter makes is one line in data/paste-trail.jsonl: when, into which app (bundle id
// and name), and a short hash of what the clipboard held, so the journal can find the clip. Never the text. Never in a
// password field, a skipped app or under secure input (PasteWatch checks before it writes). Pure store and matching:
// tests/paste_trail.swift with a temp folder. The journal reads it; nothing in the history files changes.
import Foundation

enum PasteTrail {
    struct Paste: Equatable { let t: Double; let bundle: String; let app: String; let hash: String }

    /// A short, stable hash of a text's words (FNV-1a over the lower-case words), never the text itself.
    static func hash(_ text: String) -> String {
        let words = text.lowercased().split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        var x: UInt64 = 14695981039346656037
        for b in words.utf8 { x = (x ^ UInt64(b)) &* 1099511628211 }
        return String(x, radix: 16)
    }

    /// One line to append, or nil when the same paste into the same app was kept a moment ago (Drafter's own paste
    /// also reaches the event tap as ⌘V).
    static func line(_ p: Paste, after recent: [Paste], within: Double = 2) -> String? {
        if recent.contains(where: { $0.hash == p.hash && $0.bundle == p.bundle && abs($0.t - p.t) <= within }) { return nil }
        let o: [String: Any] = ["t": (p.t * 1000).rounded() / 1000, "bundle": p.bundle, "app": p.app, "h": p.hash]
        guard let d = try? JSONSerialization.data(withJSONObject: o, options: [.sortedKeys]) else { return nil }
        return String(decoding: d, as: UTF8.self)
    }

    static func read(_ url: URL, since: Double = 0) -> [Paste] {
        guard let s = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return s.split(separator: "\n").compactMap { l in
            guard let o = (try? JSONSerialization.jsonObject(with: Data(l.utf8))) as? [String: Any], let t = (o["t"] as? NSNumber)?.doubleValue,
                  t >= since, let h = o["h"] as? String else { return nil }
            return Paste(t: t, bundle: o["bundle"] as? String ?? "", app: o["app"] as? String ?? "", hash: h)
        }
    }

    /// Appends a paste (skipped when it is the same one a moment ago). Returns whether a line was written.
    @discardableResult
    static func add(_ p: Paste, to url: URL, recent: [Paste]) -> Bool {
        guard let l = line(p, after: recent) else { return false }
        let data = Data((l + "\n").utf8)
        if let h = try? FileHandle(forWritingTo: url) { h.seekToEndOfFile(); h.write(data); try? h.close() }
        else { try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true); try? data.write(to: url) }
        return true
    }

    /// Keeps the file to its last `keep` lines (called now and then, not on every paste).
    static func trim(_ url: URL, keep: Int = 5000) {
        guard let s = try? String(contentsOf: url, encoding: .utf8) else { return }
        let lines = s.split(separator: "\n")
        guard lines.count > keep else { return }
        try? (lines.suffix(keep).joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    /// For each clip (its time and text hash), the apps it was pasted into, in order, each once: a paste whose hash is
    /// the clip's, after the clip and before the same text was copied again, within `within` seconds.
    static func destinations(clips: [(t: Double, hash: String)], pastes: [Paste], within: Double = 7 * 86400) -> [[String]] {
        var byHash: [String: [Paste]] = [:]
        for p in pastes { byHash[p.hash, default: []].append(p) }
        var nextSame: [Int: Double] = [:]
        var lastAt: [String: Double] = [:]
        for i in clips.indices.sorted(by: { clips[$0].t > clips[$1].t }) {
            if let n = lastAt[clips[i].hash] { nextSame[i] = n }
            lastAt[clips[i].hash] = clips[i].t
        }
        return clips.indices.map { i in
            let c = clips[i], end = min(c.t + within, nextSame[i] ?? .infinity)
            var out: [String] = []
            for p in (byHash[c.hash] ?? []).sorted(by: { $0.t < $1.t }) where p.t >= c.t && p.t < end {
                let name = p.app.isEmpty ? p.bundle : p.app
                if !name.isEmpty, !out.contains(name) { out.append(name) }
            }
            return out
        }
    }
}

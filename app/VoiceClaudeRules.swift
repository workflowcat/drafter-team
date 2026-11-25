// Claude cleanup after a voice take (`voiceClaude`, 17 November 2026): pure rules. The flow is in app/TalkFlow.swift,
// the engine side in engine/voice_claude.py. Parakeet's text goes in at once; Claude's version replaces it in place only
// while he has not typed since and the field still ends with it. ⌫ right after puts Parakeet's text back (Rework.takeBack).
import Foundation

enum VoiceClaudeRules {
    static let deadline = 2.5        // seconds; later = Parakeet's text stays, nothing shown
    static let markSeconds = 2.0     // how long the strip shows what Claude changed
    static let maxPairs = 3          // changed words shown in the strip

    /// Ask Claude at all: switch on, Clean or Polished (never Raw), a whole take (not live typing, not a ↩ segment),
    /// and no other take waiting to go in after it.
    static func wants(on: Bool, level: String, live: Bool, segment: Bool, queued: Int) -> Bool {
        on && level != "raw" && !live && !segment && queued == 0
    }

    /// Swap in place now: no key since the put, and the text before the caret still ends with what went in.
    static func canSwap(revisionAt: Int, revisionNow: Int, before: String?, put: String) -> Bool {
        guard revisionAt == revisionNow, !put.isEmpty, let b = before else { return false }
        return b.replacingOccurrences(of: "\u{A0}", with: " ").hasSuffix(put)
    }

    /// The engine's answer as it may go in: trimmed; nil when empty or the same as what is in the field.
    static func answer(_ text: String?, put: String) -> String? {
        let t = (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty || t == put.trimmingCharacters(in: .whitespacesAndNewlines) ? nil : t
    }

    /// Changed words, old -> new, in order (a word-level longest common subsequence; punctuation stays on its word).
    static func changes(old: String, new: String) -> [(String, String)] {
        let a = old.split(separator: " ").map(String.init), b = new.split(separator: " ").map(String.init)
        guard !a.isEmpty || !b.isEmpty else { return [] }
        var l = Array(repeating: Array(repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in stride(from: a.count - 1, through: 0, by: -1) {
            for j in stride(from: b.count - 1, through: 0, by: -1) {
                l[i][j] = a[i] == b[j] ? l[i + 1][j + 1] + 1 : max(l[i + 1][j], l[i][j + 1])
            }
        }
        var out: [(String, String)] = [], i = 0, j = 0, da: [String] = [], db: [String] = []
        func flush() {
            if !da.isEmpty || !db.isEmpty { out.append((da.joined(separator: " "), db.joined(separator: " "))) }
            da = []; db = []
        }
        while i < a.count || j < b.count {
            if i < a.count, j < b.count, a[i] == b[j] { flush(); i += 1; j += 1 }
            else if j < b.count, i == a.count || l[i][j + 1] >= l[i + 1][j] { db.append(b[j]); j += 1 }
            else { da.append(a[i]); i += 1 }
        }
        flush()
        return out
    }

    /// The strip line for 2 s: "Claude: marta → Marta · friday → Friday. · ⌫ puts it back".
    static func note(_ ch: [(String, String)]) -> String {
        let shown = ch.prefix(maxPairs).map { $0.0.isEmpty ? "+ " + $0.1 : $0.1.isEmpty ? "− " + $0.0 : $0.0 + " → " + $0.1 }
        let more = ch.count > maxPairs ? " · +\(ch.count - maxPairs)" : ""
        return "Claude: " + shown.joined(separator: " · ") + more + " · ⌫ puts it back"
    }
}

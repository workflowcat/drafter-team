// Phrases he types often, for the Shortcuts page (13 November 2026, window round: it offered a pasted chat export
// line, "[12/11/2026, 15:32:05] Name: …", as something he typed). Pure: Snippets.ideas reads the files off the main
// thread and hands the texts here. A sent line that looks pasted gives no phrases: a chat-export time stamp at a line
// start, a text found in his clipboard history, or a line longer than a typed message plausibly is.
import Foundation

enum IdeaRules {
    /// Longer than this, a sent line was pasted (typed.jsonl keeps at most 600 characters; typed messages sit far below).
    static let longest = 400
    /// Phrase length that can become a shortcut.
    static let phrase = 20...200

    /// Chat exports: "[12/11/2026, 15:32:05] Name:" (WhatsApp iOS), "12.11.26, 15:32 - Name:" (WhatsApp Android),
    /// "Name, [12.11.2026 15:32]" (Telegram), "[15:32, 12/11/2026] Name:" (Signal, Slack-style copies).
    static let stamps: [NSRegularExpression] = [
        #"^\s*\[\d{1,4}[./-]\d{1,2}[./-]\d{1,4},?\s+\d{1,2}:\d{2}(:\d{2})?(\s*[APap][Mm])?\]"#,
        #"^\s*\d{1,4}[./-]\d{1,2}[./-]\d{1,4},?\s+\d{1,2}:\d{2}(:\d{2})?(\s*[APap][Mm])?\s*[-–]\s*[^:\n]{1,60}:"#,
        #"^[^\n\[\]]{1,60},\s*\[\d{1,4}[./-]\d{1,2}[./-]\d{1,4},?\s+\d{1,2}:\d{2}(:\d{2})?\]"#,
        #"^\s*\[\d{1,2}:\d{2}(:\d{2})?(\s*[APap][Mm])?,\s*\d{1,4}[./-]\d{1,2}[./-]\d{1,4}\]"#,
    ].map { try! NSRegularExpression(pattern: $0) }

    static func norm(_ s: String) -> String {
        s.replacingOccurrences(of: "\u{A0}", with: " ").split(whereSeparator: { $0.isWhitespace }).joined(separator: " ").lowercased()
    }

    /// Does any line of this text start like a chat export?
    static func chatExport(_ text: String) -> Bool {
        text.split(separator: "\n").contains { l in
            let s = String(l)
            return stamps.contains { $0.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil }
        }
    }

    static let sentences = try! NSRegularExpression(pattern: #"(?<=[.!?])\s+|\n"#)
    /// A text cut into sentences and lines, each with its whitespace collapsed.
    static func parts(_ text: String) -> [String] {
        let marked = sentences.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "\u{1}")
        return marked.split(separator: "\u{1}").map { $0.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ") }.filter { !$0.isEmpty }
    }

    /// His clipboard history: every entry and every sentence or line in it, normalized, for a quick look-up.
    struct Clips {
        let set: Set<String>
        init(_ texts: [String]) {
            var s = Set<String>()
            for t in texts { s.insert(IdeaRules.norm(t)); for p in IdeaRules.parts(t) { s.insert(p.lowercased()) } }
            s.remove(""); set = s
        }
        func contains(_ normalized: String) -> Bool { normalized.count >= 12 && set.contains(normalized) }
    }

    static func pasted(_ text: String, clips: Clips) -> Bool {
        text.count > longest || chatExport(text) || clips.contains(norm(text))
    }

    /// Sentences of 20-200 characters in the sent lines, counted (lowercased key -> (count, the first spelling)),
    /// leaving out lines that look pasted and sentences found in the clipboard.
    static func count(sent: [String], clipboard: [String]) -> [String: (count: Int, text: String)] {
        let clips = Clips(clipboard)
        var out: [String: (count: Int, text: String)] = [:]
        for text in sent where !text.contains("⟦drafter-test⟧") && !pasted(text, clips: clips) {
            for p in parts(text) {
                guard phrase.contains(p.count), !chatExport(p) else { continue }
                let key = p.lowercased()
                guard !clips.contains(key) else { continue }
                out[key] = ((out[key]?.count ?? 0) + 1, out[key]?.text ?? p)
            }
        }
        return out
    }

    /// The phrases to offer: sent three or more times, not a shortcut already, not hidden; the most typing saved first.
    static func ideas(sent: [String], clipboard: [String], have: Set<String>, hidden: Set<String>, limit: Int) -> [(text: String, count: Int)] {
        count(sent: sent, clipboard: clipboard)
            .filter { $0.value.count >= 3 && !have.contains($0.key) && !hidden.contains($0.key) }
            .sorted { ($0.value.count * $0.key.count, $0.key) > ($1.value.count * $1.key.count, $1.key) }
            .prefix(limit).map { ($0.value.text, $0.value.count) }
    }
}

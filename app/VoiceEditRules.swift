// Voice edit of a selection (17 November 2026; Wispr Flow's command mode, Superwhisper): he selects text, holds Right
// Option and says what to change. Spoken words that start with a change word are an instruction for the local model
// (engine/server.py rewrite); anything else replaces the selection as said. The result waits in the strip as one line;
// Tab or ↵ puts it in. Pure: tests/voice_edit_rules.swift.
import Foundation

enum VoiceEditRules {
    static let offerSeconds = 20.0

    static let instruction = try! NSRegularExpression(pattern:
        #"(?i)^\s*(?:(?:please|pls|can you|could you|будь ласка|можеш|можете)[,\s]+)?(зроби|перепиши|скороти|коротше|переклади|виправ|додай|прибери|зміни|розбий|спрости|покращ|make|rewrite|shorten|translate|fix|turn|add|remove|change|split|summari[sz]e|simplify|improve|more|less|correct|format)\b"#)

    /// "Make it shorter", "translate to English", "будь ласка, виправ імена": an instruction. "Thanks for the file": new words.
    static func isInstruction(_ spoken: String) -> Bool {
        instruction.firstMatch(in: spoken, range: NSRange(spoken.startIndex..., in: spoken)) != nil
    }

    /// One line for the strip: line breaks as " ⏎ ", spaces folded, cut with "…" at `width` characters.
    static func preview(_ text: String, width: Int = 70) -> String {
        let flat = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
            .map { $0.split(whereSeparator: { $0 == " " || $0 == "\t" }).joined(separator: " ") }
            .filter { !$0.isEmpty }.joined(separator: " ⏎ ")
        return flat.count > width ? String(flat.prefix(width - 1)).trimmingCharacters(in: .whitespaces) + "…" : flat
    }

    /// Return (36) or keypad Enter (76) with no modifiers, while the offer asked for it.
    static func acceptsReturn(code: Int, plain: Bool, on: Bool) -> Bool { on && plain && (code == 36 || code == 76) }
}

// swiftc -O -parse-as-library app/VoiceEditRules.swift tests/voice_edit_rules.swift -o app/build/voice-edit-rules-test && app/build/voice-edit-rules-test
// Voice edit of a selection. Made-up lines only.
import Foundation

@main struct Checks {
    static func main() {
        let instructions = ["Make it shorter", "make it shorter.", "Translate to English", "fix the names", "Please, make it warmer",
                            "Can you simplify this", "Скороти", "Переклади англійською", "Будь ласка, виправ імена", "зроби коротше", "Rewrite it as a list"]
        for t in instructions { precondition(VoiceEditRules.isInstruction(t), "instruction: «\(t)»") }
        let words = ["Thanks for the file", "See you at five", "Makeup is fine", "Fixtures arrive on Monday", "Дякую, до завтра",
                     "Translation is ready", "Please send it", ""]
        for t in words { precondition(!VoiceEditRules.isInstruction(t), "new words: «\(t)»") }
        precondition(VoiceEditRules.preview("Short line") == "Short line")
        precondition(VoiceEditRules.preview("First line\n\nSecond   line") == "First line ⏎ Second line")
        let long = VoiceEditRules.preview(String(repeating: "word ", count: 30), width: 20)
        precondition(long.count <= 20 && long.hasSuffix("…"), long)
        precondition(VoiceEditRules.acceptsReturn(code: 36, plain: true, on: true))
        precondition(VoiceEditRules.acceptsReturn(code: 76, plain: true, on: true))
        precondition(!VoiceEditRules.acceptsReturn(code: 36, plain: false, on: true))   // ⇧↵ / ⌘↵ stay the app's
        precondition(!VoiceEditRules.acceptsReturn(code: 36, plain: true, on: false))   // no voice edit offer: ↵ is the app's
        precondition(!VoiceEditRules.acceptsReturn(code: 48, plain: true, on: true))
        print("PASS voice edit rules")
    }
}

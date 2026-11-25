// swiftc -parse-as-library app/VoiceModeRules.swift tests/voice_mode_rules.swift -o app/build/voice-mode-rules-test && app/build/voice-mode-rules-test
// Voice cleanup levels and named modes (app/VoiceModeRules.swift). Made-up lines only.
import Foundation

@main
struct VoiceModeChecks {
    static var failures = 0
    static func check(_ ok: Bool, _ what: String) { if !ok { print("FAIL: " + what); failures += 1 } }

    static func main() {
        typealias R = VoiceModeRules
        let modes = ["Email": "formal, short paragraphs", "Slack": "casual, no greetings"]

        // the level per app: his pick for the app, the app's setting, its kind's, then Clean
        check(R.pick(kind: "chat", bundle: "a.chat", byKind: [:], byApp: [:], modes: modes, picked: [:]) == VoiceChoice(), "default Clean")
        check(R.pick(kind: "chat", bundle: "a.chat", byKind: ["chat": "raw"], byApp: [:], modes: modes, picked: [:]).level == .raw, "kind")
        check(R.pick(kind: "chat", bundle: "a.chat", byKind: ["chat": "raw"], byApp: ["a.chat": "Slack"], modes: modes, picked: [:])
              == VoiceChoice(level: .polished, mode: "Slack", prompt: "casual, no greetings"), "app's own names a mode")
        check(R.pick(kind: "chat", bundle: "a.chat", byKind: [:], byApp: ["a.chat": "Slack"], modes: modes,
                     picked: ["a.chat": VoiceChoice(level: .raw)]).level == .raw, "his pick wins")
        check(R.pick(kind: "mail", bundle: "m", byKind: ["mail": "Gone"], byApp: [:], modes: modes, picked: [:]) == VoiceChoice(),
              "a deleted mode falls back to Clean")

        check(R.choice("POLISHED", modes: modes) == VoiceChoice(level: .polished), "level any case")
        check(R.choice("email", modes: modes)?.mode == "Email", "mode any case")
        check(R.choice(" ", modes: modes) == nil && R.choice("nope", modes: modes) == nil, "unknown")

        // spoken commands: the whole take only
        check(R.spoken("Mode email.") == "email", "mode email")
        check(R.spoken("mode: Raw") == "raw", "mode: raw")
        check(R.spoken("Voice mode polished") == "polished", "voice mode")
        check(R.spoken("режим чистий") == "чистий", "Ukrainian")
        check(R.spoken("the mode email is broken") == nil, "a sentence that mentions a mode")
        check(R.spoken("mode email for the client and the whole team today") == nil, "too long to be a command")
        check(R.spoken("model is ready") == nil && R.spoken("mode") == nil, "not a command")

        check(R.resolve("off", modes: modes) == .some(nil), "off clears")
        check(R.resolve("email", modes: modes) == .some(VoiceChoice(level: .polished, mode: "Email", prompt: "formal, short paragraphs")), "resolve mode")
        check(R.resolve("сирий", modes: modes) == .some(VoiceChoice(level: .raw)), "Ukrainian level")
        check(R.resolve("banana", modes: modes) == nil, "unknown name")

        // the strip
        check(R.mark(lang: "", VoiceChoice()) == "C", "C")
        check(R.mark(lang: "UK", VoiceChoice(level: .raw)) == "UK · R", "pin and R")
        check(R.mark(lang: "", VoiceChoice(level: .polished, mode: "Email")) == "P Email", "mode name")
        check(VoiceLevel.allCases.map(\.letter) == ["R", "C", "P"], "letters")

        // the local model's instruction and its answer
        let i = R.instruction(VoiceChoice(level: .polished, mode: "Email", prompt: "formal, short paragraphs"), note: "no emoji")
        check(i.contains("Style: formal, short paragraphs.") && i.contains("His notes for this app: no emoji."), "instruction")
        check(!R.instruction(VoiceChoice(level: .polished), note: "").contains("Style:"), "no prompt, no style line")
        let clean = "Can we move the call to Thursday at ten"
        check(R.accept(polished: "Could we move the call to Thursday at 10:00?", clean: clean) == "Could we move the call to Thursday at 10:00?", "accept")
        check(R.accept(polished: "  ", clean: clean) == clean, "empty answer")
        check(R.accept(polished: "Here is the text: Could we move it?", clean: clean) == clean, "a reply about the text")
        check(R.accept(polished: String(repeating: "long ", count: 40), clean: clean) == clean, "much longer")
        check(R.accept(polished: "Ok", clean: clean) == clean, "much shorter")

        let t = R.tidy([" Email ": " formal ", "": "x", "Empty": " ", "raw": "clash with a level"])
        check(t == ["Email": "formal"], "tidy: \(t)")
        var many: [String: String] = [:]
        for n in 0..<20 { many["Mode \(n)"] = "p" }
        check(R.tidy(many).count == R.maxModes, "at most \(R.maxModes)")
        check(R.tidy(["Long": String(repeating: "a", count: 500)])["Long"]?.count == R.maxPrompt, "prompt cut")

        if failures > 0 { print("\(failures) failed"); exit(1) }
        print("voice mode rules: ok")
    }
}

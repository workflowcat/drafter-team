// Voice cleanup levels and the user's own named modes (17 November 2026, research item 3, docs/research/2026-11-17-what-people-love.md).
//   Raw       Parakeet's words as heard: no clean-up, no corrections, no shape, no style. Adds nothing.
//   Clean     today's pipeline (fillers out, spoken corrections, lists, punctuation, the app's style). The default.
//   Polished  Clean, then the local model rewrites it as written text, with the user's mode's prompt and their writing note for
//             the app (`appNotes`, one place for the user's instructions). Never Claude.
// The level per app comes the way the voice style does (VoiceStyleRules.pick): the app's own, its kind's, then Clean.
// A named mode ("Email": "formal, short paragraphs") is Polished with its prompt. The user picks one for the app in front by
// saying "mode email" as the whole take, or from the `;` picker ("Voice mode"); "mode clean" / "mode off" goes back.
// Pure: tests/voice_mode_rules.swift.
import Foundation

enum VoiceLevel: String, CaseIterable {
    case raw, clean, polished
    var letter: String { switch self { case .raw: return "R"; case .clean: return "C"; case .polished: return "P" } }
    var label: String { switch self { case .raw: return "Raw"; case .clean: return "Clean"; case .polished: return "Polished" } }
}

/// What a take in this app is made into: the level, and for Polished the user's mode's name and prompt (empty: none).
struct VoiceChoice: Equatable {
    var level = VoiceLevel.clean
    var mode = ""
    var prompt = ""
}

enum VoiceModeRules {
    /// Most modes kept; longest prompt.
    static let maxModes = 12, maxPrompt = 200

    /// The app's level: a mode the user picked for it in this session, then the app's own setting, its kind's, then Clean.
    /// `modes`: name -> prompt (settings `voiceModes`); a level setting may name a mode ("Email") as well as a level.
    static func pick(kind: String, bundle: String, byKind: [String: String], byApp: [String: String],
                     modes: [String: String], picked: [String: VoiceChoice]) -> VoiceChoice {
        if let c = picked[bundle] { return c }
        for v in [byApp[bundle], byKind[kind]] {
            if let c = v.flatMap({ choice($0, modes: modes) }) { return c }
        }
        return VoiceChoice()
    }

    /// A setting's value or a spoken name as a choice: "raw", "clean", "polished" or a mode's name (any case).
    static func choice(_ name: String, modes: [String: String]) -> VoiceChoice? {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if n.isEmpty { return nil }
        if let l = VoiceLevel(rawValue: n.lowercased()) { return VoiceChoice(level: l) }
        if let k = modes.keys.first(where: { $0.lowercased() == n.lowercased() }) {
            return VoiceChoice(level: .polished, mode: k, prompt: String(modes[k]!.prefix(maxPrompt)))
        }
        return nil
    }

    /// The whole take is a mode command: "mode email", "Mode: Email.", "режим пошта", "voice mode raw". -> the name
    /// said ("off" means Clean); nil for anything else, so a sentence that only mentions a mode is dictated as it is.
    static func spoken(_ heard: String) -> String? {
        var t = heard.lowercased().trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters))
        for p in ["voice mode", "mode", "режим"] where t.hasPrefix(p + " ") || t.hasPrefix(p + ":") || t.hasPrefix(p + ",") {
            t = String(t.dropFirst(p.count)).trimmingCharacters(in: CharacterSet.whitespaces.union(.punctuationCharacters))
            let words = t.split(separator: " ")
            guard !words.isEmpty, words.count <= 3 else { return nil }
            return t
        }
        return nil
    }

    /// A spoken or picked name -> what to keep for the app: a choice, or nil to clear the user's pick ("off", "default").
    /// The outer nil: not a known name (the strip says so).
    static func resolve(_ name: String, modes: [String: String]) -> VoiceChoice?? {
        let n = name.lowercased()
        if ["off", "default", "normal", "вимкни", "звичайний"].contains(n) { return .some(nil) }
        if let c = choice(name, modes: modes) { return .some(c) }
        let uk = ["сирий": "raw", "чистий": "clean", "гарний": "polished", "відшліфований": "polished"]
        if let l = uk[n] { return .some(choice(l, modes: modes)) }
        return nil
    }

    /// The strip's mark during a take: the language pin and the level ("UK · P Email", "C", "R").
    static func mark(lang: String, _ c: VoiceChoice) -> String {
        let level = c.mode.isEmpty ? c.level.letter : c.level.letter + " " + c.mode
        return lang.isEmpty ? level : lang + " · " + level
    }

    /// The local model's instruction for Polished. `note`: the user's writing note for the app (WritingNotes.forApp).
    static func instruction(_ c: VoiceChoice, note: String) -> String {
        var s = "This is dictated speech. Rewrite it as written text: whole sentences, no spoken fillers or false starts, "
            + "the same meaning, language, names and numbers; do not add facts, greetings or sign-offs it does not have."
        let p = c.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if !p.isEmpty { s += " Style: " + p + "." }
        let n = note.trimmingCharacters(in: .whitespacesAndNewlines)
        if !n.isEmpty { s += " His notes for this app: " + n + "." }
        return s
    }

    /// The model's answer, or the clean text when it is unusable: empty, much longer or much shorter than the take,
    /// or a reply about the text instead of the text.
    static func accept(polished: String, clean: String) -> String {
        let p = polished.trimmingCharacters(in: .whitespacesAndNewlines)
        let n = clean.count
        if p.isEmpty || n == 0 { return clean }
        if p.count > n * 2 + 40 || p.count * 3 < n { return clean }
        let lower = p.lowercased()
        if ["here is", "here's", "ось ", "sure,", "звісно"].contains(where: { lower.hasPrefix($0) }) { return clean }
        return p
    }

    /// Settings: modes as saved, names trimmed, empty names and prompts out, at most `maxModes`.
    static func tidy(_ modes: [String: String]) -> [String: String] {
        var out: [String: String] = [:]
        for k in modes.keys.sorted() {
            let n = k.trimmingCharacters(in: .whitespacesAndNewlines), p = (modes[k] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !n.isEmpty, !p.isEmpty, VoiceLevel(rawValue: n.lowercased()) == nil, out.count < maxModes else { continue }
            out[n] = String(p.prefix(maxPrompt))
        }
        return out
    }
}

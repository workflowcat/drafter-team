// Parity round (15 November 2026, Cotypist Pro parity): pure rules for the clipboard context, the writing
// instructions, the personal-style slider and the numbered alternatives. Tests: tests/parity_rules.swift.
import Foundation

/// Clipboard context (setting `clipContext`): a copy from the last 2 minutes goes into the ghost's prompt (engine
/// prompt.clip_text places it after the cached head, above the screen text). Never a copy from a password manager or a
/// skipped app, never one made in a password field (secure input: History.watchClipboard drops those before Clip sees
/// them), never one that looks like a key, token, card, IBAN or one-time code. The engine checks again.
enum ClipContext {
    static let maxAge: TimeInterval = 120
    static let maxChars = 300
    /// Password managers beside the ones in the default skip list (Settings.skip).
    static let vaults: Set<String> = ["com.1password.1password", "com.agilebits.onepassword7", "com.apple.keychainaccess",
                                      "com.apple.Passwords", "com.bitwarden.desktop", "com.lastpass.LastPass",
                                      "com.dashlane.dashlanephonefinal", "in.sinew.Enpass-Desktop", "com.keepassium.mac",
                                      "org.keepassxc.keepassxc", "com.proton.pass"]

    enum Why: String, Equatable { case off, nothing, stale, vault, secret, pasted, empty }

    /// The copy for the prompt, or why it was left out (logged as a word, never the text).
    static func pick(_ text: String?, copiedAt: Date?, from app: String, now: Date, on: Bool, skip: [String],
                     secret: Bool, before: String) -> (text: String?, why: Why?) {
        guard on else { return (nil, .off) }
        guard let raw = text, let at = copiedAt else { return (nil, .nothing) }
        guard now.timeIntervalSince(at) <= maxAge, now >= at else { return (nil, .stale) }
        guard !vaults.contains(app), !skip.contains(app) else { return (nil, .vault) }
        let t = raw.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        guard !t.isEmpty else { return (nil, .empty) }
        guard !secret, !looksSecret(t) else { return (nil, .secret) }
        let flat = before.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        if flat.contains(String(t.prefix(60))) { return (nil, .pasted) }   // he pasted it: the text already holds it
        return (String(t.prefix(maxChars)), nil)
    }

    /// The checks beside QuickRules.isSecret (the clipboard history's own): an IBAN, a long token that mixes letters,
    /// digits and case (a key, a hash, a password).
    static func looksSecret(_ t: String) -> Bool {
        if t.range(of: #"\b[A-Z]{2}\d{2}(?: ?[A-Z0-9]{4}){3,7}(?: ?[A-Z0-9]{1,4})?\b"#, options: .regularExpression) != nil { return true }
        if t.range(of: #"^\s*(\d{6}|\d{3}[ -]\d{3}|\d{8})\s*$"#, options: .regularExpression) != nil { return true }
        for w in t.split(separator: " ") {
            let s = String(w).trimmingCharacters(in: CharacterSet(charactersIn: ".,;:()[]{}<>\"'"))
            guard s.count >= 20, !s.hasPrefix("http://"), !s.hasPrefix("https://") else { continue }
            let kinds = [s.contains(where: { $0.isLowercase }), s.contains(where: { $0.isUppercase }), s.contains(where: { $0.isNumber }),
                         s.contains(where: { !$0.isLetter && !$0.isNumber })].filter { $0 }.count
            if kinds >= 3 || (kinds == 2 && s.contains(where: { $0.isNumber }) && Set(s).count >= 14) { return true }
        }
        return false
    }
}

/// Writing instructions (settings `writingNote`, `appNotes`): one for every app and one per app (bundle id), his own
/// words. The engine shows them in the place line of the prompt. Empty = nothing sent (the prompt as before).
enum WritingNotes {
    static let maxChars = 300
    static func forApp(_ bundle: String, global: String, perApp: [String: String]) -> String {
        let g = global.trimmingCharacters(in: .whitespacesAndNewlines)
        let a = (perApp[bundle] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return String([g, a].filter { !$0.isEmpty }.joined(separator: "; ").prefix(maxChars))
    }
}

/// Personal style (setting `personalStrength`, 0-100 %): how much of his trained layer the model uses. A change is
/// sent once the slider settles, in steps of 10.
enum Strength {
    static func clamp(_ v: Double) -> Int { Int((min(100, max(0, v)) / 10).rounded()) * 10 }
}

/// Numbered alternatives (setting `alternatives`): while a plain ghost shows, ⌥1 ⌥2 ⌥3 put idea 1 (the main ghost),
/// 2 or 3 in its place (GhostRules.ideas: the engine's prepared futures); Tab takes as usual. Key codes are the
/// number row's, the same in every layout. Without a ghost, or with the setting off, the keys go to the app.
enum AltKeys {
    static let codes: [Int: Int] = [18: 0, 19: 1, 20: 2]
    static func pick(code: Int, option: Bool, control: Bool, command: Bool, shift: Bool, ghost: Bool, plain: Bool, on: Bool, count: Int) -> Int? {
        guard on, option, !control, !command, !shift, ghost, plain, let i = codes[code], i < count else { return nil }
        return i
    }
    /// The quiet mark after the grey words: which idea shows, of how many ("1/3"); nothing with one idea.
    static func hint(index: Int, count: Int, on: Bool) -> String { on && count > 1 ? "\(index + 1)/\(min(count, 3))" : "" }
}

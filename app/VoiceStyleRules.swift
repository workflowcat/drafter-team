// Voice style per app (17 November 2026, plan docs/plans/2026-11-17-voice-snippets-fable.md A1; Wispr Flow's styles):
// formal, casual or very casual, picked by the target app's kind (AppKind) with an override per app (settings
// `voiceStyle`, `voiceStyleApps`). Only case and the final mark change, never words. Pure: tests/voice_style_rules.swift.
import Foundation

enum VoiceStyle: String, CaseIterable {
    case formal, casual, veryCasual

    var label: String {
        switch self { case .formal: return "Formal"; case .casual: return "Casual"; case .veryCasual: return "Very casual" }
    }
}

enum VoiceStyleRules {
    /// The defaults when Settings names no style for a kind: mail formal, chat and AI boxes casual, the rest formal.
    static let defaults: [String: String] = ["mail": "formal", "chat": "casual", "ai": "casual", "other": "formal"]

    /// The app's own override, then its kind's style, then formal.
    static func pick(kind: String, bundle: String, byKind: [String: String], byApp: [String: String]) -> VoiceStyle {
        if let s = byApp[bundle].flatMap(VoiceStyle.init(rawValue:)) { return s }
        if let s = (byKind[kind] ?? defaults[kind]).flatMap(VoiceStyle.init(rawValue:)) { return s }
        return .formal
    }

    /// The text in this style. `keep`: words whose capital stays (names on screen, dictionary names); `verbatim`:
    /// spans never touched (snippet values put in by voice). `endOnly`: live typing, where the words are already in
    /// the field, so only the final mark changes.
    static func apply(_ text: String, _ style: VoiceStyle, keep: Set<String> = [], verbatim: [String] = [], endOnly: Bool = false) -> String {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return text }
        let lastLine = s.components(separatedBy: "\n").last ?? s
        let endsList = listItem.firstMatch(in: lastLine, range: NSRange(lastLine.startIndex..., in: lastLine)) != nil
        let endsVerbatim = verbatim.contains { !$0.isEmpty && s.hasSuffix($0) }
        let endsName = s.contains("\n") && words(lastLine) <= 3            // a sign-off's name line ("Best regards,\nAlex")
        let endsOpen = endsVerbatim || endsList || endsName || looksLikeLink(lastWord(s))
        switch style {
        case .formal:
            if !endOnly { s = capitalizeSentences(s, verbatim: verbatim) }
            if !endsOpen, let last = s.last, last.isLetter || last.isNumber || last == ")" || last == "»" || last == "\"",
               words(s) >= 3 { s += "." }
        case .casual:
            if !endsOpen, sentences(s) <= 2 { s = dropFinalDot(s) }
        case .veryCasual:
            if !endsOpen { s = dropFinalDot(s) }
            if !endOnly { s = lowerSentences(s, keep: keep, verbatim: verbatim) }
        }
        return s
    }

    static let listItem = try! NSRegularExpression(pattern: #"^\s*\d+[.)]\s"#)

    /// "Ok." -> "Ok"; "Wait..." and "Done!" stay.
    static func dropFinalDot(_ s: String) -> String {
        guard s.hasSuffix("."), !s.hasSuffix(".."), !looksLikeLink(lastWord(s)) else { return s }
        return String(s.dropLast())
    }

    static func words(_ s: String) -> Int { s.split(whereSeparator: { $0.isWhitespace }).count }

    /// Sentences: a closing mark (. ! ? …) followed by a space, a new line or the end, counted at least once.
    static func sentences(_ s: String) -> Int {
        var n = 0
        let chars = Array(s)
        for (i, c) in chars.enumerated() where ".!?…".contains(c) {
            let next = i + 1 < chars.count ? chars[i + 1] : " "
            if next.isWhitespace, !(i > 0 && ".!?…".contains(chars[i - 1])) { n += 1 }
        }
        if let last = chars.last, !".!?…".contains(last) { n += 1 }
        return max(1, n)
    }

    static func lastWord(_ s: String) -> String { String(s.split(whereSeparator: { $0.isWhitespace }).last ?? "") }

    /// linkedin.com/in/x, https://…, an email: never re-cased, never given a dot.
    static func looksLikeLink(_ w: String) -> Bool {
        let t = w.trimmingCharacters(in: CharacterSet(charactersIn: ".,!?;:)»\"'"))
        if t.contains("://") || t.hasPrefix("www.") || t.contains("@") { return true }
        // a dot inside a word with letters on both sides (site.com), not "2.30"
        let host = t.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? t
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count >= 2 && parts.allSatisfy { !$0.isEmpty } && parts.last!.allSatisfy(\.isLetter) && parts.last!.count >= 2
    }

    /// The index of each sentence's first letter: at the start, after ". " "! " "? " "… " and after a new line;
    /// list lines ("1. …") and verbatim spans are left out.
    static func sentenceStarts(_ s: String, verbatim: [String]) -> [String.Index] {
        let blocked = spans(s, verbatim)
        var out: [String.Index] = [], want = true, i = s.startIndex, lineStart = true, listLine = false
        while i < s.endIndex {
            let c = s[i]
            if lineStart {
                let rest = String(s[i...].prefix(6))
                listLine = listItem.firstMatch(in: rest, range: NSRange(rest.startIndex..., in: rest)) != nil
                lineStart = false
            }
            if c == "\n" { want = true; lineStart = true }
            else if c.isLetter {
                if want, !listLine, !blocked.contains(where: { $0.contains(i) }) { out.append(i) }
                want = false
            } else if ".!?…".contains(c) {
                let n = s.index(after: i)
                if n == s.endIndex || s[n].isWhitespace { want = true }
            } else if !c.isWhitespace && !"\"«(“'".contains(c) { want = false }
            i = s.index(after: i)
        }
        return out
    }

    private static func spans(_ s: String, _ verbatim: [String]) -> [Range<String.Index>] {
        var out: [Range<String.Index>] = []
        for v in verbatim where !v.isEmpty {
            var from = s.startIndex
            while let r = s.range(of: v, range: from..<s.endIndex) { out.append(r); from = r.upperBound }
        }
        return out
    }

    private static func word(at i: String.Index, in s: String) -> String {
        var j = i
        while j < s.endIndex, !s[j].isWhitespace, !",;:!?".contains(s[j]) { j = s.index(after: j) }
        return String(s[i..<j])
    }

    static func capitalizeSentences(_ s: String, verbatim: [String]) -> String {
        var out = s
        for i in sentenceStarts(s, verbatim: verbatim).reversed() where out[i].isLowercase {
            if looksLikeLink(word(at: i, in: s)) { continue }
            out.replaceSubrange(i...i, with: String(out[i]).uppercased())
        }
        return out
    }

    /// Very casual: each sentence starts small, except names, "I", all-capital words, words with an inner capital
    /// (iPhone, PixelKit), links and emails.
    static func lowerSentences(_ s: String, keep: Set<String>, verbatim: [String]) -> String {
        let kept = Set(keep.map { $0.lowercased() })
        var out = s
        for i in sentenceStarts(s, verbatim: verbatim).reversed() where out[i].isUppercase {
            let w = word(at: i, in: s)
            let bare = w.trimmingCharacters(in: CharacterSet.letters.inverted)
            let letters = bare.filter(\.isLetter)
            if bare == "I" || bare.hasPrefix("I'") || bare.hasPrefix("I’") { continue }
            if letters.count >= 2, letters.allSatisfy(\.isUppercase) { continue }
            if letters.dropFirst().contains(where: \.isUppercase) { continue }
            if looksLikeLink(w) { continue }
            if kept.contains(bare.lowercased()) || kept.contains(where: { $0.split(separator: " ").first.map(String.init) == bare.lowercased() }) { continue }
            out.replaceSubrange(i...i, with: String(out[i]).lowercased())
        }
        return out
    }
}

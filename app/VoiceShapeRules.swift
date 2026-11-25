// Voice shape per app (17 November 2026, plan A3): in a mail body a greeting line, paragraphs and a sign-off; in a
// chat, short lines only when settings `voiceChatLines` is on (off by default: a new line typed into a chat can send
// it). Spoken "new paragraph" / "new line" break the text where breaks are allowed. Never a Return key: a text with a
// line break goes in as a paste or an AX write (Focus.typeText pastes anything with a control character). Pure:
// tests/voice_shape_rules.swift. Word lists here, in both languages.
import Foundation

enum VoiceShapeRules {
    static let greetings = ["hi", "hello", "hey", "dear", "good morning", "good afternoon", "good evening",
                            "привіт", "вітаю", "добрий день", "доброго дня", "доброго ранку", "добрий вечір", "доброго вечора",
                            "шановний", "шановна", "шановні", "дорогий", "дорога", "дорогі", "салют"]
    static let closings = ["best regards", "kind regards", "warm regards", "regards", "best wishes", "best", "cheers",
                           "thanks", "thank you", "many thanks", "sincerely", "yours",
                           "з повагою", "з найкращими побажаннями", "дякую", "щиро дякую", "гарного дня", "до зв'язку", "до звʼязку",
                           "обіймаю", "на звʼязку", "на зв'язку", "всього найкращого"]
    static let paragraphCue = try! NSRegularExpression(pattern:
        #"(?i)[,.]?\s*\b(new paragraph|next paragraph|новий абзац|з нового абзацу)\b[,.:]?\s*"#)
    static let lineCue = try! NSRegularExpression(pattern:
        #"(?i)[,.]?\s*\b(new line|next line|новий рядок|з нового рядка)\b[,.:]?\s*"#)

    /// The text for the field. `kind`: AppKind; `canBreak`: a line break can reach the field safely (not live typing);
    /// `chatLines`: the chat setting; `emptyField`: nothing before the caret (a mail body, not a reply under a quote
    /// and not a subject line).
    static func shape(_ text: String, kind: String, canBreak: Bool, chatLines: Bool, emptyField: Bool) -> String {
        guard canBreak, !text.isEmpty else { return text }
        switch kind {
        case "mail": return emptyField ? mail(spokenBreaks(text)) : spokenBreaks(text)
        case "chat": return chatLines ? chat(text) : text
        case "other": return spokenBreaks(text)
        default: return text   // an AI box: as said
        }
    }

    /// "… new paragraph …" -> a blank line, "… new line …" -> a line break; the next word starts with a capital.
    static func spokenBreaks(_ text: String) -> String {
        var s = text
        for (rx, gap) in [(paragraphCue, "\n\n"), (lineCue, "\n")] {
            let ns = s as NSString
            for m in rx.matches(in: s, range: NSRange(location: 0, length: ns.length)).reversed() {
                let before = (s as NSString).substring(to: m.range.location).trimmingCharacters(in: .whitespaces)
                let mark = before.isEmpty || ".!?:…\n".contains(before.last!) ? "" : "."
                s = (s as NSString).replacingCharacters(in: m.range, with: mark + gap)
            }
        }
        return capitalAfterBreaks(s.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    static func capitalAfterBreaks(_ s: String) -> String {
        var out = "", up = false
        for c in s {
            if c == "\n" { up = true; out.append(c); continue }
            if up, c.isLetter { out += c.uppercased(); up = false; continue }
            if !c.isWhitespace { up = false }
            out.append(c)
        }
        return out
    }

    /// Clauses: pieces ending at , . ! ? … (the mark kept with its piece).
    static func clauses(_ s: String) -> [String] {
        var out: [String] = [], cur = ""
        for c in s {
            cur.append(c)
            if ",.!?…".contains(c) { out.append(cur); cur = "" }
        }
        if !cur.isEmpty { out.append(cur) }
        return out
    }

    private static func fold(_ s: String) -> String {
        s.lowercased().replacingOccurrences(of: "’", with: "'").trimmingCharacters(in: CharacterSet.letters.inverted)
    }
    private static func starts(_ clause: String, with list: [String]) -> String? {
        let f = fold(clause)
        return list.sorted { $0.count > $1.count }.first { f == $0 || f.hasPrefix($0 + " ") }
    }

    /// A mail body: "Hi Ira, thanks for the file. … Best regards, Alex" ->
    /// "Hi Ira,\n\nThanks for the file. …\n\nBest regards,\nAlex". A greeting: the first clause, at most 4 words, starting
    /// with a listed greeting. A sign-off: the last clause or two, starting with a listed closing, at most 3 words after it.
    static func mail(_ text: String) -> String {
        var parts = clauses(text.trimmingCharacters(in: .whitespacesAndNewlines))
        guard parts.count >= 2 else { return text }
        var head = "", tail = ""
        if let first = parts.first, starts(first, with: greetings) != nil,
           first.split(whereSeparator: \.isWhitespace).count <= 4, !first.contains("\n") {
            var g = first.trimmingCharacters(in: .whitespaces)
            if let l = g.last, ".!".contains(l) { g = String(g.dropLast()) + (l == "!" ? "!" : ",") }
            else if g.last != "," { g += "," }
            head = g
            parts.removeFirst()
        }
        // the sign-off: "Best regards, Alex." (two clauses) or "Thanks, Alex" or "Cheers." at the very end
        if parts.count >= 2, let k = starts(parts[parts.count - 2], with: closings),
           fold(parts[parts.count - 2]) == k, parts.last!.split(whereSeparator: \.isWhitespace).count <= 3,
           fold(parts.last!).split(separator: " ").count <= 3, !parts.last!.contains("\n") {
            var c = parts[parts.count - 2].trimmingCharacters(in: .whitespaces)
            if c.last == "." { c = String(c.dropLast()) + "," }
            var name = parts.last!.trimmingCharacters(in: .whitespaces)
            if name.last == "." { name.removeLast() }
            tail = capitalFirst(c) + "\n" + capitalFirst(name)
            parts.removeLast(2)
        } else if parts.count >= 2, let last = parts.last, let k = starts(last, with: closings), fold(last) == k {
            tail = capitalFirst(last.trimmingCharacters(in: .whitespaces))
            parts.removeLast()
        }
        guard !head.isEmpty || !tail.isEmpty || parts.joined().count >= 300 else { return text }
        let body = paragraphs(capitalFirst(parts.joined().trimmingCharacters(in: .whitespacesAndNewlines)))
        return [head, body, tail].filter { !$0.isEmpty }.joined(separator: "\n\n")
    }

    static func capitalFirst(_ s: String) -> String {
        guard let i = s.firstIndex(where: \.isLetter), s[i].isLowercase else { return s }
        if VoiceStyleRules.looksLikeLink(String(s[i...].prefix { !$0.isWhitespace })) { return s }
        var out = s; out.replaceSubrange(i...i, with: String(s[i]).uppercased()); return out
    }

    /// A long body: a blank line after a sentence end once the paragraph holds 3 sentences and 300 characters. Lines
    /// that are already there (a list, a spoken break) stay.
    static func paragraphs(_ body: String) -> String {
        body.components(separatedBy: "\n").map { line -> String in
            guard line.count >= 300, VoiceStyleRules.listItem.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) == nil else { return line }
            var out = "", para = "", n = 0
            for piece in sentencesOf(line) {
                para += piece; n += 1
                if n >= 3, para.count >= 300 { out += para.trimmingCharacters(in: .whitespaces) + "\n\n"; para = ""; n = 0 }
            }
            out += para.trimmingCharacters(in: .whitespaces)
            return out.trimmingCharacters(in: .whitespacesAndNewlines)
        }.joined(separator: "\n")
    }

    static func sentencesOf(_ s: String) -> [String] {
        var out: [String] = [], cur = ""
        let chars = Array(s)
        for (i, c) in chars.enumerated() {
            cur.append(c)
            if ".!?…".contains(c), i + 1 < chars.count, chars[i + 1].isWhitespace { out.append(cur); cur = "" }
        }
        if !cur.isEmpty { out.append(cur) }
        return out
    }

    /// A chat: one sentence per line, when the take has two or more.
    static func chat(_ text: String) -> String {
        guard !text.contains("\n") else { return text }
        let ss = sentencesOf(text).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return ss.count >= 2 ? ss.joined(separator: "\n") : text
    }
}

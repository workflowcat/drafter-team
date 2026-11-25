// Fixed rules for dictated text, before any model (idea 10, docs/voice-apps-research.md; Wispr's backtrack,
// Monologue, Typeless): a spoken self-correction keeps only the corrected words, and spoken ordinals become a
// numbered list. Ukrainian and English.
import Foundation

enum Rules {
    /// "мітинг о 2, ні тобто о 3" -> "мітинг о 3"; "send it to Sava, I mean to Mila" -> "send it to Mila";
    /// "scratch that" / "забудь це" drops the sentence before it.
    static let correct = try! NSRegularExpression(pattern:
        #"(?i)[,;]?\s*\b(ні,?\s+тобто|ой,?\s+ні|вірніше|ні,?\s+стоп|no,?\s+wait|i mean|sorry,?\s+i mean|or rather|actually,?\s+no)\b[,:]?\s+"#)
    /// Markers that are also everyday speech ("what I mean is", "так буде вірніше", "ой, ні", "actually no one"): they
    /// correct only when the words after them pick up one of the last three words ("to Sava, I mean to Mila").
    static let loose = try! NSRegularExpression(pattern: #"(?i)^(i mean|sorry,?\s+i mean|вірніше|ой,?\s+ні|actually,?\s+no)$"#)
    static let scratch = try! NSRegularExpression(pattern: #"(?i)[,.;]?\s*\b(scratch that|забудь це|видали це|delete that)\b[,.!]?\s*"#)

    static func apply(_ text: String) -> String { applyMarked(text).text }

    /// `apply` with what it did, for the strip's "Cleaned" note (app/VoicePipeline.swift): sentences scratched,
    /// corrections made, closing words cut, a list made. The text is `apply`'s, byte for byte.
    static func applyMarked(_ text: String) -> (text: String, scratched: Int, corrected: Int, closing: Int, list: Int) {
        var scratched = 0, corrected = 0
        var s = text
        // scratch that: everything back to the previous sentence end goes
        while let m = scratch.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)), let r = Range(m.range, in: s) {
            let head = String(s[..<r.lowerBound]), tail = String(s[r.upperBound...])
            let cut = head.lastIndex(where: { ".!?\n".contains($0) }).map { head.index(after: $0) } ?? head.startIndex
            s = String(head[..<cut]).trimmingCharacters(in: .whitespaces) + (tail.isEmpty ? "" : " " + tail)
            s = s.trimmingCharacters(in: .whitespaces)
            scratched += 1
        }
        // self-corrections: the words after the marker replace as many words before it, inside its own sentence only
        var guardN = 0, from = 0
        while guardN < 8, let m = correct.firstMatch(in: s, range: NSRange(location: from, length: (s as NSString).length - from)),
              let r = Range(m.range, in: s), let mr = Range(m.range(at: 1), in: s) {
            guardN += 1
            let past = m.range.location + m.range.length      // not a correction: look on after it
            let marker = String(s[mr])
            let head = String(s[..<r.lowerBound]), rest = String(s[r.upperBound...])
            // words before the last sentence end are never touched, except by a repeated word when the marker opens
            // the next sentence ("Зустріч о другій. Ні, тобто о третій")
            var cut = sentenceStart(head)
            let opens = cut > head.startIndex && ".!?".contains(head[head.index(before: cut)]) && head[cut...].allSatisfy(\.isWhitespace)
            if opens { cut = sentenceStart(head, before: head.index(before: cut)) }
            let kept = String(head[..<cut])
            // the correction runs to the end of its phrase
            let end = rest.firstIndex(where: { ".!?\n;".contains($0) }) ?? rest.endIndex
            let fix = String(rest[..<end]).trimmingCharacters(in: CharacterSet(charactersIn: " ,"))
            let after = String(rest[end...])
            var hw = head[cut...].split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            guard !fix.isEmpty, !hw.isEmpty else { from = past; continue }
            let fw = fix.split(separator: " ").map { $0.lowercased() }
            let isLoose = loose.firstMatch(in: marker, range: NSRange(marker.startIndex..., in: marker)) != nil
            // the correction starts with a word that is in the last few words ("о 2 … о 3", "to Sava … to Mila"):
            // cut back to that word; else (clear markers only) replace as many words as the correction has, at most two
            let strip: (String) -> String = { $0.lowercased().trimmingCharacters(in: .punctuationCharacters) }
            if let first = fw.first, let k = hw.indices.reversed().prefix(isLoose ? 3 : 5).first(where: { strip(hw[$0]) == first }) {
                hw.removeLast(hw.count - k)
            } else if isLoose || opens {
                from = past; continue                              // "what I mean is …", "так буде вірніше, ніж …": as said
            } else {
                hw.removeLast(min(hw.count, min(2, max(1, fw.count))))
            }
            let done = kept + (kept.isEmpty || kept.hasSuffix("\n") ? "" : " ") + (hw + [fix]).joined(separator: " ")
            s = done + after
            from = (done as NSString).length
            corrected += 1
        }
        let t = trailingFillers(s), l = list(t)
        let closing = t == s.trimmingCharacters(in: .whitespacesAndNewlines) ? 0 : 1
        return (l, scratched, corrected, closing, l == t ? 0 : 1)
    }

    /// "…let's do it. Yeah." / "…check please, okay?" / "Mm-hmm. Yeah.": words he says to close a take are not text
    /// (Andrii, 2026-10-20; 19 of his takes ended in "yeah", 6 in "okay"). Only when they stand as their own clause
    /// at the very end, after a full stop or comma; a take of nothing else is dropped. "Thank you" and "do it" stay.
    static let filler = #"(?:yeah|yea|yep|yup|yes|okay|ok|o\.k\.|alright|all right|cool|mm-?hmm|mhm|uh-?huh|um+|uh+|hmm+|ага|угу|окей|ок|ну|все|всьо|так|ладно)"#
    static let tailFiller = try! NSRegularExpression(pattern:
        #"(?i)(^|[.!?…,;:])\s*"# + filler + #"(?:[\s,.!?…]+"# + filler + #")*[\s,.!?…]*$"#)

    static func trailingFillers(_ text: String) -> String {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let m = tailFiller.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)), let r = Range(m.range, in: s) else { return s }
        let mark = Range(m.range(at: 1), in: s).map { String(s[$0]) } ?? ""
        s = String(s[..<r.lowerBound]).trimmingCharacters(in: .whitespaces)
        if s.isEmpty { return "" }
        // the sentence keeps its own end: "…check it, okay?" -> "…check it."
        if [",", ";", ":"].contains(mark) || mark.isEmpty { s += s.last.map { ".!?…".contains($0) } == true ? "" : "." } else { s += mark }
        return s
    }

    /// Where the sentence that ends `head` (or ends just before `end`) begins: after the last ".", "!" or "?" followed
    /// by a space (not "2.30"), or after the last new line.
    static func sentenceStart(_ head: String, before end: String.Index? = nil) -> String.Index {
        var i = end ?? head.endIndex
        while i > head.startIndex {
            let p = head.index(before: i)
            if head[p] == "\n" || (".!?".contains(head[p]) && (i == head.endIndex || head[i].isWhitespace)) { return i }
            i = p
        }
        return head.startIndex
    }

    /// Two or more spoken ordinals in a row become a numbered list (text before the first stays as an intro line), only
    /// when they count up from the first (перше, друге…) and each starts a clause: at the start, after a comma, colon or
    /// full stop, or as по-перше / firstly. "the first time and the second time" stays as it was said.
    static let ordinal = try! NSRegularExpression(pattern:
        #"(?i)(?:^|[\s,.;:])(по-?перше|по-?друге|по-?третє|по-?четверте|по-?п'ятє|перше|друге|третє|четверте|п'яте|п’яте|first(?:ly)?|second(?:ly)?|third(?:ly)?|fourth(?:ly)?|fifth(?:ly)?)\b[,:]?\s+"#)

    /// 1 for перше / по-перше / first / firstly, 2 for друге …; 0 for anything else.
    static func rank(_ word: String) -> Int {
        var w = word.lowercased().replacingOccurrences(of: "’", with: "'")
        if w.hasPrefix("по-") { w.removeFirst(3) } else if w.hasPrefix("по") { w.removeFirst(2) }
        if w.hasSuffix("ly") { w.removeLast(2) }
        let n = ["перше": 1, "друге": 2, "третє": 3, "четверте": 4, "п'яте": 5, "п'ятє": 5,
                 "first": 1, "second": 2, "third": 3, "fourth": 4, "fifth": 5]
        return n[w] ?? 0
    }

    static func list(_ text: String) -> String {
        let ms = ordinal.matches(in: text, range: NSRange(text.startIndex..., in: text)).filter { m in
            guard let wr = Range(m.range(at: 1), in: text) else { return false }
            let w = text[wr].lowercased()
            if w.hasPrefix("по") || w.hasSuffix("ly") { return true }       // по-перше, firstly: a list word wherever it stands
            let before = text[..<wr.lowerBound].trimmingCharacters(in: .whitespaces)
            return before.last.map { ",.;:!?\n".contains($0) } ?? true    // "the first time" is not a list
        }
        guard ms.count >= 2, ms.enumerated().allSatisfy({ i, m in
            Range(m.range(at: 1), in: text).map { rank(String(text[$0])) } == i + 1
        }) else { return text }
        var items: [String] = [], intro = ""
        for (i, m) in ms.enumerated() {
            guard let r = Range(m.range, in: text) else { continue }
            if i == 0 { intro = String(text[..<r.lowerBound]).trimmingCharacters(in: CharacterSet(charactersIn: " ,;")) }
            let next = i + 1 < ms.count ? Range(ms[i + 1].range, in: text)!.lowerBound : text.endIndex
            var item = String(text[r.upperBound..<next]).trimmingCharacters(in: CharacterSet(charactersIn: " ,;"))
            if let f = item.first { item = f.uppercased() + item.dropFirst() }
            items.append(item)
        }
        let body = items.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n")
        return intro.isEmpty ? body : intro + "\n" + body
    }

    /// Names seen on screen fix close misreadings: one letter off for short names, two for long ones, same first
    /// letter, never a word of the dictionary's plain words. ("Ліно" -> "Ліна" when Ліна is on screen.)
    static func names(_ text: String, _ names: [String]) -> String {
        guard !names.isEmpty else { return text }
        var out = text
        let tokens = text.split(whereSeparator: { !$0.isLetter && $0 != "'" && $0 != "’" }).map(String.init)
        for t in Set(tokens) where t.count >= 4 {
            for n in names where n.count >= 4 && n.first?.isUppercase == true && n != t && n.lowercased() != t.lowercased() {
                guard t.first?.lowercased() == n.first?.lowercased() else { continue }
                // a different ending is a case form in Ukrainian (Зіні, Савою), not a misreading: left alone
                let pre = zip(t.lowercased(), n.lowercased()).prefix(while: { $0 == $1 }).count
                if pre >= n.count - 2 { continue }
                let d = distance(t.lowercased(), n.lowercased())
                if d <= (n.count <= 6 ? 1 : 2) {
                    out = out.replacingOccurrences(of: #"(?<![\p{L}])"# + NSRegularExpression.escapedPattern(for: t) + #"(?![\p{L}])"#,
                                                   with: n, options: .regularExpression)
                    break
                }
            }
        }
        return out
    }

    static func distance(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        if a.isEmpty { return b.count }; if b.isEmpty { return a.count }
        var prev = Array(0...b.count)
        for i in 1...a.count {
            var cur = [i] + Array(repeating: 0, count: b.count)
            for j in 1...b.count { cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1)) }
            prev = cur
        }
        return prev[b.count]
    }

    /// `Drafter --rules-test`: prints the rules on fixed examples.
    static func selfTest() {
        let cases = ["давай зустрінемось о 2, ні тобто о 3", "send it to Sava, I mean to Mila please",
                     "купи хліб. Купи молоко, scratch that. Купи сир", "план такий: перше зробити звіт, друге надіслати Саві, третє запланувати дзвінок",
                     "we need three things first the API second the screen third the tests", "напиши Ліно що буду о 5", "let's meet tomorrow, I mean Friday", "передай Зіні привіт", "tell Zina the draft is ready",
                     // stay as said (2026-10-19 audit): everyday "I mean", "вірніше", ordinals that are not a list, a sentence before
                     "What I mean is that we need more time", "так буде вірніше, ніж чекати", "It's fine, I mean it",
                     "I saw it the first time and the second time it broke", "Купи хліб. Ні, тобто молоко",
                     // still corrected
                     "we need three things: first, the API, second, the screen, third, the tests", "meet at 2.30, no wait, at 3",
                     "Зустріч о другій. Ні, тобто о третій.",
                     // closing words cut (2026-10-20)
                     "Can you check please? Yeah, thank you. Yeah.", "Let's do it. Okay, yeah.", "So check the letter, okay?",
                     "Mm-hmm. Yeah.", "Скинь мені акт, ага.", "Is this okay", "I said yeah to him", "Yeah, insert the last thing"]
        for c in cases { print("«\(c)»\n  -> «\(names(apply(c), ["Ліна", "Sava", "Mila", "Зіна", "Віра"]))»") }
    }
}

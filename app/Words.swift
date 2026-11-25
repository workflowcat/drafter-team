// Text clean-up for dictation and the shared dictionary's spelling rules, taken as they are from Voice Notes
// (Main.swift, 2026-10-18): Tidy drops "uh"/"um" and doubled words, Words writes Andrii's terms the right way.
import Foundation

enum Tidy {
    // compiled once (2026-11-14, efficiency round: five compiles on every call, three calls per draft during a take)
    private static func rx(_ pattern: String) -> NSRegularExpression? { try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) }
    private static let fillers = rx("(?:,\\s*)?(?<![\\p{L}'’-])(uh+|um+|uhm+|erm|er|hmm+|mhm|mm+|е-е+|ем+|мм+)(?![\\p{L}'’-])[,…]?\\s*")
    private static let doubled = rx("(?<![\\p{L}'’-])([\\p{L}'’]+)(?:[,]?\\s+\\1(?![\\p{L}'’-]))+")
    private static let spaceBeforeMark = rx("\\s+([,.?!])")
    private static let leading = rx("^[,.\\s]+")
    private static let spaces = rx("[ \\t]{2,}")
    private static func sub(_ s: String, _ r: NSRegularExpression?, _ with: String) -> String {
        guard let r else { return s }
        return r.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: with)
    }

    /// The last text cleaned and its result: a take's draft is cleaned three times as it arrives (Talk.lastDraft,
    /// the strip, live typing). Words.fix reads words.json changes, so a changed dictionary is keyed in too.
    private static var memo: (text: String, stamp: Int, out: String)?
    private static let memoLock = NSLock()

    /// Drops "uh", "um" and a word said twice in a row ("the the", "I I"), then mends spaces and capitals.
    static func clean(_ text: String) -> String {
        let stamp = Words.stamp
        memoLock.lock(); let m = memo; memoLock.unlock()
        if let m, m.text == text, m.stamp == stamp { return m.out }
        let out = cleanNow(text)
        memoLock.lock(); memo = (text, stamp, out); memoLock.unlock()
        return out
    }

    /// `clean` with what it dropped: fillers ("uh", "um") and words said twice, counted on the heard text (the
    /// strip's "Cleaned" note, app/VoicePipeline.swift). The text is `clean`'s.
    static func marked(_ text: String) -> (text: String, fillers: Int, repeats: Int) {
        let all = NSRange(text.startIndex..., in: text)
        let f = fillers?.numberOfMatches(in: text, range: all) ?? 0
        let r = doubled?.numberOfMatches(in: sub(text, fillers, " "), range: NSRange(location: 0, length: (sub(text, fillers, " ") as NSString).length)) ?? 0
        return (clean(text), f, r)
    }

    private static func cleanNow(_ text: String) -> String {
        var s = sub(text, fillers, " ")
        s = sub(s, doubled, "$1")
        s = sub(s, spaceBeforeMark, "$1")
        s = sub(s, leading, "")
        s = Words.fix(sub(s, spaces, " ").trimmingCharacters(in: .whitespacesAndNewlines))
        // A sentence that lost its first word starts with a small letter now.
        var out = "", up = true
        for ch in s {
            if up, ch.isLetter {
                out += ch.uppercased()
                up = false
            } else {
                out.append(ch)
                if ".?!".contains(ch) { up = true } else if !ch.isWhitespace { up = false }
            }
        }
        return out
    }
}

/// Andrii's own words (words.json): written the right way however they were heard. Plain text
/// replacement after the read, so it costs no time.
enum Words {
    /// The shared dictionary.
    static let file: URL = {
        Home.words
    }()

    private static var json: [String: Any] { loaded.json }
    /// Read again when words.json changes (a word learned from his edits counts at once).
    private static var loaded: (stamp: Date?, json: [String: Any], keep: NSRegularExpression?, rules: [(NSRegularExpression, String)]) = (nil, [:], nil, [])
    private static var generation = 0
    /// Changes whenever words.json is read again (Tidy's memo keys on it).
    static var stamp: Int { refresh(); return generation }
    private static func refresh() {
        let m = (try? FileManager.default.attributesOfItem(atPath: file.path))?[.modificationDate] as? Date
        guard m != loaded.stamp || loaded.stamp == nil else { return }
        loaded.stamp = m; generation += 1
        loaded.json = readJSON()
        loaded.keep = makeKeep(); loaded.rules = makeRules()
    }
    private static func readJSON() -> [String: Any] {
        guard let d = try? Data(contentsOf: file),
              let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return [:] }
        return j
    }

    /// Phrases that stay as heard ("the cloud" is not Claude).
    static var keep: NSRegularExpression? { refresh(); return loaded.keep }
    private static func makeKeep() -> NSRegularExpression? {
        let k = (json["keep"] as? [String] ?? []).sorted { $0.count > $1.count }
            .map { $0.split(separator: " ").map { NSRegularExpression.escapedPattern(for: String($0)) }.joined(separator: "[\\s-]+") }
        guard !k.isEmpty else { return nil }
        return try? NSRegularExpression(pattern: "(?<![\\p{L}\\p{N}])(?:" + k.joined(separator: "|") + ")(?![\\p{L}\\p{N}])", options: [.caseInsensitive])
    }

    static var rules: [(NSRegularExpression, String)] { refresh(); return loaded.rules }
    private static func makeRules() -> [(NSRegularExpression, String)] {
        let j = json
        var out: [(NSRegularExpression, String)] = []
        func add(_ parts: [String], _ gap: String, _ to: String) {
            let body = parts.map { NSRegularExpression.escapedPattern(for: $0) }.joined(separator: gap)
            if let r = try? NSRegularExpression(pattern: "(?<![\\p{L}\\p{N}])" + body + "(?![\\p{L}\\p{N}])", options: [.caseInsensitive]) {
                out.append((r, NSRegularExpression.escapedTemplate(for: to)))
            }
        }
        for (heard, meant) in (j["heard"] as? [String: String] ?? [:]).sorted(by: { $0.key.count > $1.key.count }) {
            add(heard.split(separator: " ").map(String.init), "\\s+", meant)
        }
        for term in (j["terms"] as? [String] ?? []).sorted(by: { $0.count > $1.count }) {
            // PixelKit is also heard as "pixel kit", Notes42 as "notes 42", GitHub as "git hub".
            var parts: [String] = [], cur = ""
            for ch in term {
                let last = cur.last
                let cut = ch == " " || (last != nil && ((last!.isLowercase && ch.isUppercase) || (last!.isLetter && ch.isNumber) || (last!.isNumber && ch.isLetter)))
                if cut, !cur.isEmpty {
                    parts.append(cur)
                    cur = ""
                }
                if ch != " " { cur.append(ch) }
            }
            if !cur.isEmpty { parts.append(cur) }
            if parts.count == 1, term.count > 4, term.lowercased().hasSuffix("kit") { parts = [String(term.dropLast(3)), "kit"] }
            add(parts, "[\\s-]?", term)
        }
        return out
    }

    static func fix(_ text: String) -> String {
        var s = text
        // Kept phrases step aside (as private-use marks) while the rules run, then come back.
        var kept: [String] = []
        if let keep {
            let ns = s as NSString
            for m in keep.matches(in: s, range: NSRange(location: 0, length: ns.length)).reversed() {
                kept.append(ns.substring(with: m.range))
                s = (s as NSString).replacingCharacters(in: m.range, with: "\u{E000}\(kept.count - 1)\u{E001}")
            }
        }
        for (r, to) in rules { s = r.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: to) }
        for (i, k) in kept.enumerated() { s = s.replacingOccurrences(of: "\u{E000}\(i)\u{E001}", with: k) }
        return s
    }
}

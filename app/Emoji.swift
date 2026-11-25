// Emoji codes (1 November 2026; Cotypist and Pretype have them, he lost them in the switch): ":" and two or more
// letters at the start of a word offer one emoji as a chip, Tab puts it in place of the code. Names come from Unicode
// itself plus the usual chat codes (:joy, :+1, :tada); the emoji he used most in his own writing (data/typed.jsonl)
// win a tie. "http:", "10:30" and "a:b" never trigger: the colon must start a word.
import Foundation

enum Emoji {
    struct Entry { let emoji: String; let name: String; let words: [String]; let joined: String; let alias: Bool }

    /// The usual chat codes, first so ":joy" is 😂 and not a Unicode name that starts with "joy".
    static let aliases: [(String, String)] = [
        ("joy", "😂"), ("lol", "😂"), ("rofl", "🤣"), ("heart", "❤️"), ("love", "😍"), ("+1", "👍"), ("thumbsup", "👍"),
        ("-1", "👎"), ("thumbsdown", "👎"), ("ok", "👌"), ("pray", "🙏"), ("thanks", "🙏"), ("tada", "🎉"), ("party", "🥳"),
        ("rocket", "🚀"), ("fire", "🔥"), ("eyes", "👀"), ("100", "💯"), ("smile", "😄"), ("laughing", "😆"),
        ("sweat_smile", "😅"), ("wink", "😉"), ("blush", "😊"), ("thinking", "🤔"), ("sob", "😭"), ("cry", "😢"),
        ("shrug", "🤷"), ("facepalm", "🤦"), ("clap", "👏"), ("muscle", "💪"), ("wave", "👋"), ("check", "✅"),
        ("x", "❌"), ("warning", "⚠️"), ("star", "⭐"), ("sparkles", "✨"), ("hug", "🤗"), ("coffee", "☕"), ("beer", "🍺"),
        ("ua", "🇺🇦"), ("ukraine", "🇺🇦"), ("cool", "😎"), ("sad", "😔"), ("angry", "😠"), ("skull", "💀"), ("kiss", "😘"),
        ("upside", "🙃"), ("raised_hands", "🙌"), ("handshake", "🤝"), ("money", "💰"), ("calendar", "📅"), ("memo", "📝"),
        ("bulb", "💡"), ("zap", "⚡"), ("point_up", "☝️"), ("point_right", "👉"), ("see_no_evil", "🙈"), ("grin", "😁"),
        ("slightly_smiling", "🙂"), ("neutral", "😐"), ("eyeroll", "🙄"), ("melt", "🫠"), ("salute", "🫡"), ("plus", "➕"),
    ]

    static let table: [Entry] = build()
    private static var mine: [String: Int] = [:], loaded = Date.distantPast

    private static func build() -> [Entry] {
        var out: [Entry] = [], seen = Set<String>()
        for (code, e) in aliases {
            out.append(Entry(emoji: e, name: code.replacingOccurrences(of: "_", with: " "), words: [code], joined: code, alias: true))
            seen.insert(e)
        }
        let ranges: [ClosedRange<UInt32>] = [0x1F300...0x1F5FF, 0x1F600...0x1F64F, 0x1F680...0x1F6FF, 0x1F900...0x1F9FF,
                                             0x1FA70...0x1FAFF, 0x2600...0x27BF, 0x2B00...0x2BFF]
        for r in ranges {
            for v in r {
                guard let s = Unicode.Scalar(v), s.properties.isEmoji, !(0x1F3FB...0x1F3FF).contains(v),
                      let n = s.properties.name else { continue }
                // emoji by default as is; a symbol that is text by default gets the emoji form (❤ -> ❤️)
                let e = s.properties.isEmojiPresentation ? String(s) : String(s) + "\u{FE0F}"
                guard !seen.contains(e), !seen.contains(String(s)) else { continue }
                let words = n.lowercased().split(separator: " ").map(String.init)
                out.append(Entry(emoji: e, name: words.joined(separator: " "), words: words, joined: words.joined(), alias: false))
            }
        }
        return out
    }

    /// How often he used each emoji (his typed lines), read at most every 10 minutes, off the main thread
    /// (2026-11-14: the whole-file scan held the key path ~150 ms on a 2.9 MB typed.jsonl); until the first read is
    /// back, the order is the plain one.
    private static func refresh() {
        guard Date().timeIntervalSince(loaded) > 600 else { return }
        loaded = Date()
        DispatchQueue.global(qos: .utility).async {
            let t = (try? String(contentsOf: Home.data.appendingPathComponent("typed.jsonl"), encoding: .utf8)) ?? ""
            var n: [String: Int] = [:]
            for ch in t where ch.unicodeScalars.first.map({ $0.properties.isEmojiPresentation || ($0.properties.isEmoji && $0.value > 0x2000) }) == true {
                n[String(ch), default: 0] += 1
                if ch.unicodeScalars.count == 1, let s = ch.unicodeScalars.first, !s.properties.isEmojiPresentation { n[String(ch) + "\u{FE0F}", default: 0] += 1 }
            }
            DispatchQueue.main.async { mine = n }
        }
    }

    /// The best emoji for a code: an exact chat code, then a whole word of its name, then a name that starts with it.
    static func match(_ code: String) -> Entry? {
        refresh()
        let c = code.lowercased(), flat = c.replacingOccurrences(of: "_", with: "")
        func rank(_ e: Entry) -> Int? {
            // a chat code that starts with it beats a long Unicode name (":fir" is 🔥, not 🎆 fireworks)
            if e.alias { return e.joined == c ? 0 : (e.joined.hasPrefix(c) ? 2 : nil) }
            if e.words.contains(c) { return 1 }
            if e.joined.hasPrefix(flat) { return 3 }
            if e.words.contains(where: { $0.hasPrefix(c) }) { return 4 }
            return nil
        }
        return table.compactMap { e in rank(e).map { (e, $0) } }
            .min { a, b in
                if a.1 != b.1 { return a.1 < b.1 }
                let ua = mine[a.0.emoji] ?? 0, ub = mine[b.0.emoji] ?? 0
                if ua != ub { return ua > ub }
                return a.0.words.count != b.0.words.count ? a.0.words.count < b.0.words.count : a.0.name.count < b.0.name.count
            }?.0
    }

    /// The chip for the code just before the caret, or nil.
    static func offer(_ before: String) -> [String: Any]? {
        let line = before.components(separatedBy: "\n").last ?? ""
        guard let colon = line.lastIndex(of: ":") else { return nil }
        let code = String(line[line.index(after: colon)...])
        guard code.count >= 2, code.count <= 24, code.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "_+-".contains($0)) }),
              code.contains(where: { $0.isLetter }) || ["+1", "-1", "100"].contains(code) else { return nil }
        if colon > line.startIndex {
            let prev = line[line.index(before: colon)]
            guard prev.isWhitespace || "([\"«".contains(prev) else { return nil }
        }
        guard let e = match(code) else { return nil }
        return ["id": "snippet", "chip": "⇥ \(e.emoji)  \(e.name)",
                "run": ["kind": "expand", "old": ":" + code, "new": e.emoji, "key": "emoji"]]
    }

    /// `Drafter --emoji-test`: fixed codes and what they give; nothing is typed anywhere.
    static func selfTest() {
        print("emoji table: \(table.count) entries")
        let cases: [(String, String?)] = [("hi :fire", "🔥"), ("ok :joy", "😂"), (":+1", "👍"), ("so :tada", "🎉"), ("x :thumbs", "👍"),
                                          ("go :rock", "🪨"), ("go :rocke", "🚀"), ("so :fir", "🔥"), ("a :hea", "❤️"), ("b :thu", "👍"), ("see :heart", "❤️"), ("http://a:b", nil), ("at 10:30", nil),
                                          ("a:fire", nil), ("one :f", nil), ("t :ua", "🇺🇦"), ("hmm :thinki", "🤔"), ("z :pizza", "🍕")]
        var bad = 0
        for (input, want) in cases {
            let got = (offer(input)?["run"] as? [String: Any])?["new"] as? String
            if got != want { bad += 1 }
            print(got == want ? "ok  " : "FAIL", input, "->", got ?? "-", got == want ? "" : "(want \(want ?? "-"))")
        }
        print(bad == 0 ? "all cases ok" : "\(bad) cases failed")
    }
}

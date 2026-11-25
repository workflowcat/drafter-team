import Foundation

/// One transcript line to export. `who` is a display name or "".
struct CueLine: Equatable {
    var who: String
    var start: Double?
    var text: String
}

/// Transcript exports: plain text, SRT subtitles, Markdown. Pure Foundation.
enum TranscriptFormats {
    static let perWord = 0.35, minRead = 1.0, maxCue = 7.0, maxChars = 84, gap = 0.05, minCue = 0.5

    static func stamp(_ t: Double) -> String {
        let s = max(0, Int(t))
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%02d:%02d", s / 60, s % 60)
    }

    /// "[mm:ss] who: text" per line.
    static func text(_ lines: [CueLine]) -> String {
        lines.map { l in
            var s = ""
            if let t = l.start { s += "[\(stamp(t))] " }
            if !l.who.isEmpty { s += "\(l.who): " }
            return s + l.text.trimmingCharacters(in: .whitespacesAndNewlines)
        }.joined(separator: "\n") + (lines.isEmpty ? "" : "\n")
    }

    /// SRT cues: end = next start minus 0.05 s (at least start + 0.5); the last and untimed lines go by reading pace
    /// (0.35 s a word, 1 to 7 s); long cues split. `total`, when given, caps the last cue's end.
    static func srt(_ lines: [CueLine], total: Double? = nil) -> String {
        let kept = lines.map { CueLine(who: $0.who, start: $0.start, text: $0.text.trimmingCharacters(in: .whitespacesAndNewlines)) }
            .filter { !$0.text.isEmpty }
        // 1. starts: untimed lines follow the previous one at reading pace
        var starts: [Double] = []
        var next = 0.0
        for l in kept {
            let s = max(l.start ?? next, starts.last ?? 0)
            starts.append(s)
            next = s + reading(l.text)
        }
        // 2. ends, 3. splits
        var cues: [(Double, Double, String)] = []
        for (i, l) in kept.enumerated() {
            let s = starts[i]
            var e: Double
            if i + 1 < kept.count { e = starts[i + 1] - gap } else {
                e = s + reading(l.text)
                if let total, total > s { e = min(e, total) }
            }
            e = max(e, s + minCue)
            let prefix = l.who.isEmpty ? "" : "\(l.who): "
            for (cs, ce, part) in split(l.text, start: s, end: e) { cues.append((cs, ce, prefix + part)) }
        }
        return cues.enumerated().map { n, c in "\(n + 1)\n\(srtTime(c.0)) --> \(srtTime(c.1))\n\(c.2)\n" }.joined(separator: "\n")
    }

    static func markdown(title: String, meta: String, summary: [String], todos: [String], lines: [CueLine]) -> String {
        var parts: [String] = []
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !t.isEmpty { parts.append("# \(t)") }
        let m = meta.trimmingCharacters(in: .whitespacesAndNewlines)
        if !m.isEmpty { parts.append(m) }
        let sum = summary.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        if !sum.isEmpty { parts.append("## Summary\n\n" + sum.map { "- \($0)" }.joined(separator: "\n")) }
        let todo = todos.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        if !todo.isEmpty { parts.append("## To-dos\n\n" + todo.map { "- [ ] \($0)" }.joined(separator: "\n")) }
        let body = lines.compactMap { l -> String? in
            let x = l.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if x.isEmpty { return nil }
            var head: [String] = []
            if !l.who.isEmpty { head.append("**\(l.who)**") }
            if let s = l.start { head.append("[\(stamp(s))]") }
            return (head + [x]).joined(separator: " ")
        }
        if !body.isEmpty { parts.append("## Transcript\n\n" + body.joined(separator: "\n\n")) }
        return parts.isEmpty ? "" : parts.joined(separator: "\n\n") + "\n"
    }

    // MARK: - helpers

    static func reading(_ text: String) -> Double {
        let words = text.split(whereSeparator: { $0.isWhitespace }).count
        return min(maxCue, max(minRead, Double(words) * perWord))
    }

    static func srtTime(_ t: Double) -> String {
        let ms = Int((max(0, t) * 1000).rounded())
        return String(format: "%02d:%02d:%02d,%03d", ms / 3_600_000, ms / 60_000 % 60, ms / 1000 % 60, ms % 1000)
    }

    /// Splits a cue longer than 7 s or 84 characters at sentence ends, then commas, then words, into parts of at most
    /// 84 characters (fewer when the cue lasts long, aiming at 7 s each), with times shared by length.
    static func split(_ text: String, start: Double, end: Double) -> [(Double, Double, String)] {
        let dur = end - start
        guard dur > maxCue || text.count > maxChars else { return [(start, end, text)] }
        let limit = dur > maxCue ? max(12, min(maxChars, Int(Double(text.count) * maxCue / dur))) : maxChars
        var chunks = pack(pieces(text, at: ".!?…"), limit)
        chunks = chunks.flatMap { $0.count > limit ? pack(pieces($0, at: ",;:"), limit) : [$0] }
        chunks = chunks.flatMap { $0.count > limit ? pack($0.split(separator: " ").map(String.init), limit) : [$0] }
        let total = Double(chunks.reduce(0) { $0 + $1.count })
        guard chunks.count > 1, total > 0 else { return [(start, end, text)] }
        var out: [(Double, Double, String)] = []
        var t = start
        for (i, c) in chunks.enumerated() {
            if i == chunks.count - 1 { out.append((t, end, c)); break }
            let e = t + dur * Double(c.count) / total
            out.append((t, max(t + 0.01, e - gap), c))
            t = e
        }
        return out
    }

    /// Text cut after any of `marks` followed by a space.
    private static func pieces(_ text: String, at marks: String) -> [String] {
        var out: [String] = [], cur = ""
        let chars = Array(text)
        for (i, ch) in chars.enumerated() {
            cur.append(ch)
            if marks.contains(ch), i + 1 < chars.count, chars[i + 1] == " " {
                out.append(cur.trimmingCharacters(in: .whitespaces)); cur = ""
            }
        }
        let rest = cur.trimmingCharacters(in: .whitespaces)
        if !rest.isEmpty { out.append(rest) }
        return out
    }

    /// Joins pieces greedily into chunks of at most `limit` characters (a single longer piece stays whole).
    private static func pack(_ pieces: [String], _ limit: Int) -> [String] {
        var out: [String] = [], cur = ""
        for p in pieces {
            if cur.isEmpty { cur = p } else if cur.count + 1 + p.count <= limit { cur += " " + p } else { out.append(cur); cur = p }
        }
        if !cur.isEmpty { out.append(cur) }
        return out
    }
}

// Local, literal previews. No file access, markup execution or UI dependencies.
import Foundation

enum MarkdownBlock: Equatable {
    case heading(level: Int, text: String)
    case bullet(text: String)
    case code(text: String)
    case paragraph(text: String)

    var text: String {
        switch self {
        case .heading(_, let text), .bullet(let text), .code(let text), .paragraph(let text): return text
        }
    }
}

enum NotePreviewRules {
    static func shouldAutoExpandSparse(totalItems: Int, maxSparse: Int = 30) -> Bool {
        totalItems > 0 && totalItems <= maxSparse
    }

    static func recordingBadges(hasVideo: Bool, shotCount: Int, todoCount: Int, app: String) -> [String] {
        var out: [String] = []
        let app = compact(app)
        if hasVideo { out.append("Video") }
        else if !app.isEmpty { out.append(app) }
        if shotCount > 0 { out.append("\(shotCount) " + (shotCount == 1 ? "shot" : "shots")) }
        if todoCount > 0 { out.append("\(todoCount) " + (todoCount == 1 ? "to-do" : "to-dos")) }
        return out
    }

    static func recordingPreviewLines(points: [String], mine: String,
                                      turns: [(who: String, text: String)], maxLines: Int = 3) -> [String] {
        guard maxLines > 0 else { return [] }
        func lines(_ texts: [String]) -> [String] {
            texts.flatMap { parseMarkdownBlocks($0).flatMap { $0.text.components(separatedBy: .newlines) } }
                .map(compact).filter { !$0.isEmpty }
        }
        let summary = lines(points)
        if !summary.isEmpty { return Array(summary.prefix(maxLines)) }
        let notes = lines([mine])
        if !notes.isEmpty { return Array(notes.prefix(maxLines)) }
        let transcript = lines(turns.map(\.text))
        // Prefer substantive turns; retain a one-word take when it is all that was said.
        let fillers: Set<String> = ["um", "uh", "hmm", "hm", "ah", "oh", "ok", "okay", "yes", "no", "yeah", "yep", "right"]
        let useful = transcript.filter {
            let words = $0.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
            return words.count > 1 && words.contains { !fillers.contains($0) }
        }
        if !transcript.isEmpty { return Array((useful.isEmpty ? transcript : useful).prefix(maxLines)) }
        // Even a take containing only markup punctuation still has a visible preview.
        return Array((points + [mine] + turns.map(\.text)).map(compact).filter { !$0.isEmpty }.prefix(maxLines))
    }

    static func parseMarkdownBlocks(_ text: String) -> [MarkdownBlock] {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        var out: [MarkdownBlock] = [], paragraph: [String] = [], code: [String] = []
        var fence = 0
        func flush() {
            let s = paragraph.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !s.isEmpty { out.append(.paragraph(text: s)) }
            paragraph = []
        }
        for raw in normalized.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            let ticks = line.prefix(while: { $0 == "`" }).count
            if fence > 0 {
                if ticks >= fence, line.dropFirst(ticks).trimmingCharacters(in: .whitespaces).isEmpty {
                    out.append(.code(text: code.joined(separator: "\n"))); code = []; fence = 0
                } else { code.append(raw) }
            } else if ticks >= 3 {
                flush(); fence = ticks
            } else if line.isEmpty {
                flush()
            } else if let h = heading(line) {
                flush(); out.append(.heading(level: h.level, text: h.text))
            } else if let b = bullet(line) {
                flush(); out.append(.bullet(text: b))
            } else { paragraph.append(raw) }
        }
        if fence > 0 { out.append(.code(text: code.joined(separator: "\n"))) }
        flush()
        return out
    }

    static func noteHeadlineAndPreview(_ text: String) -> (headline: String?, body: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let blocks = parseMarkdownBlocks(trimmed)
        if case .heading(_, let title) = blocks.first {
            return (title, blocks.dropFirst().map(\.text).joined(separator: "\n\n"))
        }
        let lines = trimmed.components(separatedBy: .newlines)
        if let first = lines.first, lines.dropFirst().contains(where: { !compact($0).isEmpty }),
           !first.isEmpty, first.count <= 80, first.split(whereSeparator: \.isWhitespace).count <= 10,
           !".!?;:".contains(first.last!), !first.hasPrefix("```"), bullet(first) == nil,
           !first.hasPrefix("#"), !first.contains("://") {
            return (first, parseMarkdownBlocks(lines.dropFirst().joined(separator: "\n")).map(\.text).joined(separator: "\n\n"))
        }
        return (nil, trimmed)
    }

    private static func compact(_ text: String) -> String { text.split(whereSeparator: \.isWhitespace).joined(separator: " ") }
    private static func heading(_ line: String) -> (level: Int, text: String)? {
        let n = line.prefix(while: { $0 == "#" }).count
        guard (1...3).contains(n), line.dropFirst(n).first?.isWhitespace == true else { return nil }
        let text = line.dropFirst(n).trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? nil : (n, text)
    }
    private static func bullet(_ line: String) -> String? {
        var tail: Substring
        if line.hasPrefix("- ") || line.hasPrefix("• ") { tail = line.dropFirst(2) }
        else {
            let n = line.prefix(while: { $0.isASCII && $0.isNumber }).count
            guard n > 0, line.dropFirst(n).hasPrefix(". ") else { return nil }
            tail = line.dropFirst(n + 2)
        }
        let text = tail.trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? nil : text
    }
}

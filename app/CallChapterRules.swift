// Local, deterministic call navigation and brief composition. No file or network access.
import Foundation

struct CallChapterTurn: Equatable, Hashable {
    let start: Double?
    let end: Double?
    let who: String
    let text: String
}

struct CallChapter: Equatable, Identifiable {
    let start: Double
    let end: Double
    let title: String
    var id: Double { start }
}

enum HybridNoteBlock: Equatable {
    case human(text: String)
    case aiPoint(text: String, citations: [Double])
    case todo(text: String, citations: [Double])
}

enum CallChapterRules {
    private static let wordPattern = try! NSRegularExpression(pattern: #"[\p{L}\p{N}]+(?:['’][\p{L}\p{N}]+)*"#)
    private static let stop = Set("a an and are as at be been but by can could did do does for from had has have he her here him his how i if in is it its just like me more my no not of on or our out so some that the their them then there these they this those to too us was we were what when which who will with would yes you your okay well really about let's".split(separator: " ").map(String.init))

    private static func words(_ text: String) -> [String] {
        wordPattern.matches(in: text, range: NSRange(text.startIndex..., in: text)).map { (text as NSString).substring(with: $0.range) }
    }
    private static func tokens(_ text: String) -> Set<String> {
        Set(words(text).map { $0.lowercased() }.filter { $0.count > 1 && !stop.contains($0) })
    }
    private static func timed(_ turns: [CallChapterTurn]) -> [CallChapterTurn] {
        turns.enumerated().filter { _, t in
            guard let s = t.start else { return false }
            return s.isFinite && s >= 0 && !t.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }.sorted { a, b in a.element.start! == b.element.start! ? a.offset < b.offset : a.element.start! < b.element.start! }.map(\.element)
    }

    /// Keep both tracks and their original ends: merged display turns cannot prove a silence gap.
    static func transcriptTurns(from data: Data, careful: Bool = false) -> [CallChapterTurn] {
        guard let json = try? JSONSerialization.jsonObject(with: data) else { return [] }
        let rows: [[String: Any]]
        if careful, let object = json as? [String: Any] {
            rows = (object["me"] as? [[String: Any]] ?? []) + (object["them"] as? [[String: Any]] ?? [])
        } else { rows = json as? [[String: Any]] ?? [] }
        return rows.compactMap { row in
            guard let text = row["text"] as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return CallChapterTurn(start: row["start"] as? Double, end: row["end"] as? Double,
                                   who: row["who"] as? String ?? "", text: text)
        }
    }

    /// Natural cuts win; sparse topics use balanced cuts at actual turn starts. At most eight chapters.
    static func chapters(turns: [CallChapterTurn], duration: Double) -> [CallChapter] {
        guard duration.isFinite, duration > 0 else { return [] }
        let rows = timed(turns).filter { $0.start! < duration }
        guard !rows.isEmpty else { return [] }
        let target = duration < 60 ? 1 : min(8, max(1, Int(min(duration / 480, 6)) + (duration >= 600 ? 3 : 1)))
        let minimum = max(45, duration / Double(max(1, target) * 3))
        let sets = rows.map { tokens($0.text) }
        var candidates: [(time: Double, score: Double)] = []
        let firstEnd = rows[0].end.flatMap { $0.isFinite && $0 >= rows[0].start! ? $0 : nil }
        var coveredUntil = firstEnd ?? rows[0].start!
        var previousEndKnown = firstEnd != nil
        for i in rows.indices.dropFirst() {
            let t = rows[i].start!
            let left = sets[max(0, i - 3)..<i].reduce(into: Set<String>()) { $0.formUnion($1) }
            let right = sets[i..<min(rows.count, i + 3)].reduce(into: Set<String>()) { $0.formUnion($1) }
            let overlap = Double(left.intersection(right).count) / Double(max(1, min(left.count, right.count)))
            let gap = previousEndKnown ? t - coveredUntil : 0
            if gap >= 25 || (left.count >= 3 && right.count >= 3 && overlap < 0.25) {
                candidates.append((t, gap >= 25 ? 3 + min(gap / 120, 1) : 1 - overlap))
            }
            // Unknown ends cover up to the next start: never infer silence from word count.
            if let end = rows[i].end, end.isFinite, end >= t {
                coveredUntil = max(coveredUntil, end); previousEndKnown = true
            } else {
                coveredUntil = max(coveredUntil, t); previousEndKnown = false
            }
        }
        var cuts = [0.0, duration]
        func fits(_ t: Double) -> Bool { cuts.allSatisfy { abs($0 - t) >= minimum } }
        for candidate in candidates.sorted(by: { $0.score == $1.score ? $0.time < $1.time : $0.score > $1.score }) {
            guard cuts.count <= target else { break }
            if fits(candidate.time) { cuts.append(candidate.time) }
        }
        // Fill long uninterrupted discussions, without manufacturing timestamps between words.
        while cuts.count <= target {
            let available = rows.map { $0.start! }.filter(fits)
            guard let cut = available.max(by: { a, b in
                let da = cuts.map { abs($0 - a) }.min()!, db = cuts.map { abs($0 - b) }.min()!
                return da == db ? a > b : da < db
            }) else { break }
            cuts.append(cut)
        }
        cuts.sort()
        return (0..<(cuts.count - 1)).map { i in
            let text = rows.filter { $0.start! >= cuts[i] && $0.start! < cuts[i + 1] }.map(\.text)
            return CallChapter(start: cuts[i], end: cuts[i + 1], title: chapterTitle(text))
        }
    }

    private static func chapterTitle(_ lines: [String]) -> String {
        var counts: [String: Int] = [:]
        for line in lines { for token in tokens(line) { counts[token, default: 0] += 1 } }
        // Prefer a short source phrase, scored by the recurring content in this chapter.
        var best: (text: String, score: Double)?
        for line in lines {
            let parts = line.components(separatedBy: CharacterSet(charactersIn: ".!?;:\n"))
            for part in parts {
                let all = words(part)
                let content = all.filter { !stop.contains($0.lowercased()) }
                guard !content.isEmpty else { continue }
                let selected = all.count >= 2 && all.count <= 5 ? all : Array(content.prefix(4))
                let score = selected.reduce(0.0) { $0 + Double(counts[$1.lowercased(), default: 0]) } / Double(selected.count)
                let text = selected.joined(separator: " ")
                if best == nil || score > best!.score { best = (text, score) }
            }
        }
        guard var title = best?.text else {
            let fallback = lines.flatMap(words).prefix(5).joined(separator: " ")
            if fallback.isEmpty { return "Chapter 1" }
            return words(fallback).count == 1 ? fallback + " discussion" : fallback
        }
        if words(title).count == 1 { title += " discussion" }
        title = String(title.prefix(1)).uppercased() + title.dropFirst()
        return title
    }

    static func formatChaptersForCopy(_ chapters: [CallChapter]) -> String {
        chapters.map { "\(CallTimelineRules.formatOffset($0.start)) — \($0.title)" }.joined(separator: "\n")
    }

    static func hybridNotes(myNotes: String, summary: [String], todos: [String], turns: [CallChapterTurn]) -> [HybridNoteBlock] {
        let index = timed(turns).map { (time: $0.start!, tokens: tokens($0.text)) }
        func citations(_ text: String) -> [Double] {
            let query = tokens(text)
            guard query.count >= 2 else { return [] }
            let matches = index.compactMap { row -> (time: Double, score: Double)? in
                let count = query.intersection(row.tokens).count
                let coverage = Double(count) / Double(query.count)
                guard count >= 2, coverage >= 0.4 else { return nil }
                return (row.time, coverage + Double(count) / Double(max(1, row.tokens.count)) * 0.2)
            }.sorted { $0.score == $1.score ? $0.time < $1.time : $0.score > $1.score }
            var result: [Double] = []
            for match in matches where !result.contains(match.time) {
                result.append(match.time)
                if result.count == 2 { break }
            }
            return result.sorted()
        }
        let human = myNotes.components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        return human.map { .human(text: $0) }
            + bullets(summary).map { .aiPoint(text: $0, citations: citations($0)) }
            + bullets(todos).map { .todo(text: $0, citations: citations($0)) }
    }

    /// Returns a target only inside a known long gap. Unknown ends and trailing silence are left alone.
    static func nextPlayableTime(at t: Double, turns: [CallChapterTurn], minimumGap: Double = 3) -> Double? {
        guard t.isFinite, t >= 0, minimumGap.isFinite, minimumGap >= 0 else { return nil }
        let rows = timed(turns)
        var coveredUntil = 0.0
        for (i, row) in rows.enumerated() {
            let start = row.start!
            if t < start { return start - coveredUntil >= minimumGap && t >= coveredUntil ? start : nil }
            if let end = row.end, end.isFinite, end >= start { coveredUntil = max(coveredUntil, end) }
            else {
                // An untimed end can contain speech all the way to the next turn (or the recording end).
                coveredUntil = max(coveredUntil, i + 1 < rows.count ? rows[i + 1].start! : .infinity)
            }
            if t < coveredUntil { return nil }
        }
        return nil
    }

    /// Strict stepping: exact matches move on; duplicate or invalid timestamps never trap the control.
    static func nextChangedShot(at t: Double, shots: [Double], direction: Int = 1) -> Double? {
        guard t.isFinite, direction != 0 else { return nil }
        let valid = shots.filter { $0.isFinite && $0 >= 0 }
        return direction > 0 ? valid.filter { $0 > t }.min() : valid.filter { $0 < t }.max()
    }

    static func shareBrief(title: String, dateLabel: String, duration: Double, people: [String], myNotes: String,
                           summary: [String], todos: [String], chapters: [CallChapter], links: [String]) -> String {
        let heading = clean(title).isEmpty ? "Meeting brief" : clean(title)
        var sections = ["# " + heading, [clean(dateLabel), CallTimelineRules.formatOffset(duration)].filter { !$0.isEmpty }.joined(separator: " · ")]
        let names = people.map(clean).filter { !$0.isEmpty }
        if !names.isEmpty { sections.append("Participants: " + names.joined(separator: ", ")) }
        let human = bullets(myNotes.components(separatedBy: "\n")).map(clean).filter { !$0.isEmpty }
        if !human.isEmpty { sections.append("## Your Notes\n" + human.map { "- " + $0 }.joined(separator: "\n")) }
        let points = bullets(summary).map(clean).filter { !$0.isEmpty }
        if !points.isEmpty { sections.append("## Key Takeaways\n" + points.map { "- " + $0 }.joined(separator: "\n")) }
        let actions = bullets(todos).map(clean).filter { !$0.isEmpty }
        if !actions.isEmpty { sections.append("## Action Items\n" + actions.map { "- [ ] " + $0 }.joined(separator: "\n")) }
        if chapters.count >= 2 {
            sections.append("## Chapters\n" + chapters.map { "- \(CallTimelineRules.formatOffset($0.start)) — \(clean($0.title))" }.joined(separator: "\n"))
        }
        let urls = extractedURLs(from: links + [myNotes] + summary + todos)
        if !urls.isEmpty { sections.append("## Links\n" + urls.map { "- " + $0 }.joined(separator: "\n")) }
        return sections.joined(separator: "\n\n") + "\n"
    }

    static func extractedURLs(from texts: [String]) -> [String] {
        let rx = try! NSRegularExpression(pattern: #"https?://[^\s<>\"\[\]]+"#, options: .caseInsensitive)
        var result: [String] = []
        for text in texts {
            for match in rx.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                let candidate = (text as NSString).substring(with: match.range).trimmingCharacters(in: CharacterSet(charactersIn: ".,;!?)"))
                guard let url = URLComponents(string: candidate), let host = url.host, host.contains("."),
                      url.user == nil, url.password == nil, !result.contains(candidate) else { continue }
                result.append(candidate)
            }
        }
        return result
    }

    private static func bullets(_ items: [String]) -> [String] {
        items.flatMap { $0.components(separatedBy: "\n") }.compactMap { raw in
            var line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.hasPrefix("#"), line != "---", !line.hasPrefix("```") else { return nil }
            line = line.replacingOccurrences(of: #"^(?:[-*•]\s+|\d+[.)]\s+)?(?:\[[ xX]\]\s*)?"#, with: "", options: .regularExpression)
            return line.isEmpty ? nil : line
        }
    }
    /// Briefs carry prose and web links, never machine paths or local Markdown link targets.
    private static func clean(_ text: String) -> String {
        var value = text.replacingOccurrences(of: #"\[([^\]]+)\]\((?!https?://)[^)]+\)"#, with: "$1", options: .regularExpression)
        value = value.replacingOccurrences(of: #"(?i)(?:file://[^\s<>]+|(?<![\w:/])(?:~/|/(?!/)|[A-Z]:\\|(?:\.\.?/|data/|app/|engine/))[^\s<>]*)"#, with: "", options: .regularExpression)
        value = value.replacingOccurrences(of: #"[\r\n\t]+"#, with: " ", options: .regularExpression)
        return value.replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

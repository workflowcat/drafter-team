// Pre-meeting "5-second brief" rules for RecordWindow (Wave 8B): pure Foundation, zero AppKit/SwiftUI.
// Parses /prep context and open /promises for the call's participants, deduplicates and caps text length,
// and governs auto-hide once live outline notes arrive or 120 s elapse. Test: tests/pre_meeting_brief_rules.swift.
import Foundation

struct PreMeetingBrief: Equatable {
    var participants: [String] = []
    var lines: [String] = []
    var promises: [String] = []
    var recentTopics: [String] = []

    var isEmpty: Bool {
        lines.isEmpty && promises.isEmpty && recentTopics.isEmpty
    }
}

enum PreMeetingBriefRules {
    static let autoHideAfterSeconds = 120
    static let maxLines = 4
    static let maxPromises = 3
    static let maxRecentTopics = 3
    static let maxDisplayItems = 5
    static let maxLineLength = 110
    static let maxPromiseLength = 100

    enum BriefVisibility: Equatable {
        case hidden
        case collapsed
        case expanded
    }

    struct DisplayItem: Equatable {
        enum Kind: Equatable { case context, promise, topic }
        let kind: Kind
        let text: String
        let isPrimary: Bool
    }

    /// Shows the expanded brief only for calls, when non-empty and not dismissed, and either before 120 s
    /// with no live outline yet or when the user manually expanded it.
    static func shouldShowBrief(
        isCall: Bool,
        secondsRecorded: Int,
        hasLiveOutline: Bool,
        dismissed: Bool,
        brief: PreMeetingBrief,
        manuallyExpanded: Bool = false
    ) -> Bool {
        guard isCall, !brief.isEmpty, !dismissed else { return false }
        if manuallyExpanded { return true }
        return !hasLiveOutline && secondsRecorded < autoHideAfterSeconds
    }

    /// Full UI visibility state: `.hidden` when inapplicable or dismissed, `.expanded` when shown,
    /// `.collapsed` when auto-hidden or collapsed by the user (rendering a compact "Show brief" pill).
    static func visibility(
        isCall: Bool,
        secondsRecorded: Int,
        hasLiveOutline: Bool,
        dismissed: Bool,
        brief: PreMeetingBrief,
        userOverride: Bool? = nil
    ) -> BriefVisibility {
        guard isCall, !brief.isEmpty, !dismissed else { return .hidden }
        if userOverride == false { return .collapsed }
        if shouldShowBrief(
            isCall: isCall,
            secondsRecorded: secondsRecorded,
            hasLiveOutline: hasLiveOutline,
            dismissed: dismissed,
            brief: brief,
            manuallyExpanded: userOverride == true
        ) {
            return .expanded
        }
        return .collapsed
    }

    /// Query string sent to POST /prep from the calendar event title and participants.
    static func queryText(eventTitle: String, participants: [String]) -> String {
        let parts = ([eventTitle] + participants).map(clean).filter { !$0.isEmpty }
        return parts.joined(separator: " ")
    }

    /// Crisp card header: "Before this call" or "Before this call · Mila, Sava".
    static func headerTitle(for brief: PreMeetingBrief) -> String {
        guard !brief.participants.isEmpty else { return "Before this call" }
        if brief.participants.count <= 2 {
            return "Before this call · " + brief.participants.joined(separator: ", ")
        }
        return "Before this call · " + brief.participants.prefix(2).joined(separator: ", ") + " +\(brief.participants.count - 2)"
    }

    /// Parses POST /prep response and GET /promises rows into a compact, scannable brief.
    static func parsePrepResponse(
        _ json: [String: Any]?,
        promises: [[String: Any]]?,
        participants: [String]
    ) -> PreMeetingBrief {
        let prepPeople = (json?["people"] as? [String]) ?? []
        let mergedParticipants = unique(participants + prepPeople)

        let rawLines = (json?["lines"] as? [String]) ?? []
        var lines: [String] = []
        var seenLines = Set<String>()
        var topics: [String] = []
        var seenTopics = Set<String>()

        func addTopic(_ raw: String) {
            guard topics.count < maxRecentTopics else { return }
            let normalized = clean(raw)
            guard !normalized.isEmpty else { return }
            let capped = cap(normalized, limit: maxLineLength)
            if seenTopics.insert(fold(capped)).inserted {
                topics.append(capped)
            }
        }

        for raw in rawLines {
            let normalized = clean(raw)
            guard !normalized.isEmpty else { continue }
            if let datedTopic = extractDatedTopic(normalized) {
                addTopic(datedTopic)
            }
            if lines.count < maxLines {
                let capped = cap(normalized, limit: maxLineLength)
                if seenLines.insert(fold(capped)).inserted {
                    lines.append(capped)
                }
            }
        }

        for key in ["recentTopics", "topics"] {
            for raw in (json?[key] as? [String]) ?? [] {
                addTopic(raw)
            }
        }

        let matchedPromises = filterPromises(
            promises ?? [],
            participants: mergedParticipants,
            existingLines: lines
        )

        return PreMeetingBrief(
            participants: mergedParticipants,
            lines: lines,
            promises: matchedPromises,
            recentTopics: topics
        )
    }

    /// Balanced bullet list for the 5-second card (at most 5 tight lines, never starving open promises).
    static func displayItems(for brief: PreMeetingBrief) -> [DisplayItem] {
        var out: [DisplayItem] = []
        var seen = Set<String>()

        let lineBudget: Int
        if brief.promises.isEmpty {
            lineBudget = min(maxLines, maxDisplayItems)
        } else {
            let reservePromises = min(brief.promises.count, 2)
            lineBudget = min(maxLines, max(1, maxDisplayItems - reservePromises))
        }

        for (index, line) in brief.lines.prefix(lineBudget).enumerated() {
            guard out.count < maxDisplayItems else { break }
            if seen.insert(fold(line)).inserted {
                out.append(DisplayItem(kind: .context, text: line, isPrimary: index == 0))
            }
        }

        for promise in brief.promises {
            guard out.count < maxDisplayItems else { break }
            if seen.insert(fold(promise)).inserted {
                out.append(DisplayItem(kind: .promise, text: promise, isPrimary: true))
            }
        }

        // Fill remaining slots with additional lines or topics if space remains.
        if out.count < maxDisplayItems, brief.lines.count > lineBudget {
            for line in brief.lines.dropFirst(lineBudget) {
                guard out.count < maxDisplayItems else { break }
                if seen.insert(fold(line)).inserted {
                    out.append(DisplayItem(kind: .context, text: line, isPrimary: false))
                }
            }
        }

        if out.count < maxDisplayItems {
            for topic in brief.recentTopics {
                guard out.count < maxDisplayItems else { break }
                let foldedTopic = fold(topic)
                let alreadyCovered = seen.contains { $0 == foldedTopic || $0.contains(foldedTopic) }
                if !alreadyCovered && seen.insert(foldedTopic).inserted {
                    out.append(DisplayItem(kind: .topic, text: topic, isPrimary: out.isEmpty))
                }
            }
        }

        return out
    }

    // MARK: helpers

    private static func filterPromises(
        _ rows: [[String: Any]],
        participants: [String],
        existingLines: [String]
    ) -> [String] {
        guard !participants.isEmpty, !rows.isEmpty else { return [] }
        let expressions = participantMatchers(participants)
        guard !expressions.isEmpty else { return [] }
        let foldedLines = existingLines.map(fold)

        func matchesParticipant(_ texts: [String]) -> Bool {
            texts.contains { text in
                let folded = fold(text)
                guard !folded.isEmpty else { return false }
                let range = NSRange(folded.startIndex..., in: folded)
                return expressions.contains { $0.firstMatch(in: folded, range: range) != nil }
            }
        }

        var overdueRows: [[String: Any]] = []
        var normalRows: [[String: Any]] = []
        for row in rows {
            if (row["overdue"] as? Bool) == true { overdueRows.append(row) } else { normalRows.append(row) }
        }

        var out: [String] = []
        var seenIDs = Set<String>()
        var seenTexts = Set<String>()

        for row in overdueRows + normalRows {
            guard out.count < maxPromises else { break }
            guard isOpenPromise(row) else { continue }
            let id = clean(row["id"] as? String ?? "")
            if !id.isEmpty, !seenIDs.insert(id).inserted { continue }

            let who = clean(row["who"] as? String ?? "")
            let person = clean(row["person"] as? String ?? "")
            let what = clean(row["what"] as? String ?? "")
            let phrase = clean(row["phrase"] as? String ?? "")
            let body = what.isEmpty ? phrase : what
            guard !body.isEmpty else { continue }

            guard matchesParticipant([who, person, what, phrase]) else { continue }

            let foldedBody = fold(body)
            if foldedBody.count >= 6, foldedLines.contains(where: { $0.contains(foldedBody) }) {
                continue
            }

            let formatted: String
            let label = who.isEmpty ? person : who
            if !label.isEmpty, let first = label.split(whereSeparator: \.isWhitespace).first,
               !foldedBody.contains(fold(String(first))) {
                formatted = "\(body) · \(label)"
            } else {
                formatted = body
            }

            let capped = cap(formatted, limit: maxPromiseLength)
            if seenTexts.insert(fold(capped)).inserted {
                out.append(capped)
            }
        }

        return out
    }

    private static func isOpenPromise(_ row: [String: Any]) -> Bool {
        if let flag = row["isDone"] as? Bool, flag { return false }
        if let doneBool = row["done"] as? Bool, doneBool { return false }
        if let doneNum = row["done"] as? NSNumber, doneNum.doubleValue != 0 { return false }
        let status = clean(row["status"] as? String ?? "").lowercased()
        if ["done", "closed", "dropped", "completed"].contains(status) { return false }
        return true
    }

    private static func participantMatchers(_ participants: [String]) -> [NSRegularExpression] {
        var tokens: [String] = []
        var seen = Set<String>()
        for raw in participants {
            let full = fold(raw)
            if !full.isEmpty, seen.insert(full).inserted {
                tokens.append(full)
            }
            if let first = full.split(whereSeparator: \.isWhitespace).first.map(String.init),
               first.count >= 3, seen.insert(first).inserted {
                tokens.append(first)
            }
        }
        return tokens.compactMap { token in
            let word = token.contains("@") ? #"[\p{L}\p{M}\p{N}_@.+-]"# : #"[\p{L}\p{M}\p{N}_]"#
            return try? NSRegularExpression(
                pattern: "(?<!" + word + ")" + NSRegularExpression.escapedPattern(for: token) + "(?!" + word + ")"
            )
        }
    }

    private static func extractDatedTopic(_ line: String) -> String? {
        guard let rx = try? NSRegularExpression(pattern: #"^\d{4}-\d{2}-\d{2}\s*:\s*(.+)$"#) else { return nil }
        let range = NSRange(line.startIndex..., in: line)
        guard let match = rx.firstMatch(in: line, range: range),
              match.numberOfRanges > 1,
              let topicRange = Range(match.range(at: 1), in: line) else { return nil }
        let topic = clean(String(line[topicRange]))
        return topic.isEmpty ? nil : topic
    }

    static func clean(_ value: String) -> String {
        value.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    static func fold(_ value: String) -> String {
        value.replacingOccurrences(of: "’", with: "'").replacingOccurrences(of: "ʼ", with: "'")
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .lowercased()
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }

    static func cap(_ value: String, limit: Int) -> String {
        guard limit > 1, value.count > limit else { return value }
        let prefix = String(value.prefix(limit - 1))
        if let lastSpace = prefix.lastIndex(of: " "), prefix.distance(from: prefix.startIndex, to: lastSpace) > limit / 2 {
            return String(prefix[..<lastSpace]).trimmingCharacters(in: .whitespacesAndNewlines) + "…"
        }
        return prefix.trimmingCharacters(in: .whitespacesAndNewlines) + "…"
    }

    private static func unique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for raw in values {
            let trimmed = clean(raw)
            guard !trimmed.isEmpty else { continue }
            if seen.insert(fold(trimmed)).inserted {
                out.append(trimmed)
            }
        }
        return out
    }
}

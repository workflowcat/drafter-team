// Local topic suggestions and reversible tidy candidates. No disk, UI, or network access.
import Foundation

struct TopicInput {
    let id: String
    let kind: String
    let text: String
    let app: String
    let at: Double
    let tags: [TapeTag]
    let pinned: Bool
}

struct TopicCluster: Identifiable, Equatable {
    let id: String
    let title: String
    let subtitle: String
    let itemIds: [String]
    let kinds: [String: Int]
    let latestAt: Double
    let earliestAt: Double
    let primaryTag: TapeTag?
}

enum TidyReason: String, CaseIterable {
    case duplicate, fragment, shortClip
    var title: String {
        switch self {
        case .duplicate: return "Duplicates"
        case .fragment: return "Short fragments"
        case .shortClip: return "Trivial clips"
        }
    }
}

struct TidyCandidate: Identifiable, Equatable {
    let id: String
    let reason: TidyReason
    let preview: String
    let at: Double
    let kind: String
    let duplicateOf: String?
}

enum TopicClusterRules {
    private static let entities: Set<String> = ["person", "project", "tool", "site"]
    private static let bursts: Set<String> = ["typed", "spoken", "draft"]
    private static let stop: Set<String> = Set((
        "a an and are as at be been but by can could did do does for from had has have he her here him his how i if in into is it its just like me my no not of on or our out she so that the their them then there these they this those to too up us was we were what when where which who will with would you your yes okay ok thanks please need want today tomorrow " +
        "а але без би був була були бути в вам вас ваш вже ви від він вона вони все для до є за з зі і із й їх її як який яка які коли ми мені мене на нам нас не ні ну о ось по про при та так те ти то того тому тут у це цей ця ці чи що щоб я ще потрібно треба будь ласка " +
        "и или но это как уже для что чтобы мне меня мы вы он она они оно был была быть его если нет да вот же ещё")
        .split(separator: " ").map(String.init))

    private struct Words {
        var keys: [String] = []
        var labels: [String: String] = [:]
    }

    /// Bounded scan: at most 1,536 scalars and 24 distinct significant words per item.
    /// Small suffix rules cover common English plurals and Ukrainian noun/adjective inflections.
    private static func words(_ text: String, stems: inout [String: String]) -> Words {
        var out = Words(), word = ""
        func take() {
            defer { word.removeAll(keepingCapacity: true) }
            guard word.count >= 3, !stop.contains(word) else { return }
            let key: String
            if let cached = stems[word] { key = cached }
            else { key = stem(word); stems[word] = key }
            if out.labels[key] == nil { out.keys.append(key); out.labels[key] = word }
        }
        for s in text.lowercased().unicodeScalars.prefix(1536) {
            if CharacterSet.letters.contains(s) { word.unicodeScalars.append(s) }
            else { take(); if out.keys.count >= 24 { break } }
        }
        if out.keys.count < 24 { take() }
        return out
    }

    private static func stem(_ word: String) -> String {
        let suffixes = word.utf8.first.map { $0 < 128 } == true
            ? ["ing", "ies", "ed", "es", "s"]
            : ["ання", "ення", "ями", "ами", "ого", "ому", "ими", "ією", "ів", "ий", "ій", "ою", "ах", "ях", "ом", "ам", "ям", "ої", "а", "у", "і", "и", "е", "я", "ю"]
        let length = word.count
        for s in suffixes where word.hasSuffix(s) && length - s.count >= 4 {
            return String(word.dropLast(s.count)) + (s == "ies" ? "y" : "")
        }
        return word
    }

    /// Newest first with stable ties; sorting costs N log N, matching is bounded per input.
    /// Tag links are not time-limited. Keyword links use maxGapHours; typing/voice bursts use 20 minutes.
    /// `untaggedBursts`: a burst joins two rows only when neither carries a person or project (the stream's topics,
    /// review 25 November 2026: a burst chained a tagged topic to unrelated rows typed next to it).
    /// `commonShare`: a word on more than that share of the rows (and on more than 8) links nothing, and a burst needs a
    /// shared word (the stream's topics, 25 November 2026: on the user's rows, bursts and their everyday words chained 1,312 of
    /// 1,484 rows into one topic).
    static func cluster(_ items: [TopicInput], maxGapHours: Double = 36, untaggedBursts: Bool = false, commonShare: Double? = nil) -> [TopicCluster] {
        let rows = items.sorted { $0.at != $1.at ? $0.at > $1.at : $0.id < $1.id }
        guard !rows.isEmpty else { return [] }
        var parent = Array(rows.indices)
        func root(_ i: Int) -> Int {
            var p = i
            while parent[p] != p { parent[p] = parent[parent[p]]; p = parent[p] }
            return p
        }
        func join(_ a: Int, _ b: Int) {
            let x = root(a), y = root(b)
            if x != y { parent[max(x, y)] = min(x, y) }
        }
        var lexicon: [Words] = [], tagLast: [String: Int] = [:], appLast: [String: Int] = [:]
        // Four recent witnesses per word prevent popular words from causing quadratic comparisons.
        var tokenLast: [String: [Int]] = [:]
        let gap = max(0, maxGapHours) * 3600
        lexicon.reserveCapacity(rows.count)
        var stems: [String: String] = [:]
        for row in rows { lexicon.append(words(row.text, stems: &stems)) }
        var common = Set<String>()
        if let share = commonShare {
            var df: [String: Int] = [:]
            for w in lexicon { for k in w.keys { df[k, default: 0] += 1 } }
            let limit = max(8, Int(Double(rows.count) * share))
            common = Set(df.filter { $0.value > limit }.map(\.key))
        }
        for (i, row) in rows.enumerated() {
            let w = lexicon[i]
            let linkKeys = common.isEmpty ? w.keys : w.keys.filter { !common.contains($0) }
            for tag in row.tags where entities.contains(tag.kind) && !tag.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let key = tag.kind + ":" + tag.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                if let j = tagLast[key] { join(i, j) }
                tagLast[key] = i
            }
            var shared: [Int: Int] = [:]
            for key in linkKeys {
                for j in tokenLast[key] ?? [] where rows[j].at - row.at <= gap { shared[j, default: 0] += 1 }
            }
            for (j, n) in shared {
                let union = linkKeys.count + lexicon[j].keys.count - n
                if n >= 2 || (union > 0 && Double(n) / Double(union) >= 0.25) { join(i, j) }
            }
            for key in linkKeys {
                var bucket = tokenLast[key] ?? []
                if bucket.count == 4 { bucket.removeFirst() }
                bucket.append(i); tokenLast[key] = bucket
            }
            if bursts.contains(row.kind), !row.app.isEmpty {
                func tagged(_ r: TopicInput) -> Bool { r.tags.contains { entities.contains($0.kind) } }
                if let j = appLast[row.app], rows[j].at - row.at <= 1200, !untaggedBursts || (!tagged(row) && !tagged(rows[j])),
                   commonShare == nil || !Set(linkKeys).isDisjoint(with: lexicon[j].keys.filter { !common.contains($0) }) { join(i, j) }
                appLast[row.app] = i
            }
        }
        var members: [Int: [Int]] = [:]
        for i in rows.indices { members[root(i), default: []].append(i) }
        return members.values.map { indices in
            var kinds: [String: Int] = [:], tags: [TapeTag: Int] = [:], counts: [String: Int] = [:], labels: [String: String] = [:]
            for i in indices {
                kinds[rows[i].kind == "draft" ? "typed" : rows[i].kind, default: 0] += 1
                for tag in Set(rows[i].tags) where entities.contains(tag.kind) && !cleanTitle(tag.name).isEmpty { tags[tag, default: 0] += 1 }
                for key in lexicon[i].keys {
                    counts[key, default: 0] += 1
                    if labels[key] == nil { labels[key] = lexicon[i].labels[key] }
                }
            }
            let tag = tags.keys.sorted {
                if tags[$0] != tags[$1] { return tags[$0]! > tags[$1]! }
                let a = $0.kind + ":" + $0.name, b = $1.kind + ":" + $1.name
                return a < b
            }.first
            let top = counts.keys.sorted {
                counts[$0] != counts[$1] ? counts[$0]! > counts[$1]! : $0 < $1
            }.prefix(3).compactMap { labels[$0].map(capitalized) }.joined(separator: " · ")
            let title = tag.map { cleanTitle($0.name) } ?? (top.isEmpty ? "Standalone" : top)
            let subtitle = [("typed", "draft", "drafts"), ("spoken", "voice note", "voice notes"), ("copied", "clip", "clips"), ("call", "recording", "recordings")]
                .compactMap { key, one, many -> String? in
                    guard let n = kinds[key] else { return nil }; return "\(n) \(n == 1 ? one : many)"
                }.joined(separator: " · ")
            return TopicCluster(id: "topic:" + indices.map { rows[$0].id }.min()!, title: title, subtitle: subtitle,
                                itemIds: indices.map { rows[$0].id }, kinds: kinds,
                                latestAt: rows[indices[0]].at, earliestAt: rows[indices.last!].at, primaryTag: tag)
        }.sorted { $0.latestAt != $1.latestAt ? $0.latestAt > $1.latestAt : $0.id < $1.id }
    }

    private static func capitalized(_ s: String) -> String {
        if ["kyc", "api", "ui", "ux", "sql", "url"].contains(s.lowercased()) { return s.uppercased() }
        return s.prefix(1).uppercased() + s.dropFirst()
    }
    private static func cleanTitle(_ text: String) -> String {
        let line = text.split(whereSeparator: \.isNewline).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard line.contains(where: \.isLetter) else { return "" }
        return capitalized(String(line.prefix(80)))
    }
    private static func normalized(_ s: String) -> String {
        s.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
    private static func prefix(_ short: String, of long: String) -> Bool {
        guard !short.isEmpty, short.count < long.count, long.hasPrefix(short) else { return false }
        let next = long[long.index(long.startIndex, offsetBy: short.count)]
        return !next.isLetter && !next.isNumber
    }
    /// Conservative near-identity: case/spacing and trailing sentence punctuation only.
    /// Numbers, negation, URLs and code must not become approximate duplicates.
    private static func comparable(_ s: String) -> String {
        normalized(s).trimmingCharacters(in: CharacterSet(charactersIn: ".!? "))
    }

    /// Keep the fullest burst at its own time; leave distinct ideas and paragraphs intact.
    static func mergeCleanNote(_ texts: [(at: Double, kind: String, text: String)], title: String) -> String {
        let ordered = texts.enumerated().sorted { $0.element.at != $1.element.at ? $0.element.at < $1.element.at : $0.offset < $1.offset }
        var kept: [(text: String, key: String)] = []
        for part in ordered {
            let text = part.element.text.trimmingCharacters(in: .whitespacesAndNewlines), key = comparable(part.element.text)
            guard !text.isEmpty else { continue }
            if !key.isEmpty, kept.contains(where: { $0.key == key || prefix(key, of: $0.key) }) { continue }
            let contained = kept.indices.filter { !key.isEmpty && prefix(kept[$0].key, of: key) }
            for i in contained.reversed() { kept.remove(at: i) }
            kept.append((text, key))
        }
        let heading = cleanTitle(title)
        return "# " + (heading.isEmpty ? "Notes" : heading) + "\n\n" + kept.map(\.text).joined(separator: "\n\n")
    }

    /// Protect URLs, paths, identifiers and short code from the tiny-fragment heuristics.
    private static func isReferenceOrCode(_ s: String) -> Bool {
        if s.contains(where: { "/\\@#_{}[]<>=$`;:|".contains($0) }) { return true }
        if s.contains("."), !s.contains(" ") { return true }
        if s.contains(where: \.isNumber) || s.contains("(") || s.contains(")") { return true }
        let first = s.split(whereSeparator: \.isWhitespace).first?.lowercased() ?? ""
        return ["let", "var", "func", "return", "import", "git", "cd", "ls", "pwd", "sudo", "echo", "npm", "print", "true", "false", "nil"].contains(first)
    }

    static func findTidyCandidates(_ items: [TopicInput]) -> [TidyCandidate] {
        let rows = items.sorted { $0.at != $1.at ? $0.at > $1.at : $0.id < $1.id }
        let keys = rows.map { comparable($0.text) }
        // Buckets by the first word, capped at 32 neighbours. Only same-kind/app repetitions qualify.
        var buckets: [String: [Int]] = [:], duplicates: [Int: Int] = [:]
        for i in rows.indices where rows[i].kind != "call" {
            guard !keys[i].isEmpty else { continue }
            let key = rows[i].kind + "|" + rows[i].app + "|" + String(keys[i].split(separator: " ").first ?? "")
            for j in buckets[key] ?? [] where abs(rows[j].at - rows[i].at) <= 600 && duplicates[j] == nil {
                let equal = keys[i] == keys[j], iShort = prefix(keys[i], of: keys[j]), jShort = prefix(keys[j], of: keys[i])
                guard equal || iShort || jShort else { continue }
                if !rows[i].pinned && (iShort || equal) {
                    duplicates[i] = j; break
                }
                if !rows[j].pinned && (jShort || equal && rows[i].pinned) { duplicates[j] = i }
            }
            var b = buckets[key] ?? []
            if b.count == 32 { b.removeFirst() }; b.append(i); buckets[key] = b
        }
        var survivors = Set<Int>()
        for var j in duplicates.values {
            while let next = duplicates[j] { j = next }
            survivors.insert(j)
        }
        return rows.indices.compactMap { i in
            let row = rows[i]
            guard !row.pinned, row.kind != "call", !survivors.contains(i) else { return nil }
            let text = row.text.trimmingCharacters(in: .whitespacesAndNewlines)
            var reason: TidyReason?, target: String?
            if var j = duplicates[i] {
                while let next = duplicates[j] { j = next }
                reason = .duplicate; target = rows[j].id
            } else if !isReferenceOrCode(text) {
                let count = text.split(whereSeparator: \.isWhitespace).count
                if row.kind == "typed", count < 3, text.count < 16 { reason = .fragment }
                else if row.kind == "copied", count <= 1, text.count < 24 { reason = .shortClip }
            }
            guard let reason else { return nil }
            return TidyCandidate(id: row.id, reason: reason, preview: String(text.prefix(180)), at: row.at, kind: row.kind, duplicateOf: target)
        }
    }
}

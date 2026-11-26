// The Links & Files hub's value types and pure rules. No disk, network or UI access.
import Foundation

enum LinkSource: String, CaseIterable, Codable {
    case copied, mentioned

    var label: String {
        switch self {
        case .copied: return "Copied"
        case .mentioned: return "Mentioned"
        }
    }

    var glyph: String {
        switch self {
        case .copied: return "link"
        case .mentioned: return "globe"
        }
    }
}

struct LinkRowInput {
    let id: String
    let kind: String
    let clip: String
    let text: String
    let title: String
    let app: String
    let when: Double
    let tags: [String]
    let filePath: String
}

struct LinkItem: Equatable, Identifiable {
    let id: String
    let url: String
    let normalizedURL: String
    let host: String
    let title: String
    let source: LinkSource
    let origin: String
    let when: Double
    let mentions: Int
    let tags: [String]
    let journalId: String?
    let filePath: String?
}

enum LinksRules {
    private static let tracking: Set<String> = ["fbclid", "gclid", "igshid", "mc_cid", "mc_eid"]
    private static let urlPattern = try! NSRegularExpression(pattern: #"https?://[^\s<>\"'`“”‘’]+"#, options: .caseInsensitive)

    /// Keep balanced brackets in paths, but remove punctuation from the surrounding sentence or Markdown.
    private static func cleanURL(_ raw: String) -> String {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let pairs: [Character: Character] = [")": "(", "]": "[", "}": "{"]
        while let last = value.last {
            if ".,;:!?<>\"'`“”‘’".contains(last) { value.removeLast(); continue }
            if let open = pairs[last], value.filter({ $0 == last }).count > value.filter({ $0 == open }).count {
                value.removeLast(); continue
            }
            break
        }
        return value
    }

    /// An invalid or non-web address has no normalized URL. Preserve query order and percent encoding.
    static func normalize(_ raw: String) -> String {
        let value = cleanURL(raw)
        guard !value.contains(where: \.isWhitespace),
              var parts = URLComponents(string: value),
              let scheme = parts.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = parts.host, !host.isEmpty, parts.url != nil else { return "" }
        parts.scheme = scheme
        parts.host = host.lowercased()
        if parts.path == "/" { parts.path = "" }
        if let query = parts.percentEncodedQuery {
            let kept = query.split(separator: "&", omittingEmptySubsequences: false).filter { part in
                let name = String(part.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)[0])
                let key = (name.removingPercentEncoding ?? name).lowercased()
                return !key.hasPrefix("utm_") && !tracking.contains(key)
            }.joined(separator: "&")
            parts.percentEncodedQuery = kept.isEmpty ? nil : kept
        }
        return parts.string ?? ""
    }

    static func host(of url: String) -> String {
        guard let host = URLComponents(string: normalize(url))?.host?.lowercased() else { return "" }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    /// Return occurrences in reading order. Extraction below counts one mention per journal row.
    static func extractURLs(from text: String) -> [String] {
        let source = text as NSString
        return urlPattern.matches(in: text, range: NSRange(location: 0, length: source.length)).compactMap {
            let value = cleanURL(source.substring(with: $0.range))
            return normalize(value).isEmpty ? nil : value
        }
    }

    static func extract(from rows: [LinkRowInput]) -> [LinkItem] {
        let textKinds: Set<String> = ["draft", "drafts", "typed", "voice", "spoken", "said", "text", "call", "calls", "copied"]
        var items: [LinkItem] = []
        var seen = Set<String>()
        for row in rows {
            let kind = row.kind.lowercased(), clip = row.clip.lowercased()
            guard clip == "link" || clip == "file" || textKinds.contains(kind) else { continue }
            let source: LinkSource = clip == "link" || clip == "file" ? .copied : .mentioned
            let urls = extractURLs(from: row.text)
            for url in urls {
                let key = normalize(url)
                // A URL repeated within one entry is still one journal mention.
                guard seen.insert(row.id + "\u{0}" + key).inserted else { continue }
                items.append(make(url: key, title: row.title, source: source, origin: row.app,
                                  when: row.when, tags: row.tags, journalId: row.id, file: row.filePath))
            }
            if urls.isEmpty, clip == "file", !trim(row.filePath).isEmpty,
               seen.insert(row.id + "\u{0}file:" + trim(row.filePath)).inserted {
                items.append(make(url: "", title: row.title, source: .copied, origin: row.app,
                                  when: row.when, tags: row.tags, journalId: row.id, file: row.filePath))
            }
        }
        return merge(local: items, remote: [])
    }

    /// Key for deduplicating hub items: URLs dedupe by normalized URL, local absolute file paths dedupe by path,
    /// and bare file names keep source/origin/title so two different "invoice.pdf" rows do not collapse.
    private static func itemKey(normalizedURL: String, file: String, source: LinkSource, origin: String, title: String) -> String {
        if !normalizedURL.isEmpty { return "url:" + normalizedURL }
        if file.hasPrefix("/") { return "file:" + file }
        return "att:\(source.rawValue):\(fold(trim(origin))):\(fold(trim(title))):\(fold(file))"
    }

    /// The newest occurrence supplies provenance. A useful title and a journal jump survive older occurrences.
    static func merge(local: [LinkItem], remote: [LinkItem]) -> [LinkItem] {
        var byKey: [String: LinkItem] = [:]
        for item in local + remote {
            let normalized = normalize(item.url.isEmpty ? item.normalizedURL : item.url)
            let file = trim(item.filePath ?? "")
            guard !normalized.isEmpty || !file.isEmpty else { continue }
            let cleanTitle = title(item.title, fallback: normalized.isEmpty ? (file as NSString).lastPathComponent : normalized)
            let key = itemKey(normalizedURL: normalized, file: file, source: item.source, origin: item.origin, title: cleanTitle)
            let clean = LinkItem(id: key, url: normalized, normalizedURL: normalized, host: host(of: normalized),
                                 title: cleanTitle,
                                 source: item.source, origin: trim(item.origin), when: stamp(item.when), mentions: max(1, item.mentions),
                                 tags: unique(item.tags), journalId: nonempty(item.journalId), filePath: nonempty(file))
            guard let old = byKey[key] else { byKey[key] = clean; continue }
            let newest = clean.when > old.when ? clean : old
            let older = clean.when > old.when ? old : clean
            let best = titleScore(older.title) > titleScore(newest.title) ? older.title : newest.title
            byKey[key] = LinkItem(id: key, url: newest.url, normalizedURL: normalized, host: newest.host,
                                 title: best, source: newest.source, origin: newest.origin.isEmpty ? older.origin : newest.origin,
                                 when: newest.when, mentions: old.mentions + clean.mentions, tags: unique(newest.tags + older.tags),
                                 journalId: newest.journalId ?? older.journalId, filePath: newest.filePath ?? older.filePath)
        }
        return byKey.values.sorted { $0.when == $1.when ? $0.id < $1.id : $0.when > $1.when }
    }

    static func filter(_ items: [LinkItem], query: String, source: LinkSource?, host: String?) -> [LinkItem] {
        let words = fold(query).split(whereSeparator: \.isWhitespace).map(String.init)
        let domain = host.map { value -> String in
            let value = trim(value).lowercased()
            let parsed = self.host(of: value)
            return parsed.isEmpty ? (value.hasPrefix("www.") ? String(value.dropFirst(4)) : value) : parsed
        } ?? ""
        return items.filter { item in
            guard source == nil || item.source == source, domain.isEmpty || item.host == domain else { return false }
            let hay = fold(([item.title, item.url, item.host, item.origin, item.source.label, item.filePath ?? ""] + item.tags).joined(separator: " "))
            return words.allSatisfy { hay.contains($0) }
        }
    }

    /// Counts represent hub items, not the number of times each item was mentioned.
    static func topHosts(_ items: [LinkItem], limit: Int = 10) -> [(host: String, count: Int)] {
        guard limit > 0 else { return [] }
        var counts: [String: Int] = [:]
        for item in items where !item.host.isEmpty { counts[item.host, default: 0] += 1 }
        var ranked: [(host: String, count: Int)] = counts.map { (host: $0.key, count: $0.value) }
        ranked.sort { a, b in a.count == b.count ? a.host < b.host : a.count > b.count }
        return Array(ranked.prefix(limit))
    }

    static func sourceCounts(_ items: [LinkItem]) -> [LinkSource: Int] {
        var counts = Dictionary(uniqueKeysWithValues: LinkSource.allCases.map { ($0, 0) })
        for item in items { counts[item.source, default: 0] += 1 }
        return counts
    }

    static func markdown(_ item: LinkItem) -> String {
        guard !item.url.isEmpty else { return item.filePath ?? item.title }
        let label = trim(item.title)
        guard !label.isEmpty, label != item.url, normalize(label) != normalize(item.url) else { return item.url }
        let escaped = label.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "[", with: "\\[").replacingOccurrences(of: "]", with: "\\]")
            .components(separatedBy: .newlines).joined(separator: " ")
        let target = item.url.replacingOccurrences(of: "(", with: "%28").replacingOccurrences(of: ")", with: "%29")
        return "[\(escaped)](\(target))"
    }

    /// Elapsed units, independent of the device's locale and daylight-saving boundary.
    static func relativeTime(_ when: Double, now: Double) -> String {
        guard when.isFinite, now.isFinite, when > 0 else { return "Unknown time" }
        let delta = now - when, seconds = abs(delta)
        guard seconds.isFinite else { return "Unknown time" }
        if seconds < 60 { return "Just now" }
        let units: [(Double, String)] = [(365 * 86400, "y"), (30 * 86400, "mo"), (7 * 86400, "w"), (86400, "d"), (3600, "h"), (60, "m")]
        let unit = units.first { seconds >= $0.0 }!
        let value = String(format: "%.0f", floor(seconds / unit.0)) + unit.1
        return delta < 0 ? "In " + value : value + " ago"
    }

    private static func make(url: String, title raw: String, source: LinkSource, origin: String, when: Double,
                             tags: [String], journalId: String?, file: String) -> LinkItem {
        let file = trim(file), fallback = url.isEmpty ? (file as NSString).lastPathComponent : url
        let cleanTitle = title(raw, fallback: fallback)
        let id = itemKey(normalizedURL: url, file: file, source: source, origin: origin, title: cleanTitle)
        return LinkItem(id: id, url: url, normalizedURL: url, host: host(of: url),
                        title: cleanTitle, source: source, origin: origin, when: stamp(when),
                        mentions: 1, tags: unique(tags), journalId: nonempty(journalId), filePath: nonempty(file))
    }

    private static func title(_ raw: String, fallback: String) -> String {
        let value = raw.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return value.isEmpty || !normalize(value).isEmpty ? fallback : value
    }

    private static func titleScore(_ value: String) -> Int {
        // Descriptive words beat any URL. Among descriptions retain the more informative one.
        normalize(value).isEmpty && !value.isEmpty ? value.count : 0
    }

    private static func trim(_ value: String) -> String { value.trimmingCharacters(in: .whitespacesAndNewlines) }
    private static func nonempty(_ value: String?) -> String? { value.flatMap { trim($0).isEmpty ? nil : trim($0) } }
    private static func stamp(_ value: Double) -> Double { value.isFinite ? max(0, value) : 0 }
    private static func fold(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }
    private static func unique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.map(trim).filter { !$0.isEmpty && seen.insert(fold($0)).inserted }
    }
}

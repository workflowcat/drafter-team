// Topics and daily summaries in the stream (topics round, 24 November 2026; the user: "some kind of sorting by topic and
// grouping, easier to view" and "a daily summary rather than this infinite journal of stuff I will likely never go back
// to"). Built on TopicClusterRules (local: shared people and projects, shared words, bursts in one app); no model, no
// network, nothing stored. Pure (Foundation), tests/stream_group_rules.swift.
import Foundation

enum StreamGroupRules {
    /// The topics of a set of rows: clusters of two or more, biggest last-touched first; the rest are loose ends.
    static func topics(_ items: [TopicInput]) -> (topics: [TopicCluster], loose: [String]) {
        // First look at the user's real rows (25 November 2026): one company tag on most rows pulled 1,365 rows into one
        // "topic", and pairs of copies or screenshots made dozens of two-row topics. So a tag on more than a quarter
        // of the rows (and over 40 of them) is home, not a topic, and does not join rows; and a topic needs three rows,
        // or two sharing a person or project, with at least one the user typed, said or recorded.
        let all = TopicClusterRules.cluster(withoutHomeTags(items), untaggedBursts: true, commonShare: commonShare).filter { keeps($0, of: items.count) }.map(stableId)
        let at = Dictionary(items.map { ($0.id, $0.at) }, uniquingKeysWith: { a, _ in a })
        let text = Dictionary(items.map { ($0.id, $0.text) }, uniquingKeysWith: { a, _ in a })
        // merged by keywords, named by a line, then merged again where two got the same line
        let topics = merged(merged(all, at: at).map { named($0, text: text) }, at: at)
        let inTopic = Set(topics.flatMap(\.itemIds))
        let loose = items.sorted { $0.at > $1.at }.map(\.id).filter { !inTopic.contains($0) }
        return (topics, loose)
    }

    static let homeShare = 0.25, homeMin = 40, commonShare = 0.08
    /// The rows with every tag that sits on too many of them taken off (it would join them all).
    static func withoutHomeTags(_ items: [TopicInput]) -> [TopicInput] {
        var n: [String: Int] = [:]
        for it in items { for k in Set(it.tags.map { $0.kind + ":" + $0.name.lowercased() }) { n[k, default: 0] += 1 } }
        let limit = Swift.max(homeMin, Int(Double(items.count) * homeShare))
        let home = Set(n.filter { $0.value > limit }.map(\.key))
        guard !home.isEmpty else { return items }
        return items.map { it in
            TopicInput(id: it.id, kind: it.kind, text: it.text, app: it.app, at: it.at,
                       tags: it.tags.filter { !home.contains($0.kind + ":" + $0.name.lowercased()) }, pinned: it.pinned)
        }
    }
    /// A cluster worth showing as a topic.
    /// Never one that holds more than a quarter of the rows (over 40): that is a chain, not a topic.
    static func keeps(_ c: TopicCluster, of total: Int = 0) -> Bool {
        guard c.title != "Standalone" else { return false }
        guard c.itemIds.count <= Swift.max(homeMin, Int(Double(total) * homeShare)) || total == 0 else { return false }
        let own = (c.kinds["typed"] ?? 0) + (c.kinds["spoken"] ?? 0) + (c.kinds["call"] ?? 0) + (c.kinds["draft"] ?? 0)
        guard own > 0 else { return false }
        return c.itemIds.count >= 3 || (c.itemIds.count == 2 && c.primaryTag != nil)
    }

    /// A topic's id apart from its label (review 25 November 2026): a person's or project's topic is that tag, so it
    /// stays open, chosen and in place while rows come and go; an untagged one keeps its oldest row.
    static func stableId(_ c: TopicCluster) -> TopicCluster {
        guard let t = c.primaryTag else { return c }
        return TopicCluster(id: "tag:" + t.kind + ":" + t.name.lowercased(), title: c.title, subtitle: c.subtitle, itemIds: c.itemIds, kinds: c.kinds,
                            latestAt: c.latestAt, earliestAt: c.earliestAt, primaryTag: c.primaryTag)
    }
    static let mergeSpan = 60.0 * 86400
    /// The clusters split a topic where weeks pass between its rows. One person or project is one topic (the same tag,
    /// not the same word: a person and a project of one name stay two); untagged ones join by their line only within
    /// `mergeSpan` of each other (review 25 November 2026: a common line joined unrelated work). Rows newest first.
    static func merged(_ cs: [TopicCluster], at: [String: Double]) -> [TopicCluster] {
        var order: [String] = [], by: [String: [TopicCluster]] = [:]
        var open: [String: (key: String, oldest: Double)] = [:]   // per line: the group being filled, its oldest time
        for c in cs.sorted(by: { $0.latestAt != $1.latestAt ? $0.latestAt > $1.latestAt : $0.id < $1.id }) {
            let k: String
            if let t = c.primaryTag { k = "tag:" + t.kind + ":" + t.name.lowercased() }
            else {
                let base = "line:" + c.title.lowercased()
                if let o = open[base], o.oldest - c.latestAt <= mergeSpan { k = o.key; open[base] = (k, min(o.oldest, c.earliestAt)) }
                else { k = base + "#" + String(order.count); open[base] = (k, c.earliestAt) }
            }
            if by[k] == nil { order.append(k) }
            by[k, default: []].append(c)
        }
        return order.compactMap { k -> TopicCluster? in
            guard let g = by[k], let first = g.first else { return nil }
            if g.count == 1 { return first }
            var kinds: [String: Int] = [:]
            for c in g { for (kk, n) in c.kinds { kinds[kk, default: 0] += n } }
            let ids = g.flatMap(\.itemIds).sorted { (at[$0] ?? 0) > (at[$1] ?? 0) }
            let id = first.primaryTag != nil ? first.id : (g.map(\.id).min() ?? first.id)
            return TopicCluster(id: id, title: first.title, subtitle: subtitle(kinds), itemIds: ids, kinds: kinds,
                                latestAt: g.map(\.latestAt).max() ?? first.latestAt, earliestAt: g.map(\.earliestAt).min() ?? first.earliestAt,
                                primaryTag: first.primaryTag)
        }.sorted { $0.latestAt != $1.latestAt ? $0.latestAt > $1.latestAt : $0.id < $1.id }
    }
    /// A topic with no person or project tag is titled by its keywords ("Before · Friday · Map"), which reads badly;
    /// it is named instead by its most typical line: the row sharing most of those words, newest first among equals,
    /// cut to one short sentence.
    static func named(_ c: TopicCluster, text: [String: String]) -> TopicCluster {
        guard c.primaryTag == nil else { return c }
        let keys = Set(c.title.lowercased().components(separatedBy: " · ").filter { !$0.isEmpty })
        guard !keys.isEmpty else { return c }
        func score(_ id: String) -> Int {
            let w = Set((text[id] ?? "").lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init))
            return keys.intersection(w).count
        }
        // a sentence beats a file path or a link; a path alone is named by its file
        // a picture's line ("Screen · ...") is the classifier's words, not the user's: it names a topic only as a last resort
        let pictureHeads = PictureLookRules.Kind.allCases.map { PictureLookRules.word($0) + " · " }
        func isPath(_ t: String) -> Bool {
            t.hasPrefix("/") || t.hasPrefix("~/") || t.contains("://") || pictureHeads.contains { t.hasPrefix($0) }
        }
        var best: (id: String, n: Int)? = nil
        for pass in [false, true] where best == nil {
            for id in c.itemIds where isPath(text[id] ?? "") == pass { let n = score(id); if n > (best?.n ?? 0) { best = (id, n) } }
        }
        guard let b = best, var t = text[b.id] else { return c }
        if isPath(t) { t = (t.trimmingCharacters(in: .whitespacesAndNewlines) as NSString).lastPathComponent }
        let line = StreamZoomRules.summary(t, max: 60)
        guard line.count >= 4 else { return c }
        return TopicCluster(id: c.id, title: line, subtitle: c.subtitle, itemIds: c.itemIds, kinds: c.kinds,
                            latestAt: c.latestAt, earliestAt: c.earliestAt, primaryTag: c.primaryTag)
    }

    /// "2 drafts · 1 voice note" (the same words TopicClusterRules uses).
    static func subtitle(_ kinds: [String: Int]) -> String {
        [("typed", "draft", "drafts"), ("spoken", "voice note", "voice notes"), ("copied", "clip", "clips"), ("call", "recording", "recordings")]
            .compactMap { key, one, many -> String? in guard let n = kinds[key] else { return nil }; return "\(n) \(n == 1 ? one : many)" }
            .joined(separator: " · ")
    }

    /// A day's summary line: its biggest topics (two rows or more), at most `max`, no two the same.
    static func dayTopics(_ items: [TopicInput], max: Int = 3) -> [String] {
        let t = topics(items).topics.sorted { $0.itemIds.count != $1.itemIds.count ? $0.itemIds.count > $1.itemIds.count : $0.latestAt > $1.latestAt }
        var seen = Set<String>(), out: [String] = []
        for c in t where seen.insert(c.title.lowercased()).inserted {
            out.append(c.title)
            if out.count >= max { break }
        }
        return out
    }

    /// Whether a day shows as one summary line: on with `foldPast`, never today or yesterday, never a day the user opened,
    /// never the day holding the chosen row (the arrows open the day they walk into), never in best-first order.
    static func folded(day: String, today: String, yesterday: String, foldPast: Bool, ranked: Bool,
                       opened: Set<String>, chosenDay: String?) -> Bool {
        guard foldPast, !ranked else { return false }
        return day != today && day != yesterday && !opened.contains(day) && day != chosenDay
    }

    /// The words after a folded day's name: "Lantern order form · Station map · and 12 more" or, with no topic,
    /// the first thing that day.
    static func dayLine(topics: [String], first: String, count: Int) -> String {
        guard !topics.isEmpty else { return first }
        return topics.joined(separator: " · ")
    }
}

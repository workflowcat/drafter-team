// Pure snapshots: no journal store, disk, network, or screen access.
import Foundation

struct TodayItem: Equatable {
    let id: String
    let kind: String
    let at: Double
}
struct TodayTopic: Identifiable, Equatable {
    let id: String
    let title: String
    let itemIDs: [String]
    let latestAt: Double
}
struct TodayPromise: Identifiable, Equatable {
    let id: String
    let what: String
    let person: String
    let app: String
    let due: Double?
    let overdue: Bool
}
struct TodayDigest: Equatable {
    let headline: String
    let calls: Int
    let voiceNotes: Int
    let drafts: Int
    let clips: Int
    let topics: [TodayTopic]
    let overdueCount: Int
    let promises: [TodayPromise]
}

enum TodayThreadRules {
    static func summarize(items: [TodayItem], topics: [TodayTopic], promises: [TodayPromise],
                          now: Date = Date(), calendar: Calendar = .current) -> TodayDigest {
        let start = calendar.startOfDay(for: now).timeIntervalSince1970
        let end = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now))!.timeIntervalSince1970
        var ids = Set<String>(), counts: [String: Int] = [:]
        for item in items where item.at.isFinite && item.at >= start && item.at < end {
            if ids.insert(item.id).inserted { counts[item.kind, default: 0] += 1 }
        }
        var topicIDs = Set<String>()
        let active = topics.filter { !$0.title.isEmpty && !ids.isDisjoint(with: $0.itemIDs) }
            .sorted { $0.latestAt != $1.latestAt ? $0.latestAt > $1.latestAt : $0.id < $1.id }
            .filter { topicIDs.insert($0.id).inserted }
        var promiseIDs = Set<String>()
        let ordered = promises.filter { !$0.id.isEmpty && promiseIDs.insert($0.id).inserted }.sorted {
            if $0.overdue != $1.overdue { return $0.overdue }
            let a = validDue($0.due) ?? .infinity, b = validDue($1.due) ?? .infinity
            return a != b ? a < b : $0.id < $1.id
        }
        let calls = counts["call", default: 0], voice = counts["spoken", default: 0]
        let drafts = counts["typed", default: 0] + counts["draft", default: 0], clips = counts["copied", default: 0]
        let headline = [(active.count, "topic"), (calls, "call"), (ordered.count, "open promise")]
            .filter { $0.0 > 0 }.map { "\($0.0) \($0.1)\($0.0 == 1 ? "" : "s")" }.joined(separator: " · ")
        return TodayDigest(headline: headline.isEmpty ? "Today's thread" : headline,
                           calls: calls, voiceNotes: voice, drafts: drafts, clips: clips,
                           topics: Array(active.prefix(3)), overdueCount: ordered.filter(\.overdue).count, promises: ordered)
    }
    private static func validDue(_ value: Double?) -> Double? {
        guard let value, value.isFinite, value > 0 else { return nil }; return value
    }
    static func parsePromises(_ rows: [[String: Any]], now: Double = Date().timeIntervalSince1970) -> [TodayPromise] {
        rows.compactMap { row in
            guard let id = row["id"] as? String, !id.isEmpty,
                  let what = row["what"] as? String else { return nil }
            if let done = row["done"], !(done is NSNull), (done as? NSNumber)?.doubleValue != 0 { return nil }
            let due = validDue((row["due"] as? NSNumber)?.doubleValue)
            return TodayPromise(id: id, what: what, person: row["who"] as? String ?? row["person"] as? String ?? "",
                                app: row["app"] as? String ?? "", due: due,
                                overdue: row["overdue"] as? Bool ?? (due.map { $0 < now } ?? false))
        }
    }
}

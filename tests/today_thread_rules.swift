// swiftc -parse-as-library app/TodayThreadRules.swift tests/today_thread_rules.swift -o app/build/today-thread-test && app/build/today-thread-test
import Foundation

@main struct TodayThreadChecks {
    static func check(_ ok: @autoclosure () -> Bool, _ message: String) {
        if !ok() { print("FAIL: " + message); exit(1) }
    }
    static func main() {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "America/New_York")!
        // DST boundary: this local day has 23 hours.
        let now = ISO8601DateFormatter().date(from: "2026-03-08T18:00:00Z")!
        let start = cal.startOfDay(for: now).timeIntervalSince1970
        let end = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: now))!.timeIntervalSince1970
        check(end - start == 23 * 3600, "fixture crosses DST")
        var items = [TodayItem(id: "call", kind: "call", at: start), TodayItem(id: "voice", kind: "spoken", at: start + 1),
            TodayItem(id: "draft", kind: "typed", at: start + 2), TodayItem(id: "clip", kind: "copied", at: end - 1),
            TodayItem(id: "old", kind: "call", at: start - 1), TodayItem(id: "tomorrow", kind: "call", at: end)]
        items.append(items[0])
        let topics = (1...4).map { TodayTopic(id: "t\($0)", title: "Station \($0)", itemIDs: ["draft"], latestAt: start + Double($0)) }
            + [TodayTopic(id: "old", title: "Earlier", itemIDs: ["old"], latestAt: start - 1)]
        let promises = [TodayPromise(id: "later", what: "Prepare draft", person: "Demo Guest", app: "Mail", due: end, overdue: false),
                        TodayPromise(id: "past", what: "Review plan", person: "Demo Guest", app: "Mail", due: start - 1, overdue: true),
                        TodayPromise(id: "soon", what: "Check outline", person: "", app: "", due: start + 10, overdue: false),
                        TodayPromise(id: "none", what: "Plan", person: "", app: "", due: nil, overdue: false)]
        let result = TodayThreadRules.summarize(items: items, topics: topics, promises: promises, now: now, calendar: cal)
        check(result.calls == 1 && result.voiceNotes == 1 && result.drafts == 1 && result.clips == 1, "only today; deduplicated")
        check(result.topics.map(\.id) == ["t4", "t3", "t2"], "three active topics by recency")
        check(result.headline == "4 topics · 1 call · 4 open promises", "headline grammar")
        check(result.overdueCount == 1, "past-due count")
        check(result.promises.map(\.id) == ["past", "soon", "later", "none"], "promise ordering")
        let rows: [[String: Any]] = [["id": "open", "what": "Review plan", "who": "Demo Guest", "due": start - 1, "done": NSNull()],
                                   ["id": "closed", "what": "Done", "done": 123], ["what": "No ID"],
                                   ["id": "unknown", "what": "Plan", "due": Double.nan]]
        let parsed = TodayThreadRules.parsePromises(rows, now: start)
        check(parsed.count == 2 && parsed[0].overdue && parsed[0].person == "Demo Guest", "parse API response")
        check(parsed[1].due == nil, "invalid dates")
        let empty = TodayThreadRules.summarize(items: [], topics: topics, promises: [], now: now, calendar: cal)
        check(empty.headline == "Today's thread" && empty.topics.isEmpty && empty.overdueCount == 0, "quiet empty state")
        print("today thread rules: pass")
    }
}

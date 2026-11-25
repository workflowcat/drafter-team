import Foundation

struct LookupQuery {
    static let reserved: Set<String> = [";docs", ";links", ";meetings", ";free", ";accounts"]
    let trigger: String
    let kind: String
    let query: String
    private static let pattern = try! NSRegularExpression(pattern: #"(?:^|(?<=\s))(;(docs|links|meetings|free|accounts)(?:[ \t]+[^\r\n]{0,200})?)\z"#)

    static func parse(_ before: String) -> LookupQuery? {
        guard let match = pattern.firstMatch(in: before, range: NSRange(before.startIndex..., in: before)),
              let full = Range(match.range(at: 1), in: before), let kind = Range(match.range(at: 2), in: before) else { return nil }
        let trigger = String(before[full]), name = String(before[kind])
        return LookupQuery(trigger: trigger, kind: name,
                           query: String(trigger.dropFirst(name.count + 1)).trimmingCharacters(in: .whitespaces))
    }

    var label: String {
        switch kind {
        case "docs": return "Search Google Drive"
        case "links": return "Find a saved link"
        case "meetings": return "Find a meeting link"
        case "free": return "Find free times to insert"
        default: return "Check Google account"
        }
    }
    var action: [String: Any] {
        ["id": "lookup", "chip": label + (query.isEmpty ? "" : " · " + query),
         "run": ["kind": "lookup.search", "old": trigger]]
    }

    static func unchanged(before: String, value: String, caret: Int,
                          expectedBefore: String, expectedValue: String, expectedCaret: Int, trigger: String) -> Bool {
        !trigger.isEmpty && before.hasSuffix(trigger) && before == expectedBefore && value == expectedValue && caret == expectedCaret
    }
}

// A plain-text brief to share a topic, person or call: title, summary, open items, web links. Foundation only.
import Foundation

enum ShareBriefRules {
    private static func line(_ text: String) -> String {
        text.components(separatedBy: .controlCharacters).joined(separator: " ")
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
    private static func unique(_ strings: [String]) -> [String] {
        var seen = Set<String>()
        return strings.map(line).filter { !$0.isEmpty && seen.insert($0).inserted }
    }
    static func formatShareBrief(title: String, subtitle: String = "", summary: String, todos: [String] = [], links: [String] = []) -> String {
        var sections = [line(title), line(subtitle), summary.trimmingCharacters(in: .whitespacesAndNewlines)]
        let tasks = unique(todos)
        if !tasks.isEmpty { sections.append("Open items\n" + tasks.map { "- " + $0 }.joined(separator: "\n")) }
        // Local file links mean nothing to a recipient: only web links go in.
        let urls = unique(links).filter {
            guard let u = URLComponents(string: $0), ["https", "http"].contains(u.scheme?.lowercased() ?? ""),
                  let host = u.host, !host.isEmpty, u.user == nil, u.password == nil else { return false }
            return true
        }
        if !urls.isEmpty { sections.append("Links\n" + urls.joined(separator: "\n")) }
        return sections.filter { !$0.isEmpty }.joined(separator: "\n\n") + "\n"
    }
}

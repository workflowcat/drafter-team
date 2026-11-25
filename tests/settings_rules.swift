import Foundation

// swiftc -parse-as-library app/SettingsRules.swift tests/settings_rules.swift -o app/build/settings-rules-test && app/build/settings-rules-test
// Made-up calendars.
@main
struct SettingsRuleChecks {
    static func check(_ ok: Bool, _ what: String) { if !ok { print("FAIL: " + what); exit(1) } }

    static func main() {
        let g = CalendarGroups.group([
            ("1", "Work", "me@example.com"), ("2", "Transferred from old@example.org", "me@example.com"),
            ("3", "Birthdays", "Other"), ("4", "Holidays", "me@example.com"), ("5", "Transferred from a@example.net", "me@example.com"),
            ("6", "Personal", ""),
        ])
        check(g.map(\.heading) == ["Other", "me@example.com", "Transferred"], "accounts, then one Transferred group: \(g.map(\.heading))")
        check(g[1].rows.map(\.name) == ["Holidays", "Work"], "own calendars by title")
        check(g[2].rows.map(\.name) == ["a@example.net", "old@example.org"], "transferred rows are the address alone")
        check(!g.flatMap(\.rows).contains { $0.name.contains("Transferred") }, "the phrase is never on a row")
        check(g[0].rows.map(\.name).sorted() == ["Birthdays", "Personal"], "no account and 'Other' go together")
        print("settings rules: all checks passed")
    }
}

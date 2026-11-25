// swiftc -parse-as-library app/SourceRules.swift tests/source_rules.swift -o app/build/source-rules-test && app/build/source-rules-test
// Made-up sources.
import Foundation

@main
struct SourceRuleChecks {
    static func check(_ ok: Bool, _ what: String) { if !ok { print("FAIL: " + what); exit(1) } }

    static func main() {
        let json = Data(#"""
        {"sources":[
          {"name":"mail","label":"Email (Gmail)","enabled":true,"count":1234,"updated":1000000.0,"error":"","running":false,"note":"read-only"},
          {"name":"beeper","label":"Chats","enabled":false,"count":0,"updated":0,"error":"","running":false,"note":""},
          {"name":"drive","label":"Drive","enabled":true,"count":7,"updated":999000,"error":"cannot reach the account","running":false},
          {"label":"no name"},
          {"name":"extra"}
        ]}
        """#.utf8)
        let rows = SourceRules.rows(data: json)
        check(rows.map(\.name) == ["mail", "beeper", "drive", "extra"], "rows in order, nameless dropped: \(rows.map(\.name))")
        check(rows[0].label == "Email (Gmail)" && rows[0].enabled && rows[0].count == 1234 && rows[0].updated == 1000000, "mail fields")
        check(rows[2].updated == 999000, "integer 'updated' reads as seconds")
        check(rows[3].label == "extra" && !rows[3].enabled && rows[3].count == 0, "missing fields default")
        check(SourceRules.rows(data: Data("nope".utf8)).isEmpty, "bad JSON: no rows")
        check(SourceRules.rows([:]).isEmpty, "no sources key: no rows")

        let now = 1000000.0
        let d = SourceRules.detail(rows[0], now: now + 2 * 3600 + 120)
        check(d == "1,234 items · updated 2 h ago", "count and age: \(d)")
        check(SourceRules.detail(rows[1], now: now) == "never updated", "never updated")
        check(SourceRules.detail(rows[2], now: now) == "cannot reach the account", "error wins")
        var run = rows[2]; run.running = true
        check(SourceRules.detail(run, now: now) == "updating…", "running wins over the error")
        var one = rows[0]; one.count = 1
        check(SourceRules.detail(one, now: now + 30) == "1 item · updated just now", "one item, just now")

        check(SourceRules.ago(59) == "just now" && SourceRules.ago(-5) == "just now", "under a minute or clock skew")
        check(SourceRules.ago(60) == "1 min ago" && SourceRules.ago(3599) == "59 min ago", "minutes")
        check(SourceRules.ago(3600) == "1 h ago" && SourceRules.ago(86399) == "23 h ago", "hours")
        check(SourceRules.ago(3 * 86400 + 5) == "3 d ago", "days")
        check(SourceRules.thousands(0) == "0" && SourceRules.thousands(999) == "999" && SourceRules.thousands(1000) == "1,000"
              && SourceRules.thousands(1234567) == "1,234,567", "thousands")

        check(!SourceRules.anyRunning(rows), "none running")
        check(SourceRules.anyRunning(rows + [run]), "one running")
        print("source rules: all checks passed")
    }
}

// swiftc -parse-as-library app/ShareBriefRules.swift tests/share_brief_rules.swift -o app/build/share-brief-test && app/build/share-brief-test
import Foundation

@main struct ShareBriefChecks {
    static func check(_ ok: @autoclosure () -> Bool, _ message: String) {
        if !ok() { print("FAIL: " + message); exit(1) }
    }
    static func main() {
        let brief = ShareBriefRules.formatShareBrief(title: "Orchard", subtitle: "Planning", summary: "Review outline",
            todos: ["Prepare draft", "Prepare draft", "  "],
            links: ["https://example.test/outline", "custom-app://open?file=Station", "file:///tmp/Station", "https://user:pw@example.test/x"])
        check(brief.hasPrefix("Orchard\n\nPlanning\n\nReview outline"), "title, subtitle, summary")
        check(brief.contains("Open items\n- Prepare draft\n\nLinks") || brief.contains("Open items\n- Prepare draft\n"), "share open items, deduped")
        check(brief.components(separatedBy: "Prepare draft").count == 2, "open items deduped")
        check(brief.contains("https://example.test/outline"), "web link kept")
        check(!brief.contains("custom-app://") && !brief.contains("file://") && !brief.contains("user:pw"), "recipient-ready links")
        let bare = ShareBriefRules.formatShareBrief(title: "Station\nPlan", summary: " A plan ")
        check(bare == "Station Plan\n\nA plan\n", "control characters folded, empty sections dropped")
        print("share brief rules: pass")
    }
}

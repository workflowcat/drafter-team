// swiftc -parse-as-library app/PreMeetingBriefRules.swift tests/pre_meeting_brief_rules.swift -o app/build/pre-meeting-brief-test && app/build/pre-meeting-brief-test
// Pure Foundation tests for Wave 8B pre-meeting "5-second brief" parsing, filtering and auto-hide rules.
import Foundation

@main
struct PreMeetingBriefRulesTest {
    static var failed = 0, checks = 0
    static func check(_ ok: Bool, _ what: String) {
        checks += 1
        if !ok {
            failed += 1
            print("FAIL", what)
        }
    }

    static func main() {
        testEmptyAndHeader()
        testShowAndVisibilityRules()
        testParsePrepLinesAndTopics()
        testPromiseParticipantFiltering()
        testDisplayItemBudget()
        print(failed == 0 ? "pre-meeting brief rules: \(checks) checks pass" : "\(failed) of \(checks) failed")
        if failed > 0 { exit(1) }
    }

    static func testEmptyAndHeader() {
        let empty = PreMeetingBrief()
        check(empty.isEmpty, "default brief is empty")
        check(PreMeetingBrief(participants: ["Mila Synthetic"]).isEmpty, "participants alone still count as empty brief")
        check(!PreMeetingBrief(lines: ["Mila Synthetic — Product Lead"]).isEmpty, "brief with a line is not empty")
        check(!PreMeetingBrief(promises: ["Send spec · Mila Synthetic"]).isEmpty, "brief with a promise is not empty")
        check(!PreMeetingBrief(recentTopics: ["Q4 onboarding"]).isEmpty, "brief with a recent topic is not empty")

        check(PreMeetingBriefRules.headerTitle(for: empty) == "Before this call", "header without participants")
        check(PreMeetingBriefRules.headerTitle(for: PreMeetingBrief(participants: ["Mila Synthetic"])) == "Before this call · Mila Synthetic", "header with one participant")
        check(PreMeetingBriefRules.headerTitle(for: PreMeetingBrief(participants: ["Mila Synthetic", "Sava"])) == "Before this call · Mila Synthetic, Sava", "header with two participants")
        check(PreMeetingBriefRules.headerTitle(for: PreMeetingBrief(participants: ["Mila Synthetic", "Sava", "Nora Reed", "Taras Demo"])) == "Before this call · Mila Synthetic, Sava +2", "header caps participant list with +N")

        check(PreMeetingBriefRules.queryText(eventTitle: "  Weekly sync ", participants: ["Mila Synthetic", "", "  Sava "]) == "Weekly sync Mila Synthetic Sava", "query text trims and joins event title and participants")
        check(PreMeetingBriefRules.queryText(eventTitle: "   ", participants: ["", " "]).isEmpty, "empty query text stays empty")
    }

    static func testShowAndVisibilityRules() {
        let brief = PreMeetingBrief(
            participants: ["Mila Synthetic"],
            lines: ["Mila Synthetic — Product Lead · Atlas"],
            promises: ["Send rollout notes · Mila Synthetic"]
        )
        let empty = PreMeetingBrief()

        // Non-calls, empty briefs, and dismissed briefs never show.
        check(!PreMeetingBriefRules.shouldShowBrief(isCall: false, secondsRecorded: 5, hasLiveOutline: false, dismissed: false, brief: brief), "never shows for non-call note")
        check(!PreMeetingBriefRules.shouldShowBrief(isCall: false, secondsRecorded: 5, hasLiveOutline: false, dismissed: false, brief: brief, manuallyExpanded: true), "manual expand still respects isCall")
        check(!PreMeetingBriefRules.shouldShowBrief(isCall: true, secondsRecorded: 5, hasLiveOutline: false, dismissed: false, brief: empty), "never shows for empty brief")
        check(!PreMeetingBriefRules.shouldShowBrief(isCall: true, secondsRecorded: 5, hasLiveOutline: false, dismissed: true, brief: brief), "never shows once dismissed")
        check(!PreMeetingBriefRules.shouldShowBrief(isCall: true, secondsRecorded: 5, hasLiveOutline: false, dismissed: true, brief: brief, manuallyExpanded: true), "dismissed overrides manual expand")

        // Time and live-outline auto-hide boundaries.
        check(PreMeetingBriefRules.shouldShowBrief(isCall: true, secondsRecorded: 0, hasLiveOutline: false, dismissed: false, brief: brief), "shows at call start")
        check(PreMeetingBriefRules.shouldShowBrief(isCall: true, secondsRecorded: 119, hasLiveOutline: false, dismissed: false, brief: brief), "shows at 119 s before auto-hide")
        check(!PreMeetingBriefRules.shouldShowBrief(isCall: true, secondsRecorded: 120, hasLiveOutline: false, dismissed: false, brief: brief), "auto-hides at 120 s")
        check(PreMeetingBriefRules.shouldShowBrief(isCall: true, secondsRecorded: 240, hasLiveOutline: false, dismissed: false, brief: brief, manuallyExpanded: true), "shows after 120 s when manually expanded")
        check(!PreMeetingBriefRules.shouldShowBrief(isCall: true, secondsRecorded: 45, hasLiveOutline: true, dismissed: false, brief: brief), "auto-hides once live outline notes arrive")
        check(PreMeetingBriefRules.shouldShowBrief(isCall: true, secondsRecorded: 45, hasLiveOutline: true, dismissed: false, brief: brief, manuallyExpanded: true), "shows with live outline when manually expanded")

        // Visibility state transitions (hidden / collapsed pill / expanded card).
        check(PreMeetingBriefRules.visibility(isCall: true, secondsRecorded: 10, hasLiveOutline: false, dismissed: false, brief: brief) == .expanded, "initial call state is expanded")
        check(PreMeetingBriefRules.visibility(isCall: true, secondsRecorded: 10, hasLiveOutline: false, dismissed: false, brief: brief, userOverride: false) == .collapsed, "user collapse switches to pill")
        check(PreMeetingBriefRules.visibility(isCall: true, secondsRecorded: 120, hasLiveOutline: false, dismissed: false, brief: brief) == .collapsed, "120 s auto-collapses to pill")
        check(PreMeetingBriefRules.visibility(isCall: true, secondsRecorded: 50, hasLiveOutline: true, dismissed: false, brief: brief) == .collapsed, "live outline auto-collapses to pill")
        check(PreMeetingBriefRules.visibility(isCall: true, secondsRecorded: 180, hasLiveOutline: true, dismissed: false, brief: brief, userOverride: true) == .expanded, "clicking Show brief re-expands card")
        check(PreMeetingBriefRules.visibility(isCall: true, secondsRecorded: 10, hasLiveOutline: false, dismissed: true, brief: brief, userOverride: true) == .hidden, "dismiss hides both card and pill")
        check(PreMeetingBriefRules.visibility(isCall: false, secondsRecorded: 10, hasLiveOutline: false, dismissed: false, brief: brief) == .hidden, "non-call stays completely hidden")
    }

    static func testParsePrepLinesAndTopics() {
        let nilBrief = PreMeetingBriefRules.parsePrepResponse(nil, promises: nil, participants: [])
        check(nilBrief.isEmpty, "nil prep and promises produce empty brief")

        let errBrief = PreMeetingBriefRules.parsePrepResponse(["lines": [], "error": "offline"], promises: [], participants: ["Mila Synthetic"])
        check(errBrief.isEmpty && errBrief.participants == ["Mila Synthetic"], "error payload keeps participant but empty brief")

        let longLine = "Mila Synthetic — " + String(repeating: "very detailed context note ", count: 8)
        let prep: [String: Any] = [
            "people": ["Mila Synthetic", "Sava"],
            "lines": [
                "  Mila Synthetic — Product Lead · Atlas  ",
                "mila synthetic — product lead · atlas",   // case-insensitive duplicate
                "  note: Prefers crisp\n  bullet updates",
                "  2026-11-18: Atlas onboarding review",
                longLine,
                "Fifth line should be dropped by 4-line cap"
            ]
        ]

        let parsed = PreMeetingBriefRules.parsePrepResponse(prep, promises: nil, participants: ["Sava", "  "])
        check(parsed.participants == ["Sava", "Mila Synthetic"], "calendar participants come first and deduplicate prep people")
        check(parsed.lines.count == 4, "caps brief lines at 4 after deduplicating")
        check(parsed.lines[0] == "Mila Synthetic — Product Lead · Atlas", "trims surrounding spaces")
        check(parsed.lines[1] == "note: Prefers crisp bullet updates", "collapses internal newlines and spaces")
        check(parsed.lines[3].count <= PreMeetingBriefRules.maxLineLength && parsed.lines[3].hasSuffix("…"), "caps long lines cleanly with ellipsis")
        check(parsed.recentTopics == ["Atlas onboarding review"], "extracts dated note title into recentTopics")
    }

    static func testPromiseParticipantFiltering() {
        let prep: [String: Any] = [
            "people": ["Mila Synthetic"],
            "lines": [
                "Mila Synthetic — Product Lead · Atlas",
                "  followup: Share prototype link"
            ]
        ]
        let longPromise = "Deliver " + String(repeating: "quarterly architecture summary ", count: 6)
        let promises: [[String: Any]] = [
            // Open promise matching first name (non-overdue)
            ["id": "p1", "who": "Mila", "what": "Send Q4 rollout plan", "overdue": false],
            // Duplicate of p1 by id
            ["id": "p1", "who": "Mila", "what": "Send Q4 rollout plan", "overdue": false],
            // Already covered inside prep lines ("Share prototype link")
            ["id": "p2", "who": "Mila Synthetic", "what": "Share prototype link", "overdue": false],
            // Overdue promise matching via `what` text mentioning participant
            ["id": "p3", "who": "", "what": "Confirm milestone dates with Mila", "overdue": true],
            // Done / dropped promises must be excluded
            ["id": "p4", "who": "Mila Synthetic", "what": "Completed item", "done": 1_700_000_000],
            ["id": "p5", "who": "Mila Synthetic", "what": "Dropped item", "status": "dropped"],
            ["id": "p6", "who": "Mila Synthetic", "what": "Flagged done", "isDone": true],
            // Unrelated person must be excluded
            ["id": "p7", "who": "Nora Reed", "what": "Unrelated review", "overdue": true],
            // Third open promise (long, should be capped)
            ["id": "p8", "who": "Sava", "what": longPromise, "overdue": false],
            // Fourth open promise should be dropped by 3-promise cap
            ["id": "p9", "who": "Sava", "what": "Fourth open item", "overdue": false]
        ]

        let parsed = PreMeetingBriefRules.parsePrepResponse(prep, promises: promises, participants: ["Sava"])
        check(parsed.promises.count == 3, "caps matched open promises at 3")
        check(parsed.promises[0] == "Confirm milestone dates with Mila", "overdue promise sorts first and avoids redundant who suffix")
        check(parsed.promises[1] == "Send Q4 rollout plan · Mila", "appends who label when not already in promise text")
        check(parsed.promises[2].count <= PreMeetingBriefRules.maxPromiseLength && parsed.promises[2].hasSuffix("…"), "caps long promise text")
        check(!parsed.promises.contains(where: { $0.contains("Nora") || $0.contains("Completed") || $0.contains("Dropped") || $0.contains("Flagged") || $0.contains("prototype") }), "excludes unrelated, completed, and duplicate-of-line promises")

        // Word-boundary safety: short name "Al" must NOT match "Calendar" or "Final", but MUST match "Al Chen" / "Al".
        let boundaryPromises: [[String: Any]] = [
            ["id": "b1", "who": "Calendar Bot", "what": "Final checklist"],
            ["id": "b2", "who": "Al", "what": "Share benchmark table"]
        ]
        let shortNameBrief = PreMeetingBriefRules.parsePrepResponse(nil, promises: boundaryPromises, participants: ["Al"])
        check(shortNameBrief.promises == ["Share benchmark table · Al"], "word boundary prevents substring false positives")

        // No participants at all -> never leak unrelated promises.
        let noPeopleBrief = PreMeetingBriefRules.parsePrepResponse(nil, promises: boundaryPromises, participants: [])
        check(noPeopleBrief.isEmpty && noPeopleBrief.promises.isEmpty, "never leaks promises when participants are empty")
    }

    static func testDisplayItemBudget() {
        let dense = PreMeetingBrief(
            participants: ["Mila Synthetic", "Sava"],
            lines: ["Line one", "Line two", "Line three", "Line four"],
            promises: ["Promise A · Mila", "Promise B · Sava", "Promise C · Mila"],
            recentTopics: ["Extra topic"]
        )
        let items = PreMeetingBriefRules.displayItems(for: dense)
        check(items.count == 5, "display items capped at 5 total lines")
        check(items.filter { $0.kind == .promise }.count == 2, "reserves room for open promises even when 4 prep lines exist")
        check(items.first?.isPrimary == true && items.first?.kind == .context, "first context line marked primary")

        let topicsOnly = PreMeetingBrief(
            participants: ["Sava"],
            lines: [],
            promises: [],
            recentTopics: ["Release dry run", "Audio health check"]
        )
        let topicItems = PreMeetingBriefRules.displayItems(for: topicsOnly)
        check(topicItems.count == 2 && topicItems[0].kind == .topic && topicItems[0].isPrimary, "renders recent topics when lines are empty")
    }
}

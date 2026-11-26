// swiftc -parse-as-library app/SettingsSearchRules.swift tests/settings_search_rules.swift -o app/build/settings-search-rules-test && app/build/settings-search-rules-test
import Foundation

@main
struct SettingsSearchChecks {
    static func check(_ ok: Bool, _ what: String) {
        if !ok { print("FAIL: " + what); exit(1) }
    }

    static func main() {
        // Multi-word matching
        check(SettingsSearchRules.matches(query: "", title: "Fix typos"), "empty query matches everything")
        check(SettingsSearchRules.matches(query: "   ", title: "Fix typos"), "whitespace query matches everything")
        check(SettingsSearchRules.matches(query: "typo uk", title: "Fix Ukrainian typos too"), "multi-word matches out of order")
        check(!SettingsSearchRules.matches(query: "typo voice", title: "Fix Ukrainian typos too"), "missing token fails")
        check(SettingsSearchRules.matches(query: "claude", title: "⌥Tab reworks the selected text", extra: "cloud claude"), "extra tags match")

        // Cyrillic / Ukrainian & diacritics folding + empty/no-match checks
        check(SettingsSearchRules.matches(query: "ГРН", title: "A number and грн to ₴"), "Cyrillic case-insensitive match")
        check(SettingsSearchRules.matches(query: "І В У", title: "No line break after і в у з а о"), "Ukrainian multi-token match")
        check(SettingsSearchRules.matches(query: "cafe", title: "Café theme"), "diacritic-insensitive match")
        check(SettingsSearchRules.isSearching("voice"), "non-empty query is searching")
        check(!SettingsSearchRules.isSearching("   "), "whitespace query is not searching")
        check(SettingsSearchRules.anyMatch(query: "typos", titles: ["Fix typos", "Quick capture"]), "anyMatch true on hit")
        check(!SettingsSearchRules.anyMatch(query: "zzzz-no-such-setting", titles: ["Fix typos", "Quick capture"]), "anyMatch false on no-match (empty state)")
        check(SettingsSearchRules.anyMatch(query: "", titles: []), "empty query always matches even with empty list")

        // Category visibility & Advanced expansion
        check(SettingsSearchRules.showCategory(.typing, selected: .all, query: ""), "all shows typing")
        check(SettingsSearchRules.showCategory(.typing, selected: .typing, query: ""), "selected matches")
        check(!SettingsSearchRules.showCategory(.voice, selected: .typing, query: ""), "other category hidden when no query")
        check(SettingsSearchRules.showCategory(.voice, selected: .typing, query: "mic"), "search overrides category filter")

        check(!SettingsSearchRules.advancedOpen(toggled: false, selected: .all, query: ""), "advanced folded by default")
        check(SettingsSearchRules.advancedOpen(toggled: true, selected: .all, query: ""), "advanced open when toggled")
        check(SettingsSearchRules.advancedOpen(toggled: false, selected: .all, query: "idle"), "advanced auto-opens on search")
        check(SettingsSearchRules.advancedOpen(toggled: false, selected: .typing, query: ""), "advanced auto-opens on typing tab")
        check(!SettingsSearchRules.advancedOpen(toggled: false, selected: .cloud, query: ""), "cloud tab keeps advanced folded")

        // Permissions checklist
        let allOK = SettingsSearchRules.permissions(accessibility: true, screenRecording: true, calendar: true, captureSystemKeyOn: false, captureEnabled: true)
        check(allOK.count == 5, "5 items when capture enabled")
        check(SettingsSearchRules.attentionCount(allOK) == 0, "0 items need attention when all granted")

        let missing = SettingsSearchRules.permissions(accessibility: false, screenRecording: true, calendar: false, captureSystemKeyOn: true, captureEnabled: true)
        check(SettingsSearchRules.attentionCount(missing) == 2, "accessibility and the key need attention; calendars are optional")
        check(SettingsSearchRules.attentionCount(SettingsSearchRules.permissions(accessibility: true, microphone: false, screenRecording: true, calendar: true, voiceOn: true, captureSystemKeyOn: false, captureEnabled: false)) == 1, "the microphone is needed once voice is on")
        check(SettingsSearchRules.attentionCount(SettingsSearchRules.permissions(accessibility: true, microphone: false, screenRecording: false, calendar: true, voiceOn: false, screenUsed: false, captureSystemKeyOn: false, captureEnabled: false)) == 0, "unused permissions stay grey")
        check(missing.first { $0.id == "accessibility" }?.settingsURL.contains("Privacy_Accessibility") == true, "accessibility deep link")

        let noCap = SettingsSearchRules.permissions(accessibility: true, screenRecording: true, calendar: true, captureSystemKeyOn: true, captureEnabled: false)
        check(noCap.count == 4, "capture key check omitted when capture disabled")
        check(SettingsSearchRules.attentionCount(noCap) == 0, "disabled capture needs no attention")

        print("settings search rules: all checks passed")
    }
}

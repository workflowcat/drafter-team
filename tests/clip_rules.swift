import Foundation

// swiftc -O -parse-as-library app/ClipRules.swift tests/clip_rules.swift -o app/build/clip-rules-test && app/build/clip-rules-test
// Display-only URL fallbacks: generated IDs disappear; fetched titles and technical identifiers survive.
@main
struct ClipTitleChecks {
    static func main() {
        var failed = 0
        func check(_ value: String, _ expected: String) {
            if value != expected { failed += 1; print("FAIL: \(value) != \(expected)") }
        }
        let hex = "0123456789abcdef0123456789abcdef"
        let uuid = "12345678-1234-abcd-5678-123456789abc"
        check(ClipRules.cleanSlug("Project-notes-" + hex), "Project notes")
        check(ClipRules.cleanSlug("Project-notes-" + hex.uppercased()), "Project notes")
        check(ClipRules.cleanSlug("Project-notes-" + uuid), "Project notes")
        check(ClipRules.cleanSlug("Project-notes-123456789"), "Project notes")
        check(ClipRules.cleanSlug("Project%20notes-" + hex), "Project notes")
        check(ClipRules.cleanSlug("inkling-2-mini"), "inkling-2-mini")
        check(ClipRules.cleanSlug("release-2"), "release-2")
        check(ClipRules.cleanSlug("org/my-repo"), "org/my-repo")
        check(ClipRules.cleanSlug(hex), "")
        check(ClipRules.cleanSlug(uuid), "")
        check(ClipRules.linkTitle("https://www.notion.so/Project-notes-" + hex), "Project notes")
        check(ClipRules.linkTitle("https://app.notion.so/space/Project-notes-" + hex + "?view=all"), "Project notes")
        check(ClipRules.linkTitle("https://example.notion.site/Project-notes-" + uuid), "Project notes")
        check(ClipRules.linkTitle("https://www.notion.so/" + hex), "notion.so")
        check(ClipRules.linkTitle("https://example.org/models/inkling-2-mini"), "inkling-2-mini")
        check(ClipRules.linkTitle("https://github.com/org/my-repo"), "org/my-repo")
        check(ClipRules.linkTitle("https://huggingface.co/org/inkling-2-mini"), "org/inkling-2-mini")
        check(ClipRules.linkTitle("https://example.org/a-slug", title: "Fetched-title-42"), "Fetched-title-42")
        check(ClipRules.linkTitle("https://example.org/"), "example.org")
        check(ClipRules.linkTitle("https://example.org/field-notes-guide"), "field notes guide")
        print(failed == 0 ? "clip titles: all passed" : "clip titles: \(failed) failed")
        exit(failed == 0 ? 0 : 1)
    }
}

// swiftc -parse-as-library app/ObsidianExportRules.swift tests/obsidian_export_rules.swift -o app/build/obsidian-export-test && app/build/obsidian-export-test
import Foundation

@main struct ObsidianExportChecks {
    static func check(_ ok: @autoclosure () -> Bool, _ message: String) {
        if !ok() { print("FAIL: " + message); exit(1) }
    }
    static func main() throws {
        let fm = FileManager.default
        let temp = realpath(NSTemporaryDirectory(), nil)!
        let base = String(cString: temp); free(temp)
        let root = URL(fileURLWithPath: base).appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: root) }
        let vault = root.appendingPathComponent("Orchard")
        try fm.createDirectory(at: vault, withIntermediateDirectories: false)
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        check(ObsidianExportRules.safeSlug("../../Station / Plan\\draft\n") == "station-plan-draft", "slug removes path syntax")
        check(ObsidianExportRules.safeSlug("  Café 東京  ") == "café-東京", "Unicode filename")
        check(ObsidianExportRules.safeSlug(String(repeating: "東", count: 300)).utf8.count <= 120, "bounded filename bytes")
        check(ObsidianExportRules.safeSlug("...\0") == "note", "empty slug fallback")
        check(ObsidianExportRules.targetURL(vaultPath: "", date: date, title: "Station") == nil, "off")
        check(ObsidianExportRules.targetURL(vaultPath: root.appendingPathComponent("missing").path, date: date, title: "Station") == nil, "missing vault")
        for folder in ["..", "../outside", "/outside", "Drafter/sub", "a\\b", "\0"] {
            check(ObsidianExportRules.targetURL(vaultPath: vault.path, subfolder: folder, date: date, title: "Station") == nil, "reject subfolder traversal")
        }
        let alias = root.appendingPathComponent("Alias")
        try fm.createSymbolicLink(at: alias, withDestinationURL: vault)
        check(ObsidianExportRules.targetURL(vaultPath: alias.path, date: date, title: "Station") == nil, "symlink root")
        let target = ObsidianExportRules.targetURL(vaultPath: vault.path, date: date, title: "Station")!
        check(target.deletingLastPathComponent().lastPathComponent == "Drafter", "contained in export folder")
        check(!fm.fileExists(atPath: target.deletingLastPathComponent().path), "target lookup is read-only")
        let note = ObsidianExportRules.formatCallNote(title: "Station\nPlan", date: date, people: ["Demo Guest", "Demo Guest"], entities: ["Orchard"],
            summary: "Review the outline.", todos: ["Prepare draft", "Prepare draft"], notes: "Keep notes here.")
        check(note.contains("type: call\n"), "type frontmatter")
        check(note.contains("people: [\"Demo Guest\"]"), "people quoted and deduplicated")
        check(note.contains("source: drafter"), "source frontmatter")
        check(note.contains("[[Demo Guest]] · [[Orchard]]"), "linked entities")
        check(note.components(separatedBy: "- [ ] Prepare draft").count == 2, "one checkbox")
        check(note.contains("## Summary") && note.contains("## Notes"), "note sections")
        check(note.contains("# Station Plan"), "title cannot inject frontmatter")
        _ = try ObsidianExportRules.writeAtomically(content: note, to: target).get()
        let saved = try String(contentsOf: target, encoding: .utf8)
        check(saved == note, "complete atomic note")
        if case .success = ObsidianExportRules.writeAtomically(content: "overwrite", to: target) { fatalError("must not overwrite") }
        check(ObsidianExportRules.targetURL(vaultPath: vault.path, date: date, title: "Station")!.lastPathComponent.hasSuffix("-2.md"), "collision suffix")
        let second = ObsidianExportRules.targetURL(vaultPath: vault.path, date: date, title: "Station")!
        _ = try ObsidianExportRules.writeAtomically(content: "second", to: second).get()
        check(ObsidianExportRules.targetURL(vaultPath: vault.path, date: date, title: "Station")!.lastPathComponent.hasSuffix("-3.md"), "third collision")
        let other = root.appendingPathComponent("Outside")
        try fm.createDirectory(at: other, withIntermediateDirectories: false)
        let linked = vault.appendingPathComponent("Linked")
        try fm.createSymbolicLink(at: linked, withDestinationURL: other)
        check(ObsidianExportRules.targetURL(vaultPath: vault.path, subfolder: "Linked", date: date, title: "Station") == nil, "symlink export directory")
        if case .success = ObsidianExportRules.writeAtomically(content: "escaped", to: linked.appendingPathComponent("bad.md")) { fatalError("symlink followed") }
        // Swap the export directory after target lookup: the writer must still refuse the symlink.
        let delayed = ObsidianExportRules.targetURL(vaultPath: vault.path, subfolder: "Later", date: date, title: "Station")!
        try fm.createSymbolicLink(at: delayed.deletingLastPathComponent(), withDestinationURL: other)
        if case .success = ObsidianExportRules.writeAtomically(content: "escaped", to: delayed) { fatalError("late symlink followed") }
        let outsideFiles = try fm.contentsOfDirectory(atPath: other.path)
        check(outsideFiles.isEmpty, "outside untouched")
        let topic = ObsidianExportRules.formatTopicNote(title: "Orchard", date: date, summary: "A plan", notes: "Fragments")
        check(topic.contains("type: topic"), "topic note")
        let brief = ObsidianExportRules.formatShareBrief(title: "Orchard", subtitle: "Planning", summary: "Review outline", todos: ["Prepare draft"],
            links: ["https://example.test/outline", "obsidian://open?vault=Orchard&file=Station", "file:///tmp/Station"])
        check(brief.contains("Open items\n- Prepare draft"), "share open items")
        check(brief.contains("https://example.test/outline") && !brief.contains("obsidian://") && !brief.contains("file://"), "recipient-ready links")
        print("obsidian export rules: pass")
    }
}

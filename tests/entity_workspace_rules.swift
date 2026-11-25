// swiftc -parse-as-library app/LinksRules.swift app/EntityWorkspaceRules.swift tests/entity_workspace_rules.swift -o app/build/entity-workspace-rules-test && app/build/entity-workspace-rules-test
// Synthetic values only. No journal files, screen text, services or wall clock are accessed.
import Foundation

@main
struct EntityWorkspaceRulesTests {
    static var checks = 0
    static var failures = 0
    static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        checks += 1
        if !condition() { failures += 1; print("FAIL: " + message) }
    }
    static let entry: [String: Any] = [
        "kind": "person", "uk": "Ганна Квітка", "latin": "Hanna Kvitka",
        "short": ["Ганя", "Hanna", " hanna "], "forms": ["Ганни", "Ганною", "Квітці"],
        "emails": ["hanna+notes@example.test", "HANNA+NOTES@EXAMPLE.TEST"],
        "phones": ["+000 000 0001"], "heard": ["Not an alias"]
    ]
    static var person: EntityWorkspaceIdentity { EntityWorkspaceRules.identity(entry) }
    static func row(_ id: String, _ text: String = "", kind: String = "typed", clip: String = "text",
                    when: Double = 100, title: String = "", tags: [String] = []) -> EntityJournalInput {
        EntityJournalInput(id: id, kind: kind, clip: clip, when: when, text: text, title: title,
                           app: "Sample Notes", tags: tags)
    }

    static func main() {
        aliases(); categories(); promises(); links(); tabsAndEmpty(); context()
        print("entity workspace rules: \(checks) checks, \(failures) failures")
        exit(failures == 0 ? 0 : 1)
    }

    static func aliases() {
        check(person.display == "Ганна Квітка", "Ukrainian display follows Names")
        check(person.latin == "Hanna Kvitka", "Latin subtitle")
        check(person.kind == "person", "kind preserved")
        check(person.phones == ["+000 000 0001"], "phones preserved")
        check(person.emails.count == 1, "emails folded and deduplicated")
        check(person.aliases.count == 8, "display, Latin, short, forms and email included once")
        check(person.aliases == EntityWorkspaceRules.aliases(entry), "entry convenience API")
        check(!person.aliases.contains("not an alias"), "mishearings are not match aliases")
        for text in ["Зустріч для Ганни.", "Нотатки з Ганною.", "Привіт, Ганя!", "To: HANNA+NOTES@EXAMPLE.TEST",
                     "Notes for Hanna Kvitka", "(Квітці)", "ГАННА   КВІТКА"] {
            check(EntityWorkspaceRules.matches(text, aliases: person.aliases), "matches synthetic alias: \(text)")
        }
        for text in ["Hannah", "PreHanna", "x_hanna", "x-hanna+notes@example.test"] {
            let aliases = text.contains("@") ? ["hanna+notes@example.test"] : person.aliases
            check(!EntityWorkspaceRules.matches(text, aliases: aliases), "rejects partial name or address: \(text)")
        }
        check(!EntityWorkspaceRules.matches("hanna@sample.example.test", aliases: ["hanna@sample.example"]), "email domain must not match a prefix")
        check(EntityWorkspaceRules.matches("L'ÉTOILE", aliases: ["l’etoile"]), "diacritics and apostrophes fold")
        check(EntityWorkspaceRules.matches("пʼять", aliases: ["п’ять"]), "Ukrainian apostrophes fold")
        check(EntityWorkspaceRules.matches("Use C++.", aliases: ["C++"]), "regex symbols are literal")
        check(!EntityWorkspaceRules.matches("anything", aliases: ["", " \n "]), "empty aliases match nothing")
        let display = EntityWorkspaceRules.identity(["display": "Sample Display", "uk": "Sample Form", "latin": "Sample Latin"])
        check(display.aliases.count == 3 && display.display == "Sample Display", "explicit display joins aliases")
        check(EntityWorkspaceRules.identity(["uk": " ", "latin": "Bramblix"]).display == "Bramblix", "blank Ukrainian falls back to Latin")
        for kind in ["project", "company", "place", "term"] {
            let identity = EntityWorkspaceRules.identity(["kind": kind, "latin": "Bramblix", "short": ["BRX"]])
            check(identity.kind == kind && EntityWorkspaceRules.build(entity: identity, journal: [row("x", "BRX notes")]).counts.total == 1,
                  "same workspace rules for \(kind)")
        }
    }

    static func sampleRows() -> [EntityJournalInput] {
        var call = row("call", kind: "call", when: 400, title: "Weekly review")
        call.related = ["Hanna Kvitka"]; call.documentID = "sample-call"; call.duration = 180
        call.points = ["Review the outline."]
        call.pictures = [EntityPicture(id: "call-shot", journalID: "call", when: 405, title: "Call picture")]
        var image = row("image", kind: "copied", clip: "image", when: 300, tags: ["Ганна Квітка"])
        image.pictures = [EntityPicture(id: "image", journalID: "image", when: 300, title: "Sample picture")]
        var shot = row("shot", "Ганя: sample caption", kind: "shot", clip: "image", when: 200)
        shot.pictures = [EntityPicture(id: "shot", journalID: "shot", when: 200, title: "Sample shot", shotID: "sample-shot")]
        var voice = row("note", kind: "spoken", when: 110, title: "Hanna's long note")
        voice.documentID = "sample-note"
        return [
            row("draft", "For Ганни", when: 100), row("voice", "Ганя", kind: "spoken", when: 600),
            row("clip", "Hanna copied this", kind: "copied", when: 500), call, image, shot, voice,
            row("unrelated", "Other contact"), row("partial", "Hannah"),
            row("unknown", "Hanna", kind: "unsupported"), row("voice", "Hanna duplicate", kind: "spoken", when: 10)
        ]
    }

    static func categories() {
        let model = EntityWorkspaceRules.build(entity: person, journal: sampleRows())
        check(model.overview.map(\.id) == ["voice", "clip", "call", "image", "shot", "note", "draft"], "newest-first timeline and unique journal IDs")
        check(model.calls.map(\.id) == ["call"], "calls bucket")
        check(model.draftsAndVoice.map(\.id) == ["voice", "note", "draft"], "typed, voice and long notes bucket")
        check(model.clips.map(\.id) == ["clip"], "plain clips bucket excludes images")
        check(model.pictures.map(\.id) == ["call-shot", "image", "shot"], "call pictures, clipboard images and shot packs")
        check(model.calls.first?.duration == 180 && model.calls.first?.points.count == 1, "call summary retained")
        let missingImage = EntityWorkspaceRules.build(entity: person, journal: [row("missing-image", "Hanna", clip: "image")])
        check(missingImage.pictures.count == 1 && missingImage.pictures[0].path.isEmpty, "a missing thumbnail keeps its picture row")
        check(model.counts == EntityWorkspaceCounts(total: 7, calls: 1, links: 0, pictures: 3, promises: 0), "counts do not double-count pictures in journal total")
        let splitName = row("split", "Kvitka", title: "Hanna")
        check(EntityWorkspaceRules.build(entity: EntityWorkspaceRules.identity(["latin": "Hanna Kvitka"]), journal: [splitName]).overview.isEmpty,
              "separate fields cannot manufacture a full-name match")
        for kind in ["calls", "draft", "drafts", "voice", "said", "text", "clip", "picture"] {
            check(EntityWorkspaceRules.build(entity: person, journal: [row(kind, "Hanna", kind: kind)]).counts.total == 1, "supported kind \(kind)")
        }
        var tagged = row("tagged", "No name in text", tags: ["Квітці"])
        check(EntityWorkspaceRules.build(entity: person, journal: [tagged]).counts.total == 1, "forms in tags")
        tagged.tags = []; tagged.points = ["Hanna will review"]
        check(EntityWorkspaceRules.build(entity: person, journal: [tagged]).counts.total == 1, "names in call summary points")
        let ties = [row("b", "Hanna", when: .nan), row("a", "Hanna", when: .infinity), row("c", "Hanna", when: -3)]
        check(EntityWorkspaceRules.build(entity: person, journal: ties).overview.map(\.id) == ["a", "b", "c"], "invalid timestamps sort deterministically")
    }

    static func promises() {
        let rows: [[String: Any]] = [
            ["id": "who", "who": "Ганна Квітка", "what": "Review the outline", "t": 100, "due": 200, "done": NSNull()],
            ["id": "form", "who": "Sample Contact", "phrase": "Send a note for Ганни", "t": 90, "done": false],
            ["id": "email", "person": "hanna+notes@example.test", "what": "Send the sample file", "t": "80", "due": "240"],
            ["id": "what", "what": "Hanna: review the sample", "t": 70, "due": Double.nan],
            ["id": "wrong", "who": "Hannah", "what": "Other work"],
            ["id": "done", "who": "Hanna", "what": "Finished", "done": 15],
            ["id": "boolean", "who": "Hanna", "what": "Finished", "done": true],
            ["id": "closed", "who": "Hanna", "what": "Finished", "status": "closed"],
            ["id": "empty", "who": "Hanna"], ["who": "Hanna", "what": "Missing ID"],
            ["id": "who", "who": "Hanna", "what": "Old duplicate", "t": 2],
            ["id": "app", "app": "Hanna", "what": "Unrelated app name"]
        ]
        let found = EntityWorkspaceRules.filterPromises(rows, aliases: person.aliases)
        check(found.map(\.id) == ["who", "form", "email", "what"], "only matching open promises, newest first, IDs unique")
        check(found[1].what == "Send a note for Ганни", "phrase fallback")
        check(found[2].due == 240 && found[2].when == 80, "numeric string timestamps")
        check(found[3].due == nil, "invalid due date is absent")
        check(EntityWorkspaceRules.filterPromises(rows, aliases: []).isEmpty, "no identity does not return all promises")
        check(EntityWorkspaceRules.build(entity: person, journal: [], promises: rows).counts.promises == 4, "promise summary count")
    }

    static func links() {
        var file = row("files", "/tmp/sample-one.pdf\n/tmp/sample-two.pdf", kind: "copied", clip: "file", tags: ["Hanna"])
        file.filePaths = ["/tmp/sample-one.pdf", "/tmp/sample-two.pdf"]
        var call = row("call-link", kind: "call", title: "Hanna review")
        call.points = ["Read https://example.test/brief"]
        let rows = [
            row("one", "Hanna https://EXAMPLE.TEST/outline?utm_source=sample", when: 50),
            row("two", "https://example.test/outline https://example.test/outline", kind: "copied", clip: "link", when: 100, tags: ["Hanna"]),
            row("ignore", "Other https://example.test/private-example"), file, call
        ]
        let remote = LinksRules.parseSources([
            ["title": "Sample outline", "url": "https://example.test/outline?fbclid=test", "src": "mail", "t": 150],
            ["title": "Sample attachment", "file": "outline.pdf", "src": "mail", "t": 40, "from": "Sample Contact"]
        ])
        let model = EntityWorkspaceRules.build(entity: person, journal: rows, remoteLinks: remote)
        check(model.links.count == 5, "deduplicated link, 2 local files, call link and remote attachment")
        let link = model.links.first { $0.normalizedURL == "https://example.test/outline" }
        check(link?.mentions == 3, "one mention per row plus source")
        check(link?.journalId == "two", "local Journal jump survives remote merge")
        check(link?.title == "Sample outline" && link?.source == .mail, "remote title and newest provenance")
        check(model.links.filter { $0.filePath?.hasPrefix("/tmp/") == true }.count == 2, "multi-file clip splits into files")
        check(!model.links.contains { $0.url.contains("private-example") }, "unrelated journal links excluded")
        check(model.links.contains { $0.url == "https://example.test/brief" }, "extract call summary URLs")
        let titled = EntityWorkspaceRules.build(entity: person, journal: [row("title-link", "Hanna", title: "https://example.test/title")])
        check(titled.links.count == 1, "extract links from the stored title")
        if let link { check(LinksRules.markdown(link) == "[Sample outline](https://example.test/outline)", "copy Markdown reuses link formatting") }
    }

    static func tabsAndEmpty() {
        let empty = EntityWorkspaceRules.build(entity: EntityWorkspaceRules.identity([:]), journal: sampleRows())
        check(empty.counts == EntityWorkspaceCounts(), "empty identity has zero counts")
        for tab in EntityWorkspaceTab.allCases {
            check(empty.content(for: tab).isEmpty && empty.counts.count(tab) == 0, "empty \(tab.rawValue) tab")
            check(!tab.label.isEmpty && !tab.glyph.isEmpty, "tab label and glyph")
        }
        var model = EntityWorkspaceRules.build(entity: person, journal: sampleRows())
        model.links = LinksRules.parseSources([["src": "drive", "url": "https://example.test/sample"]])
        check(EntityWorkspaceRules.build(entity: EntityWorkspaceIdentity(), journal: [], remoteLinks: model.links).counts.total == 0
              && EntityWorkspaceRules.build(entity: EntityWorkspaceIdentity(), journal: [], remoteLinks: model.links).links.isEmpty,
              "no identity never exposes unrelated source results")
        model.promises = [EntityPromise(id: "one", what: "Sample task", who: "Hanna", app: "", when: 100, due: nil)]
        for tab in EntityWorkspaceTab.allCases {
            let content = model.content(for: tab)
            let total = content.journal.count + content.links.count + content.pictures.count + content.promises.count
            check(total == model.counts.count(tab), "\(tab.rawValue) count describes its visible content")
            switch tab {
            case .overview: check(content.journal == model.overview, "overview filtered content")
            case .calls: check(content.journal == model.calls, "calls filtered content")
            case .links: check(content.links == model.links, "links filtered content")
            case .pictures: check(content.pictures == model.pictures, "pictures filtered content")
            case .promises: check(content.promises == model.promises, "promises filtered content")
            }
        }
    }

    static func context() {
        check(EntityContextLevel.allCases.map(\.label) == ["L1 Name", "L2 One-line", "L3 Full pack"], "context level labels")
        check(EntityContextLevel.allCases.map(\.rawValue) == [1, 2, 3], "engine level values")
        let response: [String: Any] = ["found": 1, "name": "Sample canonical name", "text": "  A sample line.\n\n- Detail\n- Link  "]
        check(EntityWorkspaceRules.contextCopyText(response, entity: person, level: .name) == "Sample canonical name", "L1 canonical name only")
        check(EntityWorkspaceRules.contextCopyText(response, entity: person, level: .oneLine) == "A sample line. - Detail - Link", "L2 is one line")
        check(EntityWorkspaceRules.contextCopyText(response, entity: person, level: .fullPack) == "A sample line.\n\n- Detail\n- Link", "L3 paragraphs preserved")
        check(EntityWorkspaceRules.contextCopyText(["found": 0], entity: person, level: .name) == person.display, "L1 can copy selected name without a pack")
        for level in EntityContextLevel.allCases {
            check(EntityWorkspaceRules.contextCopyText(["error": "Context disabled"], entity: person, level: level).isEmpty, "errors never copied")
            if level != .name {
                check(EntityWorkspaceRules.contextCopyText(["found": 0], entity: person, level: level).isEmpty, "missing pack stays empty")
            }
        }
    }
}

// swiftc -parse-as-library app/LinksRules.swift tests/links_rules.swift -o app/build/links-rules-test && app/build/links-rules-test
// Synthetic values only; no files, services, clocks or live journal data are read.
import Foundation

@main
struct LinksRulesTests {
    static var checks = 0
    static var failures = 0
    static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        checks += 1
        if !condition() { failures += 1; print("FAIL: " + message) }
    }

    static func row(_ id: String, _ text: String, when: Double = 100, kind: String = "typed", clip: String = "text",
                    title: String = "", app: String = "Sample Notes", tags: [String] = [], file: String = "") -> LinkRowInput {
        LinkRowInput(id: id, kind: kind, clip: clip, text: text, title: title, app: app, when: when, tags: tags, filePath: file)
    }

    static func item(_ url: String, title: String = "", source: LinkSource = .mentioned, when: Double = 100,
                     mentions: Int = 1, tags: [String] = [], journal: String? = nil, file: String? = nil) -> LinkItem {
        LinkItem(id: "synthetic", url: url, normalizedURL: LinksRules.normalize(url), host: LinksRules.host(of: url),
                 title: title.isEmpty ? url : title, source: source, origin: "Sample Sender", when: when,
                 mentions: mentions, tags: tags, journalId: journal, filePath: file)
    }

    static func main() throws {
        normalization(); extraction(); merging(); filtering(); summaries(); formatting()
        check(LinkSource.allCases.map(\.label) == ["Copied", "Mentioned"], "source labels")
        check(Set(LinkSource.allCases.map(\.glyph)).isSubset(of: ["globe", "link", "mail", "chat", "file", "folder", "book"]), "existing glyph names")
        let encoded = try JSONEncoder().encode(LinkSource.allCases)
        let decoded = try JSONDecoder().decode([LinkSource].self, from: encoded)
        check(decoded == LinkSource.allCases, "source Codable round trip")
        print("links rules: \(checks) checks, \(failures) failures")
        exit(failures == 0 ? 0 : 1)
    }

    static func normalization() {
        let cases = [
            ("  HTTPS://WWW.EXAMPLE.TEST/  ", "https://www.example.test"),
            ("http://EXAMPLE.TEST/Guide/", "http://example.test/Guide/"),
            ("https://example.test/path.,);]>", "https://example.test/path"),
            ("https://example.test/wiki/Guide_(sample)).", "https://example.test/wiki/Guide_(sample)"),
            ("https://example.test/a%29", "https://example.test/a%29"),
            ("https://example.test/?utm_source=sample&x=1&utm_medium=chat&fbclid=abc&y=2", "https://example.test?x=1&y=2"),
            ("https://example.test/?GCLID=a&igshid=b&mc_cid=d&mc_eid=e&UTM_campaign=f", "https://example.test"),
            ("https://example.test/?ref=dev&utm_source=x", "https://example.test?ref=dev"),
            ("https://example.test/?%75tm_source=a&reference=keep&pref=keep&referral=keep", "https://example.test?reference=keep&pref=keep&referral=keep"),
            ("https://example.test/?q=a%2Fb%20c&tag=one&tag=two&sig=A+b%2Bc&utm_term=skip#Part", "https://example.test?q=a%2Fb%20c&tag=one&tag=two&sig=A+b%2Bc#Part"),
            ("https://example.test:8443/#section", "https://example.test:8443#section"),
            ("https://example.test/?flag=&fbclid=no", "https://example.test?flag="),
            ("https://xn--bcher-kva.example.test/page", "https://xn--bcher-kva.example.test/page"),
            ("https://example.test/?", "https://example.test"),
            ("https://example.test/?&x=1&&utm_source=a", "https://example.test?&x=1&"),
            ("not a URL", ""), ("https://", ""), ("javascript:alert(1)", ""),
            ("file:///tmp/synthetic.txt", ""), ("", "")
        ]
        for (raw, expected) in cases {
            let actual = LinksRules.normalize(raw)
            check(actual == expected, "normalize \(raw): got \(actual)")
            check(LinksRules.normalize(actual) == actual, "normalization is idempotent: \(raw)")
        }
        check(LinksRules.host(of: "HTTPS://WWW.EXAMPLE.TEST/a") == "example.test", "host without www")
        check(LinksRules.host(of: "https://docs.example.test:8443/a") == "docs.example.test", "host preserves subdomain, removes port")
        check(LinksRules.host(of: "bad input") == "", "invalid host")
        check(LinksRules.normalize("https://example.test/?q=one") != LinksRules.normalize("https://example.test/?q=two"), "meaningful query values stay distinct")
        check(LinksRules.normalize("http://example.test") != LinksRules.normalize("https://example.test"), "schemes stay distinct")
        check(LinksRules.normalize("https://example.test/#one") != LinksRules.normalize("https://example.test/#two"), "fragment routes stay distinct")
    }

    static func extraction() {
        let text = "Read <https://example.test/a>, [guide](https://example.test/wiki/Guide_(sample)).\n“HTTPS://docs.example.test/b?x=1&y=2”; and https://example.test/c!]"
        check(LinksRules.extractURLs(from: text) == ["https://example.test/a", "https://example.test/wiki/Guide_(sample)", "HTTPS://docs.example.test/b?x=1&y=2", "https://example.test/c"], "prose, Markdown, quotes and balanced brackets")
        check(LinksRules.extractURLs(from: "Sample 🌱 https://example.test/a\nhttps://example.test/b") == ["https://example.test/a", "https://example.test/b"], "Unicode before URL uses correct ranges")
        check(LinksRules.extractURLs(from: "https://example.test/a https://example.test/a").count == 2, "extractURLs preserves occurrences")
        check(LinksRules.extractURLs(from: "www.example.test mailto:sample@example.test ftp://example.test/a https://") == [], "only complete web URLs")
        check(LinksRules.extractURLs(from: "https://a.example.test/1, https://b.example.test/2") == ["https://a.example.test/1", "https://b.example.test/2"], "comma-separated URLs strip trailing comma")
        check(LinksRules.extractURLs(from: "Map https://example.test/at/50.45,30.52.") == ["https://example.test/at/50.45,30.52"], "internal comma preserved in path")
        let longPath = String(repeating: "a", count: 400)
        check(LinksRules.extractURLs(from: "Check https://example.test/" + longPath) == ["https://example.test/" + longPath], "long URLs extracted cleanly")
        let rows = [
            row("old", "https://example.test/guide?utm_source=copy", when: 100, kind: "copied", clip: "link", title: "Sample field guide", tags: ["Research", "Draft"]),
            row("new", "Read https://example.test/guide. Again https://example.test/guide?fbclid=sample", when: 300, title: "https://example.test/guide", app: "Sample Editor", tags: ["draft", "Review", ""]),
            row("voice", "See https://docs.example.test/notes", when: 200, kind: "voice", title: "Sample notes"),
            row("call", "Discuss https://example.test/guide", when: 150, kind: "call"),
            row("ignore", "https://ignore.example.test", kind: "image", clip: "image"),
            row("empty", "No links in this synthetic line")
        ]
        let links = LinksRules.extract(from: rows)
        check(links.count == 2, "extract excludes unsupported and empty rows")
        let guide = links[0]
        check(guide.url == "https://example.test/guide" && guide.normalizedURL == guide.url, "canonical URL in extracted item")
        check(guide.when == 300 && guide.source == .mentioned && guide.origin == "Sample Editor", "newest occurrence supplies provenance")
        check(guide.mentions == 3, "one mention per journal row")
        check(guide.title == "Sample field guide", "older descriptive title beats newest URL title")
        check(guide.tags == ["draft", "Review", "Research"], "unique merged tags, newest spelling first")
        check(guide.journalId == "new", "newest journal jump")
        check(guide.id == "url:https://example.test/guide", "stable canonical ID")
        check(links[1].source == .mentioned && links[1].when == 200, "voice URL and newest-first order")
        check(LinksRules.extract(from: [rows[0]])[0].source == .copied, "dedicated clip is copied")
        check(LinksRules.extract(from: [rows[0], rows[0]])[0].mentions == 1, "same journal row is not counted twice")
        for kind in ["draft", "drafts", "typed", "voice", "spoken", "said", "text", "call", "calls", "copied"] {
            check(LinksRules.extract(from: [row(kind, "https://example.test/" + kind, kind: kind)]).first?.source == .mentioned, "embedded URL in \(kind)")
        }
        let files = LinksRules.extract(from: [row("file", "", kind: "copied", clip: "file", file: "/tmp/synthetic/plan.pdf")])
        check(files.count == 1 && files[0].filePath == "/tmp/synthetic/plan.pdf", "local file-only clip")
        check(files[0].title == "plan.pdf" && files[0].source == .copied && files[0].host.isEmpty, "file fallback title and source")
        check(LinksRules.extract(from: []).isEmpty, "empty extraction")
    }

    static func merging() {
        let local = item("https://example.test/guide?utm_source=local", title: "Sample guide with details", source: .copied, when: 100, mentions: 2, tags: ["Research"], journal: "journal-1")
        let remote = item("HTTPS://EXAMPLE.TEST/guide?fbclid=sample", when: 500, mentions: 3, tags: ["research", "Team"])
        let merged = LinksRules.merge(local: [local], remote: [remote])
        check(merged.count == 1 && merged[0].mentions == 5, "merge combines mention counts across sources")
        check(merged[0].when == 500 && merged[0].source == .mentioned, "newest provenance")
        check(merged[0].title == "Sample guide with details" && merged[0].journalId == "journal-1", "remote merge preserves useful local title and journal jump")
        check(merged[0].tags == ["research", "Team"], "merge combines tags uniquely")
        check(merged[0].id == "url:https://example.test/guide", "canonical ID survives merge")
        check(LinksRules.merge(local: merged, remote: []) == merged, "remerge without new occurrences is stable")
        let files = LinksRules.merge(local: [item("", title: "Sample plan", source: .copied, when: 10, journal: "file-row", file: "/tmp/synthetic/plan.pdf")], remote: [
            item("", when: 20, file: "/tmp/synthetic/plan.pdf"), item("", when: 30, file: "/tmp/synthetic/other.pdf")])
        check(files.count == 2 && files[1].mentions == 2, "file-only dedup uses path")
        check(files[1].journalId == "file-row" && files[1].title == "Sample plan", "file dedup preserves journal jump and title")
        // Bare file names with different titles must NOT collapse into one row
        let attachments = LinksRules.merge(local: [item("", title: "January Invoice", when: 100, file: "invoice.pdf"),
                                                   item("", title: "February Invoice", when: 200, file: "invoice.pdf")], remote: [])
        check(attachments.count == 2, "distinct bare file names with the same name stay separate")
        let sorted = LinksRules.merge(local: [item("https://z.example.test", when: 5), item("https://a.example.test", when: 5)], remote: [item("https://new.example.test", when: 20)])
        check(sorted.map(\.host) == ["new.example.test", "a.example.test", "z.example.test"], "newest first, deterministic ties")
        check(LinksRules.merge(local: [item("https://example.test", when: .nan)], remote: []).first?.when == 0, "invalid timestamp cannot break sorting")
        check(LinksRules.merge(local: [item("", file: "  ")], remote: []).isEmpty, "empty targets ignored")
        check(LinksRules.merge(local: [], remote: []).isEmpty, "empty merge")
    }

    static func filtering() {
        let items = LinksRules.merge(local: [
            item("https://example.test/guide", title: "Sample Café Guide", source: .copied, tags: ["Research"]),
            item("https://docs.example.test/notes", title: "Sample Notes", source: .mentioned),
            item("", title: "Sample Plan", source: .copied, file: "/tmp/synthetic/plan.pdf")], remote: [])
        func matches(_ q: String = "", _ s: LinkSource? = nil, _ h: String? = nil) -> [LinkItem] {
            LinksRules.filter(items, query: q, source: s, host: h)
        }
        check(matches() == items, "empty filters preserve order")
        check(matches("  CAFE research ").count == 1, "case and accent insensitive multiword query matches tags")
        check(matches("sender", .mentioned).count == 1, "origin searchable with source intersection")
        check(matches("notes", .copied).isEmpty, "query and source both required")
        check(matches("", nil, "WWW.EXAMPLE.TEST").count == 1, "host filter normalizes www and case")
        check(matches("", nil, "https://example.test/").count == 1, "host filter accepts a web address")
        check(matches("", .mentioned, "example.test").isEmpty, "host filter is exact, not subdomain substring")
        check(matches("synthetic plan.pdf", .copied).count == 1, "file path searchable")
        check(matches("example.test/guide").count == 1, "URL searchable")
        check(matches("drive").isEmpty, "absent word does not match")
        check(matches("sample missing").isEmpty, "all query words required")
        check(LinksRules.filter([], query: "sample", source: nil, host: nil).isEmpty, "empty filtering")
    }

    static func summaries() {
        let items = [item("https://example.test/a", source: .copied, mentions: 10), item("https://example.test/b", source: .mentioned),
                     item("https://z.example.test", source: .mentioned), item("https://a.example.test", source: .copied),
                     item("", source: .copied, file: "sample.pdf")]
        let hosts = LinksRules.topHosts(items)
        check(hosts.map(\.host) == ["example.test", "a.example.test", "z.example.test"], "hosts sorted by count, ties alphabetically")
        check(hosts.map(\.count) == [2, 1, 1], "host counts items rather than mentions; excludes files")
        check(LinksRules.topHosts(items, limit: 1).map(\.host) == ["example.test"], "host limit")
        check(LinksRules.topHosts(items, limit: 0).isEmpty && LinksRules.topHosts(items, limit: -1).isEmpty, "nonpositive host limit")
        check(LinksRules.topHosts([]).isEmpty, "empty hosts")
        check(LinksRules.topHosts((0..<12).map { item("https://site\($0).example.test") }).count == 10, "default host limit")
        let counts = LinksRules.sourceCounts(items)
        check(counts[.copied] == 3 && counts[.mentioned] == 2, "every source counted")
        check(LinksRules.sourceCounts([]).values.allSatisfy { $0 == 0 }, "empty counts include zeros")
    }

    static func formatting() {
        check(LinksRules.markdown(item("https://example.test/guide", title: "Sample guide")) == "[Sample guide](https://example.test/guide)", "Markdown title and URL")
        check(LinksRules.markdown(item("https://example.test/guide")) == "https://example.test/guide", "bare URL without a title")
        check(LinksRules.markdown(item("https://example.test", title: "HTTPS://EXAMPLE.TEST/")) == "https://example.test", "equivalent URL title is not repeated")
        check(LinksRules.markdown(item("https://example.test/a_(b)", title: "Sample [plan]")) == "[Sample \\[plan\\]](https://example.test/a_%28b%29)", "Markdown escapes label and destination brackets")
        check(LinksRules.markdown(item("", title: "Sample file", file: "/tmp/synthetic/sample.pdf")) == "/tmp/synthetic/sample.pdf", "file without URL copies path")
        let now = 2_000_000_000.0
        let cases: [(Double, String)] = [(0, "Just now"), (59, "Just now"), (60, "1m ago"), (3599, "59m ago"),
            (3600, "1h ago"), (86399, "23h ago"), (86400, "1d ago"), (7 * 86400, "1w ago"),
            (30 * 86400, "1mo ago"), (365 * 86400, "1y ago"), (2 * 365 * 86400, "2y ago")]
        for (age, expected) in cases { check(LinksRules.relativeTime(now - age, now: now) == expected, "relative time at \(age) seconds") }
        check(LinksRules.relativeTime(now + 60, now: now) == "In 1m", "future timestamp")
        check(LinksRules.relativeTime(0, now: now) == "Unknown time", "missing timestamp")
        check(LinksRules.relativeTime(-1, now: now) == "Unknown time", "negative timestamp")
        check(LinksRules.relativeTime(.nan, now: now) == "Unknown time", "NaN timestamp")
        check(LinksRules.relativeTime(now, now: .infinity) == "Unknown time", "infinite clock")
    }
}

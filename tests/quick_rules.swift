import Foundation

// swiftc -O -parse-as-library app/QuickRules.swift app/PictureLookRules.swift app/ClipRules.swift tests/quick_rules.swift -o app/build/quick-rules-test && app/build/quick-rules-test
// The Quick panel's rules with made-up rows: fold, filter tiers, merge and pins, what the clipboard keeps, secrets,
// the instant rewrites, the time in a row, the global key; and how long a filter takes over 1,000 and 3,000 rows.
@main
struct QuickRuleChecks {
    static var failures = 0
    static func check(_ ok: Bool, _ what: String) { if !ok { print("FAIL: " + what); failures += 1 } }

    static func main() {
        keySequences(); clips(); fold(); filter(); rank(); merge(); keep(); secrets(); rewrites(); times(); keys(); picker()
        // timing is not a release gate (a busy Mac failed releases on it): BENCH=1 runs it on its own
        if ProcessInfo.processInfo.environment["BENCH"] == "1" { speed() }
        if failures > 0 { print("\(failures) failed"); exit(1) }
        print("quick rules: all passed")
    }

    static func item(_ k: QuickKind, _ t: String, _ at: Double, app: String = "Sample") -> QuickItem { QuickItem(kind: k, text: t, app: app, at: at) }

    /// Made-up event sequences through the two keys (fix round: ⌃⌥V never opened the panel directly).
    /// Round three: what a copy is, links, files, actions, stored pictures (made-up values only).
    static func clips() {
        let k = ClipRules.kind
        check(k(["public.utf8-plain-text"], "hello there") == .text, "plain text")
        check(k(["public.utf8-plain-text"], "https://example.com/a/b?x=1") == .link, "a link")
        check(k(["public.utf8-plain-text"], "see https://example.com") == .text, "a sentence with a link stays text")
        check(k(["public.utf8-plain-text"], "ftp://example.com/a") == .text, "ftp is not a link")
        check(k(["public.file-url", "public.utf8-plain-text", "public.tiff"], "drawings.pdf") == .file, "Finder copy is a file")
        check(k(["public.png"], nil) == .image, "a picture")
        check(k(["public.tiff", "public.utf8-plain-text"], "caption") == .text, "a picture with text keeps the text")
        check(ClipRules.rich(["public.rtf", "public.utf8-plain-text"]), "rich text flagged")
        let p = ClipRules.parts("https://www.example.com/plans/station%20one?utm_source=x")
        check(p.host == "example.com" && p.last == "station one", "host and last part: \(p)")
        let u = ClipRules.untracked("https://example.com/a?id=4&utm_source=news&fbclid=abc&utm_medium=mail")
        check(u == "https://example.com/a?id=4", "trackers dropped: \(u)")
        check(ClipRules.untracked("https://example.com/a?utm_source=x") == "https://example.com/a", "no empty query")
        check(ClipRules.markdown("https://example.com/plans/station", title: "Station [draft]") == "[Station (draft)](https://example.com/plans/station)", "markdown with title")
        check(ClipRules.markdown("https://example.com/plans/station", title: "") == "[example.com · station](https://example.com/plans/station)", "markdown without title")
        let f = ClipRules.fileParts("/Volumes/home/me/Desktop/drawings.pdf", home: "/Volumes/home/me")
        check(f.name == "drawings.pdf" && f.folder == "~/Desktop", "file parts: \(f)")
        check(ClipRules.bytes(482_113) == "482 KB" && ClipRules.bytes(912) == "912 B" && ClipRules.bytes(2_400_000) == "2.4 MB", "sizes")
        check(ClipRules.firstTarget(in: "the plan is at (https://example.com/p), thanks")?.value == "https://example.com/p", "first link in text")
        check(ClipRules.firstTarget(in: "saved to ~/Desktop/plan.pdf today")?.kind == .file, "first path in text")
        check(ClipRules.firstTarget(in: "a / b and 1/2") == nil, "no target")
        check(ClipRules.actions(.link).count == 4 && ClipRules.actions(.image).count == 4 && ClipRules.actions(.file).count == 4, "keys per kind")
        check(ClipRules.actions(.text, target: .link).map(\.id) == ["open", "markdown", "untracked"], "text holding a link")
        check(ClipRules.actions(.text).isEmpty, "plain text has no extra keys")
        check(ClipRules.searchExtra(.link, text: "https://example.com/plans/station", title: "Station plans", ocr: "").contains("plans station Station plans"), "link search")
        check(ClipRules.searchExtra(.file, text: "/Volumes/home/me/Desktop/drawings.pdf", title: "", ocr: "").contains("drawings.pdf"), "file search")
        let st: [ClipRules.Stored] = [.init(name: "a", bytes: 50, t: 1), .init(name: "b", bytes: 50, t: 2), .init(name: "c", bytes: 50, t: 3), .init(name: "x", bytes: 5, t: 9)]
        check(Set(ClipRules.prune(st, live: ["a", "b", "c"], total: 120)) == ["x", "a"], "prune: orphan, then oldest over the cap")
        check(ClipRules.prune(st, live: ["a", "b", "c", "x"], total: 1000).isEmpty, "prune: nothing under the cap")
        let d1 = Data([1, 2, 3]), d2 = Data([1, 2, 4])
        check(ClipRules.clipName(d1) == ClipRules.clipName(d1) && ClipRules.clipName(d1) != ClipRules.clipName(d2), "picture names")
        check(ClipRules.dedupeKey(text: "Image · 4 × 3", clip: "a") != ClipRules.dedupeKey(text: "Image · 4 × 3", clip: "b"), "two pictures of one size")
    }

    static func keySequences() {
        let V = 9, A = 0, M = 46
        func machine() -> QuickKeys { var k = QuickKeys(panelKey: QuickRules.hotkey("⌃⌥V"), switchKey: QuickRules.hotkey("⌘⇧V")); k.quickForm = true; return k }   // the held small list (switchQuickForm)
        func run(_ k: inout QuickKeys, _ es: [QuickKeyEvent]) -> [QuickKeyAction] { es.flatMap { k.route($0) } }
        var k = machine()
        check(run(&k, [.flags("⌃"), .flags("⌃⌥"), .down(V, "⌃⌥"), .up(V, "⌃⌥"), .flags("⌃"), .flags("")]) == [.pass, .pass, .togglePanel, .pass, .pass, .pass],
              "⌃⌥V down/up: the panel, nothing else")
        k = machine()
        check(run(&k, [.flags("⌘"), .flags("⌘⇧"), .down(V, "⌘⇧"), .up(V, "⌘⇧"), .flags("⇧"), .flags("")]) == [.pass, .pass, .openSwitch, .pass, .put, .pass],
              "⌘⇧V tap and release: open, then put on the release, even before the strip is drawn")
        k = machine()
        check(run(&k, [.down(V, "⌘⇧"), .down(V, "⌘⇧"), .down(V, "⌘⇧"), .flags("")]) == [.openSwitch, .step(1), .step(1), .put], "⌘⇧V, V, V, release")
        k = machine()
        check(run(&k, [.down(V, "⌘⇧"), .down(A, "⌘⇧")]) == [.openSwitch, .toPanel(A)] && !k.switching, "⌘⇧ held, a letter: into the panel")
        // 17 November: ⌘⇧V opens the full picker at once (the default); ⌘⇧V again moves down; the app gets the rest
        func at(_ e: QuickKeyEvent, _ t: Double) -> QuickKeyEvent { var e = e; e.at = t; return e }
        var f = QuickKeys(panelKey: nil, switchKey: QuickRules.hotkey("⌘⇧V"))
        check(run(&f, [.flags("⌘"), .flags("⌘⇧"), .down(V, "⌘⇧")]) == [.pass, .pass, .openFull] && !f.switching, "⌘⇧V: the full picker, nothing held")
        check(run(&f, [.down(V, "⌘⇧", repeat: true)]) == [.swallow], "a held ⌘⇧V opens it once")
        f.panelOpen = true
        check(run(&f, [.down(V, "⌘⇧"), .down(V, "⌘⇧")]) == [.next, .next], "⌘⇧V again while open: the next row")
        check(run(&f, [.down(125, "⌘⇧"), .down(36, ""), .flags("")]) == [.pass, .pass, .pass], "↓ and ↵ go to the picker's own keys, a release puts nothing")
        f.panelOpen = false
        f.armSwap(until: 200)
        check(run(&f, [at(.down(V, "⌘⇧"), 199)]) == [.swap], "⌘⇧V within 2 s of a paste: the swap first")
        check(run(&f, [at(.down(V, "⌘⇧"), 201)]) == [.openFull], "later: the picker again")
        k = QuickKeys(panelKey: nil, switchKey: QuickRules.hotkey("⌘⇧V")); k.quickForm = true
        check(run(&k, [.down(V, "⌘⇧"), .down(49, "⌘⇧")]) == [.openSwitch, .toPanel(49)] && !k.switching, "⌘⇧V held, Space: the full picker")
        check(run(&k, [.down(49, "⌘⇧")]) == [.pass], "⌘⇧Space without the switcher is the app's")
        check(run(&k, [.down(9, "⌃⌥")]) == [.pass], "no full-picker key: ⌃⌥V is the app's")
        k = machine()
        check(run(&k, [.down(V, "⌘⇧"), .flags("⌘"), .down(V, "⌘"), .flags("")]) == [.openSwitch, .pass, .step(1), .put], "⇧ let go before ⌘: still held until ⌘ goes")
        k = machine()
        check(run(&k, [.down(V, "⌘⇧"), .flags("⇧"), .flags("")]) == [.openSwitch, .put, .pass], "⌘ let go before ⇧: put at once")
        k = machine()
        check(run(&k, [.down(V, "⌘⇧"), .down(V, "⌘⇧", repeat: true), .down(53, "⌘⇧"), .flags("")]) == [.openSwitch, .swallow, .cancel, .pass], "a held V does not step; Esc cancels, the release puts nothing")
        // the old bug: the release was missed (no flags event before the next key); ⌃⌥V must still open the panel
        k = machine()
        check(run(&k, [.down(V, "⌘⇧"), .down(V, "⌃⌥")]) == [.openSwitch, .put, .togglePanel], "a missed release ends the switcher, then ⌃⌥V opens the panel")
        k = machine()
        check(run(&k, [.down(V, "⌘⇧"), .down(A, "")]) == [.openSwitch, .put, .pass], "a missed release: a plain letter goes to the app, not into the panel")
        // exact modifiers
        k = machine()
        check(run(&k, [.down(V, "⌘"), .down(V, "⌃⌥⇧"), .down(V, "⌘⇧⌥"), .down(V, "⌃")]) == [.pass, .pass, .pass, .pass], "⌘V, ⌃⌥⇧V, ⌘⇧⌥V, ⌃V: untouched")
        k = machine(); k.panelOpen = true
        check(run(&k, [.down(V, "⌘⇧")]) == [.pass], "no switcher while the panel is open")
        // a Ukrainian layout: the same key codes (В on the V key, Ф on A), so the same actions
        k = machine()
        check(run(&k, [.down(V, "⌘⇧"), .down(V, "⌘⇧"), .down(M, "⌘⇧")]) == [.openSwitch, .step(1), .toPanel(M)], "by key code, whatever the layout")
        k = machine()
        check(run(&k, [.down(V, "⌃⌥")]) == [.togglePanel], "⌃⌥V on any layout")
        // wire round: ← → step through the chosen clip's written forms
        let L = 123, R = 124
        k = machine(); k.panelOpen = true; k.forms = 3
        check(run(&k, [.down(R), .down(R), .down(L)]) == [.form(1), .form(1), .form(-1)], "panel, a clip with forms: → → ← step forms")
        check(run(&k, [.down(R, "⇧"), .down(R, "⌘")]) == [.pass, .pass], "⇧→ and ⌘→ are not form steps")
        k = machine(); k.panelOpen = true; k.forms = 0
        check(run(&k, [.down(R), .down(L)]) == [.pass, .pass], "a clip without forms: the arrows as before")
        k = machine(); k.forms = 2
        check(run(&k, [.down(R)]) == [.pass], "panel closed: → goes to the app")
        k = machine(); k.forms = 2
        check(run(&k, [.down(V, "⌘⇧"), .down(R, "⌘⇧"), .down(V, "⌘⇧"), .down(L, "⌘⇧"), .flags("")]) == [.openSwitch, .form(1), .step(1), .form(-1), .put],
              "switcher with forms: → ← step forms, V the next copy, the release puts")
        k = machine(); k.forms = 0
        check(run(&k, [.down(V, "⌘⇧"), .down(R, "⌘⇧"), .down(L, "⌘⇧"), .flags("")]) == [.openSwitch, .step(1), .step(-1), .put], "switcher without forms: → ← move copies as before")
        check(QuickRules.stepForm(0, by: 1, forms: 3) == 1 && QuickRules.stepForm(3, by: 1, forms: 3) == 0 && QuickRules.stepForm(0, by: -1, forms: 3) == 3,
              "forms wrap: as copied, 1, 2, 3, as copied")
        check(QuickRules.stepForm(2, by: 1, forms: 0) == 0, "no forms: always as copied")
    }

    static func fold() {
        check(QuickRules.fold("Їжак  Ґанок") == QuickRules.fold("іжак ганок"), "Ukrainian marks fold both ways")
        check(QuickRules.fold("Café\nCRÈME") == "cafe creme", "Latin accents, case and line breaks fold")
        check(QuickRules.fold("пʼять") == QuickRules.fold("п'ять"), "the apostrophe folds")
        let it = item(.copied, "Зустріч у четвер о 10:00", 0)
        check(it.first == "Зустріч у четвер о 10:00" && !it.single && item(.copied, "https://example.com/a", 0).single, "first line; only a line with no spaces is cut in the middle")
        let multi = item(.typed, "\n  first line  \nsecond", 0)
        check(multi.first == "first line" && !multi.single, "first line with words, several lines")
    }

    static func filter() {
        let rows = [item(.copied, "Plan for the station visit", 50), item(.typed, "the visit plan, then the station", 40),
                    item(.voice, "Нотатка про вокзал і план", 30), item(.copied, "https://example.com/a?b=1", 20, app: "Safari")]
        check(QuickRules.filter(rows, query: "", kind: nil) == [0, 1, 2, 3], "no query: all, in order")
        check(QuickRules.filter(rows, query: "", kind: .copied) == [0, 3], "kind filter")
        check(QuickRules.filter(rows, query: "station visit", kind: nil) == [0, 1], "whole query first, then all words")
        check(QuickRules.filter(rows, query: "STATION", kind: nil) == [0, 1], "case-insensitive")
        check(QuickRules.filter(rows, query: "ВОКЗАЛ", kind: nil) == [2], "Ukrainian, case-insensitive")
        check(QuickRules.filter(rows, query: "safari", kind: nil) == [3], "the app is searched too")
        check(QuickRules.filter(rows, query: "nothing like it", kind: nil).isEmpty, "no match")
        var pinned = rows; pinned[3].pinned = true
        check(QuickRules.filter(pinned, query: "a", kind: nil).first == 3, "pinned matches first")
    }

    /// Five made-up cases; the table goes into docs/rounds/2026-11-14-quick.md.
    static func rank() {
        let now = 1_000_000_000.0, h = 3600.0, d = 86400.0
        func top(_ rows: [QuickItem], _ q: String, _ u: QuickUses) -> String {
            QuickRules.filter(rows, query: q, kind: nil, uses: u, now: now).first.map { rows[$0].text } ?? "-"
        }
        func s(_ it: QuickItem, _ q: String, _ u: QuickUses) -> String {
            let w = Array(QuickRules.fold(q).utf8)
            let m = it.key.withUnsafeBufferPointer { k in w.withUnsafeBufferPointer { memmem(k.baseAddress, k.count, $0.baseAddress, $0.count) != nil } }
                ? (it.head.starts(with: w) ? 4.0 : 3.0) : 1.5
            return String(format: "%.2f", QuickRules.score(match: m, at: it.at, now: now, item: u.items[it.id] ?? [], app: u.apps[it.appID] ?? []))
        }
        var table: [String] = []
        // 1. pasted three times this week vs a one-off copy an hour old
        let a1 = item(.copied, "invoice template for the client", now - 5 * d), b1 = item(.copied, "the invoice was paid", now - h)
        var u1 = QuickUses(); for t in [1.0, 3, 5] { QuickRules.used(&u1, a1, at: now - t * d) }
        check(top([b1, a1], "invoice", u1) == a1.text, "three pastes this week beat a newer one-off copy")
        table.append("| 1 | `invoice` | copied 5 d ago, put in 3× this week | copied 1 h ago, never put in | A \(s(a1, "invoice", u1)) · B \(s(b1, "invoice", u1)) | A |")
        // 2. one paste a month ago vs the same newer copy
        var u2 = QuickUses(); QuickRules.used(&u2, a1, at: now - 30 * d)
        check(top([b1, a1], "invoice", u2) == b1.text, "an old single paste does not beat a fresh copy")
        table.append("| 2 | `invoice` | copied 5 d ago, put in once 30 d ago | copied 1 h ago | A \(s(a1, "invoice", u2)) · B \(s(b1, "invoice", u2)) | B |")
        // 3. the whole query vs only its words, same age
        let a3 = item(.typed, "see you at the station tomorrow", now - 2 * h), b3 = item(.typed, "tomorrow I go to the station", now - 2 * h)
        check(top([b3, a3], "station tomorrow", QuickUses()) == a3.text, "the whole query beats its words")
        table.append("| 3 | `station tomorrow` | holds the phrase, 2 h | holds both words apart, 2 h | A \(s(a3, "station tomorrow", QuickUses())) · B \(String(format: "%.2f", QuickRules.score(match: 1.5, at: b3.at, now: now, item: [], app: []))) | A |")
        // 4. equal matches; one from an app the user puts things in from often
        let a4 = item(.copied, "room 4.12 second floor", now - 3 * h, app: "Mail"), b4 = item(.copied, "room 2.01 ground floor", now - 2 * h, app: "Notes")
        var u4 = QuickUses(); for k in 0..<6 { QuickRules.used(&u4, item(.copied, "other mail line \(k)", now - d, app: "Mail"), at: now - Double(k) * d) }
        check(top([b4, a4], "room", u4) == a4.text, "the app he pastes from often tips an equal match")
        table.append("| 4 | `room` | from Mail (6 puts from Mail this week), 3 h | from Notes, 2 h | A \(s(a4, "room", u4)) · B \(s(b4, "room", u4)) | A |")
        // 5. starts with the query but 3 days old vs the query in the middle, fresh
        let a5 = item(.voice, "budget notes for Thursday", now - 3 * d), b5 = item(.voice, "send the budget today", now - h)
        check(top([a5, b5], "budget", QuickUses()) == b5.text, "fresh beats an old start-of-line match")
        table.append("| 5 | `budget` | starts with it, 3 d | in the middle, 1 h | A \(s(a5, "budget", QuickUses())) · B \(s(b5, "budget", QuickUses())) | B |")
        print("| case | query | A | B | score | first |\n|---|---|---|---|---|---|\n" + table.joined(separator: "\n"))
        // ids stay the same across runs, and the store keeps numbers and ids only
        check(QuickRules.hash("x") == QuickRules.hash("x") && QuickRules.hash("x") != QuickRules.hash("y"), "hash")
        var u = QuickUses(); for k in 0..<30 { QuickRules.used(&u, a1, at: Double(k)) }
        check(u.items[a1.id]?.count == 20 && QuickUses(u.json) == u, "last 20 times; JSON round trip")
    }

    static func merge() {
        let rows = [item(.copied, "same", 10), item(.copied, "other", 20), item(.copied, "same", 30), item(.typed, "same", 5)]
        let m = QuickRules.merge(rows, pins: [])
        check(m.map(\.text) == ["same", "other", "same"] && m.map(\.at) == [30, 20, 5], "a repeated copy moves to the top, once")
        let pins = [QuickPin(kind: .copied, text: "other", app: "Sample", at: 20), QuickPin(kind: .voice, text: "kept pin", app: "", at: 1)]
        let p = QuickRules.merge(rows, pins: pins)
        check(p.map(\.text) == ["other", "kept pin", "same", "same"] && p[0].pinned && p[1].pinned && !p[2].pinned, "pins on top, in pin order, not twice")
        check(QuickPin(QuickPin(kind: .typed, text: "x", app: "A", at: 2).json) == QuickPin(kind: .typed, text: "x", app: "A", at: 2), "pin round trip")
    }

    static func keep() {
        let now = 100.0 * 86400
        let rows: [(t: Double, text: String)] = [(now - 40 * 86400, "old"), (now - 10, "a"), (now - 9, "b"), (now - 8, "a"), (now - 7, "c")]
        check(QuickRules.keepClips(rows, now: now, max: 1000, days: 30) == [2, 3, 4], "old ones go, the newest of a repeat stays")
        check(QuickRules.keepClips(rows, now: now, max: 2, days: 30) == [3, 4], "at most max, the newest")
        check(QuickRules.keepClips(rows, now: now, max: 10, days: 0).count == 4, "days 0: no age limit")
        check(QuickRules.keepClips(rows, now: now, max: 10, days: 30, secret: { $0 == "b" }) == [3, 4], "secrets go")
    }

    static func secrets() {
        let rules = QuickRules.secretRules(QuickRules.defaultSecrets)
        check(rules.count == QuickRules.defaultSecrets.count, "every default pattern compiles")
        // made-up values, built at run time so no scanner mistakes this file for a real key
        let key = "sk-" + String(repeating: "Ab3d", count: 8)
        let card = String(repeating: "4242 ", count: 3) + "4242"
        check(QuickRules.isSecret(key, rules), "an API key")
        check(QuickRules.isSecret("token = " + String(repeating: "x9", count: 6), rules), "key = value")
        check(QuickRules.isSecret("Card: " + card, rules), "a card number that passes Luhn")
        check(!QuickRules.isSecret("Order 1234 5678 9012 3456", rules), "an order number that fails Luhn")
        check(QuickRules.isSecret("481 516", rules) && QuickRules.isSecret("  271828 ", rules), "a one-time code alone")
        check(!QuickRules.isSecret("Meet at 10:00, room 2048", rules), "an ordinary line")
        check(!QuickRules.isSecret("https://example.com/docs/d/" + String(repeating: "aB1", count: 15) + "/edit", rules), "a document link stays")
        check(!QuickRules.isSecret("a-long-article-slug-about-the-2026-station-plans", rules), "a slug stays")
        check(QuickRules.isSecret(String(repeating: "Zq7", count: 14), rules), "a bare token line")
        check(!QuickRules.isSecret("2026", rules), "a year stays")
    }

    static func rewrites() {
        let link = "https://example.com/p?id=7&utm_source=x&utm_medium=y&fbclid=z#top"
        check(QuickRules.cleanLink(link) == "https://example.com/p?id=7#top", "tracking off, the rest stays")
        check(QuickRules.cleanLink("https://example.com/p?utm_source=x") == "https://example.com/p", "no parameters left")
        check(QuickRules.plain("**Bold** and `code`\u{200B} [site](https://example.com/?si=abc)  \n# Head") == "Bold and code site (https://example.com/)\nHead",
              "plain: marks, invisible characters, links, headings")
        check(QuickRules.plain("2 * 3 * 4") == "2 * 3 * 4", "plain: lone stars stay")
        check(QuickRules.oneLine("first\n\n  second  line\nthird") == "first second line third", "one line")
        check(QuickRules.quote("one\n\ntwo\n") == "> one\n>\n> two", "as a quote")
        check(QuickRules.local("nope", "x") == nil && QuickRules.local("quote", "x") == "> x", "local by id")
    }

    static func times() {
        check(QuickRules.ago(100, now: 130) == "now", "now")
        check(QuickRules.ago(0, now: 300) == "5m" && QuickRules.ago(0, now: 7200) == "2h" && QuickRules.ago(0, now: 3 * 86400) == "3d", "m h d")
        check(QuickRules.ago(0, now: 200 * 86400) == "1.01", "old: day.month")
    }

    static func keys() {
        check(QuickRules.hotkey("⌃⌥V") == QuickHotkey(code: 9, ctrl: true, alt: true, cmd: false, shift: false), "the suggested key")
        check(QuickRules.defaultKey == "" && QuickRules.hotkey(QuickRules.defaultKey) == nil, "keys round two: no full-picker key by default")
        check(QuickRules.hotkey(QuickRules.suggestedKey) != nil, "⌃⌥V can still be set")
        check(QuickRules.hotkey("ctrl+opt+v") == QuickRules.hotkey("⌃⌥V"), "written in words")
        check(QuickRules.hotkey("⌃⌥Space") == nil && QuickRules.hotkey("⌘Space") == nil, "reserved keys are never taken")
        check(QuickRules.hotkey("⌘⇧Space") != nil, "another Space key is fine")
        check(QuickRules.hotkey("") == nil && QuickRules.hotkey("V") == nil && QuickRules.hotkey("⇧V") == nil, "off, or no ⌃ ⌥ ⌘")
        check(QuickRules.hotkey("⌃⌥Ж") == nil, "unknown key")
    }

    /// The picker round: the quick form's rows, its step, the buttons on the foot, the row's second line.
    static func picker() {
        var pinned = item(.copied, "pinned copy", 50); pinned.pinned = true
        let rows = [pinned, item(.copied, "newest", 40), item(.typed, "typed", 39),
                    QuickItem(kind: .copied, text: "Image · 4 × 3", app: "Sample", at: 38, image: true, picture: "c-x.png"),
                    item(.copied, "b", 37), item(.voice, "said", 36), item(.copied, "c", 35), item(.copied, "d", 34), item(.copied, "e", 33), item(.copied, "f", 32)]
        check(QuickRules.quickRows(rows, count: 5) == [1, 4, 6, 7, 8], "quick form: the five newest copies, no pin, picture, typed or voice")
        check(QuickRules.quickRows([], count: 5).isEmpty && QuickRules.quickRows(rows, count: 2) == [1, 4], "quick form: none, or fewer")
        check(QuickRules.wrap(4, by: 1, count: 5) == 0 && QuickRules.wrap(0, by: -1, count: 5) == 4 && QuickRules.wrap(1, by: 1, count: 5) == 2, "quick step wraps both ways")
        check(QuickRules.wrap(3, by: 1, count: 0) == 0, "quick step with no rows")

        func ids(_ g: [[QuickRules.PickerButton]]) -> [[String]] { g.map { $0.map(\.id) } }
        let text = QuickRules.PickerRow()
        check(ids(QuickRules.buttons(text, quick: false)) == [["put", "copy"], ["rewrite", "pick"], ["pin", "remove"]], "a text: paste, copy | rewrite, pick | pin, remove")
        var formed = text; formed.forms = 3
        check(ids(QuickRules.buttons(formed, quick: false))[1] == ["form", "rewrite", "pick"], "a text with forms: ← → first in its group")
        var linkIn = text; linkIn.target = .link
        check(ids(QuickRules.buttons(linkIn, quick: false))[2] == ["open", "markdown", "untracked"], "a text holding a link: the link's keys")
        let link = QuickRules.PickerRow(clip: .link)
        check(ids(QuickRules.buttons(link, quick: false)) == [["put", "copy"], ["rewrite"], ["open", "markdown", "untracked"], ["pin", "remove"]], "a link: no Pick parts")
        let file = QuickRules.PickerRow(clip: .file)
        check(ids(QuickRules.buttons(file, quick: false)) == [["put"], ["reveal", "copyFile", "path"], ["pin", "remove"]], "a file: paste, reveal, copy file, copy path")
        check(QuickRules.buttons(file, quick: false)[1].map(\.key) == ["⌘R", "⌘C", "⌥⌘C"], "a file's keys as ClipRules has them")
        let pic = QuickRules.PickerRow(clip: .image, image: true, picture: true)
        check(ids(QuickRules.buttons(pic, quick: false)) == [["put", "withText", "copy"], ["text", "save"], ["pin", "remove"]], "a picture: paste, with text, copy | copy text, save")
        let sized = QuickRules.PickerRow(clip: .image, image: true, picture: false)
        check(ids(QuickRules.buttons(sized, quick: false)) == [["pin", "remove"]], "a picture kept as its size only: pin and remove")
        check(ids(QuickRules.buttons(nil, quick: false)) == [["close"]], "nothing chosen: close")
        // clip kinds round (17 November 2026): formatted text: ↵ puts the form shown ("With formatting", or "Text" via ← →); several files; a PDF
        var rich = text; rich.formatted = true; rich.shape = .rich
        check(ids(QuickRules.buttons(rich, quick: false))[0] == ["put", "copy"], "formatted text: paste the form shown, copy; no ⇧↵ (key map F3)")
        check(QuickRules.buttons(rich, quick: false)[0].map(\.key) == ["↵", "⌘C"], "formatted text: ↵ only, ⇧↵ is for pictures")
        var richForms = rich; richForms.forms = 1
        check(QuickRules.buttons(richForms, quick: false).joined().contains { $0.key == "← →" }, "formatted text: its \"Text\" form is on ← →")
        var files = file; files.shape = .files
        check(QuickRules.buttons(files, quick: false)[0].first?.word == "Paste files", "several files: paste files")
        var pdf = pic; pdf.shape = .pdf
        check(QuickRules.buttons(pdf, quick: false)[0].first?.word == "Paste PDF", "PDF data: paste PDF")
        let shaped = QuickItem(kind: .copied, text: "#1E90FF", app: "Sample", at: 1, shape: .color, note: "#1E90FF")
        check(shaped.shape == .color && shaped.id == QuickItem(kind: .copied, text: "#1E90FF", app: "Sample", at: 1).id, "a shape keeps the row's id")
        check(QuickItem(kind: .copied, text: "plain", app: "Sample", at: 1).shape == nil, "an old row has no shape")
        check(QuickRules.buttons(text, quick: false).flatMap { $0 }.filter(\.primary).map(\.id) == ["put"], "one main button")
        var pinnedRow = text; pinnedRow.pinned = true
        check(QuickRules.buttons(pinnedRow, quick: false).last?.first?.word == "Unpin", "a pinned row says unpin")
        check(ids(QuickRules.buttons(text, quick: true)) == [["put"], ["next"], ["search", "close"]], "quick: let go, next, search, close")
        check(ids(QuickRules.buttons(formed, quick: true))[1] == ["next", "form"], "quick with forms: ← → too")
        check(QuickRules.buttons(text, quick: true)[0][0].key == "⌘" && QuickRules.buttons(nil, quick: true)[0][0].primary == false, "quick: ⌘ under the paste")
        check(ids(QuickRules.buttons(text, quick: false, rework: true)) == [["run"], ["list"]], "rewrite menu")
        check(ids(QuickRules.buttons(text, quick: false, rework: true, result: true)) == [["put", "copy"], ["back", "list"]], "rewrite result")
        // every key on a button is one the picker reads (Quick.key and QuickKeys.route)
        let known: Set<String> = ["↵", "⇧↵", "⌘C", "⌥⌘C", "← →", "⇥", "⌘E", "⌘P", "⌘⌫", "⌘O", "⌘M", "⌘T", "⌘R", "⌘S", "⌫", "esc", "⌘", "V", "A–Z"]
        for r in [text, formed, linkIn, link, file, pic, sized] {
            for b in QuickRules.buttons(r, quick: false).flatMap({ $0 }) + QuickRules.buttons(r, quick: true).flatMap({ $0 }) {
                check(known.contains(b.key), "a known key: \(b.key) on \(b.id)")
                check(!b.glyph.isEmpty && b.glyph != "more", "a glyph for \(b.id)")
            }
        }
        check(QuickRules.meta(app: "Safari", at: 0, now: 240, extra: ["example.com"]) == "Safari · 4m · example.com", "the second line")
        check(QuickRules.meta(app: "", at: 0, now: 30, extra: ["", "2 KB"]) == "now · 2 KB", "the second line without an app")
    }

    /// Made-up rows; each key of a typed query filters the whole list again, as the panel does.
    static func speed() {
        let words = ["план", "зустріч", "вокзал", "station", "drawings", "четвер", "link", "notes", "кава", "report", "Київ", "draft",
                     "ідея", "budget", "акт", "Міла", "invoice", "звіт", "maps", "дзвінок"]
        var g = SystemRandomNumberGenerator()
        func row(_ i: Int) -> QuickItem {
            let n = Int.random(in: 6...60, using: &g)
            let t = (0..<n).map { _ in words.randomElement(using: &g)! }.joined(separator: " ")
            return QuickItem(kind: QuickKind.allCases[i % 3], text: t, app: ["Notes", "Safari", "Beeper"][i % 3], at: Double(10_000_000 - i))
        }
        for n in [1000, 3000] {
            let t0 = Date()
            let rows = (0..<n).map(row)
            let merged = QuickRules.merge(rows, pins: [])
            let build = Date().timeIntervalSince(t0) * 1000
            var worst = 0.0, total = 0.0, keys = 0
            for q in ["зустріч вокз", "station draw", "zzz", "к", "budget акт міла"] {
                var typed = ""
                for ch in q {
                    typed.append(ch)
                    let s = Date()
                    _ = QuickRules.filter(merged, query: typed, kind: nil)
                    let ms = Date().timeIntervalSince(s) * 1000
                    worst = max(worst, ms); total += ms; keys += 1
                }
            }
            print(String(format: "speed: %d rows, build %.1f ms (once, off the main thread), filter per key avg %.2f ms, worst %.2f ms", n, build, total / Double(keys), worst))
            check(worst < 5, "filter under 5 ms per key over \(n) rows (worst \(worst))")
        }
    }
}

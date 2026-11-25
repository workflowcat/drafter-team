import Foundation

// swiftc -O -parse-as-library app/JournalMeta.swift tests/journal_meta.swift -o app/build/journal-meta-test && app/build/journal-meta-test
// Each fact once per view and one row per text kept as several kinds, with made-up rows only.
@main
struct JournalMetaTest {
    static var failed = 0
    static func check(_ ok: Bool, _ what: String) { if !ok { failed += 1; print("FAIL " + what) } }
    static func main() {
        typealias M = JournalMeta
        // the row's time: the clock under a day, a date where no header names it
        // the app once: not inside a session of that app
        let inClaude = MetaContext(day: true, app: "Claude")
        check(M.cluster(took: "0:52", app: "Claude", tag: nil, in: inClaude) == [.length("0:52")], "no app inside its session")
        check(M.cluster(took: "0:52", app: "Claude", tag: nil, in: MetaContext(day: true)) == [.app("Claude"), .length("0:52")], "app outside a session")
        check(M.cluster(took: nil, app: "claude", tag: nil, in: inClaude) == [], "case does not matter")
        // the tag: only on reveal, never the group's own name, the other tag under Related to
        check(M.cluster(took: nil, app: "Mail", tag: "Mila Synthetic", in: MetaContext(day: true)) == [.app("Mail")], "tag hidden at rest")
        check(M.cluster(took: nil, app: "Mail", tag: "Mila Synthetic", in: MetaContext(day: true), reveal: true) == [.tag("Mila Synthetic"), .app("Mail")], "tag on hover")
        check(M.cluster(took: nil, app: "Mail", tag: "Lantern", in: MetaContext(tag: "Lantern")) == [.app("Mail")], "not the group's own tag")
        check(M.cluster(took: nil, app: "Mail", tag: "Sava", in: MetaContext(tag: "Lantern")) == [.tag("Sava"), .app("Mail")], "the other tag under a group")
        // where it went replaces the app; inside that app's session only "sent" stays
        check(M.cluster(took: "0:18", app: "Claude", fate: "sent in Claude", tag: nil, in: MetaContext(day: true)) == [.app("sent in Claude"), .length("0:18")], "fate")
        check(M.cluster(took: "0:18", app: "Claude", fate: "sent in Claude", tag: nil, in: inClaude) == [.app("sent"), .length("0:18")], "fate in its session")
        // drop order: tag, then app, then length; text never
        let parts: [M.Part] = [.tag("Lantern"), .app("Telegram"), .length("1:02")]
        check(M.fit(parts, widths: [60, 60, 30], room: 400) == parts, "all fit")
        check(M.fit(parts, widths: [60, 60, 30], room: 110) == [.app("Telegram"), .length("1:02")], "tag first")
        check(M.fit(parts, widths: [60, 60, 30], room: 60) == [.length("1:02")], "then app")
        check(M.fit(parts, widths: [60, 60, 30], room: 10) == [], "then length")
        // the reader: one header, the rest in Details
        check(M.header(noun: "Voice note", ago: "an hour ago", took: "0:52", app: "Claude", fate: nil) == "Voice note · an hour ago · 0:52 · Claude", "header")
        check(M.header(noun: "Voice note", ago: "an hour ago", took: "0:52", app: "Claude", fate: "sent in Claude") == "Voice note · an hour ago · 0:52 · sent in Claude", "header with fate")
        let d = M.details(exact: "Saturday 14 November 2026, 21:14:40", chars: 286, est: true,
                          also: [M.Also(kind: "typed", app: "Claude", at: 0, sent: true), M.Also(kind: "copied", app: "Notes", at: 60)], clock: { $0 == 0 ? "21:15" : "21:16" })
        check(d == ["Saturday 14 November 2026, 21:14:40", "286 characters", "Estimated start: shown from the first whole word", "Sent line in Claude, 21:15", "Clip in Notes, 21:16"], "details \(d)")
        let header = M.header(noun: "Voice note", ago: "an hour ago", took: "0:52", app: "Claude", fate: nil)
        check(!d.contains { $0.contains("0:52") } && !header.contains("2026"), "no fact in both")
        // the status line: nothing the chunk header or the sidebar says
        check(M.status(query: "", results: 120, filter: "everything", sidebarShows: true, group: nil, picked: 1) == "", "quiet status")
        check(M.status(query: "map", results: 3, filter: "from Mail", sidebarShows: false, group: nil, picked: 1) == "3 results · from Mail", "status searching, no sidebar")
        // kinds: a colour and a glyph each, glyphs all different
        check(Set(M.kinds.map(\.glyph)).count == M.kinds.count, "one glyph per kind")
        check(M.kindId("copied", clip: "link") == "link" && M.kindId("spoken", clip: "text") == "spoken", "kind ids")
        // site marks: stable, www dropped
        check(M.siteMark("www.example.org") == M.siteMark("example.org") && M.siteMark("example.org").letter == "E", "site mark")
        check((0..<4).contains(M.siteMark("lantern.test").series), "site colour in range")

        // one text, several kinds
        let t0 = 1_000_000.0
        let rows = [
            M.Row(kind: "spoken", at: t0, text: "Send the final drawings by three, please.", app: "Claude"),
            M.Row(kind: "typed", at: t0 + 40, text: "send the final drawings by three please", app: "Claude", sent: true),
            M.Row(kind: "copied", at: t0 + 90, text: "Send the final drawings by three, please!", app: "Notes"),
            M.Row(kind: "typed", at: t0 + 2000, text: "Room 4.12, second floor, the door on the left", app: "Mail"),
            M.Row(kind: "copied", at: t0 + 1990, text: "Room 4.12, second floor, the door on the left", app: "Mail"),
            M.Row(kind: "copied", at: t0 + 9000, text: "Room 4.12, second floor, the door on the left", app: "Mail"),
            M.Row(kind: "spoken", at: t0 + 3000, text: "A different thought about the station map", app: "Notes"),
            M.Row(kind: "typed", at: t0 + 3050, text: "Something else entirely about invoices", app: "Notes"),
            M.Row(kind: "call", at: t0 + 3060, text: "A different thought about the station map", app: "Zoom")]
        let g = M.merge(rows)
        check(g[0].map(Set.init) == [1, 2], "voice note takes its sent line and clip: \(g)")
        check(g[3] == [4], "draft takes the clip before it")
        check(g[5] == nil && !g.values.contains { $0.contains(5) }, "a copy hours later stays")
        check(g[6] == nil, "different text and a recording never merge")
        check(M.fate(g[0]!.map { rows[$0] }) == "sent in Claude", "fate sent")
        check(M.fate([rows[4]]) == "copied", "fate copied")
        check(M.fate([M.Row(kind: "typed", at: 0, text: "x", app: "Claude")]) == "in Claude", "fate draft")
        // small edits allowed, short texts not
        check(M.same(M.norm("Could you send the final drawings by three"), M.norm("Could you send the final drawing by three")), "one letter")
        check(!M.same(M.norm("ok"), M.norm("ok!")) || M.norm("ok") == M.norm("ok!"), "short equal only")
        check(!M.same(M.norm("See you at the station at nine"), M.norm("See you at the station at nine, then we go to the studio together")), "a longer text is not the same")
        // speed: 3,000 made-up rows
        var big: [M.Row] = []
        for i in 0..<3000 { big.append(M.Row(kind: ["spoken", "typed", "copied"][i % 3], at: Double(i / 3 * 1000 + i % 3 * 30), text: "made up line number \(i / 3) about the lantern form", app: "Notes")) }
        let s = Date(); let bg = M.merge(big); let ms = Date().timeIntervalSince(s) * 1000
        print(String(format: "merge 3000 rows: %d groups in %.0f ms", bg.count, ms))
        check(bg.count == 1000, "every triple merged")
        // card text
        check(M.codeLike("git log --oneline | head -5; echo $PATH"), "a command is code")
        check(M.codeLike("func a() {\n    let x = 1\n    return x\n}"), "indented lines are code")
        check(!M.codeLike("Could you send the drawings by Friday? Thanks."), "a sentence is not code")
        check(!M.codeLike(""), "empty is not code")
        let long = String(repeating: "word ", count: 60) + "lantern here"
        let at = (long as NSString).range(of: "lantern").location
        let w = M.window(long, match: at, room: 120)
        check(w > 0 && w < at && at - w <= 80, "the window starts before a far match")
        check(M.window(long, match: 10, room: 120) == 0, "a near match keeps the top")
        check(M.window(long, match: nil, room: 120) == 0, "no match keeps the top")
        check(Array(long.utf16)[w - 1] == 32, "the window starts at a word")
        let para = "The lantern form is ready. " + String(repeating: "More words follow here. ", count: 8)
        check(M.firstSentence(para) == 26, "first sentence ends after the full stop")
        check(M.firstSentence("Short. Text.") == nil, "a short text has no stronger sentence")
        // wire round: one outline at a time
        check(M.outline(keys: true, chosen: false) == (true, false), "keys, nothing chosen: the pane line")
        check(M.outline(keys: true, chosen: true) == (false, true), "keys and a chosen card: the card ring only")
        check(M.outline(keys: false, chosen: true) == (false, false), "no keys: a neutral ring, no line")
        check(M.outline(keys: false, chosen: false) == (false, false), "nothing")
        // chips under space pressure
        let cw = [70.0, 60, 80]
        check(M.chipFit(widths: cw, textHeight: 38, room: 75, chipH: 20, rowWidth: 230, footFree: 40) == (3, true), "short text: a chip row under it")
        check(M.chipFit(widths: cw, textHeight: 38, room: 75, chipH: 20, rowWidth: 140, footFree: 40) == (2, true), "a narrow card: two fit")
        check(M.chipFit(widths: cw, textHeight: 75, room: 75, chipH: 20, rowWidth: 230, footFree: 140) == (2, false), "a full card: the foot's room")
        check(M.chipFit(widths: cw, textHeight: 75, room: 75, chipH: 20, rowWidth: 230, footFree: 40) == (0, false), "no room: the chips go first")
        check(M.chipFit(widths: [], textHeight: 10, room: 75, chipH: 20, rowWidth: 230, footFree: 200) == (0, false), "no chips")
        check(M.foundGlyph("dateRange") == "calendar" && M.foundGlyph("money") == "coin" && M.foundGlyph("version") == "hash", "glyphs")
        print(failed == 0 ? "journal meta: all passed" : "journal meta: \(failed) failed")
        exit(failed == 0 ? 0 : 1)
    }
}

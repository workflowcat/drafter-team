import Foundation

// swiftc -O -parse-as-library app/DetectRules.swift app/ClipRules.swift app/FormatRules.swift app/FoundRules.swift tests/found_rules.swift -o app/build/found-rules-test && app/build/found-rules-test
// Things inside a text in the views (wire round): Pick parts' things from the detector, "In this text", the reader's
// keys for found things, "Copy as…" entries and keys, the destination of a paste, the Quick panel's forms. Made-up text.
@main
struct FoundRulesTest {
    static var failed = 0
    static func check(_ ok: Bool, _ what: String) { if !ok { failed += 1; print("FAIL " + what) } }
    static let tz = TimeZone(identifier: "Europe/Kyiv")!
    static let hints = DetectHints(timeZone: tz, home: "/Users/Shared")
    static func at(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 12) -> Date {
        var c = Calendar(identifier: .gregorian); c.timeZone = tz
        return c.date(from: DateComponents(year: y, month: m, day: d, hour: h))!
    }

    static func main() {
        pick(); inText(); keys(); forms(); dest(); quick(); marks(); store()
        print(failed == 0 ? "found rules: all passed" : "found rules: \(failed) failed")
        exit(failed == 0 ? 0 : 1)
    }

    static func pick() {
        let text = "Call Mila on 20.11 about https://example.org/plan, the invoice is 1 250 грн, write to mila@example.org. Your code is 482193"
        let things = FoundRules.pickThings(written: at(2026, 11, 15), hints: hints)(text)
        let kinds = things.map(\.kind)
        check(kinds.contains("date") && kinds.contains("link") && kinds.contains("amount") && kinds.contains("email"), "pick: date, link, amount, email (\(kinds))")
        check(!things.contains { $0.label.contains("482193") }, "pick: a one-time code is never a thing")
        let ns = text as NSString
        check(things.allSatisfy { ns.substring(with: $0.range) == $0.label }, "pick: ranges are the words")
    }

    static func inText() {
        let w = at(2026, 11, 15)   // a Sunday
        let f = Detect.scan("See you on Friday at https://example.org, it costs $40", written: w, hints: hints)
        let lines = FoundRules.inThisText(f)
        check(lines.count == 3, "in this text: three things (\(lines.count))")
        if let d = lines.first(where: { $0.kind == "date" }) {
            check(d.words.lowercased().contains("friday") && d.value.contains("20"), "a date: its words and the resolved day (\(d.words) → \(d.value))")
        } else { check(false, "a date line") }
        // resolved against the time the item was written, not today
        let old = Detect.scan("на п'ятницю", written: at(2025, 3, 3), hints: hints)
        check(FoundRules.inThisText(old).first?.value.contains("7") == true, "a weekday resolves against the writing day (\(FoundRules.inThisText(old).first?.value ?? "-"))")
        check(FoundRules.inThisText(Detect.scan("код 482193", written: w, hints: hints)).isEmpty, "sensitive: nothing")
    }

    static func keys() {
        typealias K = FoundRules.FoundKey
        var s = FoundFocus()
        let ks = ["K", "C", "R"], built = [true, true, false]
        var e: FoundRules.FoundEffect
        (s, e) = FoundRules.route(s, .next, count: 3, keys: ks, built: built); check(e == .focus(0), "⌥↓: the first thing")
        (s, e) = FoundRules.route(s, .prev, count: 3, keys: ks, built: built); check(e == .focus(2), "⌥↑ wraps to the last")
        (s, e) = FoundRules.route(s, .ret, count: 3, keys: ks, built: built); check(e == .openMenu && s.menu && s.row == 0, "↵ opens the actions")
        (s, e) = FoundRules.route(s, .down, count: 3, keys: ks, built: built); check(e == .none && s.row == 1, "↓ in the list")
        (s, e) = FoundRules.route(s, .ret, count: 3, keys: ks, built: built); check(e == .run(1) && !s.menu, "↵ runs the one the keys are on")
        (s, e) = FoundRules.route(s, .ret, count: 3, keys: ks, built: built)
        (s, e) = FoundRules.route(s, .key("K"), count: 3, keys: ks, built: built); check(e == .run(0), "K: Add to Calendar by its key")
        (s, e) = FoundRules.route(s, .ret, count: 3, keys: ks, built: built)
        (s, e) = FoundRules.route(s, .key("R"), count: 3, keys: ks, built: built); check(e == .none && s.menu, "an action not built does nothing")
        (s, e) = FoundRules.route(s, .esc, count: 3, keys: ks, built: built); check(e == .closeMenu && s.index == 2, "esc closes the list, the focus stays")
        (s, e) = FoundRules.route(s, .key("C"), count: 3, keys: ks, built: built); check(e == .pass, "the list shut: a letter passes")
        (s, e) = FoundRules.route(s, .esc, count: 3, keys: ks, built: built); check(e == .clear && s.index == nil, "esc again drops the focus")
        (s, e) = FoundRules.route(s, .esc, count: 3, keys: ks, built: built); check(e == .pass, "nothing in focus: esc passes")
        (s, e) = FoundRules.route(FoundFocus(), .next, count: 0, keys: [], built: []); check(e == .pass, "no things: ⌥↓ passes")
        (s, e) = FoundRules.route(FoundFocus(), .ret, count: 3, keys: ks, built: built); check(e == .pass, "nothing in focus: ↵ passes")
        _ = K.other
    }

    static func forms() {
        let w = at(2026, 11, 15)
        let date = FoundRules.forms(text: "20.11.2026", focused: nil, written: w, clip: true, hints: hints)
        check(date.first?.kind == "date" && date.contains { $0.id == "iso" && $0.text == "2026-11-20" }, "a date clip: its forms (\(date.map(\.id)))")
        check(!date.contains { $0.text == "20.11.2026" }, "a form that changes nothing is left out")
        let messy = "The station  map shows every platform, lift and exit in one view, it is\nupdated each night and the “old” one — gone.\u{200B}"
        let m = FoundRules.forms(text: messy, focused: nil, written: w, clip: true, hints: hints)
        let ids = m.map(\.id)
        check(ids.contains("joined") && ids.contains("spaces") && ids.contains("visible") && ids.contains("dashes") && ids.contains("straight") && ids.contains("ukQuotes"),
              "a messy clip: every clean-up (\(ids))")
        check(m.allSatisfy { $0.kind == "text" && !$0.preview.contains("\n") }, "clean-ups count as text, previews are one line")
        if let q = m.first(where: { $0.id == "straight" }) { check(q.preview.contains("\"old\""), "the preview shows the change (\(q.preview))") }
        check(FoundRules.forms(text: messy, focused: nil, written: w, clip: false, hints: hints).isEmpty, "not a clip: no clean-ups")
        // a thing in focus: its forms only
        let f = Detect.scan("Pay 1250 грн by Friday", written: w, hints: hints).first { $0.kind == .money }!
        let mf = FoundRules.forms(text: "Pay 1250 грн by Friday", focused: f, written: w, clip: true, hints: hints)
        check(!mf.isEmpty && mf.allSatisfy { $0.kind == "money" }, "money in focus: its forms only (\(mf.map(\.id)))")
        // a stored rule first
        var mem = FormatMemory(); _ = FormatLearn.answer("date", dest: nil, form: "enLong", yes: true, in: &mem)
        check(FoundRules.forms(text: "20.11.2026", focused: nil, written: w, clip: true, memory: mem, hints: hints).first?.id == "enLong", "his rule first")
        // the menu's keys
        var menu = FormsMenu(use: .copy, entries: date)
        var e: FoundRules.MenuEffect
        (menu, e) = FoundRules.route(menu, .down); (menu, e) = FoundRules.route(menu, .down)
        check(menu.row == 2 && e == .none, "↓ ↓")
        (menu, e) = FoundRules.route(menu, .ret); check(e == .apply(2), "↵ applies")
        (menu, e) = FoundRules.route(menu, .keep); check(e == .keep(2), "⌥↵ keeps it as a new clip")
        (menu, e) = FoundRules.route(menu, .up); (menu, e) = FoundRules.route(menu, .up); (menu, e) = FoundRules.route(menu, .up)
        check(menu.row == 0, "stops at the top")
        (menu, e) = FoundRules.route(menu, .esc); check(e == .close, "esc")
        check(FoundRules.route(FormsMenu(use: .insert, entries: []), .ret).1 == .close, "nothing to apply: closes")
        check(FoundRules.preview("abc", "abc  " + String(repeating: "x", count: 100)).count <= 57, "preview length")
    }

    static func dest() {
        check(FoundRules.dest(bundle: "com.apple.Terminal", kind: "other") == .terminal, "Terminal")
        check(FoundRules.dest(bundle: "com.jetbrains.pycharm", kind: "other") == .code, "an editor")
        check(FoundRules.dest(bundle: "ru.keepcoder.Telegram", kind: "chat") == .chat, "a chat")
        check(FoundRules.dest(bundle: "com.apple.mail", kind: "mail") == .mail, "mail")
        check(FoundRules.dest(bundle: "com.anthropic.claudefordesktop", kind: "ai") == .chat, "an assistant box reads as a chat")
        check(FoundRules.dest(bundle: "com.apple.Notes", kind: "other") == .other, "else other")
    }

    static func quick() {
        let w = at(2026, 11, 15)
        let term = FoundRules.quickForms("20.11.2026", written: w, dest: .terminal)
        let chat = FoundRules.quickForms("2026-11-20", written: w, dest: .chat)
        check(term.kind == "date" && term.forms.first?.id == "iso", "terminal: the machine form first (\(term.forms.map(\.id)))")
        check(chat.forms.first?.id == "uk", "chat: the local written form first (\(chat.forms.map(\.id)))")
        check(FoundRules.quickForms("Thanks, see you tomorrow at the station", written: w, dest: .chat).forms.isEmpty, "a sentence: no forms")
        check(FoundRules.quickForms("4111 1111 1111 1111", written: w, dest: .chat).forms.isEmpty, "a card: no forms")
        var mem = FormatMemory(); _ = FormatLearn.answer("date", dest: .terminal, form: "enLong", yes: true, in: &mem)
        let r = FoundRules.quickForms("20.11.2026", written: w, dest: .terminal, memory: mem)
        check(r.ruled && r.forms.first?.id == "enLong", "a destination rule: the row starts on it")
        check(!FoundRules.quickForms("20.11.2026", written: w, dest: .chat, memory: mem).ruled, "another destination: as copied")
    }

    static func marks() {
        let w = at(2026, 11, 15)
        let m = FoundRules.searchMarks("Pay 1 250 грн to GB82 WEST 1234 5698 7654 32 by 20.11.2026, call +380 44 123 4567", written: w)
        check(m.bits & 64 != 0 && m.bits & 2048 != 0 && m.bits & 32 != 0, "money, iban and date bits: \(m.bits)")
        var cal = Calendar(identifier: .gregorian); cal.timeZone = .current
        check(m.days == [cal.date(from: DateComponents(year: 2026, month: 11, day: 20))!.timeIntervalSince1970], "the day mentioned: \(m.days)")
        check(FoundRules.searchMarks("", written: w).bits == 0, "empty text: nothing")
        check(FoundRules.searchMarks("code 482913 to sign in", written: w).bits & (64 | 128) == 0, "a one-time code counts as nothing")
    }

    static func store() {
        let st = SearchMarkStore(), w = at(2026, 11, 15).timeIntervalSince1970
        let a = st.marks(id: "x1", text: "Pay 1 250 грн by 20.11.2026", written: w)
        _ = st.marks(id: "x1", text: "Pay 1 250 грн by 20.11.2026", written: w)
        check(st.computed == 1 && a.bits & 64 != 0, "the same text: the detector once (\(st.computed))")
        let b = st.marks(id: "x1", text: "write to mila@example.org", written: w)
        check(st.computed == 2 && b.bits & 256 != 0 && b.bits & 64 == 0, "a changed text: read again")
        check(st.stored(id: "x1") == b && st.stored(id: "nope") == nil, "stored only reads, never runs the detector")
        st.forget(id: "x1"); check(st.stored(id: "x1") == nil && st.count == 0, "forget")
    }
}

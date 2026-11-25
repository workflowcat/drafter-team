import Foundation

// swiftc -parse-as-library app/EditRules.swift tests/edit_rules.swift -o app/build/edit-rules-test && app/build/edit-rules-test
// Made-up lines only.
@main
struct EditRulesTest {
    static var failed = 0, ran = 0
    static func check(_ ok: Bool, _ what: String) { ran += 1; if !ok { failed += 1; print("FAIL", what) } }

    static func main() {
        typealias R = EditRules
        // where it may run
        check(R.allowed(on: true, secure: false, password: false, skipped: false), "on")
        check(!R.allowed(on: true, secure: true, password: false, skipped: false), "secure input")
        check(!R.allowed(on: true, secure: false, password: true, skipped: false), "password field")
        check(!R.allowed(on: true, secure: false, password: false, skipped: true), "skipped app")
        check(!R.allowed(on: false, secure: false, password: false, skipped: false), "off")
        // when
        check(R.due(lastMove: 10, lastLetter: 5, now: 11.6), "a move, then a rest")
        check(!R.due(lastMove: 10, lastLetter: 5, now: 11), "rest too short")
        check(!R.due(lastMove: 10, lastLetter: 10.5, now: 13), "a letter after the move: writing")
        check(!R.due(lastMove: nil, lastLetter: nil, now: 13), "no move")
        check(R.due(lastMove: 10, lastLetter: nil, now: 12), "a move, no letters at all")
        // which text
        let sel = R.span(value: "short. рахунок надішлю звтра зранку, дякую. end", caret: 7, selLen: 35)
        check(sel?.trigger == .selection && sel?.offset == 7 && sel?.text == "рахунок надішлю звтра зранку, дякую", "a selection")
        check(R.span(value: "short text here and more words to fill it up", caret: 0, selLen: 5) == nil, "a short selection: nothing")
        let field = "first line of the note\nthe second line with a typo in it, long enough\nthird"
        let p = R.span(value: field, caret: 30, selLen: 0)
        check(p?.trigger == .editing && p?.text == "the second line with a typo in it, long enough" && p?.offset == 23, "caret paragraph")
        check(R.span(value: field, caret: (field as NSString).length, selLen: 0) == nil, "caret at the end: writing on")
        check(R.span(value: field + "  \n", caret: (field as NSString).length, selLen: 0) == nil, "only spaces after the caret")
        check(R.span(value: "too short a field", caret: 3, selLen: 0) == nil, "short field")
        check(R.span(value: field, caret: 72, selLen: 0) == nil, "caret paragraph too short (third)")
        check(R.span(value: "👍 " + field, caret: 34, selLen: 0)?.offset == 26, "UTF-16 offsets past an emoji")
        let t = R.trimmed(R.Span(text: "⟦drafter-test⟧ hello there", offset: 4, trigger: .selection))
        check(t.text == "hello there" && t.offset == 4 + 15, "test marker cut")
        // placing engine marks
        let span = R.Span(text: "рахунок надішлю звтра зранку", offset: 10, trigger: .selection)
        let raw = [R.Mark(at: 16, len: 5, old: "звтра", new: "завтра", kind: "typo", why: "you usually write «завтра»"),
                   R.Mark(at: 0, len: 7, old: "рахунок", new: "Рахунок", kind: "unclear", why: "x"),
                   R.Mark(at: 2, len: 3, old: "zzz", new: "y", kind: "tone", why: "stale")]
        let placed = R.place(raw, in: span)
        check(placed.count == 2 && placed[0].at == 10 && placed[1].at == 26, "placed in reading order, the stale one dropped")
        // after applying one, the rest move
        let rest = R.after(applying: placed[0], placed)
        check(rest.count == 1 && rest[0].at == 26, "same length: no move")
        let longer = R.after(applying: placed[1], [placed[1], R.Mark(at: 40, len: 2, old: "ab", new: "a", kind: "typo", why: "")])
        check(longer == [R.Mark(at: 41, len: 2, old: "ab", new: "a", kind: "typo", why: "")], "longer fix moves later marks by 1")
        // Tab
        let ms = [R.Mark(at: 5, len: 4, old: "a", new: "b", kind: "typo", why: ""), R.Mark(at: 20, len: 3, old: "c", new: "d", kind: "tone", why: "")]
        check(R.tabTarget(ms, caret: 21, hovered: 0, shown: nil) == 1, "caret in a mark wins")
        check(R.tabTarget(ms, caret: 9, hovered: nil, shown: nil) == 0, "caret at a mark's end")
        check(R.tabTarget(ms, caret: 12, hovered: 1, shown: 0) == 1, "then the hovered one")
        check(R.tabTarget(ms, caret: 12, hovered: nil, shown: 0) == 0, "then the shown one")
        check(R.tabTarget(ms, caret: 12, hovered: nil, shown: nil) == 1, "then the next after the caret")
        check(R.tabTarget(ms, caret: 30, hovered: nil, shown: nil) == 0, "else the first")
        check(R.tabTarget([], caret: 3, hovered: nil, shown: nil) == nil, "no marks")
        // Esc
        check(R.esc(shown: 1, sinceLastEsc: nil) == .dismiss(1), "Esc: the shown mark goes")
        check(R.esc(shown: 0, sinceLastEsc: 0.3) == .all, "Esc twice: all")
        check(R.esc(shown: nil, sinceLastEsc: 2) == .pass, "no chip: the Esc is the app's")
        // chips
        check(R.label(ms[0]) == "a → b", "label without why")
        check(R.label(R.Mark(at: 0, len: 3, old: " 🎉", new: "", kind: "tone", why: "you send no emoji to them")) == "remove «🎉» · you send no emoji to them", "removal label")
        check(R.label(R.Mark(at: 0, len: 3, old: String(repeating: "x", count: 40), new: "y", kind: "t", why: String(repeating: "w", count: 60))).count <= 80, "label capped")
        check(R.styleResult("one\ntwo").hasPrefix("⇥ one two"), "style result on one line")
        // keys
        check(R.writes(code: 0, typed: "a", command: false) && R.writes(code: 36, typed: "\r", command: false), "letters and Return write")
        check(!R.writes(code: 123, typed: "\u{F702}", command: false) && !R.writes(code: 0, typed: "a", command: true), "arrows and ⌘ keys do not")
        check(R.moves(code: 51) && R.moves(code: 123) && !R.moves(code: 0), "delete and arrows move")
        print(failed == 0 ? "edit rules: \(ran) ok" : "edit rules: \(failed) of \(ran) failed")
        exit(failed == 0 ? 0 : 1)
    }
}

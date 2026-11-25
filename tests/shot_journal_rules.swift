import Foundation
import CoreGraphics

// swiftc -parse-as-library app/PenRules.swift app/ShotPackRules.swift app/ShotJournalRules.swift tests/shot_journal_rules.swift -o app/build/shot-journal-test && app/build/shot-journal-test
// The screenshot tool, journal side: safe ids, the card's line, the mark count, the sent word, the answer's lines,
// what the search reads, the row's keys. Made-up shots only.
@main
struct ShotJournalTest {
    static var failures = 0
    static func check(_ ok: Bool, _ what: String) { if !ok { print("FAIL: " + what); failures += 1 } }

    static func main() {
        var set = ShotPack(id: "s", t: 1, width: 10, height: 10)
        set.setPictures([ShotPicture(file: "", width: 10, height: 10, marks: [ShotMark(kind: "pin", x: 1, y: 1, n: 1, text: "made-up")]),
                         ShotPicture(file: "", width: 10, height: 10, marks: [ShotMark(kind: "arrow", x: 1, y: 1, toX: 5, toY: 5), ShotMark(kind: "blur", x: 0, y: 0, w: 2, h: 2)])])
        check(ShotJournalRules.pictureText(set) == "2", "a set: the card's count")
        check(ShotJournalRules.pictureText(ShotPack(id: "o", t: 1, width: 1, height: 1)) == "", "one picture: no count")
        check(ShotJournalRules.markCount(set) == 2, "marks of every picture, blurs not counted")
        check(ShotJournalRules.searchText(set).contains("made-up"), "every picture's mark words searched")
        let k = ShotJournalRules.newestPerShot([("a", 1), ("", 2), ("a", 3), ("b", 4), ("", 5)])
        check(k == [1, 2, 3, 4], "one card per shot, the newest: \(k)")
        check(ShotJournalRules.validId("20261115-104207-3fa1"), "a real id")
        for bad in ["", "../x", "a/b", "a.b", String(repeating: "a", count: 65), "a b"] { check(!ShotJournalRules.validId(bad), "unsafe id: \(bad)") }

        var p = ShotPack(id: "20261115-104207-3fa1", t: 0, app: "Safari", window: "Station plan", width: 1280, height: 720)
        check(ShotJournalRules.cardLine(p, fallback: "Image · 1280 × 720") == "Image · 1280 × 720", "no note: the row's own line")
        check(ShotJournalRules.cardLine(nil, fallback: "Image") == "Image", "no pack: the row's own line")
        p.note = "  the lift button\n is  too small "
        check(ShotJournalRules.cardLine(p, fallback: "x") == "the lift button is too small", "the note on one line")

        check(ShotJournalRules.markCount(p) == 0 && ShotJournalRules.markText(0) == "", "no marks, nothing drawn")
        p.marks = [ShotMark(kind: "pin", x: 1, y: 2, n: 1), ShotMark(kind: "box", x: 0, y: 0, w: 5, h: 5),
                   ShotMark(kind: "blur", x: 0, y: 0, w: 5, h: 5), ShotMark(kind: "pin", x: 3, y: 4, n: 2, text: "this one")]
        check(ShotJournalRules.markCount(p) == 3, "a blur is not counted")
        check(ShotJournalRules.markText(3) == "3" && ShotJournalRules.markText(12) == "9+", "count text")

        check(ShotJournalRules.sentWord(p) == nil, "never sent")
        p.sent = [ShotSent(to: .claude, t: 20), ShotSent(to: .file, t: 30, detail: "Screenshot 2026-11-15 at 10.42.07.png"), ShotSent(to: .clipboard, t: 10)]
        check(ShotJournalRules.lastSent(p)?.to == .file, "the newest hand-off")
        check(ShotJournalRules.sentWord(p) == "File · Screenshot 2026-11-15 at 10.42.07.png", "word with detail: \(ShotJournalRules.sentWord(p) ?? "nil")")
        p.sent = [ShotSent(to: .claudeCode, t: 1)]
        check(ShotJournalRules.sentWord(p) == "Claude Code", "word alone")

        check(ShotJournalRules.answerLines(nil).isEmpty, "no answer")
        let a = "## What I see\n\n- The button is 18 px high.\n```\ncode\n```\nMake it 44 px.\nThird line"
        check(ShotJournalRules.answerLines(a) == ["What I see", "The button is 18 px high."], "first two lines: \(ShotJournalRules.answerLines(a))")
        check(ShotJournalRules.answerLines(a, max: 5) == ["What I see", "The button is 18 px high.", "code", "Make it 44 px.", "Third line"],
              "fences dropped: \(ShotJournalRules.answerLines(a, max: 5))")

        p.answer = "Make it bigger."
        let s = ShotJournalRules.searchText(p)
        check(s.hasPrefix("the lift button"), "the note first")
        check(s.contains("this one") && s.contains("Station plan") && s.contains("Make it bigger."), "marks, window, answer: \(s)")
        check(ShotJournalRules.searchText(ShotPack(id: "x", t: 0, width: 1, height: 1)) == "", "empty pack: nothing")

        let acts = ShotJournalRules.actions(pinned: false)
        check(acts.map(\.key) == ["⇥", "⌘↵", "⌘C", "⌘E", "⌘O", "⌘P", "⌘⌫"], "keys in order")
        check(acts.first { $0.key == "⌘E" }?.act == .markUp && acts.first { $0.key == "⌘C" }?.act == .copyAgent, "⌘E marks up, ⌘C copies for agent")
        check(Set(acts.map(\.key)).count == acts.count, "one action per key")
        check(ShotJournalRules.actions(pinned: true).contains { $0.word == "Unpin" }, "pinned: Unpin")
        check(ShotJournalRules.tabSends(isShot: true, inList: true, picked: 1), "⇥ sends from the list")
        check(!ShotJournalRules.tabSends(isShot: true, inList: false, picked: 1), "⇥ elsewhere moves panes")
        check(!ShotJournalRules.tabSends(isShot: true, inList: true, picked: 3), "several picked: ⇥ moves panes")
        check(!ShotJournalRules.tabSends(isShot: false, inList: true, picked: 1), "not a shot")

        if failures > 0 { print("\(failures) failed"); exit(1) }
        print("shot journal rules: all passed")
    }
}

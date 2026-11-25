import Foundation

// swiftc -parse-as-library app/LiveType.swift tests/live_type.swift -o app/build/live-type-test && app/build/live-type-test
// Live typing rules with made-up lines in English and Ukrainian: steady words, where the field stands in a new draft,
// the smallest edit, the key steps (played on a pretend field) and the meter.
@main
struct LiveTypeTest {
    static var failed = 0
    static func check(_ ok: Bool, _ what: String, line: Int = #line) {
        if !ok { failed += 1; print("FAIL line \(line): \(what)") }
    }
    static func w(_ s: String) -> [Substring] { s.split(separator: " ") }

    /// Applies a plan to a pretend field and returns what it holds.
    static func apply(_ p: LiveType.Plan, to have: String) -> String {
        let (t, caret) = LiveType.run(p.keys, on: have)
        check(caret == t.count, "caret back at the end after fixes (\(caret) of \(t.count))")
        return t + p.append
    }

    static func main() {
        // steady: the strip's rule, the last word waits unless he paused
        check(LiveType.steady(w("we can go"), w("we can go to"), still: 0) == 3, "agreeing words, the new one waits")
        check(LiveType.steady(w("we can go to"), w("we can go to"), still: 2) == 3, "all alike: the last word still waits")
        check(LiveType.steady(w("we can go to"), w("we can go to"), still: 3) == 4, "three alike: he paused, the last word too")
        check(LiveType.steady(w("ми можемо піти"), w("ми можемо йти далі"), still: 0) == 2, "Ukrainian: stops at the changed word")
        check(LiveType.steady([], w("hello"), still: 0) == 0, "first draft: nothing steady")
        check(LiveType.head("Перше речення. Друге\nтретє слово", words: 3) == "Перше речення. Друге", "head keeps its own spaces")

        // words and cores
        check(LiveType.words("  Так, звісно!  ok ").map(\.core) == ["так", "звісно", "ok"], "cores drop marks and case")
        check(LiveType.onlyMarks("so we go to the park", "So, we go to the park."), "only marks")
        check(!LiveType.onlyMarks("so we go", "so we went"), "a changed word is not only marks")

        // aligned: the field's last words found in the new draft
        let have1 = "we can meet at the cafe"
        let want1 = "We can meet at the cafe, near the river and then"
        if let j = LiveType.aligned(have1, in: want1) { check(String(want1[..<j]) == "We can meet at the cafe,", "aligned past a comma and a capital") }
        else { check(false, "aligned found nothing") }
        let have2 = "я думаю що завтра ми"
        let want2 = "Я думаю, що завтра ми підемо в парк"
        if let j = LiveType.aligned(have2, in: want2) { check(String(want2[j...]) == " підемо в парк", "Ukrainian: rest after the field") }
        else { check(false, "Ukrainian aligned found nothing") }
        check(LiveType.aligned("one two three", in: "nothing alike here at all") == nil, "no place: nil")
        check(LiveType.aligned("", in: "abc") == "abc".startIndex, "empty run: the start")

        // changes: one small change per differing word, the rest untouched
        let c1 = LiveType.changes("so we go to the park and", "So, we go to the park, and")
        check(c1 == [.init(at: 0, remove: 2, insert: "So,"), .init(at: 20, remove: 0, insert: ",")], "per word: \(c1)")
        check(LiveType.touched(c1) == 6, "six characters touched, the words between untouched")
        let c2 = LiveType.changes("does it work", "does that work")
        check(c2 == [.init(at: 5, remove: 1, insert: "tha")], "one word changed, its shared letter kept: \(c2)")
        let c3 = LiveType.changes("we will go", "we'll go")
        check(c3.count == 1 && LiveType.touched(c3) < 8, "different word count: one change in the middle \(c3)")

        // keys on a pretend field: every edit lands where it should, the caret ends at the end
        for (a, b) in [("so we go to the park and", "So, we go to the park, and"), ("does it work", "does that work"),
                       ("we will go", "we'll go"), ("привіт як справи", "Привіт, як справи?"), ("abc", "abcdef"),
                       ("tail words here", "tail words"), ("Завтра о другій", "Завтра о третій"), ("x", "y")] {
            let ch = LiveType.changes(a, b)
            let (t, caret) = LiveType.run(LiveType.keys(ch, length: a.count), on: a)
            check(t == b && caret == t.count, "keys turn «\(a)» into «\(b)»: got «\(t)» caret \(caret)")
        }
        // a change at the very end moves no caret
        check(LiveType.keys(LiveType.changes("the end", "the end."), length: 7) == [.type(".")], "a full stop at the end: one key step")
        check(!LiveType.keys(LiveType.changes("does it work", "does that work"), length: 12).contains(.left(12)), "never back to the start")

        // plan while talking
        var p = LiveType.plan(have: "we can meet", want: "we can meet at the", end: false)
        check(p.keys.isEmpty && p.append == " at the" && p.next == "we can meet at the", "grows: append only")
        p = LiveType.plan(have: "we can meet at the cafe", want: "We can meet at the cafe, near the river", end: false)
        check(p.left.count == 1 && p.append == " near the river" && p.keys == [.type(",")], "while talking: the comma at the caret goes in, the capital far back waits: \(p.keys) \(p.left)")
        check(apply(p, to: "we can meet at the cafe") == "we can meet at the cafe, near the river", "field keeps going")
        // the next draft after that: still aligned, still going
        let p2 = LiveType.plan(have: p.next, want: "We can meet at the cafe, near the river at noon", end: false)
        check(p2.append == " at noon", "after a waiting fix the words keep coming: \(p2.append)")
        p = LiveType.plan(have: "добре дякую", want: "Добре, дякую і тобі", end: false)
        check(apply(p, to: "добре дякую") == "Добре, дякую і тобі", "Ukrainian: a capital and a comma near the caret go in at once: \(p.keys)")
        p = LiveType.plan(have: "does it", want: "does that work", end: false)
        check(apply(p, to: "does it") == "does that work", "last word changed: fixed at the caret")
        p = LiveType.plan(have: "alpha beta gamma delta epsilon zeta eta theta", want: "something else entirely and much more", end: false)
        check(p.lost && p.keys.isEmpty && p.append.isEmpty, "no place for the run: nothing typed while talking")
        p = LiveType.plan(have: "we can meet at", want: "we can meet", end: false)
        check(p.keys.isEmpty && p.append.isEmpty, "a draft that shrank: wait")

        // plan at the end: fix only what changed, no retyping
        p = LiveType.plan(have: "so we go to the park and then", want: "So, we go to the park, and then home.", end: true)
        check(apply(p, to: "so we go to the park and then") == "So, we go to the park, and then home.", "end: marks fixed in place, rest added")
        check(p.fixed == 6, "end: six characters touched, not the whole tail (\(p.fixed))")
        p = LiveType.plan(have: "Завтра о другій зустрінемось", want: "Завтра о третій зустрінемось.", end: true)
        check(apply(p, to: "Завтра о другій зустрінемось") == "Завтра о третій зустрінемось.", "end: one Ukrainian word swapped in the middle")
        check(p.fixed <= 12, "end: a word swap touches only that word (\(p.fixed))")
        // too big a change: the field stays, nothing typed over it
        let long = "this is a long take about the garden plan for next spring with many words in it"
        p = LiveType.plan(have: long, want: "Okay.", end: true)
        check(p.keys.isEmpty && !p.left.isEmpty, "end: a final that rewrites most of the take is not typed over")
        // the 2026-10-19 rule still holds: a much shorter final never wipes the field
        p = LiveType.plan(have: String(repeating: "word ", count: 50), want: "short", end: true)
        check(p.keys.isEmpty, "short final never erases a long field")

        // spacing
        check(LiveType.spaced("hello", after: "d") == " hello", "space after a letter")
        check(LiveType.spaced(", then", after: "d") == ", then", "no space before a comma")
        check(LiveType.spaced("hello", after: " ") == "hello", "no double space")
        check(LiveType.spaced("hello", after: nil) == "hello", "empty field")

        // meter: shown -> steady -> field
        var m = LiveType.Meter()
        m.saw(words: 2, at: 0.0)
        m.settled(words: 1, at: 0.4)
        m.typed(words: 1, at: 0.4)
        m.saw(words: 3, at: 0.6)
        m.settled(words: 3, at: 0.9)
        m.typed(words: 3, at: 1.5)
        check(m.lagSteady.count == 3 && m.lagSteady[0] == 0 && abs(m.lagSteady[1] - 0.6) < 1e-9 && abs(m.lagSteady[2] - 0.6) < 1e-9, "steady lag \(m.lagSteady)")
        check(abs(m.lagShown[0] - 0.4) < 1e-9 && abs(m.lagShown[2] - 0.9) < 1e-9, "shown lag \(m.lagShown)")
        check(m.steps == 2 && m.landed == 3, "two steps, three words")
        check(m.summary == "steady -> field median 600 ms, worst 600 ms; shown -> field median 900 ms, worst 1500 ms", "summary: \(m.summary)")
        check(LiveType.Meter.median([3, 1, 2]) == 2 && LiveType.Meter.median([1, 2, 3, 4]) == 2.5, "median")

        // the cut-off fault: at the end the field always reaches the final text (keys, or the run replaced whole),
        // never a few live words with the rest only on the clipboard
        let ends: [(String, String)] = [
            ("Let's meet on", "Let's meet on Friday at ten, and bring the made-up plan for the launch with the two drafts and the budget sheet."),
            ("the quick brown fox", "A quick brown fox jumps over the lazy dog near the river bank."),
            ("Привіт, як справи з", "Привіт! Як там справи з вигаданим планом на наступний тиждень?"),
            ("one two three four five six seven", "Completely different words came back from the careful reading of the note."),
            ("Hello there", "Hello there, friend."),
            ("hello there friend", "Hello there, friend."),
        ]
        for (have, want) in ends {
            switch LiveType.endWay(have: have, want: want) {
            case .keys(let p):
                let got = apply(p, to: have)
                check(got == want || (p.marksOnly && LiveType.onlyMarks(got, want)), "end by keys reaches the final: «\(got)»")
            case .replace(let t):
                check(t == want, "the run is replaced by the whole final text")
            }
        }
        if case .replace = LiveType.endWay(have: "one two three four five six seven", want: "Completely different words came back from the careful reading of the note.") {} else {
            check(false, "a run far from the final is replaced whole")
        }
        print(failed == 0 ? "live type: all passed" : "live type: \(failed) failed")
        exit(failed == 0 ? 0 : 1)
    }
}

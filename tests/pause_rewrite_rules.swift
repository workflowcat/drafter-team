// swiftc -parse-as-library app/PauseRewriteRules.swift tests/pause_rewrite_rules.swift -o app/build/pause-rewrite-test && app/build/pause-rewrite-test
// The pause rewrite's pure rules (app/PauseRewriteRules.swift): where a chip may appear, when to ask, the chip's text and
// marks, freshness. Made-up lines only.
import Foundation

@main
struct PauseRewriteChecks {
    static var failures = 0
    static func check(_ ok: Bool, _ what: String) { if !ok { print("FAIL: " + what); failures += 1 } }

    static func main() {
        typealias R = PauseRewriteRules
        // never in skipped apps, password fields, under secure input, mid-line, or with the switch off
        check(R.allowed(on: true, secure: false, skipped: false, password: false, mid: false), "allowed")
        check(!R.allowed(on: false, secure: false, skipped: false, password: false, mid: false), "off")
        check(!R.allowed(on: true, secure: true, skipped: false, password: false, mid: false), "secure input")
        check(!R.allowed(on: true, secure: false, skipped: true, password: false, mid: false), "skipped app")
        check(!R.allowed(on: true, secure: false, skipped: false, password: true, mid: false), "password field")
        check(!R.allowed(on: true, secure: false, skipped: false, password: false, mid: true), "mid-line")
        check(R.pause == 1.5 && R.minWords == 6 && R.maxChars == 800, "the numbers")

        // when to ask: a finished sentence of 3+ words and 6+ words in all (same as engine/pause_rewrite.py ready)
        check(!R.ready("ок, дякую"), "short")
        check(!R.ready("so I was thinking we could maybe meet"), "no finished sentence")
        check(!R.ready("Ok. Fine. Sure. Yes, we can meet then"), "short sentences only")
        check(R.ready("Sure, I'll send the notes tonight. Talk on"), "a sentence, then more")
        check(R.ready("привіт, звіт буде в четверь до обіду. дані від вас"), "Ukrainian")
        check(R.ready("we can start the pilot on Monday with five users!"), "ends with !")
        check(!R.ready(String(repeating: "слово ", count: 200) + "."), "too long")
        check(!R.ready("see v2.1 of the doc and the 3.5 notes for it"), "a dot inside a word is no sentence end")

        // the test marker: only at the very start, offset in UTF-16 units
        let m = R.message("⟦drafter-test⟧ hello there. how are you")
        check(m?.text == "hello there. how are you" && m?.offset == ("⟦drafter-test⟧ " as NSString).length, "marker offset: \(String(describing: m))")
        check(R.message("hello ⟦drafter-test⟧") == nil, "a marker in the middle")
        check(R.message("plain text").map { $0.offset } == 0, "no marker")

        // the chip text and marks
        let new = "привіт, звіт буде в четвер до обіду. дані від вас прийшли вчора"
        let at = ("привіт, звіт буде в " as NSString).length
        let l = R.label(new, marks: [[at, 6], [-1, 2], [at, 0], [999, 3]])
        check(l.text == new && l.marks == [NSRange(location: at, length: 6)], "marks kept and bad ones dropped: \(l.marks)")
        check((l.text as NSString).substring(with: l.marks[0]) == "четвер", "the mark covers the changed word")
        let long = String(repeating: "a", count: 300) + " end"
        let cut = R.label(long, marks: [[0, 3], [302, 3]])
        check(cut.text.count == R.chipChars && cut.text.hasSuffix("…") && cut.marks == [NSRange(location: 0, length: 3)], "cut at chipChars, marks past the cut dropped")

        // fresh: no key, same text, in time
        check(R.fresh(sentSeq: 4, nowSeq: 4, sentBefore: "a b", nowBefore: "a b", elapsed: 1.2), "fresh")
        check(!R.fresh(sentSeq: 4, nowSeq: 5, sentBefore: "a b", nowBefore: "a b", elapsed: 1.2), "a key since")
        check(!R.fresh(sentSeq: 4, nowSeq: 4, sentBefore: "a b", nowBefore: "a b c", elapsed: 1.2), "text changed")
        check(!R.fresh(sentSeq: 4, nowSeq: 4, sentBefore: "a b", nowBefore: "a b", elapsed: 9), "too late")

        // Tab only while the field still ends with what was rewritten (a no-break space reads as a space)
        check(R.stillEnds(before: "Earlier line\nsee you\u{A0}tomorow then", text: "see you tomorow then"), "still ends")
        check(!R.stillEnds(before: "see you tomorow then!", text: "see you tomorow then"), "typed on")
        check(!R.stillEnds(before: "anything", text: ""), "empty text")

        if failures > 0 { print("\(failures) failed"); exit(1) }
        print("pause rewrite rules: all checks passed")
    }
}

import Foundation

// swiftc -parse-as-library app/ReaderRules.swift tests/reader_rules.swift -o app/build/reader-rules-test && app/build/reader-rules-test
// Made-up lines only.
@main
struct ReaderRulesTest {
    static var failed = 0, ran = 0
    static func check(_ ok: Bool, _ what: String) { ran += 1; if !ok { failed += 1; print("FAIL", what) } }

    static func main() {
        typealias R = ReaderRules
        // where it runs
        check(R.applies(kind: "chat", value: "hi"), "chat box")
        check(!R.applies(kind: "ai", value: "hi") && !R.applies(kind: "mail", value: "hi"), "not in AI or mail")
        check(R.applies(kind: "other", value: "⟦drafter-test⟧ hi"), "test field anywhere")
        // when
        check(R.wait("ok") == nil && R.wait("ok sure") == nil, "under 3 words: nothing")
        check(R.wait("see you tomorrow then") == R.rest, "rest after 3 words")
        check(R.wait("see you tomorrow.") == R.ended && R.wait("are you coming?\u{201D}") == R.ended, "sentence end")
        check(R.wait("⟦drafter-test⟧ ok sure") == nil, "the marker is not a word")
        // test marker
        check(R.message("⟦drafter-test⟧ рахунок звтра")! == ("рахунок звтра", 15), "marker cut, offset in UTF-16")
        check(R.message("рахунок звтра")! == ("рахунок звтра", 0), "no marker")
        check(R.message("so ⟦drafter-test⟧ x") == nil, "marker mid-message: skip")
        check(R.testContext("Вони: коли рахунок?\nшум\n\n⟦drafter-test⟧ ок", span: "⟦drafter-test⟧ ок") == "Вони: коли рахунок?", "test context")
        check(R.testContext("Вони: коли?\n\nок", span: "ок") == "", "no context outside a test field")
        // which fixes
        let e = R.Edit(at: 0, len: 5, old: "звтра", new: "завтра")
        check(R.keep(e, known: { _ in false }), "unknown word: kept")
        check(!R.keep(e, known: { $0 == "звтра" }), "the Mac knows it: dropped")
        check(R.keep(R.Edit(at: 0, len: 6, old: "незнаю", new: "не знаю"), known: { _ in true }), "a split stays")
        check(R.shifted([e], by: 15).first?.at == 15, "shift")
        // the chip
        check(R.label([], ask: "") == nil, "nothing to say")
        check(R.label([e], ask: "") == "⇥ Fix 1 · звтра → завтра", "fix")
        check(R.label([], ask: "they asked about рахунок") == "↩ they asked about рахунок", "ask")
        check(R.label([e], ask: "they asked about рахунок")!.hasPrefix("⇥ Fix 1 · звтра → завтра · ↩ they"), "both")
        let long = R.label([e, e, e, e], ask: "they asked about something long")!
        check(long.count == 69 && long.hasSuffix("…"), "cut at 70")
        // fresh
        check(R.fresh(sentSeq: 3, nowSeq: 3, sentBefore: "a", nowBefore: "a", elapsed: 0.2), "fresh")
        check(!R.fresh(sentSeq: 3, nowSeq: 4, sentBefore: "a", nowBefore: "a", elapsed: 0.2), "a key since: dropped")
        check(!R.fresh(sentSeq: 3, nowSeq: 3, sentBefore: "a", nowBefore: "ab", elapsed: 0.2), "text changed")
        check(!R.fresh(sentSeq: 3, nowSeq: 3, sentBefore: "a", nowBefore: "a", elapsed: 1.3), "too late")
        print(failed == 0 ? "reader rules: \(ran) passed" : "reader rules: \(failed) of \(ran) failed")
        exit(failed == 0 ? 0 : 1)
    }
}

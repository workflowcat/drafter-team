import Foundation

// swiftc -parse-as-library app/DiffRules.swift tests/diff_rules.swift -o app/build/diff-rules-test && app/build/diff-rules-test
// Synthetic test cases only.
@main
struct DiffRulesTest {
    static var failed = 0, ran = 0
    static func check(_ ok: Bool, _ what: String) {
        ran += 1
        if !ok { failed += 1; print("FAIL", what) }
    }

    static func reconstruct(_ parts: [DiffSegment]) -> (before: String, after: String) {
        let before = parts.filter { $0.kind != .added }.map(\.text).joined()
        let after = parts.filter { $0.kind != .removed }.map(\.text).joined()
        return (before, after)
    }

    static func coalesced(_ parts: [DiffSegment]) -> Bool {
        for i in 1..<parts.count {
            if parts[i].kind == parts[i - 1].kind { return false }
        }
        return parts.allSatisfy { !$0.text.isEmpty }
    }

    static func verifyInvariants(_ before: String, _ after: String, _ parts: [DiffSegment], _ label: String) {
        let r = reconstruct(parts)
        check(r.before == before, "\(label): reconstructs before")
        check(r.after == after, "\(label): reconstructs after")
        check(coalesced(parts), "\(label): segments coalesced and non-empty")
    }

    static func main() {
        typealias R = DiffRules

        // 1. Empty & identical text
        check(R.diff(before: "", after: "").isEmpty, "both empty -> empty")
        let same = R.diff(before: "Hello world", after: "Hello world")
        check(same == [DiffSegment(kind: .same, text: "Hello world")], "identical text -> single .same")
        let sameStats = R.stats(same)
        check(sameStats.added == 0 && sameStats.removed == 0, "identical stats -> 0/0")

        // 2. Pure insertion & pure deletion
        let insAll = R.diff(before: "", after: "new draft text")
        check(insAll == [DiffSegment(kind: .added, text: "new draft text")], "empty -> added")
        check(R.stats(insAll) == (3, 0), "empty -> added stats")

        let delAll = R.diff(before: "old draft text", after: "")
        check(delAll == [DiffSegment(kind: .removed, text: "old draft text")], "removed -> empty")
        check(R.stats(delAll) == (0, 3), "removed -> empty stats")

        // 3. Mid-sentence insertion & deletion
        let insMid = R.diff(before: "Send the report tomorrow", after: "Send the quarterly report tomorrow")
        verifyInvariants("Send the report tomorrow", "Send the quarterly report tomorrow", insMid, "mid insert")
        check(insMid == [
            DiffSegment(kind: .same, text: "Send the "),
            DiffSegment(kind: .added, text: "quarterly "),
            DiffSegment(kind: .same, text: "report tomorrow"),
        ], "mid insert segments")
        check(R.stats(insMid) == (1, 0), "mid insert stats")

        let delMid = R.diff(before: "Please check the draft notes today", after: "Please check the notes today")
        verifyInvariants("Please check the draft notes today", "Please check the notes today", delMid, "mid delete")
        check(delMid == [
            DiffSegment(kind: .same, text: "Please check the "),
            DiffSegment(kind: .removed, text: "draft "),
            DiffSegment(kind: .same, text: "notes today"),
        ], "mid delete segments")
        check(R.stats(delMid) == (0, 1), "mid delete stats")

        // 4. Replacements
        let rep = R.diff(before: "Book a quick call at noon", after: "Schedule a short sync at noon")
        verifyInvariants("Book a quick call at noon", "Schedule a short sync at noon", rep, "replacement")
        check(R.stats(rep) == (3, 3), "replacement word counts")
        check(rep.contains(DiffSegment(kind: .removed, text: "Book")) && rep.contains(DiffSegment(kind: .added, text: "Schedule")), "replacement keeps changed words")
        check(rep.contains(DiffSegment(kind: .same, text: " at noon")), "replacement preserves shared tail")

        // 5. Ukrainian (Cyrillic), apostrophes, and punctuation
        let ukBefore = "Привіт! Надішлю звіт звтра зранку, ім'я файлу уточню."
        let ukAfter = "Вітаю! Надішлю звіт завтра зранку, ім'я документа уточню?"
        let ukDiff = R.diff(before: ukBefore, after: ukAfter)
        verifyInvariants(ukBefore, ukAfter, ukDiff, "Ukrainian + punctuation")
        check(R.tokenize("компʼютер і ім'я, don't!") == ["компʼютер", " ", "і", " ", "ім'я", ",", " ", "don't", "!"], "Ukrainian + English apostrophes tokenized cleanly")
        check(R.stats(ukDiff) == (3, 3), "Ukrainian diff counts 3 added / 3 removed words (punctuation excluded)")
        check(ukDiff.contains(DiffSegment(kind: .removed, text: "звтра")), "Ukrainian typo removed")
        check(ukDiff.contains(DiffSegment(kind: .added, text: "завтра")), "Ukrainian fix added")
        check(ukDiff.contains(DiffSegment(kind: .removed, text: ".")) && ukDiff.contains(DiffSegment(kind: .added, text: "?")), "punctuation diff isolated from word")

        // Punctuation-only edit should report 0/0 changed words
        let punctOnly = R.diff(before: "Готово.", after: "Готово!")
        verifyInvariants("Готово.", "Готово!", punctOnly, "punctuation only")
        check(punctOnly == [
            DiffSegment(kind: .same, text: "Готово"),
            DiffSegment(kind: .removed, text: "."),
            DiffSegment(kind: .added, text: "!"),
        ], "punctuation only isolates mark")
        check(R.stats(punctOnly) == (0, 0), "punctuation only stats -> 0/0")

        // 6. Whitespace and multiline preservation
        let wsBefore = "Line one\n  indented\titem\nLine three"
        let wsAfter = "Line one\n  indented\tentry\nLine three"
        let wsDiff = R.diff(before: wsBefore, after: wsAfter)
        verifyInvariants(wsBefore, wsAfter, wsDiff, "multiline whitespace")
        check(wsDiff == [
            DiffSegment(kind: .same, text: "Line one\n  indented\t"),
            DiffSegment(kind: .removed, text: "item"),
            DiffSegment(kind: .added, text: "entry"),
            DiffSegment(kind: .same, text: "\nLine three"),
        ], "multiline tabs and spaces preserved")
        check(R.stats(wsDiff) == (1, 1), "multiline whitespace stats")

        // 7. Large-text fallback (> 600 tokens)
        let prefixWords = "Start of large paste. "
        let suffixWords = " End of large paste."
        let bigA = prefixWords + (0..<400).map { "alpha\($0)" }.joined(separator: " ") + suffixWords
        let bigB = prefixWords + (0..<400).map { "beta\($0)" }.joined(separator: " ") + suffixWords
        let bigTokensA = R.tokenize(bigA)
        check(bigTokensA.count > R.maxTokens, "large-text fixture exceeds maxTokens (\(bigTokensA.count))")
        let t0 = Date()
        let bigDiff = R.diff(before: bigA, after: bigB)
        let elapsed = Date().timeIntervalSince(t0)
        verifyInvariants(bigA, bigB, bigDiff, "large-text fallback")
        check(elapsed < 0.5, "large-text fallback completes quickly (\(elapsed)s)")
        check(bigDiff.first == DiffSegment(kind: .same, text: prefixWords), "large-text fallback preserves common prefix")
        check(bigDiff.last == DiffSegment(kind: .same, text: suffixWords), "large-text fallback preserves common suffix")
        check(R.stats(bigDiff) == (400, 400), "large-text fallback stats accurate")

        // Large text with tiny middle edit still diffs precisely because prefix/suffix trim brings middle under limit
        let shared = (0..<350).map { "word\($0)" }.joined(separator: " ")
        let bigSmallEditA = shared + " oldval " + shared
        let bigSmallEditB = shared + " newval " + shared
        let bigSmallDiff = R.diff(before: bigSmallEditA, after: bigSmallEditB)
        verifyInvariants(bigSmallEditA, bigSmallEditB, bigSmallDiff, "large text small middle edit")
        check(R.stats(bigSmallDiff) == (1, 1), "large text small middle edit gives exact 1/1 diff")

        print(failed == 0 ? "diff rules: \(ran) ok" : "diff rules: \(failed) of \(ran) failed")
        exit(failed == 0 ? 0 : 1)
    }
}

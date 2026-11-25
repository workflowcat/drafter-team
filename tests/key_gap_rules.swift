import Foundation

// swiftc -parse-as-library app/KeyGapRules.swift tests/key_gap_rules.swift -o app/build/key-gap-rules-test && app/build/key-gap-rules-test
// Key gaps (14 November 2026): the histogram of gaps between typed letters, with made-up key sequences only.
@main
struct KeyGapRulesChecks {
    static var failures = 0
    static func check(_ ok: Bool, _ what: String) { if !ok { print("FAIL: " + what); failures += 1 } }
    static let ms: UInt64 = 1_000_000
    static let a: UInt16 = 0x61

    static func main() {
        // a run of letters in one chat field: the first key starts it, the ask after it confirms the field
        var g = KeyGaps()
        var t: UInt64 = 1_000 * ms, rev = 1
        check(g.key(at: t, rev: rev, field: 0, unit: a, secure: false, ghost: false) == nil, "the first key has no gap")
        check(g.field("chat", rev: rev) == nil, "the field read logs nothing")
        for (gap, ghost) in [(50, false), (70, true), (100, false), (130, false), (170, true), (250, false), (400, false), (800, false), (1500, true)] {
            t += UInt64(gap) * ms; rev += 1
            check(g.key(at: t, rev: rev, field: 0, unit: a, secure: false, ghost: ghost) == nil, "within the minute nothing is logged")
            _ = g.field("chat", rev: rev)
        }
        check(g.counts == [1, 1, 1, 1, 1, 1, 1, 1] && g.pauses == 1 && g.ghost == 3, "one gap per bucket, one pause, three after a ghost")
        // edges: 60 ms goes to lt90, 59 to lt60, 1000 is a pause
        var e = KeyGaps(); var te: UInt64 = 0
        _ = e.key(at: te, rev: 1, field: 0, unit: a, secure: false, ghost: false); _ = e.field("other", rev: 1)
        for (i, gap) in [59, 60, 999, 1000].enumerated() { te += UInt64(gap) * ms; _ = e.key(at: te, rev: i + 2, field: 0, unit: a, secure: false, ghost: false) }
        check(e.counts == [1, 1, 0, 0, 0, 0, 0, 1] && e.pauses == 1, "bucket edges: 59 | 60 | 999 | 1000 = pause")

        // a minute later the next key writes the line of the minute before
        t += 61_000 * ms; rev += 1
        let line = g.key(at: t, rev: rev, field: 0, unit: a, secure: false, ghost: false)
        check(line == "keygap chat lt60 1 lt90 1 lt120 1 lt150 1 lt200 1 lt300 1 lt500 1 lt1000 1 pause 1 ghost 3", "the minute's line: \(line ?? "nil")")
        check(g.pauses == 1 && g.counts.reduce(0, +) == 0, "the new window holds only the key that closed the old one (a pause)")

        // what is never counted
        var n = KeyGaps(); var tn: UInt64 = 0
        _ = n.key(at: tn, rev: 1, field: 0, unit: a, secure: false, ghost: false); _ = n.field("mail", rev: 1)
        tn += 100 * ms; _ = n.key(at: tn, rev: 2, field: 0, unit: 0x08, secure: false, ghost: false)          // Backspace
        tn += 100 * ms; _ = n.key(at: tn, rev: 3, field: 0, unit: a, secure: false, ghost: false)             // after it: no gap
        _ = n.field("mail", rev: 3)                                                                            // the ask after the key
        check(n.total == 0, "a control key breaks the run: \(n.total)")
        tn += 100 * ms; _ = n.key(at: tn, rev: 4, field: 0, unit: a, secure: false, ghost: false)
        check(n.total == 1, "the next letter counts again")
        tn += 100 * ms; _ = n.key(at: tn, rev: 6, field: 0, unit: a, secure: false, ghost: false)             // a key in between (Tab taken)
        check(n.total == 1, "a key that did not reach typing breaks the run")
        tn += 100 * ms; _ = n.key(at: tn, rev: 7, field: 1, unit: a, secure: false, ghost: false)             // a click: new field
        check(n.total == 1, "a click (new field token) breaks the run")
        tn += 100 * ms; _ = n.key(at: tn, rev: 8, field: 1, unit: a, secure: false, ghost: false)
        check(n.total == 1, "a run not yet confirmed by a field read is not counted")
        _ = n.field("mail", rev: 8)
        tn += 100 * ms; _ = n.key(at: tn, rev: 9, field: 1, unit: a, secure: false, ghost: false)
        check(n.total == 2, "confirmed: counted")
        tn += 100 * ms; _ = n.key(at: tn, rev: 10, field: 1, unit: a, secure: true, ghost: false)
        check(n.total == 2, "secure input: nothing")
        tn += 100 * ms; _ = n.key(at: tn, rev: 11, field: 1, unit: a, secure: false, ghost: false)
        check(n.total == 2, "nor the gap across it")
        _ = n.field("mail", rev: 11)
        tn += 100 * ms; _ = n.key(at: tn, rev: 12, field: 1, unit: a, secure: false, ghost: false)
        check(n.total == 3, "after it again")
        check(n.field(nil, rev: 12) == nil, "a password field or skipped app logs nothing")
        tn += 100 * ms; _ = n.key(at: tn, rev: 13, field: 1, unit: a, secure: false, ghost: false)
        tn += 100 * ms; _ = n.key(at: tn, rev: 14, field: 1, unit: a, secure: false, ghost: false)
        check(n.total == 3, "nothing in a field that may not be counted")
        for u: UInt16 in [0x0D, 0x09, 0x1B, 0x7F, 0xF700, 0xF8FF] { check(!KeyGaps.isLetter(u), "not a letter: \(u)") }
        for u: UInt16 in [0x20, 0x61, 0x0456, 0x2019] { check(KeyGaps.isLetter(u), "a letter: \(u)") }

        // the gap before the last key (cadence round): known only inside a run of letters in one field
        var c = KeyGaps(); var tc: UInt64 = 0
        _ = c.key(at: tc, rev: 1, field: 0, unit: a, secure: false, ghost: false)
        check(c.lastMs == -1, "the first key has no gap")
        tc += 85 * ms; _ = c.key(at: tc, rev: 2, field: 0, unit: a, secure: false, ghost: false)
        check(c.lastMs == 85, "a gap before the field is confirmed is still known: \(c.lastMs)")
        tc += 140 * ms; _ = c.key(at: tc, rev: 4, field: 0, unit: a, secure: false, ghost: false)
        check(c.lastMs == -1, "a key in between: unknown")
        tc += 50 * ms; _ = c.key(at: tc, rev: 5, field: 0, unit: 0x0D, secure: false, ghost: false)
        check(c.lastMs == -1, "Return: unknown")
        tc += 50 * ms; _ = c.key(at: tc, rev: 6, field: 0, unit: a, secure: false, ghost: false)
        tc += 70 * ms; _ = c.key(at: tc, rev: 7, field: 0, unit: a, secure: true, ghost: false)
        check(c.lastMs == -1, "secure input: unknown")

        // a new app kind closes the window at once
        let k = n.field("ai", rev: 14)
        check(k == "keygap mail lt60 0 lt90 0 lt120 3 lt150 0 lt200 0 lt300 0 lt500 0 lt1000 0 pause 0 ghost 0", "kind change: \(k ?? "nil")")
        check(n.total == 0 && n.field("ai", rev: 14) == nil, "the same kind again: nothing to write")
        check(KeyGaps().flushed == nil, "an empty window writes nothing")

        // the line holds only the kind and numbers
        if let l = line {
            let words = l.split(separator: " ")
            check(words.count == 22 && words[0] == "keygap" && KeyGaps.kinds.contains(String(words[1])), "shape")
            check(words.dropFirst(2).enumerated().allSatisfy { $0.offset % 2 == 1 ? Int($0.element) != nil : Int($0.element) == nil }, "names then numbers")
        }

        print(failures == 0 ? "key gap rules: all passed" : "key gap rules: \(failures) failed")
        exit(failures == 0 ? 0 : 1)
    }
}

extension KeyGaps { var flushed: String? { var c = self; return c.flush() } }

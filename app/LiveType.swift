// Live typing rules (pure, 2026-11-14): which words of a draft are steady, what goes into the field next, and the
// smallest set of key steps that turns what Drafter typed into the final text. Talk (Voice.swift) does the typing.
//
// Why (Andrii, 2026-11-14: "the part up top near the notch is looking really good while typing in the text box is quite
// slower"): the field got only words two drafts agreed on minus the last two (the strip: minus the last one); once a
// word already in the field changed in a later draft (a comma, a capital after a new full stop, a word near a 28 s
// cut), nothing more went in until Enter, and then the rest came in one burst (13-14 November: 20 of 36 piece ends,
// 12-1,572 characters at once); at the end the changed tail was backspaced and typed again.
import Foundation

enum LiveType {
    // MARK: steady words

    /// How many words of `next` are steady, by the strip's own rule (Pill.fadeIn): the same as in the previous draft,
    /// never the newest word. `still` counts drafts in a row that came out exactly alike: at 3 he has paused, and the
    /// last word is steady too (it waited for his next word before, which can be seconds).
    static func steady(_ prev: [Substring], _ next: [Substring], still: Int) -> Int {
        var n = 0
        while n < min(prev.count, next.count), prev[n] == next[n] { n += 1 }
        if still >= 3 { return n }
        return n == next.count ? max(0, n - 1) : n
    }

    /// The first `n` words of a text as they stand in it (its own spaces and line breaks).
    static func head(_ text: String, words n: Int) -> String {
        guard n > 0 else { return "" }
        let w = words(text)
        guard !w.isEmpty else { return "" }
        return String(text[..<w[min(n, w.count) - 1].end])
    }

    struct Word { let start: String.Index, end: String.Index, core: String }

    /// Words split at white space, each with its letters and digits in lower case (`core`): "Так," and "так" are one word.
    static func words(_ s: String) -> [Word] {
        var out: [Word] = [], i = s.startIndex
        while i < s.endIndex {
            while i < s.endIndex, s[i].isWhitespace { i = s.index(after: i) }
            guard i < s.endIndex else { break }
            let a = i
            while i < s.endIndex, !s[i].isWhitespace { i = s.index(after: i) }
            out.append(Word(start: a, end: i, core: core(s[a..<i])))
        }
        return out
    }

    static func core<S: StringProtocol>(_ w: S) -> String {
        String(String.UnicodeScalarView(w.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }))
    }

    /// Same words, only case and punctuation differ.
    static func onlyMarks(_ a: String, _ b: String) -> Bool {
        words(a).map(\.core).filter { !$0.isEmpty } == words(b).map(\.core).filter { !$0.isEmpty }
    }

    // MARK: where the field stands in a new text

    /// The place in `want` just after the words the field already holds (`have`): its last two words (else its last one)
    /// found in `want`, as near to where they are in `have` as possible. Case and punctuation are ignored, so a comma
    /// or a capital that came later never loses the place. Nil when they are not found near there.
    static func aligned(_ have: String, in want: String) -> String.Index? {
        let hw = words(have).map(\.core), ww = words(want)
        guard !hw.isEmpty else { return want.startIndex }
        let wc = ww.map(\.core), m = hw.count
        for k in [2, 1] where hw.count >= k {
            let tail = Array(hw.suffix(k))
            if tail.allSatisfy(\.isEmpty) { continue }
            for d in 0...4 {
                for j in Set([m + d, m - d]).sorted() where j >= k && j <= wc.count {
                    if Array(wc[(j - k)..<j]) == tail { return ww[j - 1].end }
                }
            }
        }
        return nil
    }

    // MARK: edits

    /// One change inside the field's run: at character `at` (of the run as it is), `remove` characters go and `insert`
    /// comes in their place.
    struct Change: Equatable { var at: Int, remove: Int, insert: String }

    /// Key steps for the field: `left`/`right` move the caret, `select` takes characters before the caret (Shift+Left),
    /// `type` writes over what is selected (or at the caret), `erase` deletes the selection (Backspace).
    enum Key: Equatable { case left(Int), right(Int), select(Int), type(String), erase }

    /// The changes that turn `have` into `want`, touching only what differs: word by word when both have the same words
    /// apart from marks (each differing word gets its own small change), else one change between the common start and
    /// the common end.
    static func changes(_ have: String, _ want: String) -> [Change] {
        if have == want { return [] }
        let a = Array(have), b = Array(want)
        let wa = words(have), wb = words(want)
        if wa.count == wb.count, !wa.isEmpty, gaps(have, wa) == gaps(want, wb) {
            var out: [Change] = []
            for (x, y) in zip(wa, wb) {
                let sx = String(have[x.start..<x.end]), sy = String(want[y.start..<y.end])
                guard sx != sy else { continue }
                let off = have.distance(from: have.startIndex, to: x.start)
                for c in changes1(Array(sx), Array(sy)) { out.append(Change(at: off + c.at, remove: c.remove, insert: c.insert)) }
            }
            return out
        }
        return changes1(a, b)
    }

    private static func gaps(_ s: String, _ w: [Word]) -> [String] {
        zip(w, w.dropFirst()).map { String(s[$0.end..<$1.start]) }
    }

    private static func changes1(_ a: [Character], _ b: [Character]) -> [Change] {
        var p = 0
        while p < a.count, p < b.count, a[p] == b[p] { p += 1 }
        var s = 0
        while s < a.count - p, s < b.count - p, a[a.count - 1 - s] == b[b.count - 1 - s] { s += 1 }
        let r = a.count - p - s, ins = String(b[p..<(b.count - s)])
        return r == 0 && ins.isEmpty ? [] : [Change(at: p, remove: r, insert: ins)]
    }

    /// Characters removed plus characters written.
    static func touched(_ c: [Change]) -> Int { c.reduce(0) { $0 + $1.remove + $1.insert.count } }
    /// How far back from the end of the run the caret has to go.
    static func reach(_ c: [Change], length: Int) -> Int { c.map { length - $0.at }.max() ?? 0 }

    /// The key steps for `changes` on a run of `length` characters with the caret at its end: last change first, the
    /// caret back at the end afterwards. A change at the very end needs no caret move.
    static func keys(_ changes: [Change], length: Int) -> [Key] {
        var out: [Key] = [], caret = length
        for c in changes.sorted(by: { $0.at > $1.at }) {
            let end = c.at + c.remove
            if caret > end { out.append(.left(caret - end)) }
            if c.remove > 0 { out.append(.select(c.remove)) }
            if c.insert.isEmpty { if c.remove > 0 { out.append(.erase) } } else { out.append(.type(c.insert)) }
            caret = c.at + c.insert.count   // what comes before this change did not move
        }
        // back to the end: everything after the first changed place, as it is now
        let firstAt = changes.map(\.at).min() ?? length
        let delta = changes.reduce(0) { $0 + $1.insert.count - $1.remove }
        let after = (length + delta) - (firstAt + (changes.min(by: { $0.at < $1.at })?.insert.count ?? 0))
        if !changes.isEmpty, after > 0 { out.append(.right(after)) }
        return out
    }

    /// The field after `keys`, for tests: text, caret at the end, a selection made by `select`.
    static func run(_ keys: [Key], on text: String) -> (String, Int) {
        var t = Array(text), caret = t.count, sel = 0
        for k in keys {
            switch k {
            case .left(let n): caret = max(0, caret - n); sel = 0
            case .right(let n): caret = min(t.count, caret + n); sel = 0
            case .select(let n): sel = min(caret, n)
            case .type(let s): t.removeSubrange((caret - sel)..<caret); caret -= sel; sel = 0
                t.insert(contentsOf: Array(s), at: caret); caret += s.count
            case .erase: if sel > 0 { t.removeSubrange((caret - sel)..<caret); caret -= sel; sel = 0 } else if caret > 0 { t.remove(at: caret - 1); caret -= 1 }
            }
        }
        return (String(t), caret)
    }

    // MARK: the next step

    /// What to do with the field's run `have` (what Drafter typed since it last started a run) to show `want`.
    struct Plan: Equatable {
        var keys: [Key] = []          // fixes to what is already in the field (none, or the ones allowed)
        var append = ""               // new text after the run
        var next = ""                 // the run once both are done
        var left: [Change] = []       // differences seen but not fixed (too big for now)
        var fixed = 0                 // characters touched by the fixes
        var lost = false              // `have` could not be placed in `want`: nothing typed
        var marksOnly = false         // what `left` holds is only case and punctuation (no word is wrong)
    }

    /// While he talks only small fixes near the caret (a comma, a capital, the last word); at the end of a take or an
    /// Enter piece (`end`), any fix of the same words, or one that touches at most a share of the take.
    static let midReach = 16, midTouch = 12
    static let endReach = 400, endShare = 0.3, endFloor = 24

    /// How a take's (or an Enter piece's) end reaches the final text (the cut-off fault, 14 November 2026: when the
    /// final text differed a lot from what was typed live, the field kept the few live words and the rest went only to
    /// the clipboard; 7 of 25 live ends that day). `keys`: the plan's own fixes and append get the field to the final
    /// text (or differ only in marks far back). `replace`: the whole run is replaced by the final text in one step.
    enum EndWay: Equatable { case keys(Plan), replace(String) }
    static func endWay(have: String, want: String) -> EndWay {
        let p = plan(have: have, want: want, end: true)
        if p.left.isEmpty || p.marksOnly { return .keys(p) }
        return .replace(want)
    }

    static func plan(have: String, want: String, end: Bool) -> Plan {
        var p = Plan()
        if want.hasPrefix(have) {
            p.append = String(want.dropFirst(have.count)); p.next = want
            return p
        }
        var head: String, rest: String
        if let j = aligned(have, in: want) {
            head = String(want[..<j]); rest = String(want[j...])
        } else if end || have.count - common(have, want) <= midReach {
            head = want; rest = ""   // one change from the first difference on (a short run, or the end of a take)
        } else {
            p.lost = true; p.next = have
            return p
        }
        if !end, want.count < have.count, have.hasPrefix(head) { p.next = have; return p }   // a draft that shrank: wait
        let ch = changes(have, head)
        var take: [Change] = [], wait: [Change] = []
        if !end {
            // near the caret now, the rest at the end
            for c in ch { if have.count - c.at <= midReach { take.append(c) } else { wait.append(c) } }
            if touched(take) > midTouch { wait += take; take = [] }
        } else if onlyMarks(have, head) || touched(ch) <= max(endFloor, Int(endShare * Double(max(head.count, have.count)))) {
            // a mark far back (more than `endReach` characters) is not worth walking the caret through the text
            for c in ch { if have.count - c.at <= endReach { take.append(c) } else { wait.append(c) } }
        } else {
            wait = ch
        }
        p.marksOnly = onlyMarks(have, head)
        p.keys = keys(take, length: have.count)
        p.fixed = touched(take)
        p.left = wait.sorted { $0.at < $1.at }
        p.next = run(p.keys, on: have).0 + rest
        p.append = rest
        return p
    }

    static func common(_ a: String, _ b: String) -> Int {
        var n = 0
        for (x, y) in zip(a, b) { if x != y { break }; n += 1 }
        return n
    }

    /// A space before new words when the character before the caret is not one (and the words do not start with a mark).
    static func spaced(_ t: String, after last: Character?) -> String {
        guard let last, !last.isWhitespace, let first = t.first, !first.isWhitespace, !",.!?;:)…".contains(first) else { return t }
        return " " + t
    }

    // MARK: how far the field is behind the strip

    /// Per word of a run: when it first showed in the strip, when it became steady there, when it reached the field.
    struct Meter {
        private var shown: [Double] = [], steady: [Double] = []
        private(set) var lagSteady: [Double] = [], lagShown: [Double] = []
        private(set) var landed = 0
        var steps = 0   // times words went into the field

        mutating func reset() { shown = []; steady = []; landed = 0 }
        mutating func saw(words n: Int, at t: Double) { while shown.count < n { shown.append(t) } }
        mutating func settled(words n: Int, at t: Double) {
            while steady.count < n { steady.append(t) }
            saw(words: n, at: t)
        }
        /// The first `n` words of the run are in the field now.
        mutating func typed(words n: Int, at t: Double) {
            guard n > landed else { return }
            settled(words: n, at: t)
            for i in landed..<n { lagSteady.append(t - steady[i]); lagShown.append(t - shown[i]) }
            landed = n; steps += 1
        }

        static func median(_ v: [Double]) -> Double {
            guard !v.isEmpty else { return 0 }
            let s = v.sorted(); return s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2
        }
        /// "steady -> field median X ms, worst Y ms; shown -> field median X ms, worst Y ms"
        var summary: String {
            func ms(_ x: Double) -> Int { Int((x * 1000).rounded()) }
            return "steady -> field median \(ms(Meter.median(lagSteady))) ms, worst \(ms(lagSteady.max() ?? 0)) ms; "
                + "shown -> field median \(ms(Meter.median(lagShown))) ms, worst \(ms(lagShown.max() ?? 0)) ms"
        }
    }
}

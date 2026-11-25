// Pick parts (15 November 2026; Andrii: "when I have to copy a text, to just select the parts that I need from the
// full thing and save it separately"). Pure: Foundation only, no AppKit, no files except `append` (a temp folder in
// tests). One long text is cut into pieces at a level (paragraphs, lines, sentences, list items or table rows, things),
// each piece keeps its exact range in the original (UTF-16, as NSRange), he picks pieces, and the pick becomes a new
// text: joined in the original order, or "the rest" (the original without the pick). The panel is app/PickPanel.swift;
// the state machine for its keys (`PickState`) lives here so it is tested without a screen. Tests: tests/pick_rules.swift.
import Foundation

enum PickLevel: Int, CaseIterable {
    case paragraphs = 1, lines, sentences, items, things
    var word: String {
        switch self { case .paragraphs: return "Paragraphs"; case .lines: return "Lines"; case .sentences: return "Sentences"
        case .items: return "Items"; case .things: return "Things" }
    }
    /// One piece, for the status line ("3 of 9 sentences").
    func noun(_ n: Int) -> String {
        let one: String
        switch self { case .paragraphs: one = "paragraph"; case .lines: one = "line"; case .sentences: one = "sentence"
        case .items: one = "item"; case .things: one = "thing" }
        return n == 1 ? one : one + "s"
    }
}

/// One piece of the original. `range`: the piece as he sees it (no spaces around it). `body`: the same without a list
/// mark (equal to `range` when it has none). `kind`: "text", "item", "row" (a table row), or a thing's kind ("link",
/// "date", "amount", "email", ...). `label`: a thing's short name from the detector ("" otherwise).
struct PickPiece: Equatable {
    let range: NSRange
    let body: NSRange
    var kind = "text"
    var label = ""
    var para = 0          // which paragraph it sits in (sentences from two paragraphs join with an empty line)
}

/// A detector of "things" in a text: ranges (UTF-16), a kind and a label. Injected so the panel and its tests do not
/// depend on the detector another track writes; `PickRules.basicThings` stands in until then.
typealias PickThings = (String) -> [(range: NSRange, kind: String, label: String)]

/// A kept pick: a new clip that came from another item.
struct PickRecord: Equatable {
    let text: String
    let from: String              // the source item's id (PickRules.sourceId)
    let picked: [NSRange]         // the picked ranges in the source, in order
    let at: Double                // seconds since 1970
    var level = PickLevel.sentences
    var rest = false              // true: "the rest" was kept (the pick removed)
    var mine = false              // the source was his own writing (a draft, a sent line, a voice take)

    /// The clipboard.jsonl row: a text clip like any other, plus `from`, `picked` ([[location, length], ...]),
    /// `pick` (the level) and `via` = "pick". `mine` only when true. Old readers ignore the extra keys.
    func row(app: String) -> [String: Any] {
        var r: [String: Any] = ["t": at, "text": text, "app": app, "via": "pick", "from": from,
                                "picked": picked.map { [$0.location, $0.length] }, "pick": rest ? "rest" : PickRules.levelId(level)]
        if mine { r["mine"] = true }
        return r
    }
    /// The read side: a row's derived fields, or nil for a row that did not come from a pick (old files load as before).
    static func read(_ r: [String: Any]) -> PickRecord? {
        guard let from = r["from"] as? String, !from.isEmpty, let text = r["text"] as? String else { return nil }
        let picked: [NSRange] = (r["picked"] as? [[Any]] ?? []).compactMap { p in
            guard p.count == 2, let a = (p[0] as? NSNumber)?.intValue, let b = (p[1] as? NSNumber)?.intValue, a >= 0, b >= 0 else { return nil }
            return NSRange(location: a, length: b)
        }
        let how = r["pick"] as? String ?? ""
        return PickRecord(text: text, from: from, picked: picked, at: (r["t"] as? NSNumber)?.doubleValue ?? 0,
                          level: PickRules.level(id: how) ?? .sentences, rest: how == "rest", mine: r["mine"] as? Bool ?? false)
    }
}

enum PickRules {
    static func levelId(_ l: PickLevel) -> String { ["", "paragraphs", "lines", "sentences", "items", "things"][l.rawValue] }
    static func level(id: String) -> PickLevel? { PickLevel.allCases.first { levelId($0) == id } }

    /// The id of the item a pick came from: FNV-1a 64 of kind + U+0001 + text, hex, the same as QuickItem.id for a
    /// row without a picture ("copied", "typed", "voice").
    static func sourceId(kind: String, text: String) -> String {
        var h: UInt64 = 0xcbf29ce484222325
        for b in (kind + "\u{1}" + text).utf8 { h ^= UInt64(b); h = h &* 0x100000001b3 }
        return String(h, radix: 16)
    }

    // MARK: lines

    struct Line { let range: NSRange; let trimmed: NSRange; var blank: Bool { trimmed.length == 0 } }

    /// Every line with its range (without the line break) and the same without spaces at both ends.
    static func lines(_ ns: NSString) -> [Line] {
        var out: [Line] = []
        var at = 0
        let n = ns.length
        while at <= n {
            var end = at
            while end < n, !isBreak(ns.character(at: end)) { end += 1 }
            out.append(Line(range: NSRange(location: at, length: end - at), trimmed: trim(ns, NSRange(location: at, length: end - at))))
            if end >= n { break }
            at = end + ((ns.character(at: end) == 13 && end + 1 < n && ns.character(at: end + 1) == 10) ? 2 : 1)
        }
        return out
    }
    static func isBreak(_ c: unichar) -> Bool { c == 10 || c == 13 || c == 0x2028 || c == 0x2029 }
    static func isSpace(_ c: unichar) -> Bool { c == 32 || c == 9 || c == 0xA0 || c == 0x202F || c == 0x2009 || c == 0x3000 || c == 0xFEFF || isBreak(c) }
    static func trim(_ ns: NSString, _ r: NSRange) -> NSRange {
        var a = r.location, b = r.location + r.length
        while a < b, isSpace(ns.character(at: a)) { a += 1 }
        while b > a, isSpace(ns.character(at: b - 1)) { b -= 1 }
        return NSRange(location: a, length: b - a)
    }

    /// Paragraph number of each line (blank lines between paragraphs; a blank line has the number of the one before).
    static func paraOf(_ ls: [Line]) -> [Int] {
        var p = 0, seenText = false, out: [Int] = []
        var prevBlank = false
        for l in ls {
            if l.blank { prevBlank = true; out.append(p); continue }
            if prevBlank && seenText { p += 1 }
            prevBlank = false; seenText = true
            out.append(p)
        }
        return out
    }

    // MARK: list marks and table rows

    /// The length of a list mark at the start of `r` (with the space after it), 0 when the line is not a list item:
    /// - * • · – — + ▪ ◦ ‣ ✓ ✔ ☐ ☑, "- [ ]" / "- [x]", 1. 1) 12. a) b. (a) (1) i. ii) - and Ukrainian а) б).
    static func markLength(_ ns: NSString, _ r: NSRange) -> Int {
        guard r.length >= 2 else { return 0 }
        let s = ns.substring(with: r)
        let pattern = #"^(?:[-*•·–—+▪◦‣✓✔☐☑](?:\s\[[ xX✓]\])?|\(?(?:\d{1,3}|[a-zA-Zа-яіїєґА-ЯІЇЄҐ]|[ivxIVX]{1,4})[.)])\s+"#
        guard let rx = cached(pattern), let m = rx.firstMatch(in: s, range: NSRange(location: 0, length: (s as NSString).length)) else { return 0 }
        if m.range.length >= (s as NSString).length { return 0 }          // a mark alone is not an item
        // "Mr. Smith", "A. Bondar": a single capital letter with a dot is an initial unless more marks follow
        let head = (s as NSString).substring(to: m.range.length).trimmingCharacters(in: .whitespaces)
        if head.count == 2, head.hasSuffix("."), let f = head.first, f.isLetter, f.isUppercase { return 0 }
        // roman numerals and letters only with ")" or "." and a short head; a word like "I. think" stays text
        return m.range.length
    }
    /// A table row: holds a tab between two cells, or starts and ends with "|", or has two "|" between words.
    static func isRow(_ ns: NSString, _ r: NSRange) -> Bool {
        guard r.length > 0 else { return false }
        let s = ns.substring(with: r)
        if s.contains("\t") { return true }
        let bars = s.filter { $0 == "|" }.count
        return (s.hasPrefix("|") && s.hasSuffix("|") && bars >= 2) || bars >= 2
    }
    /// A table's rule line: |---|:--:| or +---+ or only dashes and bars.
    static func isRule(_ ns: NSString, _ r: NSRange) -> Bool {
        let s = ns.substring(with: r)
        return !s.isEmpty && s.allSatisfy { "|-:+= \t".contains($0) } && s.contains("-")
    }

    // MARK: splitting

    static func split(_ text: String, _ level: PickLevel, things: PickThings? = nil) -> [PickPiece] {
        let ns = text as NSString
        let ls = lines(ns), para = paraOf(ls)
        switch level {
        case .paragraphs:
            var out: [PickPiece] = []
            var start: Int?, end = 0, p = 0
            for (i, l) in ls.enumerated() {
                if l.blank { if let s = start { out.append(piece(NSRange(location: s, length: end - s), para: p)); start = nil }; continue }
                if start == nil { start = l.trimmed.location; p = para[i] }
                end = l.trimmed.location + l.trimmed.length
            }
            if let s = start { out.append(piece(NSRange(location: s, length: end - s), para: p)) }
            return out
        case .lines:
            return ls.enumerated().filter { !$0.element.blank && !isRule(ns, $0.element.trimmed) }.map { i, l in
                let m = markLength(ns, l.trimmed)
                return PickPiece(range: l.trimmed, body: NSRange(location: l.trimmed.location + m, length: l.trimmed.length - m),
                                 kind: m > 0 ? "item" : "text", para: para[i])
            }
        case .items: return items(ns, ls, para)
        case .sentences: return sentences(ns, ls, para)
        case .things:
            let found = (things ?? basicThings)(text).filter { $0.range.length > 0 && $0.range.location + $0.range.length <= ns.length }
                .sorted { $0.range.location != $1.range.location ? $0.range.location < $1.range.location : $0.range.length > $1.range.length }
            var out: [PickPiece] = [], until = 0
            for f in found where f.range.location >= until {          // overlapping finds: the first, longest one wins
                let p = paraIndex(f.range.location, ls, para)
                out.append(PickPiece(range: f.range, body: f.range, kind: f.kind, label: f.label, para: p))
                until = f.range.location + f.range.length
            }
            return out
        }
    }
    private static func piece(_ r: NSRange, para: Int) -> PickPiece { PickPiece(range: r, body: r, para: para) }
    private static func paraIndex(_ at: Int, _ ls: [Line], _ para: [Int]) -> Int {
        for (i, l) in ls.enumerated() where at <= l.range.location + l.range.length { return para[i] }
        return para.last ?? 0
    }

    /// List items with their wrapped lines (a line indented under an item, or a plain line right under one inside the
    /// same block, belongs to it); table rows (rule lines skipped); every other line its own piece.
    private static func items(_ ns: NSString, _ ls: [Line], _ para: [Int]) -> [PickPiece] {
        var out: [PickPiece] = []
        var open = false        // the last piece is an item that may go on
        for (i, l) in ls.enumerated() {
            if l.blank { open = false; continue }
            if isRule(ns, l.trimmed) { open = false; continue }
            if isRow(ns, l.trimmed) {
                // a row's body: without the outer bars
                var b = l.trimmed
                if ns.character(at: b.location) == 124 { b = trim(ns, NSRange(location: b.location + 1, length: b.length - 1)) }
                if b.length > 0, ns.character(at: b.location + b.length - 1) == 124 { b = trim(ns, NSRange(location: b.location, length: b.length - 1)) }
                out.append(PickPiece(range: l.trimmed, body: b, kind: "row", para: para[i])); open = false; continue
            }
            let m = markLength(ns, l.trimmed)
            if m > 0 {
                out.append(PickPiece(range: l.trimmed, body: NSRange(location: l.trimmed.location + m, length: l.trimmed.length - m), kind: "item", para: para[i]))
                open = true; continue
            }
            let indented = l.trimmed.location > l.range.location
            if open, indented, var last = out.popLast() {
                let end = l.trimmed.location + l.trimmed.length
                last = PickPiece(range: NSRange(location: last.range.location, length: end - last.range.location),
                                 body: NSRange(location: last.body.location, length: end - last.body.location), kind: last.kind, para: last.para)
                out.append(last); continue
            }
            out.append(PickPiece(range: l.trimmed, body: l.trimmed, para: para[i])); open = false
        }
        return out
    }

    // MARK: sentences

    /// Never end a sentence: titles, "e.g.", Ukrainian "напр.", "вул.", "ст.", "м.", "р." and the like (lower-cased,
    /// without the dot). A word after them may start with a capital.
    static let neverEnd: Set<String> = [
        "mr", "mrs", "ms", "dr", "prof", "sr", "jr", "st", "vs", "fig", "figs", "approx", "dept",
        "corp", "gov", "lt", "col", "sgt", "capt", "mt", "ave", "blvd", "rd", "jan", "feb", "mar", "apr",
        "jun", "jul", "aug", "sep", "sept", "oct", "nov", "dec", "e.g", "i.e", "cf", "al", "p", "pp", "vol", "ch", "sec",
        "напр", "вул", "просп", "пров", "пл", "буд", "кв", "ст", "м", "с", "смт", "р", "рр", "т", "див", "проф", "доц",
        "акад", "ім", "обл", "р-н", "тис", "млн", "млрд", "коп", "дол", "розд", "п", "пп", "гл", "англ",
        "укр", "рос", "лат", "нім", "франц", "і.о", "в.о", "т.зв", "зав", "заст",
    ]
    /// May end a sentence, but only when a capital follows: "etc.", "т.д.", "т.п.", "p.m.", "a.m.", "і т.ін.".
    static let mayEnd: Set<String> = ["etc", "т.д", "т.п", "т.і", "т.ін", "p.m", "a.m", "inc", "ltd", "co", "і.т.д", "ін", "грн"]

    /// Sentences: within a paragraph, a single line break counts as a space when the line before does not end with
    /// . ! ? … : ; and the next line starts with a small letter (wrapped prose); any other line break ends the piece.
    /// A sentence ends after . ! ? … (and closing quotes or brackets) before a space, when the next word does not
    /// start with a small letter; a dot after an abbreviation (`neverEnd`), an initial ("A.", "Т."), a number ("1."
    /// inside a line) does not end it; `mayEnd` words end it only before a capital. Dots inside URLs, emails and
    /// decimals never end one, since no space follows them.
    private static func sentences(_ ns: NSString, _ ls: [Line], _ para: [Int]) -> [PickPiece] {
        // blocks: runs of lines joined by the wrap rule
        var blocks: [(NSRange, Int)] = []
        var cur: NSRange?, curPara = 0
        for (i, l) in ls.enumerated() {
            if l.blank { if let c = cur { blocks.append((c, curPara)); cur = nil }; continue }
            if let c = cur {
                let lastCh = ns.character(at: c.location + c.length - 1)
                let firstCh = ns.character(at: l.trimmed.location)
                let wrap = !"…:;.!?".utf16.contains(lastCh) && isLower(firstCh) && markLength(ns, l.trimmed) == 0
                if wrap { cur = NSRange(location: c.location, length: l.trimmed.location + l.trimmed.length - c.location); continue }
                blocks.append((c, curPara))
            }
            cur = l.trimmed; curPara = para[i]
        }
        if let c = cur { blocks.append((c, curPara)) }

        var out: [PickPiece] = []
        for (b, p) in blocks {
            var start = b.location
            let end = b.location + b.length
            // a list mark at the start of a block stays with its sentence
            var i = b.location
            while i < end {
                let c = ns.character(at: i)
                guard c == 46 || c == 33 || c == 63 || c == 0x2026 else { i += 1; continue }
                var j = i
                while j + 1 < end, [46, 33, 63, 0x2026].contains(ns.character(at: j + 1)) { j += 1 }   // ?! ... ?!.
                let singleDot = c == 46 && j == i
                while j + 1 < end, "\"'”’»)]".utf16.contains(ns.character(at: j + 1)) { j += 1 }
                let after = j + 1
                guard after < end, isSpace(ns.character(at: after)) else { i = j + 1; continue }
                var k = after
                while k < end, isSpace(ns.character(at: k)) { k += 1 }
                guard k < end else { break }
                let next = ns.character(at: k)
                if isLower(next) { i = k; continue }
                if singleDot {
                    // a single dot: look at the word before it
                    let w = wordBefore(ns, i, from: start)
                    let lw = w.lowercased()
                    if neverEnd.contains(lw) || neverEnd.contains(lastPart(lw)) { i = k; continue }
                    if mayEnd.contains(lw) || mayEnd.contains(lastPart(lw)) { if !isUpper(next) { i = k; continue } }
                    if isInitial(w) { i = k; continue }
                    if w.allSatisfy(\.isNumber), !w.isEmpty, i - w.utf16.count == start { i = k; continue }   // "1. " at the start
                }
                let r = trim(ns, NSRange(location: start, length: after - start))
                if r.length > 0 { out.append(piece(r, para: p)) }
                start = k; i = k
            }
            let r = trim(ns, NSRange(location: start, length: end - start))
            if r.length > 0 { out.append(piece(r, para: p)) }
        }
        // a list mark heading a sentence: the body leaves it out
        return out.map { pc in
            let m = markLength(ns, pc.range)
            return m > 0 ? PickPiece(range: pc.range, body: NSRange(location: pc.range.location + m, length: pc.range.length - m), kind: "item", para: pc.para) : pc
        }
    }
    /// The word right before the dot at `i` (letters, digits, dots and hyphens), not before `from`.
    private static func wordBefore(_ ns: NSString, _ i: Int, from: Int) -> String {
        var a = i
        while a > from {
            let c = ns.character(at: a - 1)
            if isSpace(c) || "([«\"'“„".utf16.contains(c) { break }
            a -= 1
        }
        return ns.substring(with: NSRange(location: a, length: i - a))
    }
    private static func lastPart(_ w: String) -> String {
        guard let d = w.lastIndex(of: ".") else { return w }
        return String(w[w.index(after: d)...])
    }
    /// "A", "Т", "J.R.R" (capitals with dots between).
    private static func isInitial(_ w: String) -> Bool {
        let parts = w.split(separator: ".", omittingEmptySubsequences: false)
        return !parts.isEmpty && parts.allSatisfy { $0.count == 1 && $0.first!.isUppercase }
    }
    static func isLower(_ c: unichar) -> Bool {
        guard let s = Unicode.Scalar(c) else { return false }
        return CharacterSet.lowercaseLetters.contains(s)
    }
    static func isUpper(_ c: unichar) -> Bool {
        guard let s = Unicode.Scalar(c) else { return false }
        return CharacterSet.uppercaseLetters.contains(s) || CharacterSet.decimalDigits.contains(s) || "\"«“„'([".unicodeScalars.contains(s)
    }

    // MARK: things (stand-in detector)

    private static var rxCache: [String: NSRegularExpression] = [:]
    private static let rxLock = NSLock()
    static func cached(_ p: String) -> NSRegularExpression? {
        rxLock.lock(); defer { rxLock.unlock() }
        if let r = rxCache[p] { return r }
        let r = try? NSRegularExpression(pattern: p)
        rxCache[p] = r
        return r
    }
    static let thingPatterns: [(kind: String, pattern: String)] = [
        ("email", #"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"#),
        ("link", #"(?:https?://|www\.)[^\s<>()"«»]+[^\s<>()"«».,;:!?'’]"#),
        ("date", #"\b\d{4}-\d{2}-\d{2}\b|\b\d{1,2}[./]\d{1,2}[./]\d{2,4}\b|\b\d{1,2}\s+(?:січня|лютого|березня|квітня|травня|червня|липня|серпня|вересня|жовтня|листопада|грудня|January|February|March|April|May|June|July|August|September|October|November|December|Jan|Feb|Mar|Apr|Jun|Jul|Aug|Sep|Oct|Nov|Dec)(?:\s+\d{4})?\b|\b(?:January|February|March|April|May|June|July|August|September|October|November|December|Jan|Feb|Mar|Apr|Jun|Jul|Aug|Sep|Oct|Nov|Dec)\.?\s+\d{1,2}(?:,\s*\d{4})?\b"#),
        ("amount", #"(?:[$€£₴]\s?\d[\d\s,.]*\d|[$€£₴]\s?\d)|\b\d[\d\s,.]*\d?\s?(?:грн|UAH|USD|EUR|дол\.|євро|\$|€|₴)(?![\p{L}])"#),
    ]
    /// Links, emails, dates and amounts by pattern: the stand-in for the detector track's `(String) -> [(range, kind,
    /// label)]`. An email's domain is not also a link (the first find at a place wins, see `split`).
    static func basicThings(_ text: String) -> [(range: NSRange, kind: String, label: String)] {
        let ns = text as NSString, all = NSRange(location: 0, length: ns.length)
        var out: [(range: NSRange, kind: String, label: String)] = []
        for (kind, p) in thingPatterns {
            guard let rx = cached(p) else { continue }
            for m in rx.matches(in: text, range: all) {
                let r = trim(ns, m.range)
                guard r.length > 0, !out.contains(where: { NSIntersectionRange($0.range, r).length > 0 }) else { continue }
                out.append((r, kind, ns.substring(with: r)))
            }
        }
        return out.sorted { $0.range.location < $1.range.location }
    }

    // MARK: the starting level

    struct Shape: Equatable { var lines = 0, listLines = 0, rowLines = 0, paragraphs = 0, sentences = 0, shortLines = 0 }
    static func shape(_ text: String) -> Shape {
        let ns = text as NSString, ls = lines(ns).filter { !$0.blank }
        var s = Shape()
        s.lines = ls.count
        s.listLines = ls.filter { markLength(ns, $0.trimmed) > 0 }.count
        s.rowLines = ls.filter { isRow(ns, $0.trimmed) || isRule(ns, $0.trimmed) }.count
        s.shortLines = ls.filter { $0.trimmed.length <= 60 && !"….!?".utf16.contains(ns.character(at: $0.trimmed.location + $0.trimmed.length - 1)) }.count
        s.paragraphs = split(text, .paragraphs).count
        s.sentences = split(text, .sentences).count
        return s
    }
    /// A list (half its lines or more are items or table rows): items. Many short lines without end marks: lines.
    /// Long prose (3+ paragraphs, 4+ sentences each on average): paragraphs. Else sentences.
    static func startLevel(_ text: String) -> PickLevel { startLevel(shape(text)) }
    static func startLevel(_ s: Shape) -> PickLevel {
        if s.lines >= 2, s.rowLines * 2 >= s.lines { return .items }
        if s.listLines >= 2, s.listLines * 2 >= s.lines { return .items }
        if s.lines >= 4, s.shortLines * 3 >= s.lines * 2 { return .lines }
        if s.paragraphs >= 3, s.sentences >= s.paragraphs * 4 { return .paragraphs }
        return .sentences
    }
    /// Worth offering "Pick parts" for a copied text: more than 3 sentences or more than 4 lines.
    static func worthPicking(_ text: String) -> Bool {
        guard text.utf16.count >= 40 else { return false }
        let ns = text as NSString
        if lines(ns).filter({ !$0.blank }).count > 4 { return true }
        return split(text, .sentences).count > 3
    }

    // MARK: quick picks

    static func all(_ n: Int) -> Set<Int> { Set(0..<n) }
    static func toEnd(from i: Int, _ n: Int) -> Set<Int> { i < n ? Set(max(0, i)..<n) : [] }
    static func toStart(from i: Int, _ n: Int) -> Set<Int> { n > 0 ? Set(0...min(i, n - 1)) : [] }
    static func run(_ a: Int, _ b: Int) -> Set<Int> { Set(min(a, b)...max(a, b)) }
    /// Pieces holding `query` (case, accents and width ignored; ' and ’ alike).
    static func containing(_ text: String, _ pieces: [PickPiece], _ query: String) -> [Int] {
        let q = fold(query.trimmingCharacters(in: .whitespaces))
        guard !q.isEmpty else { return Array(pieces.indices) }
        let ns = text as NSString
        return pieces.indices.filter { fold(ns.substring(with: pieces[$0].range)).contains(q) }
    }
    /// Pieces that are, or hold, a thing of `kind` ("link", "date", "amount", "email").
    static func withKind(_ text: String, _ pieces: [PickPiece], _ kind: String, things: PickThings? = nil) -> [Int] {
        let found = (things ?? basicThings)(text).filter { $0.kind == kind }.map(\.range)
        return pieces.indices.filter { i in pieces[i].kind == kind || found.contains { NSIntersectionRange($0, pieces[i].range).length > 0 } }
    }
    static func fold(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .replacingOccurrences(of: "’", with: "'").replacingOccurrences(of: "ʼ", with: "'")
    }

    /// Picks carried to another level: a new piece is picked when at least half of it was inside the old pick.
    static func carry(_ old: [PickPiece], _ picked: Set<Int>, to new: [PickPiece]) -> Set<Int> {
        let on = picked.sorted().compactMap { $0 < old.count ? old[$0].range : nil }
        guard !on.isEmpty else { return [] }
        return Set(new.indices.filter { i in
            let r = new[i].range
            let covered = on.reduce(0) { $0 + NSIntersectionRange($1, r).length }
            return r.length > 0 && covered * 2 >= r.length
        })
    }

    // MARK: the result

    static func joiner(_ level: PickLevel) -> String {
        switch level { case .paragraphs: return "\n\n"; case .sentences: return " "; default: return "\n" }
    }
    /// The picked pieces in the original order: sentences of one paragraph with a space (two paragraphs: an empty line),
    /// lines, items and things with a line break, paragraphs with an empty line. `marks`: list marks kept (else each
    /// item's body); trailing spaces trimmed on every line.
    static func result(_ text: String, _ pieces: [PickPiece], _ picked: Set<Int>, _ level: PickLevel, marks: Bool = true) -> String {
        let ns = text as NSString
        var out = "", lastPara = -1
        for i in picked.sorted() where i < pieces.count {
            let p = pieces[i]
            let s = ns.substring(with: marks ? p.range : p.body)
            if !out.isEmpty { out += level == .sentences && p.para != lastPara ? "\n\n" : joiner(level) }
            out += s
            lastPara = p.para
        }
        return tidy(out)
    }
    /// "The rest": the original without the picked pieces. A piece that filled its lines takes its line break with it;
    /// a piece inside a line takes one space next to it. Everything that was not a piece (headings, table rules) stays.
    static func rest(_ text: String, _ pieces: [PickPiece], _ picked: Set<Int>) -> String {
        let ns = text as NSString
        var cuts: [NSRange] = []
        for i in picked.sorted() where i < pieces.count {
            var r = pieces[i].range
            var a = r.location, b = r.location + r.length
            while a > 0, ns.character(at: a - 1) == 32 || ns.character(at: a - 1) == 9 { a -= 1 }
            while b < ns.length, ns.character(at: b) == 32 || ns.character(at: b) == 9 { b += 1 }
            let lineStart = a == 0 || isBreak(ns.character(at: a - 1)), lineEnd = b == ns.length || isBreak(ns.character(at: b))
            if lineStart && lineEnd {
                if b < ns.length { b += (ns.character(at: b) == 13 && b + 1 < ns.length && ns.character(at: b + 1) == 10) ? 2 : 1 }
                r = NSRange(location: a, length: b - a)
            } else if lineEnd {
                r = NSRange(location: a, length: r.location + r.length - a)         // the space before goes
            } else {
                r = NSRange(location: r.location, length: b - r.location)           // the space after goes
            }
            cuts.append(r)
        }
        var out = "", at = 0
        for c in cuts.sorted(by: { $0.location < $1.location }) {
            if c.location > at { out += ns.substring(with: NSRange(location: at, length: c.location - at)) }
            at = max(at, c.location + c.length)
        }
        if at < ns.length { out += ns.substring(from: at) }
        return tidy(out)
    }
    /// Trailing spaces off every line, at most one empty line in a row, no empty lines at the ends.
    static func tidy(_ s: String) -> String {
        var lines = s.components(separatedBy: "\n").map { l -> String in
            var t = Substring(l)
            while let c = t.last, c == " " || c == "\t" || c == "\r" { t = t.dropLast() }
            return String(t)
        }
        var out: [String] = []
        for l in lines { if l.isEmpty, out.last?.isEmpty ?? true { continue }; out.append(l) }
        while out.last?.isEmpty == true { out.removeLast() }
        lines = out
        return lines.joined(separator: "\n")
    }

    // MARK: saving (the file part; History.keepPick calls it on its queue)

    /// One row appended to a JSON-lines file (made if missing).
    static func append(_ url: URL, _ row: [String: Any]) {
        guard let d = try? JSONSerialization.data(withJSONObject: row), var line = String(data: d, encoding: .utf8) else { return }
        line += "\n"
        if let h = try? FileHandle(forWritingTo: url) { h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close() }
        else { try? line.write(to: url, atomically: true, encoding: .utf8) }
    }
    /// Is this row the kept pick `rec` (for its Undo): same time, same source, same text.
    static func isRow(_ r: [String: Any], of rec: PickRecord) -> Bool {
        (r["t"] as? NSNumber)?.doubleValue == rec.at && r["from"] as? String == rec.from && r["text"] as? String == rec.text
            && (r["pick"] as? String == "rest") == rec.rest
    }
}

// MARK: the panel's keys, as a state machine

enum PickKey: Equatable {
    case up, down, shiftUp, shiftDown, toEnd, toStart          // ⇧⌘↓ from here to the end, ⇧⌘↑ to the start
    case space, char(String), backspace
    case enter, cmdEnter, optEnter, esc, undo
}

enum PickEffect: Equatable {
    case none, redraw
    case save(String)          // Return: keep the pick as a new item and put it on the clipboard
    case insert(String)        // ⌘Return: into the app he came from
    case saveRest(String)      // ⌥Return: keep "the rest"
    case close                 // Esc: nothing changes
    case nothing(String)       // a word for the status line ("Nothing picked")
}

struct PickState {
    let text: String
    var level: PickLevel
    var pieces: [PickPiece]
    var picked: Set<Int> = []
    var cursor = 0
    var anchor: Int?                  // where a ⇧ run started
    var filtering = false             // typing after "/"
    var query = ""
    var marks = true                  // list marks kept in the result
    var things: PickThings?
    var undoStack: [(level: PickLevel, picked: Set<Int>, cursor: Int)] = []
    var note = ""

    init(text: String, level: PickLevel? = nil, things: PickThings? = nil) {
        self.text = text
        self.things = things
        let l = level ?? PickRules.startLevel(text)
        self.level = l
        self.pieces = PickRules.split(text, l, things: things)
    }

    /// The pieces in view (all, or those holding the filter).
    var shown: [Int] { query.isEmpty ? Array(pieces.indices) : PickRules.containing(text, pieces, query) }
    var result: String { PickRules.result(text, pieces, picked, level, marks: marks) }
    var rest: String { PickRules.rest(text, pieces, picked) }

    private mutating func remember() {
        undoStack.append((level, picked, cursor))
        if undoStack.count > 100 { undoStack.removeFirst() }
    }
    private var at: Int? { let s = shown; return s.isEmpty ? nil : s[min(max(0, cursor), s.count - 1)] }

    mutating func setLevel(_ l: PickLevel) {
        guard l != level else { return }
        remember()
        let old = pieces, cur = at.map { old[$0].range.location }
        pieces = PickRules.split(text, l, things: things)
        picked = PickRules.carry(old, picked, to: pieces)
        level = l; anchor = nil
        if let cur, let i = shown.lastIndex(where: { pieces[$0].range.location <= cur }) { cursor = i } else { cursor = 0 }
    }

    /// A click on a piece: pick or unpick it.
    mutating func click(_ piece: Int) {
        guard piece < pieces.count else { return }
        remember()
        if picked.contains(piece) { picked.remove(piece) } else { picked.insert(piece) }
        if let i = shown.firstIndex(of: piece) { cursor = i }
        anchor = nil
    }
    /// A drag from one piece to another: the run takes the state the first piece gets (one undo step for the drag).
    mutating func drag(from a: Int, to b: Int, start: Bool) {
        guard a < pieces.count, b < pieces.count else { return }
        if start { remember() }
        let base = undoStack.last?.picked ?? picked
        let on = !base.contains(a)
        let run = PickRules.run(a, b)
        picked = on ? base.union(run) : base.subtracting(run)
        if let i = shown.firstIndex(of: b) { cursor = i }
    }

    mutating func key(_ k: PickKey) -> PickEffect {
        let s = shown
        if filtering {
            switch k {
            case .char(let c): query += c; cursor = 0; return .redraw
            case .backspace:
                if query.isEmpty { filtering = false } else { query.removeLast() }
                cursor = 0; return .redraw
            case .space: query += " "; return .redraw
            case .esc: filtering = false; query = ""; cursor = 0; return .redraw
            case .enter: filtering = false; return .redraw      // the filter stays; the next Return keeps the pick
            default: break                                     // moves and picks work while typing
            }
        }
        switch k {
        case .up: cursor = max(0, cursor - 1); anchor = nil; return .redraw
        case .down: cursor = min(max(0, s.count - 1), cursor + 1); anchor = nil; return .redraw
        case .shiftUp, .shiftDown:
            guard !s.isEmpty else { return .none }
            if anchor == nil { remember(); anchor = cursor; picked.insert(s[cursor]) }
            cursor = k == .shiftUp ? max(0, cursor - 1) : min(s.count - 1, cursor + 1)
            let base = undoStack.last?.picked ?? []
            let a = anchor!, run = Set((min(a, cursor)...max(a, cursor)).map { s[$0] })
            picked = base.union(run)
            return .redraw
        case .toEnd, .toStart:
            guard !s.isEmpty else { return .none }
            remember()
            let r = k == .toEnd ? Array(s[cursor...]) : Array(s[...cursor])
            picked.formUnion(r)
            return .redraw
        case .space:
            guard let p = at else { return .none }
            click(p); return .redraw
        case .char(let c):
            switch c.lowercased() {
            case "/": filtering = true; query = ""; cursor = 0; return .redraw
            case "a": remember(); picked.formUnion(s); return .redraw                       // all (in view)
            case "n": remember(); if query.isEmpty { picked = [] } else { picked.subtract(s) }; return .redraw
            case "i": remember(); for p in s { if picked.contains(p) { picked.remove(p) } else { picked.insert(p) } }; return .redraw
            case "m": marks.toggle(); return .redraw                                        // list marks in the result
            case "1", "2", "3", "4", "5": setLevel(PickLevel(rawValue: Int(c)!)!); return .redraw
            case "l", "d", "$", "e":
                let kind = ["l": "link", "d": "date", "$": "amount", "e": "email"][c.lowercased()]!
                let hits = Set(PickRules.withKind(text, pieces, kind, things: things)).intersection(s)
                guard !hits.isEmpty else { return .nothing("No \(kind)s here") }
                remember(); picked.formUnion(hits); return .redraw
            default: return .none
            }
        case .backspace: return .none
        case .undo:
            guard let u = undoStack.popLast() else { return .nothing("Nothing to undo") }
            if u.level != level { level = u.level; pieces = PickRules.split(text, u.level, things: things) }
            picked = u.picked; cursor = u.cursor; anchor = nil
            return .redraw
        case .enter:
            let r = result
            return r.isEmpty ? .nothing("Nothing picked") : .save(r)
        case .cmdEnter:
            let r = result
            return r.isEmpty ? .nothing("Nothing picked") : .insert(r)
        case .optEnter:
            guard !picked.isEmpty else { return .nothing("Nothing picked") }
            let r = rest
            return r.isEmpty ? .nothing("Nothing left") : .saveRest(r)
        case .esc:
            if !query.isEmpty { query = ""; cursor = 0; return .redraw }
            return .close
        }
    }

    /// The status line: "3 of 9 sentences · 214 characters", and the result's first line.
    var status: (count: String, first: String) {
        let r = result
        var n = "\(picked.count) of \(pieces.count) \(level.noun(pieces.count))"
        if !query.isEmpty { n += " · \(shown.count) in view" }
        let first = r.split(separator: "\n", omittingEmptySubsequences: true).first.map(String.init) ?? ""
        return (picked.isEmpty ? n : n + " · \(r.count) characters", first)
    }
}

/// A key event, as the panel gets it, to a `PickKey`. Commands go by the key's place (A, N, I, M, L, D, E, 1-5, /),
/// so they work on the Ukrainian layout too; while he types after "/", letters are text.
enum PickKeyMap {
    static let letters: [Int: String] = [0: "a", 45: "n", 34: "i", 46: "m", 37: "l", 2: "d", 14: "e",
                                         18: "1", 19: "2", 20: "3", 21: "4", 23: "5", 44: "/"]
    static func map(code: Int, chars: String, cmd: Bool, shift: Bool, alt: Bool, filtering: Bool) -> PickKey? {
        switch code {
        case 126: return cmd && shift ? .toStart : shift ? .shiftUp : .up
        case 125: return cmd && shift ? .toEnd : shift ? .shiftDown : .down
        case 36, 76: return cmd ? .cmdEnter : alt ? .optEnter : .enter
        case 53: return .esc
        case 51: return .backspace
        case 49: return .space
        default: break
        }
        if cmd { return code == 6 ? .undo : nil }                 // ⌘Z
        if filtering { return chars.isEmpty || chars.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) ? nil : .char(chars) }
        if shift && code == 21 { return .char("$") }               // ⇧4: amounts
        return letters[code].map { .char($0) }
    }
}

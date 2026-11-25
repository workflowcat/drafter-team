// The journal's search core, pure part (search round, 14 November 2026; Andrii: "the search definitely needs to be
// improved"). No AppKit, no files: tokens for Ukrainian and English (case, marks and the three apostrophes folded,
// links and paths cut into parts, light stems), the forgiving query language (words AND, the last word a prefix,
// "a phrase", -word, filters as chips, date words offered), the other keyboard layout, typo distance, ranking weights,
// highlight ranges and snippets. The index that uses it: app/SearchIndex.swift. Tests: tests/search_rules.swift.
// Round notes: docs/rounds/2026-11-14-search.md.
import Foundation

// MARK: - every weight in one table

enum SearchWeights {
    /// Field weights (BM25F): a word in a title counts three times a word in the body.
    static let field: [SearchField: Double] = [
        .title: 3.0, .body: 1.0, .tags: 2.5, .app: 0.8, .link: 1.5, .ocr: 0.7,
        .recTitle: 3.0, .summary: 1.6, .transcript: 0.6,
    ]
    /// BM25 saturation and length normalisation.
    static let k1 = 1.2, b = 0.6
    /// How a query word reached the document (multiplies that word's score).
    static let exact = 1.0, stem = 0.85, prefix = 0.7, name = 0.85, layout = 0.8, typo1 = 0.45, typo2 = 0.3
    /// A Ukrainian stem with a vowel or end consonant changed (кінь/коня, Київ/Києві, сон/сну, рука/руці): below a
    /// plain stem. A one-edit typo in a 4-letter word, tried only when a query found under 3 items: last of all.
    static let alternation = 0.6, typo4 = 0.2
    /// Under this many hits, a query is tried again with typos on every word (4-letter words included).
    static let retryUnder = 3
    /// "a phrase" or the query words side by side in order: added as a share of the text score.
    static let phrase = 0.5, order = 0.2
    /// Fresh items rise a little: at most +25 %, half of that after 14 days. Multiplies, so a strong old hit stays
    /// above a weak new one.
    static let recency = 0.25, recencyHalfLife = 14.0 * 86400
    /// QuickRules' learned signal (puts, 0...~7.5): +4 % a unit, at most +25 %. A pin: +15 %.
    static let use = 0.04, useMax = 0.25, pin = 0.15
    /// Typos: one edit from 5 letters, two from 9; only words of the index within that distance.
    static let typoOne = 5, typoTwo = 9
    /// A prefix needs this many letters; at most this many index words per prefix (the most common first).
    static let prefixMin = 2, prefixMax = 600
    /// The order bonus, ranges and snippets are worked out for this many hits at the top.
    static let detail = 20
}

// MARK: - documents

enum SearchKind: String, CaseIterable, Codable {
    case clip, draft, voice, recording
}

enum SearchField: Int, CaseIterable, Codable {
    case title, body, tags, app, link, ocr, recTitle, summary, transcript
}

/// One journal item as the search sees it. Light: strings only, shared with whoever built it.
struct SearchDoc {
    var id: String
    var kind: SearchKind
    var time: Double                // seconds since 1970
    var app = ""
    var pinned = false
    var uses = 0.0                  // the learned signal (QuickRules.useSignal), 0 when none
    var changed = false             // he changed its text (has:change)
    var picture = false             // a copied or captured picture (has:picture)
    var title = ""                  // the first line, or a recording's title goes to recTitle
    var body = ""
    var tags: [String] = []         // entity names (people, projects), a recording's people
    var link = ""                   // a link's host, path words and page title
    var ocr = ""                    // a picture's read text
    var recTitle = ""
    var summary = ""
    var transcript = ""
    var titleInBody = false         // the title is the body's first line (set by `text`): read once, not twice
    /// Things the detector found in the text (wire round): `SearchHas` bits (date, money, phone, email, path, code,
    /// iban, link), never a sensitive thing. Set by the app (FoundRules.searchMarks); the core never runs the detector.
    var found: UInt16 = 0
    /// The days the text mentions (start of each day, seconds), for `mentions:`. Sensitive things never count.
    var mentions: [Double] = []

    init(id: String, kind: SearchKind, time: Double, app: String = "") {
        self.id = id; self.kind = kind; self.time = time; self.app = app
    }

    /// A text item: its first line is the title (at most 400 characters), the whole text the body. The body is the
    /// caller's own string, not a copy, so the search holds no second copy of his text.
    static func text(id: String, kind: SearchKind, time: Double, app: String, text: String) -> SearchDoc {
        var d = SearchDoc(id: id, kind: kind, time: time, app: app)
        d.title = String(SearchRules.firstLine(text).0.prefix(400))
        d.body = text
        d.titleInBody = true
        return d
    }

    func field(_ f: SearchField) -> String {
        switch f {
        case .title: return title
        case .body: return body
        case .tags: return tags.joined(separator: " · ")
        case .app: return app
        case .link: return link
        case .ocr: return ocr
        case .recTitle: return recTitle
        case .summary: return summary
        case .transcript: return transcript
        }
    }
    var hasLink: Bool { !link.isEmpty || body.contains("http") || title.contains("http") }
}

// MARK: - tokens

struct SearchToken: Equatable {
    let term: String     // folded
    let start: Int       // UTF-16 offset in the text
    let length: Int      // UTF-16 length
    let part: Bool       // a part of a longer token (camelCase, letters and digits)
}

enum SearchRules {
    static let termMax = 40

    enum CharClass { case letter, digit, joiner, mark, other }

    /// Latin letters with marks folded once (é -> e), from Foundation, for U+00C0...U+024F.
    private static let latinTable: [UInt32] = (0xC0...0x24F).map { v -> UInt32 in
        guard let u = Unicode.Scalar(UInt32(v)) else { return 0 }
        let f = String(Character(u)).folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        return f.unicodeScalars.count == 1 ? f.unicodeScalars.first!.value : (f.unicodeScalars.first?.value ?? 0)
    }

    /// One scalar folded: lower case, no marks, Ukrainian ї й ґ as і и г (so either spelling finds the other), the
    /// three apostrophes (' ’ ʼ, and ‘ ` ´) as a joiner inside a word.
    @inline(__always)
    static func fold(scalar v: UInt32) -> (UInt32, CharClass) {
        switch v {
        case 0x30...0x39: return (v, .digit)
        case 0x61...0x7A: return (v, .letter)
        case 0x41...0x5A: return (v + 32, .letter)
        case 0x27, 0x2019, 0x02BC, 0x2018, 0x60, 0xB4: return (0x27, .joiner)
        case 0x300...0x36F: return (0, .mark)
        case 0xD7, 0xF7: return (v, .other)
        case 0xC0...0x24F:
            let f = latinTable[Int(v - 0xC0)]
            return f == 0 ? (v, .other) : (f, .letter)
        case 0x400...0x4FF:
            var c = v
            if (0x410...0x42F).contains(c) { c += 0x20 } else if (0x400...0x40F).contains(c) { c += 0x50 }
            else if c >= 0x460, c % 2 == 0, c != 0x482 { c += 1 }
            switch c {
            case 0x457: c = 0x456          // ї -> і
            case 0x439: c = 0x438          // й -> и
            case 0x491: c = 0x433          // ґ -> г
            case 0x451: c = 0x435          // ё -> е
            default: break
            }
            return (c, .letter)
        default:
            guard v > 0x7F, let u = Unicode.Scalar(v) else { return (v, .other) }
            let p = u.properties
            if p.generalCategory == .nonspacingMark || p.generalCategory == .enclosingMark { return (0, .mark) }
            if p.isAlphabetic { return (p.lowercaseMapping.unicodeScalars.first?.value ?? v, .letter) }
            if p.numericType == .decimal { return (UInt32((p.numericValue ?? 0)) + 0x30, .digit) }
            return (v, .other)
        }
    }

    /// The text folded as a whole (for comparing phrases and names): words folded, one space between them.
    static func fold(_ s: String) -> String {
        var out: [String] = []
        scan(s) { t in if !t.part { out.append(t.term) } }
        return out.joined(separator: " ")
    }

    /// Every word of a text, folded, with its place. Letters and digits make a word; an apostrophe inside a word is
    /// dropped (м'ясо = мясо, don't = dont); anything else cuts. A word that changes case inside (fileName) or mixes
    /// letters and digits (plan2026) also gives its parts. Links and paths fall into their parts by the same rule.
    static func scan(_ s: String, limit: Int = .max, _ emit: (SearchToken) -> Void) {
        var n = 0
        scanBytes(s) { b, start, len, part in
            emit(SearchToken(term: String(decoding: b, as: UTF8.self), start: start, length: len, part: part))
            if !part { n += 1 }
            return n < limit
        }
    }

    /// The scanner itself, on the text's UTF-8 bytes: each word as its folded UTF-8 bytes (valid only during the
    /// call), its UTF-16 place, and whether it is a part. Return false to stop. No String is made per word, so the
    /// index can look words up without allocating.
    static func scanBytes(_ text: String, _ sink: (UnsafeBufferPointer<UInt8>, Int, Int, Bool) -> Bool) {
        var str = text
        str.withUTF8 { src in
            var sc = WordScanner(src)
            defer { sc.release() }
            while sc.next() { if !sink(sc.term, sc.start, sc.length, sc.part) { return } }
        }
    }

    static func terms(_ s: String) -> [String] {
        var out: [String] = []
        scan(s) { if !$0.part { out.append($0.term) } }
        return out
    }

    static func firstLine(_ text: String) -> (String, String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let nl = t.firstIndex(where: \.isNewline) else { return (t, "") }
        return (String(t[..<nl]).trimmingCharacters(in: .whitespaces), String(t[t.index(after: nl)...]).trimmingCharacters(in: .whitespacesAndNewlines))
    }

    // MARK: - stems

    static func isCyrillic(_ s: String) -> Bool { s.unicodeScalars.first.map { (0x400...0x4FF).contains($0.value) } ?? false }
    static func isLatin(_ s: String) -> Bool { s.unicodeScalars.allSatisfy { (0x61...0x7A).contains($0.value) } }

    /// Ukrainian endings, folded (й as и, ї as і), longest first. Nouns, adjectives, verbs; the stem keeps 3 letters.
    static let ukEndings: [String] = {
        let raw = [
            // adjectives
            "ього", "ьому", "ими", "іми", "ого", "ому", "ий", "ій", "им", "ім", "их", "іх", "ою", "ої", "ее", "ая",
            // nouns
            "ами", "ями", "ові", "еві", "єві", "ом", "ем", "єм", "ею", "єю", "ам", "ям", "ах", "ях", "ів", "їв", "ей",
            // verbs
            "ете", "єте", "ите", "іте", "емо", "ємо", "имо", "імо", "ать", "ять", "уть", "ють", "ить", "іть", "али",
            "ала", "ало", "или", "ила", "ило", "ати", "яти", "ити", "іти", "ути", "ть", "еш", "єш", "иш", "іш", "ав", "ив", "ла", "ло", "ли",
            "йте",
            // one letter
            "а", "я", "о", "е", "є", "и", "і", "у", "ю",
        ]
        return Array(Set(raw.map { e in String(e.unicodeScalars.map { Character(Unicode.Scalar(fold(scalar: $0.value).0)!) }) }))
            .sorted { $0.unicodeScalars.count > $1.unicodeScalars.count }
    }()
    static let ukMinStem = 3, enMinStem = 3
    private static let ukEndingValues = ukEndings.map { $0.unicodeScalars.map(\.value) }
    private static let sya = "ся".unicodeScalars.map(\.value), sy = "сь".unicodeScalars.map(\.value), ty = "ть".unicodeScalars.map(\.value)
    private static let vowels = Set("аеиіоуяює".unicodeScalars.map(\.value))

    /// The stem of a folded word: Ukrainian endings off (reflexive -ся/-сь first, then one ending, then a soft sign),
    /// English plurals, -ing and -ed off (a doubled last letter undone, a final e dropped). Digits and other scripts
    /// stay as they are. No dictionary: a small rule, so some forms still differ (see the round notes).
    static func stem(_ w: String) -> String {
        let n = w.unicodeScalars.count
        if isCyrillic(w) {
            guard n >= ukMinStem + 1 else { return w }
            var v = String.UnicodeScalarView(); v.append(contentsOf: stemCyrillic(w.unicodeScalars.map(\.value)).compactMap(Unicode.Scalar.init))
            return String(v)
        }
        guard isLatin(w), n >= enMinStem + 1 else { return w }
        var s = w
        if s.hasSuffix("ies"), n >= 5 { s = String(s.dropLast(3)) + "y" }
        else if s.hasSuffix("sses") || s.hasSuffix("shes") || s.hasSuffix("ches") || s.hasSuffix("xes") || s.hasSuffix("zes") { s = String(s.dropLast(2)) }
        else if s.hasSuffix("s"), !s.hasSuffix("ss"), !s.hasSuffix("us"), !s.hasSuffix("is"), n >= 4 { s = String(s.dropLast()) }
        else if s.hasSuffix("ing"), n - 3 >= enMinStem { s = String(s.dropLast(3)); s = undouble(s) }
        else if s.hasSuffix("ed"), n - 2 >= enMinStem - 1, n >= 4 { s = String(s.dropLast(2)); s = undouble(s) }
        if s.hasSuffix("e"), s.count >= 4 { s.removeLast() }
        return s
    }
    /// The Ukrainian rule on scalars (folded): reflexive -ся/-сь, one ending, a soft sign, a theme vowel.
    static func stemCyrillic(_ w: [UInt32]) -> [UInt32] {
        guard w.count >= ukMinStem + 1 else { return w }
        var s = w
        func ends(_ e: [UInt32]) -> Bool {
            guard s.count >= e.count else { return false }
            var i = s.count - e.count
            for x in e { if s[i] != x { return false }; i += 1 }
            return true
        }
        if (ends(sya) || ends(sy)) && s.count - 2 >= ukMinStem + 1 { s.removeLast(2) }
        for e in ukEndingValues {
            let k = e.count
            guard s.count - k >= ukMinStem, ends(e) else { continue }
            // -ть ends a verb only after a vowel (роби-ть); -ти only as -ати, -ити… (чит-ати, but звіт-и, проєкт-и)
            if e == ty, !vowels.contains(s[s.count - k - 1]) { continue }
            s.removeLast(k); break
        }
        if s.count > ukMinStem, s.last == 0x44C { s.removeLast() }
        // a verb's theme vowel (зроби-ти, зроб-ив; чита-ти, чит-ав) goes too
        if s.count > ukMinStem, let l = s.last, vowels.contains(l) { s.removeLast() }
        return s
    }
    static func utf8(_ s: [UInt32]) -> [UInt8] {
        var out: [UInt8] = []; out.reserveCapacity(s.count * 2)
        for f in s {
            if f < 0x80 { out.append(UInt8(f)) }
            else if f < 0x800 { out.append(UInt8(0xC0 | (f >> 6))); out.append(UInt8(0x80 | (f & 0x3F))) }
            else if f < 0x10000 { out.append(UInt8(0xE0 | (f >> 12))); out.append(UInt8(0x80 | ((f >> 6) & 0x3F))); out.append(UInt8(0x80 | (f & 0x3F))) }
            else { out.append(UInt8(0xF0 | (f >> 18))); out.append(UInt8(0x80 | ((f >> 12) & 0x3F))); out.append(UInt8(0x80 | ((f >> 6) & 0x3F))); out.append(UInt8(0x80 | (f & 0x3F))) }
        }
        return out
    }
    private static func undouble(_ s: String) -> String {
        let c = Array(s)
        if c.count >= 4, c[c.count - 1] == c[c.count - 2], !"lsz".contains(c[c.count - 1]), !"aeiou".contains(c[c.count - 1]) { return String(c.dropLast()) }
        return s
    }

    // MARK: - the other keyboard layout

    /// ABC -> Ukrainian-PC, the keys that differ (read from this Mac's two layouts with app/Layout.swift's
    /// UCKeyTranslate, 14 November 2026, and kept here so the search stays pure). Lower case and punctuation.
    static let toUk: [Character: Character] = {
        let pairs = "`ґ qй wц eу rк tе yн uг iш oщ pз [х ]ї \\ʼ aф sі dв fа gп hр jо kл lд ;ж 'є zя xч cс vм bи nт mь ,б .ю /."
        var m: [Character: Character] = [:]
        for p in pairs.split(separator: " ") { let c = Array(p); m[c[0]] = c[1] }
        return m
    }()
    static let toEn: [Character: Character] = {
        var m: [Character: Character] = [:]
        for (a, b) in toUk { m[b] = a }
        m["'"] = "\\"; m["’"] = "\\"; m["ї"] = "]"; m["і"] = "s"
        return m
    }()

    /// A word typed in the wrong layout, in the other one; nil when it does not change into letters of the other script.
    static func otherLayout(_ word: String) -> String? {
        let low = word.lowercased()
        let latin = low.unicodeScalars.contains { (0x61...0x7A).contains($0.value) }
        let cyr = low.unicodeScalars.contains { (0x400...0x4FF).contains($0.value) }
        guard latin != cyr else { return nil }
        let m = latin ? toUk : toEn
        let out = String(low.map { m[$0] ?? $0 })
        guard out != low else { return nil }
        // the result must be one word of the other script (an apostrophe may stay inside)
        let t = terms(out)
        guard t.count == 1, latin ? isCyrillic(t[0]) : isLatin(t[0]) else { return nil }
        return out
    }

    // MARK: - typos

    /// Edit distance with swaps of two neighbours counted as one (optimal string alignment), stopping above `max`.
    static func distance(_ a: [Unicode.Scalar], _ b: [Unicode.Scalar], max m: Int) -> Int {
        distance(a.map(\.value), b.map(\.value), max: m)
    }
    static func distance(_ a: [UInt32], _ b: [UInt32], max m: Int) -> Int {
        let n = a.count, k = b.count
        if abs(n - k) > m { return m + 1 }
        if n == 0 { return k }; if k == 0 { return n }
        var pp = [Int](repeating: 0, count: k + 1), p = Array(0...k), c = [Int](repeating: 0, count: k + 1)
        for i in 1...n {
            c[0] = i
            var low = c[0]
            for j in 1...k {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                var v = Swift.min(p[j] + 1, c[j - 1] + 1, p[j - 1] + cost)
                if i > 1, j > 1, a[i - 1] == b[j - 2], a[i - 2] == b[j - 1] { v = Swift.min(v, pp[j - 2] + 1) }
                c[j] = v
                low = Swift.min(low, v)
            }
            if low > m { return m + 1 }
            (pp, p, c) = (p, c, pp)
        }
        return p[k]
    }

    /// How many edits a query word may be off: 0 under 5 letters, 1 from 5, 2 from 9 (digits never).
    // MARK: - Ukrainian alternations

    private static let ukVowels: Set<UInt32> = Set("аеєиіоуюяь".unicodeScalars.map(\.value))
    private static let (cI, cO, cE, cYe) = (UInt32(0x456), UInt32(0x43E), UInt32(0x435), UInt32(0x454))
    /// End consonants that change before -і/-и (рука/руці, нога/нозі, вухо/вусі, друг/друзі, рік/році, Сокіл/Сокола).
    private static let consonantSwaps: [UInt32: [UInt32]] = {
        let groups = ["гзж", "кцч", "хсш"].map { Array($0.unicodeScalars.map(\.value)) }
        var m: [UInt32: [UInt32]] = [:]
        for g in groups { for c in g { m[c] = g.filter { $0 != c } } }
        return m
    }()
    /// Common Ukrainian endings tried after a stem that lost a vowel (сн → сну, сна, сном).
    static let shortEndings = ["а", "у", "і", "и", "ом", "ові", "ю", "я", "е", "ів", "ам", "ах", "ами"]

    /// Other shapes of a folded Cyrillic stem under the common alternations, in the last syllable only: і ↔ о / е / є
    /// (кін- коня, Київ Києві, осінь осені), a dropped о / е (сон сну, день дня, вікно вікон), and the end consonant
    /// г/з/ж, к/ц/ч, х/с/ш (рука руці, друг друзі). `dropEnd`: a short word whose ending the stemmer kept (дня):
    /// its last vowel goes first. Each shape is a guess for the index to confirm; none is applied to the text.
    static func alternations(_ stem: String, dropEnd: Bool = false) -> [String] {
        var s = stem.unicodeScalars.map(\.value)
        guard isCyrillic(stem), s.count >= 2 else { return [] }
        if dropEnd, s.count >= 3, ukVowels.contains(s[s.count - 1]) { s.removeLast() }
        var out: [[UInt32]] = []
        let isVowel = { (c: UInt32) in ukVowels.contains(c) }
        if let v = s.lastIndex(where: isVowel) {
            let c = s[v]
            if c == cI { for r in [cO, cE, cYe] { var x = s; x[v] = r; out.append(x) } }
            if c == cO || c == cE || c == cYe { var x = s; x[v] = cI; out.append(x) }
            // a fleeting о/е before one end consonant: сон -> сн, день -> дн
            if (c == cO || c == cE), v == s.count - 2, v >= 1, !isVowel(s[v - 1]) { var x = s; x.remove(at: v); out.append(x) }
        }
        // two end consonants: the vowel comes back between them (сн -> сон, вікн -> вікон)
        if s.count >= 2, !isVowel(s[s.count - 1]), !isVowel(s[s.count - 2]) {
            for r in [cO, cE] { var x = s; x.insert(r, at: s.count - 1); out.append(x) }
        }
        if let last = s.last, let swaps = consonantSwaps[last] { for r in swaps { var x = s; x[x.count - 1] = r; out.append(x) } }
        if dropEnd { out.insert(s, at: 0) }   // дня -> дн, then дн + an ending (дню) in the index
        var seen = Set<[UInt32]>(dropEnd ? [] : [s]), res: [String] = []
        for x in out where x.count >= 2 && seen.insert(x).inserted {
            var v = String.UnicodeScalarView(); v.append(contentsOf: x.compactMap(Unicode.Scalar.init)); res.append(String(v))
        }
        return res
    }

    static func typoBudget(_ w: String) -> Int {
        if w.unicodeScalars.contains(where: { (0x30...0x39).contains($0.value) }) { return 0 }
        let n = w.unicodeScalars.count
        return n >= SearchWeights.typoTwo ? 2 : n >= SearchWeights.typoOne ? 1 : 0
    }

    /// Letter triples with the word's ends marked: the candidate filter for typos (one edit breaks at most three).
    static func trigrams(_ w: String) -> [UInt64] { trigrams(scalars: w.unicodeScalars.map(\.value)) }
    static func trigrams(scalars: [UInt32]) -> [UInt64] {
        let s = [UInt32(1)] + scalars + [UInt32(2)]
        guard s.count >= 3 else { return [] }
        var out: [UInt64] = []
        out.reserveCapacity(s.count - 2)
        for i in 0..<(s.count - 2) { out.append(UInt64(s[i]) << 42 | UInt64(s[i + 1]) << 21 | UInt64(s[i + 2])) }
        return out
    }

    // MARK: - ranking pieces

    /// BM25 idf.
    static func idf(df: Int, docs: Int) -> Double { log(1 + (Double(docs) - Double(df) + 0.5) / (Double(df) + 0.5)) }

    /// The learned signal from QuickRules: how often and how lately he put an item in (1.5 a time fading over a week,
    /// at most 6) and a little for its app (0.2 a time, at most 1). The same numbers QuickRules.score adds.
    static func useSignal(item: [Double], app: [Double], now: Double) -> Double {
        let week = 7.0 * 86400
        let used = min(6, 1.5 * item.reduce(0) { $0 + exp(-max(0, now - $1) / week) })
        let from = min(1, 0.2 * app.reduce(0) { $0 + exp(-max(0, now - $1) / week) })
        return used + from
    }

    /// The text score with freshness, puts and the pin applied (each a bounded multiplier).
    static func final(text: Double, time: Double, now: Double, uses: Double, pinned: Bool) -> Double {
        let age = max(0, now - time)
        let fresh = 1 + SearchWeights.recency * pow(0.5, age / SearchWeights.recencyHalfLife)
        let used = 1 + min(SearchWeights.useMax, SearchWeights.use * max(0, uses))
        return text * fresh * used * (pinned ? 1 + SearchWeights.pin : 1)
    }

    // MARK: - highlight and snippet

    /// Where the query's words stand in a text (UTF-16 ranges, in order): a word whose folded form is one the search
    /// matched, or starts with the typed prefix.
    static func ranges(in text: String, terms: Set<String>, stems: Set<String> = [], prefixes: [String] = [], limit: Int = 200) -> [NSRange] {
        var out: [NSRange] = []
        scan(text) { t in
            guard !t.part, out.count < limit else { return }
            if terms.contains(t.term) || (!stems.isEmpty && stems.contains(stem(t.term))) || prefixes.contains(where: { t.term.hasPrefix($0) }) {
                out.append(NSRange(location: t.start, length: t.length))
            }
        }
        return out
    }

    /// A window of a long text around its best match (the place with the most matches near it), with the ranges inside
    /// the window. Short text comes whole.
    static func snippet(_ text: String, ranges: [NSRange], width: Int = 160) -> (text: String, ranges: [NSRange]) {
        let ns = text as NSString
        if ns.length <= width || ranges.isEmpty {
            let cut = ns.length <= width ? text : ns.substring(to: Swift.min(ns.length, width)) + "…"
            return (cut, ranges.filter { NSMaxRange($0) <= Swift.min(ns.length, width) })
        }
        var best = 0, bestN = -1
        for (i, r) in ranges.enumerated() {
            let n = ranges[i...].prefix { $0.location < r.location + width * 2 / 3 }.count
            if n > bestN { bestN = n; best = i }
        }
        let anchor = ranges[best].location
        var from = Swift.max(0, anchor - width / 3)
        // start at a word
        if from > 0 {
            let back = ns.range(of: " ", options: .backwards, range: NSRange(location: Swift.max(0, from - 20), length: from - Swift.max(0, from - 20)))
            if back.location != NSNotFound { from = back.location + 1 }
        }
        var to = Swift.min(ns.length, from + width)
        if to < ns.length {
            let fwd = ns.range(of: " ", options: .backwards, range: NSRange(location: from, length: to - from))
            if fwd.location != NSNotFound, fwd.location > anchor { to = fwd.location }
        }
        let lead = from > 0 ? "…" : "", tail = to < ns.length ? "…" : ""
        let body = ns.substring(with: NSRange(location: from, length: to - from))
        let shift = (lead as NSString).length - from
        let inside = ranges.filter { $0.location >= from && NSMaxRange($0) <= to }.map { NSRange(location: $0.location + shift, length: $0.length) }
        return (lead + body + tail, inside)
    }
}

// MARK: - the scanner

/// The word scanner as an iterator over UTF-8 bytes (no closure, no String per word): `next()` moves to the next word
/// or part; `term` holds its folded UTF-8 bytes until the next call. Call `release()` when done.
struct WordScanner {
    private let src: UnsafeBufferPointer<UInt8>
    private let buf: UnsafeMutablePointer<UInt8>
    private let cuts: UnsafeMutablePointer<Int>      // pairs: byte offset in the word, UTF-16 offset
    private var i = 0, at = 0, tlen = 0, nsc = 0, wordStart = 0, nc = 0
    private var pendingJoin = false, long = false, prevClass: UInt8 = 0, prevLowerLatin = false
    // parts of the last word still to give out
    private var partK = -1, pb = 0, pu = 0, wordEnd = 0, wordLen = 0
    private(set) var term = UnsafeBufferPointer<UInt8>(start: nil, count: 0)
    private(set) var start = 0, length = 0, part = false
    static let cap = SearchRules.termMax * 4 + 8

    init(_ s: UnsafeBufferPointer<UInt8>) {
        src = s
        buf = .allocate(capacity: Self.cap)
        cuts = .allocate(capacity: 40)
    }
    func release() { buf.deallocate(); cuts.deallocate() }

    private mutating func nextPart() -> Bool {
        while partK >= 0, partK <= nc {
            let eb = partK < nc ? cuts[2 * partK] : wordLen, eu = partK < nc ? cuts[2 * partK + 1] : wordEnd
            let bytes = eb - pb, single = bytes == 1 || (bytes == 2 && buf[pb] >= 0xC0)
            let b0 = pb, u0 = pu
            pb = eb; pu = eu; partK += 1
            if !single { term = UnsafeBufferPointer(start: buf + b0, count: bytes); start = u0; length = eu - u0; part = true; return true }
        }
        partK = -1; nc = 0
        return false
    }

    /// A word ended at `at`: give it out (and queue its parts).
    private mutating func finish() -> Bool {
        defer { tlen = 0; nsc = 0; pendingJoin = false; long = false }
        guard tlen > 0, !long else { nc = 0; return false }
        let end = at - (pendingJoin ? 1 : 0)
        term = UnsafeBufferPointer(start: buf, count: tlen); start = wordStart; length = end - wordStart; part = false
        if nc > 0 { partK = 0; pb = 0; pu = wordStart; wordEnd = end; wordLen = tlen }
        return true
    }

    mutating func next() -> Bool {
        if partK >= 0 { if nextPart() { return true } }
        let n = src.count
        while i < n {
            let b0 = src[i]
            var v: UInt32
            if b0 < 0x80 { v = UInt32(b0); i += 1 }
            else if b0 < 0xE0, i + 1 < n { v = UInt32(b0 & 0x1F) << 6 | UInt32(src[i + 1] & 0x3F); i += 2 }
            else if b0 < 0xF0, i + 2 < n { v = UInt32(b0 & 0x0F) << 12 | UInt32(src[i + 1] & 0x3F) << 6 | UInt32(src[i + 2] & 0x3F); i += 3 }
            else if i + 3 < n { v = UInt32(b0 & 0x07) << 18 | UInt32(src[i + 1] & 0x3F) << 12 | UInt32(src[i + 2] & 0x3F) << 6 | UInt32(src[i + 3] & 0x3F); i += 4 }
            else { v = 0xFFFD; i += 1 }
            let w = v > 0xFFFF ? 2 : 1
            // the common letters inline; the rest through SearchRules.fold
            var f = v, c: UInt8                     // c: 0 other, 1 letter, 2 digit, 3 joiner, 4 mark
            if v < 0x80 {
                if v >= 0x61 && v <= 0x7A { c = 1 } else if v >= 0x41 && v <= 0x5A { c = 1; f = v + 32 }
                else if v >= 0x30 && v <= 0x39 { c = 2 } else if v == 0x27 || v == 0x60 { c = 3 } else { c = 0 }
            } else if v >= 0x430 && v <= 0x44F && v != 0x439 { c = 1 }
            else {
                let (ff, cls) = SearchRules.fold(scalar: v)
                f = ff
                switch cls { case .letter: c = 1; case .digit: c = 2; case .joiner: c = 3; case .mark: c = 4; case .other: c = 0 }
            }
            switch c {
            case 1, 2:
                if tlen == 0 && !long { wordStart = at; prevClass = 0; prevLowerLatin = false; nc = 0 }
                else if (prevLowerLatin && v >= 0x41 && v <= 0x5A) || (prevClass == 1 && c == 2) || (prevClass == 2 && c == 1) {
                    if nc < 16 { cuts[2 * nc] = tlen; cuts[2 * nc + 1] = at; nc += 1 }
                }
                pendingJoin = false
                if nsc >= SearchRules.termMax { long = true; tlen = 0 }
                if !long {
                    if f < 0x80 { buf[tlen] = UInt8(f); tlen += 1 }
                    else if f < 0x800 { buf[tlen] = UInt8(0xC0 | (f >> 6)); buf[tlen + 1] = UInt8(0x80 | (f & 0x3F)); tlen += 2 }
                    else if f < 0x10000 { buf[tlen] = UInt8(0xE0 | (f >> 12)); buf[tlen + 1] = UInt8(0x80 | ((f >> 6) & 0x3F)); buf[tlen + 2] = UInt8(0x80 | (f & 0x3F)); tlen += 3 }
                    else { buf[tlen] = UInt8(0xF0 | (f >> 18)); buf[tlen + 1] = UInt8(0x80 | ((f >> 12) & 0x3F)); buf[tlen + 2] = UInt8(0x80 | ((f >> 6) & 0x3F)); buf[tlen + 3] = UInt8(0x80 | (f & 0x3F)); tlen += 4 }
                    nsc += 1
                }
                prevClass = c
                prevLowerLatin = v >= 0x61 && v <= 0x7A
                at += w
            case 3:
                let open = tlen > 0 || long
                if open && !pendingJoin { pendingJoin = true; at += w }
                else if open { let ok = finish(); at += w; if ok { return true } }
                else { at += w }
            case 4:
                at += w
            default:
                let ok = (tlen > 0 || long) ? finish() : false
                at += w
                if ok { return true }
            }
        }
        if tlen > 0 || long { if finish() { return true } }
        return partK >= 0 ? nextPart() : false
    }
}

// MARK: - the query language

enum SearchHas: String, CaseIterable {
    case link, picture, change, pin, date, money, phone, email, path, code, iban
    /// Its bit in the index's flags (16 is the index's own "title in body").
    var bit: UInt16 {
        switch self {
        case .pin: return 1; case .change: return 2; case .picture: return 4; case .link: return 8
        case .date: return 32; case .money: return 64; case .phone: return 128; case .email: return 256; case .path: return 512; case .code: return 1024; case .iban: return 2048
        }
    }
}

enum SearchFilter: Equatable {
    case kind(Set<SearchKind>)
    case app(String)                         // folded; matches an app whose folded name contains it
    case with(String)                        // folded; an entity name in the tags
    case time(lo: Double, hi: Double)        // seconds, [lo, hi)
    case has(SearchHas)
    case mentions(lo: Double, hi: Double)    // the text mentions a day in [lo, hi) (wire round)

}

/// A filter written in the query: what the chip shows and where its text is (to take it out again).
struct SearchChip: Equatable {
    let filter: SearchFilter
    let label: String
    let range: NSRange                       // in the query text, UTF-16
}

/// A date word standing alone ("yesterday", "вчора", "last week", "у понеділок", a month): offered as a filter, never
/// applied by itself. `applying` gives the query with those words turned into the filter.
struct SearchOffer: Equatable {
    let token: String                        // "in:yesterday", "in:2026-11-10"
    let label: String                        // "Yesterday", "Monday 10 Nov"
    let filter: SearchFilter
    let range: NSRange                       // the words it replaces
}

/// One word to find. `terms` is usually one folded word; "example.com" gives two, both needed.
struct SearchWord: Equatable {
    let raw: String                          // as typed (the other layout is worked out from this)
    let term: String
    var prefix = false                       // the last word while he types
}

struct SearchQuery: Equatable {
    var raw = ""
    var words: [SearchWord] = []
    var phrases: [[String]] = []             // each a run of folded words that must stand together
    var excluded: [SearchWord] = []
    var excludedPhrases: [[String]] = []
    var chips: [SearchChip] = []
    var offers: [SearchOffer] = []
    var filters: [SearchFilter] { chips.map(\.filter) }
    var isEmpty: Bool { words.isEmpty && phrases.isEmpty && chips.isEmpty && excluded.isEmpty && excludedPhrases.isEmpty }

    /// The query text without a chip (the chip's ✕).
    func removing(_ chip: SearchChip) -> String { SearchQuery.cut(raw, chip.range, with: "") }
    /// The query text with an offered date turned into its filter.
    func applying(_ offer: SearchOffer) -> String { SearchQuery.cut(raw, offer.range, with: offer.token) }

    static func cut(_ s: String, _ r: NSRange, with w: String) -> String {
        let ns = s as NSString
        guard NSMaxRange(r) <= ns.length else { return s }
        let out = ns.replacingCharacters(in: r, with: w)
        return out.split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ") + (w.isEmpty && s.hasSuffix(" ") ? " " : "")
    }
}

/// The clock and calendar a query is read with (Monday first, this Mac's time zone): passed in so tests are fixed.
struct SearchClock {
    var now: Double
    var calendar: Calendar
    init(now: Double = Date().timeIntervalSince1970, timeZone: TimeZone = .current) {
        self.now = now
        var c = Calendar(identifier: .gregorian)
        c.firstWeekday = 2; c.minimumDaysInFirstWeek = 4; c.timeZone = timeZone
        calendar = c
    }
    var date: Date { Date(timeIntervalSince1970: now) }
    func day(_ d: Date) -> (Double, Double) {
        let s = calendar.startOfDay(for: d)
        return (s.timeIntervalSince1970, calendar.date(byAdding: .day, value: 1, to: s)!.timeIntervalSince1970)
    }
    func span(_ unit: Calendar.Component, back: Int = 0) -> (Double, Double) {
        let i = calendar.dateInterval(of: unit, for: calendar.date(byAdding: unit, value: -back, to: date)!)!
        return (i.start.timeIntervalSince1970, i.end.timeIntervalSince1970)
    }
}

enum SearchQueryRules {
    static let kindWords: [String: SearchKind] = [
        "clip": .clip, "clips": .clip, "copied": .clip, "copy": .clip, "clipboard": .clip, "кліп": .clip, "скопійоване": .clip, "копія": .clip,
        "draft": .draft, "drafts": .draft, "typed": .draft, "text": .draft, "чернетка": .draft, "написане": .draft, "текст": .draft,
        "voice": .voice, "said": .voice, "dictation": .voice, "голос": .voice, "сказане": .voice, "диктування": .voice,
        "recording": .recording, "recordings": .recording, "call": .recording, "calls": .recording, "note": .recording, "notes": .recording,
        "запис": .recording, "записи": .recording, "дзвінок": .recording, "дзвінки": .recording, "нотатка": .recording,
    ]
    /// Filter keys, English and Ukrainian.
    static let keys: [String: String] = [
        "kind": "kind", "type": "kind", "тип": "kind",
        "app": "app", "in-app": "app", "програма": "app", "апка": "app",
        "with": "with", "з": "with", "із": "with",
        "in": "in", "у": "in", "в": "in", "коли": "in",
        "before": "before", "до": "before",
        "after": "after", "після": "after",
        "has": "has", "має": "has",
        "is": "is", "є": "is",
        "mentions": "mentions", "mention": "mentions", "згадує": "mentions", "згадка": "mentions", "про": "mentions",
    ]
    static let hasWords: [String: SearchHas] = [
        "link": .link, "links": .link, "url": .link, "посилання": .link, "лінк": .link,
        "picture": .picture, "image": .picture, "pic": .picture, "photo": .picture, "картинка": .picture, "фото": .picture,
        "change": .change, "changed": .change, "edit": .change, "зміна": .change, "змінене": .change,
        "pin": .pin, "pinned": .pin, "закріплене": .pin,
        "date": .date, "dates": .date, "day": .date, "дата": .date, "дати": .date, "день": .date,
        "money": .money, "amount": .money, "sum": .money, "price": .money, "гроші": .money, "сума": .money, "ціна": .money,
        "phone": .phone, "number": .phone, "телефон": .phone, "номер": .phone,
        "email": .email, "e-mail": .email, "mail": .email, "пошта": .email, "імейл": .email,
        "path": .path, "folder": .path, "шлях": .path, "тека": .path,
        "code": .code, "command": .code, "код": .code, "команда": .code,
        "iban": .iban, "account": .iban, "рахунок": .iban, "айбан": .iban,
    ]

    // MARK: date words

    static let monthsEn = ["january", "february", "march", "april", "may", "june", "july", "august", "september", "october", "november", "december"]
    static let monthsShort = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"]
    /// Ukrainian month names in the forms people write (nominative, genitive "березня", locative "у березні").
    static let monthsUk: [[String]] = [
        ["січень", "січня", "січні"], ["лютий", "лютого", "лютому"], ["березень", "березня", "березні"],
        ["квітень", "квітня", "квітні"], ["травень", "травня", "травні"], ["червень", "червня", "червні"],
        ["липень", "липня", "липні"], ["серпень", "серпня", "серпні"], ["вересень", "вересня", "вересні"],
        ["жовтень", "жовтня", "жовтні"], ["листопад", "листопада", "листопаді"], ["грудень", "грудня", "грудні"],
    ]
    static let weekdaysEn = ["monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday"]
    static let weekdaysUk: [[String]] = [
        ["понеділок", "понеділка", "понеділку"], ["вівторок", "вівторка", "вівторку"], ["середа", "середу", "середи"],
        ["четвер", "четверга", "четвергу"], ["п'ятниця", "п'ятницю", "п'ятниці"], ["субота", "суботу", "суботи"],
        ["неділя", "неділю", "неділі"],
    ]
    /// folded word -> month 1...12
    static let monthOf: [String: Int] = {
        var m: [String: Int] = [:]
        for (i, w) in monthsEn.enumerated() { m[w] = i + 1 }
        for (i, w) in monthsShort.enumerated() { m[w] = i + 1 }
        for (i, ws) in monthsUk.enumerated() { for w in ws { m[SearchRules.fold(w)] = i + 1 } }
        return m
    }()
    /// folded word -> weekday 1 (Monday) ... 7
    static let weekdayOf: [String: Int] = {
        var m: [String: Int] = [:]
        for (i, w) in weekdaysEn.enumerated() { m[w] = i + 1 }
        for (i, ws) in weekdaysUk.enumerated() { for w in ws { m[SearchRules.fold(w)] = i + 1 } }
        return m
    }()
    /// Two-word time phrases (folded) -> the in: value they mean.
    static let spans: [String: String] = {
        var m: [String: String] = [:]
        let src: [(String, [String])] = [
            ("this-week", ["this week", "цього тижня", "цей тиждень", "цьому тижні"]),
            ("last-week", ["last week", "минулого тижня", "минулий тиждень", "минулому тижні"]),
            ("this-month", ["this month", "цього місяця", "цей місяць", "цьому місяці"]),
            ("last-month", ["last month", "минулого місяця", "минулий місяць", "минулому місяці"]),
            ("this-year", ["this year", "цього року", "цей рік", "цьому році"]),
            ("last-year", ["last year", "минулого року", "минулий рік", "минулому році"]),
        ]
        for (v, ws) in src { for w in ws { m[SearchRules.fold(w)] = v } }
        return m
    }()
    static let dayWords: [String: String] = {
        var m: [String: String] = [:]
        for w in ["today", "сьогодні", "сьогодня"] { m[SearchRules.fold(w)] = "today" }
        for w in ["yesterday", "вчора", "учора"] { m[SearchRules.fold(w)] = "yesterday" }
        return m
    }()
    /// Small words before a date that go with it into the filter ("on Monday", "у понеділок", "in March", "на").
    static let datePrepositions: Set<String> = ["on", "in", "у", "в", "на", "за"]

    /// An in: value -> its interval and its chip label. Values: today, yesterday, this-week, last-week, this-month,
    /// last-month, this-year, last-year, a month name (either language, the last one that is not in the future), a
    /// year, a day yyyy-mm-dd or dd.mm(.yyyy), a weekday (the latest one, today included).
    /// `forward` (mentions:): a weekday or a month is the next one (today and this month included), and tomorrow counts.
    static func interval(_ value: String, _ clock: SearchClock, forward: Bool = false) -> (lo: Double, hi: Double, label: String)? {
        let v = SearchRules.fold(value).replacingOccurrences(of: " ", with: "-")
        let cal = clock.calendar
        if forward, ["tomorrow", "завтра"].contains(v) {
            let d = clock.day(cal.date(byAdding: .day, value: 1, to: clock.date)!); return (d.0, d.1, "Tomorrow")
        }
        switch v {
        case "today": let d = clock.day(clock.date); return (d.0, d.1, "Today")
        case "yesterday": let d = clock.day(cal.date(byAdding: .day, value: -1, to: clock.date)!); return (d.0, d.1, "Yesterday")
        case "this-week", "thisweek", "week": let s = clock.span(.weekOfYear); return (s.0, s.1, "This week")
        case "last-week", "lastweek": let s = clock.span(.weekOfYear, back: 1); return (s.0, s.1, "Last week")
        case "this-month", "thismonth", "month": let s = clock.span(.month); return (s.0, s.1, "This month")
        case "last-month", "lastmonth": let s = clock.span(.month, back: 1); return (s.0, s.1, "Last month")
        case "this-year", "thisyear", "year": let s = clock.span(.year); return (s.0, s.1, "This year")
        case "last-year", "lastyear": let s = clock.span(.year, back: 1); return (s.0, s.1, "Last year")
        default: break
        }
        if let k = spans[SearchRules.fold(value.replacingOccurrences(of: "-", with: " "))] { return interval(k, clock) }
        if let k = dayWords[v] { return interval(k, clock) }
        if let m = monthOf[v] {
            let y = cal.component(.year, from: clock.date), mNow = cal.component(.month, from: clock.date)
            let year = forward ? (m < mNow ? y + 1 : y) : (m > mNow ? y - 1 : y)
            let s = cal.date(from: DateComponents(year: year, month: m, day: 1))!
            let e = cal.date(byAdding: .month, value: 1, to: s)!
            return (s.timeIntervalSince1970, e.timeIntervalSince1970, monthsEn[m - 1].capitalized + (year == y ? "" : " \(year)"))
        }
        if let wd = weekdayOf[v] {
            // Calendar weekday: 1 = Sunday; ours 1 = Monday
            let today = (cal.component(.weekday, from: clock.date) + 5) % 7 + 1
            let back = forward ? -((wd - today + 7) % 7) : (today - wd + 7) % 7
            let d = cal.date(byAdding: .day, value: -back, to: clock.date)!
            let r = clock.day(d)
            return (r.0, r.1, weekdaysEn[wd - 1].capitalized + " " + dayLabel(d, cal))
        }
        if v.count == 4, let y = Int(v), (1990...2100).contains(y) {
            let s = cal.date(from: DateComponents(year: y, month: 1, day: 1))!, e = cal.date(byAdding: .year, value: 1, to: s)!
            return (s.timeIntervalSince1970, e.timeIntervalSince1970, String(y))
        }
        if let d = parseDay(value, clock) { let r = clock.day(d); return (r.0, r.1, dayLabel(d, cal)) }
        return nil
    }

    static func dayLabel(_ d: Date, _ cal: Calendar) -> String {
        let c = cal.dateComponents([.day, .month], from: d)
        return "\(c.day ?? 0) " + monthsShort[(c.month ?? 1) - 1].capitalized
    }

    /// 2026-11-10, 10.11.2026, 10.11 (this year), 10/11/2026.
    static func parseDay(_ s: String, _ clock: SearchClock) -> Date? {
        let parts = s.split(whereSeparator: { "-./".contains($0) }).map(String.init)
        guard parts.count >= 2, parts.allSatisfy({ Int($0) != nil }) else { return nil }
        let n = parts.map { Int($0)! }
        var y = clock.calendar.component(.year, from: clock.date), m = 0, d = 0
        if parts[0].count == 4, n.count == 3 { (y, m, d) = (n[0], n[1], n[2]) }
        else if n.count == 3 { (d, m, y) = (n[0], n[1], n[2] < 100 ? 2000 + n[2] : n[2]) }
        else { (d, m) = (n[0], n[1]) }
        guard (1...12).contains(m), (1...31).contains(d) else { return nil }
        return clock.calendar.date(from: DateComponents(year: y, month: m, day: d))
    }

    // MARK: parse

    private struct Piece { var text: String; var range: NSRange; var quoted: Bool; var negated: Bool }

    /// Cut the query into pieces: words, "quoted phrases" (also «» and “”), -negated, key:"quoted value".
    private static func pieces(_ s: String) -> [Piece] {
        let u = Array(s.utf16)
        var out: [Piece] = []
        var i = 0
        let quoteOpen: Set<UInt16> = [0x22, 0xAB, 0x201C, 0x201E], quoteClose: Set<UInt16> = [0x22, 0xBB, 0x201D, 0x201C]
        func isSpace(_ c: UInt16) -> Bool { c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D || c == 0xA0 }
        while i < u.count {
            if isSpace(u[i]) { i += 1; continue }
            let start = i
            var neg = false
            if u[i] == 0x2D, i + 1 < u.count, !isSpace(u[i + 1]) { neg = true; i += 1 }
            if quoteOpen.contains(u[i]) {
                let open = i; i += 1
                while i < u.count, !quoteClose.contains(u[i]) { i += 1 }
                let text = String(utf16CodeUnits: Array(u[(open + 1)..<i]), count: i - open - 1)
                if i < u.count { i += 1 }
                out.append(Piece(text: text, range: NSRange(location: start, length: i - start), quoted: true, negated: neg))
                continue
            }
            // a word, or key:"quoted value"
            while i < u.count, !isSpace(u[i]) {
                if u[i] == 0x3A, i + 1 < u.count, quoteOpen.contains(u[i + 1]) {
                    i += 2
                    while i < u.count, !quoteClose.contains(u[i]) { i += 1 }
                    if i < u.count { i += 1 }
                    break
                }
                i += 1
            }
            let b = neg ? start + 1 : start
            var text = String(utf16CodeUnits: Array(u[b..<i]), count: i - b)
            text = text.replacingOccurrences(of: "\"", with: "").replacingOccurrences(of: "«", with: "").replacingOccurrences(of: "»", with: "")
            out.append(Piece(text: text, range: NSRange(location: start, length: i - start), quoted: false, negated: neg))
        }
        return out
    }

    /// The query as a UI and the index need it. Words AND; the last word is a prefix unless a space follows it.
    static func parse(_ s: String, clock: SearchClock = SearchClock()) -> SearchQuery {
        var q = SearchQuery(raw: s)
        var ps = pieces(s)
        var i = 0
        var plain: [(Piece, Int)] = []    // plain words with their piece index, for date offers
        while i < ps.count {
            let p = ps[i]
            defer { i += 1 }
            if p.quoted {
                let t = SearchRules.terms(p.text)
                guard !t.isEmpty else { continue }
                if p.negated { q.excludedPhrases.append(t) } else if t.count == 1 { q.words.append(SearchWord(raw: p.text, term: t[0])) } else { q.phrases.append(t) }
                continue
            }
            if !p.negated, let colon = p.text.firstIndex(of: ":"), colon != p.text.startIndex,
               let key = keys[p.text[..<colon].lowercased()] {
                var value = String(p.text[p.text.index(after: colon)...])
                var range = p.range
                // in:this week, in:last week, in:цього тижня (the second word joins)
                if key == "in", i + 1 < ps.count, !ps[i + 1].quoted,
                   spans[SearchRules.fold(value + " " + ps[i + 1].text)] != nil {
                    value += " " + ps[i + 1].text
                    range = NSRange(location: p.range.location, length: NSMaxRange(ps[i + 1].range) - p.range.location)
                    ps.remove(at: i + 1)
                }
                if let chip = chip(key: key, value: value, range: range, clock: clock) { q.chips.append(chip); continue }
                if value.isEmpty { continue }    // "app:" still being typed: no word, no chip yet
            }
            var ts = SearchRules.terms(p.text)
            // keys that are letters in the other layout (, . ; [ ] ' are б ю ж х ї є): one word, found through the layout
            if ts.count > 1, let o = SearchRules.otherLayout(p.text), SearchRules.terms(o).count == 1 {
                let w = SearchWord(raw: p.text, term: ts.joined())
                if p.negated { q.excluded.append(w) } else { q.words.append(w); plain.append((p, q.words.count - 1)) }
                continue
            }
            if ts.isEmpty, let o = SearchRules.otherLayout(p.text), SearchRules.terms(o).count == 1 { ts = [p.text] }
            for t in ts {
                let w = SearchWord(raw: ts.count == 1 ? p.text : t, term: t)
                if p.negated { q.excluded.append(w) } else { q.words.append(w); plain.append((p, q.words.count - 1)) }
            }
        }
        // the last word is a prefix while he types (no space after it, not quoted, not a chip)
        if let last = ps.last, !last.quoted, !last.negated, NSMaxRange(last.range) == (s as NSString).length,
           let lw = q.words.last, plain.last?.1 == q.words.count - 1 {
            q.words[q.words.count - 1].prefix = lw.term.unicodeScalars.count >= SearchWeights.prefixMin
        }
        q.offers = offers(plain.map { $0.0 }, clock: clock)
        return q
    }

    static func chip(key: String, value: String, range: NSRange, clock: SearchClock) -> SearchChip? {
        let v = value.trimmingCharacters(in: .whitespaces)
        guard !v.isEmpty else { return nil }
        let f = SearchRules.fold(v)
        switch key {
        case "kind":
            let ks = Set(v.split(separator: ",").compactMap { kindWords[SearchRules.fold(String($0)).replacingOccurrences(of: " ", with: "")] ?? kindWords[String($0).lowercased()] })
            guard !ks.isEmpty else { return nil }
            return SearchChip(filter: .kind(ks), label: ks.map(\.rawValue).sorted().joined(separator: ", ").capitalized, range: range)
        case "app": return SearchChip(filter: .app(f), label: "App: " + v, range: range)
        case "with": return SearchChip(filter: .with(f), label: "With " + v, range: range)
        case "in":
            guard let t = interval(v, clock) else { return nil }
            return SearchChip(filter: .time(lo: t.lo, hi: t.hi), label: t.label, range: range)
        case "before":
            guard let t = interval(v, clock) else { return nil }
            return SearchChip(filter: .time(lo: -.infinity, hi: t.lo), label: "Before " + t.label, range: range)
        case "after":
            guard let t = interval(v, clock) else { return nil }
            return SearchChip(filter: .time(lo: t.hi, hi: .infinity), label: "After " + t.label, range: range)
        case "has":
            guard let h = hasWords[f.replacingOccurrences(of: " ", with: "")] ?? hasWords[v.lowercased()] else { return nil }
            return SearchChip(filter: .has(h), label: "Has " + h.rawValue, range: range)
        case "mentions":
            guard let t = interval(v, clock, forward: true) else { return nil }
            return SearchChip(filter: .mentions(lo: t.lo, hi: t.hi), label: "Mentions " + t.label, range: range)
        case "is":
            guard ["pinned", "pin", "закріплене"].contains(f) else { return nil }
            return SearchChip(filter: .has(.pin), label: "Pinned", range: range)
        default: return nil
        }
    }

    /// Date words standing alone, as offers: "yesterday", "вчора", "last week", "минулого тижня", "у понеділок",
    /// "березня". "may" alone is a word, not a month (offered only as in:may).
    private static func offers(_ ps: [Piece], clock: SearchClock) -> [SearchOffer] {
        var out: [SearchOffer] = []
        var i = 0
        while i < ps.count {
            let a = ps[i], fa = SearchRules.fold(a.text)
            var used = 1, value: String?, label: String?
            if i + 1 < ps.count, ps[i + 1].range.location <= NSMaxRange(a.range) + 2,
               let k = spans[fa + " " + SearchRules.fold(ps[i + 1].text)] { value = k; used = 2 }
            else if i + 2 < ps.count, datePrepositions.contains(fa),
                    let k = spans[SearchRules.fold(ps[i + 1].text) + " " + SearchRules.fold(ps[i + 2].text)] { value = k; used = 3 }
            else if let k = dayWords[fa] { value = k }
            else if datePrepositions.contains(fa), i + 1 < ps.count, let v = dateWord(SearchRules.fold(ps[i + 1].text)) { value = v; used = 2 }
            else if fa == "last" || fa == "минулого" || fa == "минулий" || fa == "минулої" || fa == "минулу",
                    i + 1 < ps.count, let wd = weekdayOf[SearchRules.fold(ps[i + 1].text)] {
                // last monday: the one in last week
                let wk = clock.span(.weekOfYear, back: 1)
                let d = clock.calendar.date(byAdding: .day, value: wd - 1, to: Date(timeIntervalSince1970: wk.0))!
                let c = clock.calendar.dateComponents([.year, .month, .day], from: d)
                value = String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!); used = 2
                label = weekdaysEn[wd - 1].capitalized + " " + dayLabel(d, clock.calendar)
            }
            else if let v = dateWord(fa) { value = v }
            if let value, let t = interval(value, clock) {
                var token = value
                if let wd = weekdayOf[value] {
                    _ = wd
                    let c = clock.calendar.dateComponents([.year, .month, .day], from: Date(timeIntervalSince1970: t.lo))
                    token = String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
                }
                let last = ps[i + used - 1]
                let range = NSRange(location: a.range.location, length: NSMaxRange(last.range) - a.range.location)
                out.append(SearchOffer(token: "in:" + token, label: label ?? t.label, filter: .time(lo: t.lo, hi: t.hi), range: range))
                i += used
                continue
            }
            i += 1
        }
        return out
    }
    private static func dateWord(_ f: String) -> String? {
        if weekdayOf[f] != nil { return f }
        if let m = monthOf[f], f != "may", f.count > 3 { return monthsEn[m - 1] }
        return nil
    }
}

// Written forms of a thing he copied (format round, 15 November 2026; Andrii: "would also be great to do a bunch of
// autoformatting on copy for dates, numbers, IBAN account, etc."). For one detected thing (app/DetectRules.swift) or
// a plain number: its useful forms, each with a short name and the text; amounts in words in Ukrainian and English as
// on invoices; IBAN, ЄДРПОУ and РНОКПП check digits (an invalid one gets no forms, only a note: never "fixed");
// a card-like number that passes Luhn is sensitive (no forms, no chip, no index); plain-text clean-ups. And the rule
// store with its learner: after the same pick three times the app may ask once "Always?"; a rule is stored only on
// his yes and undoes. Pure: Foundation only; the store's file is passed in (data/format-rules.json in the app).
// The copy chip that uses it: app/Clip.swift. Tests: tests/format_rules.swift. Notes: docs/rounds/2026-11-15-detect.md.
import Foundation

/// Where the text will go, when known: machine forms first for code and terminals, the local written form first for
/// chats and mail.
enum FormatDest: String, Codable, CaseIterable { case code, terminal, chat, mail, other }

struct FormatVariant: Equatable {
    let id: String       // stable: what a stored rule names ("compact", "iso", "uk"...)
    let name: String     // a noun phrase for the chip: "No spaces", "ISO date"
    let text: String
}

/// What a whole copied text is, when it is one thing.
struct FormatOne: Equatable {
    var kind: String                 // date, number, money, iban, phone, edrpou, rntrc, link, path, color, card
    var variants: [FormatVariant]    // empty for a sensitive or invalid thing
    var note: String? = nil          // "Check digit does not match"
    var detail: String? = nil        // "Bank code 322313"
    var sensitive = false
}

enum Format {
    static let nbsp = "\u{00A0}"     // the Ukrainian group mark: a non-breaking space (U+00A0), with a plain-space twin

    // MARK: - the whole clip

    /// The thing a copied text is, if the whole text (spaces around allowed) is exactly one: a sensitive card number,
    /// an IBAN (valid or not), a phone, a ЄДРПОУ or РНОКПП that passes its check, one detected date, money, link,
    /// path or colour, or a plain number. nil: a text that only contains things, or nothing.
    static func whole(_ text: String, written: Date = Date(), hints: DetectHints = DetectHints(), dest: FormatDest = .other) -> FormatOne? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, t.count <= 400, !t.contains("\n") else { return nil }
        let digits = t.filter { $0.isASCII && $0.isNumber }
        let onlyDigitsAndGaps = t.allSatisfy { ($0.isASCII && $0.isNumber) || $0 == " " || $0 == "-" || $0 == "\u{00A0}" }
        if onlyDigitsAndGaps, (13...19).contains(digits.count), luhn(digits), !(digits.count == 10 || digits.count == 12) {
            return FormatOne(kind: "card", variants: [], sensitive: true)
        }
        if t.range(of: #"^[A-Za-z]{2}\d{2}[A-Za-z0-9 ]{11,40}$"#, options: .regularExpression) != nil {
            let c = t.uppercased().filter { $0 != " " }
            guard c.count >= 15, c.count <= 34 else { return nil }
            if let want = Detect.ibanLen[String(c.prefix(2))], want != c.count { return FormatOne(kind: "iban", variants: [], note: "Length does not match the country") }
            guard Detect.ibanValid(c) else { return FormatOne(kind: "iban", variants: [], note: "Check digit does not match") }
            return FormatOne(kind: "iban", variants: order(ibanForms(c), "iban", dest), detail: ibanBank(c).map { "Bank code \($0)" })
        }
        let found = Detect.scan(t, written: written, hints: hints)
        if found.contains(where: \.sensitive) { return FormatOne(kind: "code", variants: [], sensitive: true) }
        if onlyDigitsAndGaps && digits.count == 8 && edrpouValid(digits) {
            return FormatOne(kind: "edrpou", variants: digits == t ? [] : [FormatVariant(id: "digits", name: "Digits only", text: digits)], detail: "ЄДРПОУ, check digit matches")
        }
        if onlyDigitsAndGaps && digits.count == 10 && !digits.hasPrefix("0") && rntrcValid(digits) {
            return FormatOne(kind: "rntrc", variants: digits == t ? [] : [FormatVariant(id: "digits", name: "Digits only", text: digits)], detail: "РНОКПП, check digit matches")
        }
        let len = (t as NSString).length
        if found.count == 1, let f = found.first, f.range.location == 0, f.range.length == len {
            let kind: String
            let v: [FormatVariant]
            switch f.kind {
            case .date, .dateRange: kind = "date"; v = dateForms(f, timeZone: hints.timeZone)
            case .money: kind = "money"; v = moneyForms(f)
            case .phone: kind = "phone"; v = phoneForms(f.value)
            case .link: kind = "link"; v = linkForms(f.value, title: "")
            case .path: kind = "path"; v = f.bare ? [] : pathForms(f.value, home: hints.home)
            case .color: kind = "color"; v = colorForms(f.value)
            case .email: kind = "email"; v = []
            default: return nil
            }
            guard !v.isEmpty else { return nil }
            return FormatOne(kind: kind, variants: order(v, kind, dest))
        }
        if found.isEmpty, let n = parseNumber(t) {
            let v = numberForms(n)
            return v.isEmpty ? nil : FormatOne(kind: "number", variants: order(v, "number", dest))
        }
        return nil
    }

    /// The forms of one found thing (the journal's "Copy as…" and "Insert as…"). Sensitive things have none.
    static func variants(for f: Found, dest: FormatDest = .other, title: String = "", hints: DetectHints = DetectHints()) -> [FormatVariant] {
        guard !f.sensitive else { return [] }
        let v: [FormatVariant], kind: String
        switch f.kind {
        case .date, .dateRange: kind = "date"; v = dateForms(f, timeZone: hints.timeZone)
        case .money: kind = "money"; v = moneyForms(f)
        case .phone: kind = "phone"; v = phoneForms(f.value)
        case .link: kind = "link"; v = linkForms(f.value, title: title)
        case .path: kind = "path"; v = f.bare ? [] : pathForms(f.value, home: hints.home)
        case .color: kind = "color"; v = colorForms(f.value)
        case .iban: kind = "iban"; v = ibanForms(f.value)
        default: return []
        }
        return order(v, kind, dest)
    }

    // MARK: - order by destination

    /// Ids of the machine forms per kind, most wanted first; the local written forms follow in their own order.
    static let machine: [String: [String]] = [
        "date": ["iso"], "number": ["plain"], "money": ["code", "plain"], "iban": ["compact"], "phone": ["e164", "tel"],
        "link": ["clean", "host"], "path": ["posix", "quoted", "url"], "color": ["hex", "rgb"],
    ]
    static let local: [String: [String]] = [
        "date": ["uk", "ukLong", "enLong", "weekday"], "number": ["uk", "ukPlain", "en"], "money": ["uk", "en", "ukWords", "enWords"],
        "iban": ["grouped"], "phone": ["national", "spaced"], "link": ["markdown"], "path": ["tilde"], "color": ["name"],
    ]
    static func order(_ v: [FormatVariant], _ kind: String, _ dest: FormatDest) -> [FormatVariant] {
        let m = machine[kind] ?? [], l = local[kind] ?? []
        let first: [String]
        switch dest {
        case .code, .terminal: first = m + l
        case .chat, .mail: first = l + m
        case .other: first = kind == "iban" || kind == "phone" || kind == "link" || kind == "path" || kind == "color" ? m + l : l + m
        }
        func rank(_ id: String) -> Int { first.firstIndex(of: id) ?? 99 }
        return v.enumerated().sorted { (rank($0.element.id), $0.offset) < (rank($1.element.id), $1.offset) }.map(\.element)
    }

    // MARK: - dates

    static let ukMonthsGen = ["січня", "лютого", "березня", "квітня", "травня", "червня", "липня", "серпня", "вересня", "жовтня", "листопада", "грудня"]
    static let enMonths = ["January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December"]
    static let enDays = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]

    static func dateForms(_ f: Found, timeZone: TimeZone) -> [FormatVariant] {
        guard let a = f.date else { return [] }
        var cal = Calendar(identifier: .gregorian); cal.timeZone = timeZone
        func parts(_ d: Date) -> (y: Int, m: Int, d: Int, hm: String?, wd: Int) {
            let c = cal.dateComponents([.year, .month, .day, .hour, .minute, .weekday], from: d)
            return (c.year!, c.month!, c.day!, f.allDay ? nil : String(format: "%02d:%02d", c.hour!, c.minute!), c.weekday!)
        }
        func one(_ d: Date, _ style: String) -> String {
            let p = parts(d)
            switch style {
            case "uk": return String(format: "%02d.%02d.%04d", p.d, p.m, p.y) + (p.hm.map { " " + $0 } ?? "")
            case "ukLong": return "\(p.d) \(ukMonthsGen[p.m - 1]) \(p.y)" + (p.hm.map { " о " + $0 } ?? "")
            case "enLong": return "\(p.d) \(enMonths[p.m - 1]) \(p.y)" + (p.hm.map { ", " + $0 } ?? "")
            default: return "\(enDays[p.wd - 1]), \(p.d) \(enMonths[p.m - 1].prefix(3)) \(p.y)" + (p.hm.map { ", " + $0 } ?? "")
            }
        }
        func both(_ style: String) -> String { f.end.map { one(a, style) + " – " + one($0, style) } ?? one(a, style) }
        return [FormatVariant(id: "iso", name: f.allDay ? "ISO date" : "ISO date and time", text: f.value),
                FormatVariant(id: "uk", name: "Numeric", text: both("uk")),
                FormatVariant(id: "ukLong", name: "Ukrainian", text: both("ukLong")),
                FormatVariant(id: "enLong", name: "English", text: both("enLong")),
                FormatVariant(id: "weekday", name: "With weekday", text: both("weekday"))]
    }

    // MARK: - numbers (every digit kept)

    struct Num: Equatable { var negative = false; var int: String; var frac: String }

    /// A plain number as written: "1234567.5", "1 234 567,5", "1,234,567.50", "-12". nil when the separator is
    /// ambiguous ("1,234" or "1.234": thousands or a fraction) or it is not a number.
    static func parseNumber(_ raw: String) -> Num? {
        var s = raw.trimmingCharacters(in: .whitespaces)
        var neg = false
        if s.hasPrefix("-") || s.hasPrefix("−") { neg = true; s.removeFirst() }
        s = s.replacingOccurrences(of: "\u{00A0}", with: " ").replacingOccurrences(of: "\u{202F}", with: " ")
        guard !s.isEmpty, s.allSatisfy({ ($0.isASCII && $0.isNumber) || " .,".contains($0) }), s.first!.isNumber, s.last!.isNumber else { return nil }
        let seps = s.filter { ".,".contains($0) }
        var int = s, frac = ""
        if seps.isEmpty {
            int = s
        } else if Set(seps).count == 2 {
            let dec = s.lastIndex(where: { ".,".contains($0) })!
            let decCh = s[dec], grp = decCh == "." ? "," : "."
            guard s[..<dec].allSatisfy({ $0 != decCh }) else { return nil }
            int = String(s[..<dec]).replacingOccurrences(of: grp, with: ""); frac = String(s[s.index(after: dec)...])
            guard groupsOK(String(s[..<dec]), grp) else { return nil }
        } else {
            let ch = seps.first!
            let pieces = s.split(separator: ch, omittingEmptySubsequences: false).map(String.init)
            if pieces.count > 2 {
                guard groupsOK(s, String(ch)) else { return nil }
                int = s.replacingOccurrences(of: String(ch), with: "")
            } else {
                let after = pieces[1]
                if after.count == 3 && !pieces[0].contains(" ") && pieces[0].count <= 3 { return nil }   // ambiguous
                int = pieces[0]; frac = after
            }
        }
        if int.contains(" ") { guard groupsOK(int, " ") else { return nil }; int = int.replacingOccurrences(of: " ", with: "") }
        guard !int.isEmpty, int.allSatisfy(\.isNumber), frac.allSatisfy(\.isNumber), int.count <= 15 else { return nil }
        guard int.count >= 5 || !frac.isEmpty else { return nil }   // a short whole number (a year, "1250") stays as it is
        return Num(negative: neg, int: int, frac: frac)
    }
    static func groupsOK(_ s: String, _ sep: String) -> Bool {
        let g = s.components(separatedBy: sep)
        guard g.count > 1 else { return true }
        return (1...3).contains(g[0].count) && g.dropFirst().allSatisfy { $0.count == 3 }
    }
    static func group(_ int: String, _ sep: String) -> String {
        var out = "", i = 0
        for ch in int.reversed() { if i > 0 && i % 3 == 0 { out = sep + out }; out = String(ch) + out; i += 1 }
        return out
    }
    static func numText(_ n: Num, _ style: String) -> String {
        let sign = n.negative ? "-" : ""
        switch style {
        case "plain": return sign + n.int + (n.frac.isEmpty ? "" : "." + n.frac)
        case "uk": return sign + group(n.int, nbsp) + (n.frac.isEmpty ? "" : "," + n.frac)
        case "ukPlain": return sign + group(n.int, " ") + (n.frac.isEmpty ? "" : "," + n.frac)
        default: return sign + group(n.int, ",") + (n.frac.isEmpty ? "" : "." + n.frac)
        }
    }
    static func numberForms(_ n: Num) -> [FormatVariant] {
        [FormatVariant(id: "plain", name: "Plain", text: numText(n, "plain")),
         FormatVariant(id: "uk", name: "Ukrainian", text: numText(n, "uk")),
         FormatVariant(id: "ukPlain", name: "Ukrainian, plain spaces", text: numText(n, "ukPlain")),
         FormatVariant(id: "en", name: "English", text: numText(n, "en"))]
    }

    // MARK: - money

    struct Cur { let code: String; let uk: String; let symbol: String?
                 let one: [String]; let sub: [String]; let fem: Bool; let subFem: Bool
                 let en: (String, String); let enSub: (String, String) }
    static let currencies: [String: Cur] = [
        "UAH": Cur(code: "UAH", uk: "грн", symbol: "₴", one: ["гривня", "гривні", "гривень"], sub: ["копійка", "копійки", "копійок"], fem: true, subFem: true,
                   en: ("hryvnia", "hryvnias"), enSub: ("kopiyka", "kopiykas")),
        "USD": Cur(code: "USD", uk: "USD", symbol: "$", one: ["долар", "долари", "доларів"], sub: ["цент", "центи", "центів"], fem: false, subFem: false,
                   en: ("dollar", "dollars"), enSub: ("cent", "cents")),
        "EUR": Cur(code: "EUR", uk: "EUR", symbol: "€", one: ["євро", "євро", "євро"], sub: ["цент", "центи", "центів"], fem: false, subFem: false,
                   en: ("euro", "euros"), enSub: ("cent", "cents")),
        "GBP": Cur(code: "GBP", uk: "GBP", symbol: "£", one: ["фунт", "фунти", "фунтів"], sub: ["пенс", "пенси", "пенсів"], fem: false, subFem: false,
                   en: ("pound", "pounds"), enSub: ("penny", "pence")),
        "PLN": Cur(code: "PLN", uk: "PLN", symbol: nil, one: ["злотий", "злоті", "злотих"], sub: ["грош", "гроші", "грошів"], fem: false, subFem: false,
                   en: ("zloty", "zlotys"), enSub: ("grosz", "groszy")),
    ]

    static func moneyForms(_ f: Found) -> [FormatVariant] {
        guard let code = f.currency, let a = f.amount else { return [] }
        // the amount as written, every digit kept (no rounding): from the normalised value
        let txt = Detect.moneyText(a)
        let parts = txt.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        var n = Num(negative: false, int: parts[0], frac: parts.count > 1 ? parts[1] : "")
        let exact = n.frac.count <= 2
        if exact { n.frac = n.frac.padding(toLength: 2, withPad: "0", startingAt: 0) }   // 2 decimals adds zeros only
        let c = currencies[code]
        var v = [FormatVariant(id: "uk", name: "Ukrainian", text: numText(n, "uk") + nbsp + (c?.uk ?? code))]
        v.append(FormatVariant(id: "en", name: "English", text: (c?.symbol ?? (code + " ")) + numText(n, "en")))
        v.append(FormatVariant(id: "code", name: "Code and number", text: code + " " + numText(n, "plain")))
        v.append(FormatVariant(id: "plain", name: "Number only", text: numText(n, "plain")))
        if exact, let c, let whole = Int(n.int), whole < 1_000_000_000_000 {
            let cents = Int(n.frac) ?? 0
            v.append(FormatVariant(id: "ukWords", name: "In words, Ukrainian", text: ukAmount(whole, cents, c)))
            v.append(FormatVariant(id: "enWords", name: "In words, English", text: enAmount(whole, cents, c)))
        }
        return v
    }

    // Ukrainian number words
    static let ukOnes = ["", "один", "два", "три", "чотири", "п'ять", "шість", "сім", "вісім", "дев'ять"]
    static let ukOnesF = ["", "одна", "дві", "три", "чотири", "п'ять", "шість", "сім", "вісім", "дев'ять"]
    static let ukTeens = ["десять", "одинадцять", "дванадцять", "тринадцять", "чотирнадцять", "п'ятнадцять", "шістнадцять", "сімнадцять", "вісімнадцять", "дев'ятнадцять"]
    static let ukTens = ["", "", "двадцять", "тридцять", "сорок", "п'ятдесят", "шістдесят", "сімдесят", "вісімдесят", "дев'яносто"]
    static let ukHundreds = ["", "сто", "двісті", "триста", "чотириста", "п'ятсот", "шістсот", "сімсот", "вісімсот", "дев'ятсот"]
    /// 1 гривня, 2 гривні, 5 гривень, 11 гривень, 21 гривня, 22 гривні.
    static func ukForm(_ n: Int, _ f: [String]) -> String {
        let h = n % 100, t = n % 10
        if (11...14).contains(h) { return f[2] }
        if t == 1 { return f[0] }
        if (2...4).contains(t) { return f[1] }
        return f[2]
    }
    static func ukTriad(_ n: Int, fem: Bool) -> [String] {
        var w: [String] = []
        if n / 100 > 0 { w.append(ukHundreds[n / 100]) }
        let r = n % 100
        if (10...19).contains(r) { w.append(ukTeens[r - 10]) }
        else {
            if r / 10 > 1 { w.append(ukTens[r / 10]) }
            if r % 10 > 0 { w.append((fem ? ukOnesF : ukOnes)[r % 10]) }
        }
        return w
    }
    static func ukWords(_ n: Int, fem: Bool) -> String {
        if n == 0 { return "нуль" }
        var w: [String] = []
        let scales: [(Int, [String], Bool)] = [(1_000_000_000, ["мільярд", "мільярди", "мільярдів"], false),
                                               (1_000_000, ["мільйон", "мільйони", "мільйонів"], false),
                                               (1000, ["тисяча", "тисячі", "тисяч"], true)]
        var rest = n
        for (size, forms, g) in scales {
            let k = rest / size
            if k > 0 { w += ukTriad(k, fem: g); w.append(ukForm(k, forms)) }
            rest %= size
        }
        w += ukTriad(rest, fem: fem)
        return w.joined(separator: " ")
    }
    /// "одна тисяча двісті п'ятдесят гривень 00 копійок"
    static func ukAmount(_ whole: Int, _ cents: Int, _ c: Cur) -> String {
        ukWords(whole, fem: c.fem) + " " + ukForm(whole, c.one) + " " + String(format: "%02d", cents) + " " + ukForm(cents, c.sub)
    }

    static let enOnes = ["", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten", "eleven", "twelve",
                         "thirteen", "fourteen", "fifteen", "sixteen", "seventeen", "eighteen", "nineteen"]
    static let enTens = ["", "", "twenty", "thirty", "forty", "fifty", "sixty", "seventy", "eighty", "ninety"]
    static func enTriad(_ n: Int) -> [String] {
        var w: [String] = []
        if n / 100 > 0 { w += [enOnes[n / 100], "hundred"] }
        let r = n % 100
        if r < 20 { if r > 0 { w.append(enOnes[r]) } }
        else { w.append(enTens[r / 10] + (r % 10 > 0 ? "-" + enOnes[r % 10] : "")) }
        return w
    }
    static func enWords(_ n: Int) -> String {
        if n == 0 { return "zero" }
        var w: [String] = [], rest = n
        for (size, name) in [(1_000_000_000, "billion"), (1_000_000, "million"), (1000, "thousand")] {
            let k = rest / size
            if k > 0 { w += enTriad(k); w.append(name) }
            rest %= size
        }
        w += enTriad(rest)
        return w.joined(separator: " ")
    }
    /// "one thousand two hundred fifty hryvnias and 00 kopiykas"
    static func enAmount(_ whole: Int, _ cents: Int, _ c: Cur) -> String {
        enWords(whole) + " " + (whole == 1 ? c.en.0 : c.en.1) + " and " + String(format: "%02d", cents) + " " + (cents == 1 ? c.enSub.0 : c.enSub.1)
    }

    // MARK: - IBAN, Ukrainian codes, cards

    static func ibanForms(_ c: String) -> [FormatVariant] {
        let grouped = stride(from: 0, to: c.count, by: 4).map { i -> String in
            let a = c.index(c.startIndex, offsetBy: i); return String(c[a..<c.index(a, offsetBy: min(4, c.count - i))]) }.joined(separator: " ")
        return [FormatVariant(id: "compact", name: "No spaces", text: c), FormatVariant(id: "grouped", name: "Groups of four", text: grouped)]
    }
    /// A Ukrainian IBAN's bank code (МФО): the six digits after the country and the check digits.
    static func ibanBank(_ c: String) -> String? {
        guard c.hasPrefix("UA"), c.count == 29 else { return nil }
        return String(c.dropFirst(4).prefix(6))
    }
    /// ЄДРПОУ: weights 1-7 (7,1-6 for codes starting with 3, 4 or 5), sum mod 11; a remainder of 10: weights + 2,
    /// mod 11 mod 10. Source: python-stdnum stdnum/ua/edrpou.py (docs/rounds/2026-11-15-detect.md).
    static func edrpouValid(_ d: String) -> Bool {
        let n = d.compactMap(\.wholeNumberValue)
        guard n.count == 8 else { return false }
        var w = "345".contains(d.first!) ? [7, 1, 2, 3, 4, 5, 6] : [1, 2, 3, 4, 5, 6, 7]
        var s = zip(w, n).map(*).reduce(0, +) % 11
        if s == 10 { w = w.map { $0 + 2 }; s = zip(w, n).map(*).reduce(0, +) % 11 % 10 }
        return s == n[7]
    }
    /// РНОКПП: weights -1 5 7 9 4 6 10 5 7, sum mod 11 mod 10. Sources: uk.wikipedia РНОКПП, python-stdnum stdnum/ua/rntrc.py.
    static func rntrcValid(_ d: String) -> Bool {
        let n = d.compactMap(\.wholeNumberValue)
        guard n.count == 10 else { return false }
        let s = zip([-1, 5, 7, 9, 4, 6, 10, 5, 7], n).map(*).reduce(0, +)
        return ((s % 11) + 11) % 11 % 10 == n[9]
    }
    static func luhn(_ d: String) -> Bool { Detect.luhn(d) }

    // MARK: - phone, link, path, colour

    static func phoneForms(_ e164: String) -> [FormatVariant] {
        var v = [FormatVariant(id: "e164", name: "International", text: e164)]
        let d = e164.filter(\.isNumber)
        if e164.hasPrefix("+380"), d.count == 12 {
            let n = Array(d.dropFirst(2))   // 0XXXXXXXXX
            let s = { (a: Int, b: Int) in String(n[a..<b]) }
            v.append(FormatVariant(id: "national", name: "National", text: "\(s(0, 3)) \(s(3, 6)) \(s(6, 8)) \(s(8, 10))"))
            v.append(FormatVariant(id: "spaced", name: "International, spaced", text: "+380 \(s(1, 3)) \(s(3, 6)) \(s(6, 8)) \(s(8, 10))"))
        }
        v.append(FormatVariant(id: "tel", name: "Phone link", text: "tel:" + e164))
        return v
    }
    static func linkForms(_ url: String, title: String) -> [FormatVariant] {
        let clean = ClipRules.untracked(url)
        var v: [FormatVariant] = []
        if clean != url { v.append(FormatVariant(id: "clean", name: "Without tracking", text: clean)) }
        v.append(FormatVariant(id: "markdown", name: "Markdown link", text: ClipRules.markdown(clean, title: title)))
        let host = ClipRules.parts(clean).host
        if !host.isEmpty, host != url { v.append(FormatVariant(id: "host", name: "Host only", text: host)) }
        return v
    }
    static func pathForms(_ abs: String, home: String) -> [FormatVariant] {
        let tilde = Detect.tildePath(abs, home)
        var v = [FormatVariant(id: "posix", name: "Full path", text: abs)]
        if tilde != abs { v.append(FormatVariant(id: "tilde", name: "With ~", text: tilde)) }
        v.append(FormatVariant(id: "url", name: "File URL", text: URL(fileURLWithPath: abs).absoluteString))
        v.append(FormatVariant(id: "quoted", name: "Quoted for a shell", text: "'" + abs.replacingOccurrences(of: "'", with: "'\\''") + "'"))
        return v
    }
    /// CSS names, only when the colour is exactly that one.
    static let colorNames: [String: String] = ["#000000": "black", "#ffffff": "white", "#ff0000": "red", "#00ff00": "lime",
        "#0000ff": "blue", "#ffff00": "yellow", "#00ffff": "cyan", "#ff00ff": "magenta", "#c0c0c0": "silver", "#808080": "gray",
        "#800000": "maroon", "#808000": "olive", "#008000": "green", "#800080": "purple", "#008080": "teal", "#000080": "navy",
        "#ffa500": "orange", "#ffc0cb": "pink", "#a52a2a": "brown", "#4b0082": "indigo", "#ee82ee": "violet", "#ffd700": "gold"]
    static func colorForms(_ value: String) -> [FormatVariant] {
        var rgb: [Int] = []
        if value.hasPrefix("#") {
            var h = String(value.dropFirst())
            if h.count == 3 || h.count == 4 { h = h.map { "\($0)\($0)" }.joined() }
            guard h.count == 6 || h.count == 8 else { return [] }
            rgb = stride(from: 0, to: 6, by: 2).compactMap { i -> Int? in
                let a = h.index(h.startIndex, offsetBy: i); return Int(h[a..<h.index(a, offsetBy: 2)], radix: 16) }
        } else if value.hasPrefix("rgb") {
            rgb = value.split(whereSeparator: { !$0.isNumber && $0 != "." }).compactMap { Double($0) }.prefix(3).map { Int($0.rounded()) }
            guard !value.contains("%") else { return [] }
        } else { return [] }
        guard rgb.count == 3, rgb.allSatisfy({ (0...255).contains($0) }) else { return [] }
        let hex = String(format: "#%02x%02x%02x", rgb[0], rgb[1], rgb[2])
        var v = [FormatVariant(id: "hex", name: "Hex", text: hex), FormatVariant(id: "rgb", name: "RGB", text: "rgb(\(rgb[0]), \(rgb[1]), \(rgb[2]))")]
        if let n = colorNames[hex] { v.append(FormatVariant(id: "name", name: "Name", text: n)) }
        return v
    }

    // MARK: - plain-text clean-ups

    static let invisible: Set<Character> = ["\u{200B}", "\u{200C}", "\u{200D}", "\u{2060}", "\u{FEFF}", "\u{00AD}"]

    /// Clean-ups that would change the text, in a fixed order: joined lines, single spaces, no invisible characters,
    /// plain dashes, straight quotes, Ukrainian quotes.
    static func cleanups(_ text: String) -> [FormatVariant] {
        var out: [FormatVariant] = []
        func add(_ id: String, _ name: String, _ t: String) { if t != text && !t.isEmpty { out.append(FormatVariant(id: id, name: name, text: t)) } }
        add("joined", "Joined lines", joinLines(text))
        add("spaces", "Single spaces", singleSpaces(text))
        add("visible", "No invisible characters", noInvisible(text))
        add("dashes", "Plain dashes", text.replacingOccurrences(of: "—", with: "-").replacingOccurrences(of: "–", with: "-"))
        add("straight", "Straight quotes", straightQuotes(text))
        add("ukQuotes", "Ukrainian quotes", ukQuotes(text))
        return out
    }
    /// Lines broken by a PDF or a mail reader joined back: paragraphs (a blank line) and list lines stay; a word split
    /// by a hyphen at a line end is rejoined. Only for a paragraph that looks wrapped: every line but the last 40+
/// characters, at most half of them ending a sentence, no code-like or indented lines.
    static func joinLines(_ text: String) -> String {
        let paras = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n\n")
        var any = false
        let joined = paras.map { p -> String in
            let lines = p.components(separatedBy: "\n")
            // wrapped: every line but the last is long (40+), at most half end a sentence, nothing looks like code or a list
            let body = lines.dropLast()
            guard lines.count > 1, body.allSatisfy({ $0.count >= 40 }),
                  body.filter({ ".!?:;".contains($0.trimmingCharacters(in: .whitespaces).last ?? " ") }).count * 2 <= body.count,
                  !lines.contains(where: { $0.contains("{") || $0.contains("}") || $0.hasPrefix("    ") || $0.hasPrefix("\t") }) else { return p }
            var out = lines[0]
            for l in lines.dropFirst() {
                let t = l.trimmingCharacters(in: .whitespaces)
                if t.isEmpty || t.range(of: #"^([-•*–]|\d+[.)])\s"#, options: .regularExpression) != nil || out.count < 40 && !out.hasSuffix("-") {
                    out += "\n" + l; continue
                }
                any = true
                if out.hasSuffix("-"), let f = t.first, f.isLetter, f.isLowercase, let prev = out.dropLast().last, prev.isLetter {
                    out = String(out.dropLast()) + t
                } else { out = out.trimmingCharacters(in: .whitespaces) + " " + t }
            }
            return out
        }.joined(separator: "\n\n")
        return any ? joined : text
    }
    static func singleSpaces(_ text: String) -> String {
        text.components(separatedBy: "\n").map { l in
            l.replacingOccurrences(of: #"[ \t]{2,}"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
        }.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
    static func noInvisible(_ text: String) -> String {
        String(text.filter { !invisible.contains($0) }.map { "\u{00A0}\u{202F}\u{2007}".contains($0) ? " " : $0 })
    }
    static func straightQuotes(_ text: String) -> String {
        String(text.map { ch -> Character in
            switch ch { case "“", "”", "„", "«", "»": return "\""; case "‘", "’", "ʼ": return "'"; default: return ch }
        })
    }
    /// "…" and “…” to «…» (pairs only; an odd quote leaves the text as it is).
    static func ukQuotes(_ text: String) -> String {
        let qs = text.filter { $0 == "\"" || $0 == "“" || $0 == "”" || $0 == "„" }
        guard !qs.isEmpty, qs.count % 2 == 0 else { return text }
        var open = true
        return String(text.map { ch -> Character in
            guard ch == "\"" || ch == "“" || ch == "”" || ch == "„" else { return ch }
            defer { open.toggle() }
            return open ? "«" : "»"
        })
    }
}

// MARK: - the rule store and its learner

struct FormatRule: Codable, Equatable { var kind: String; var dest: String?; var form: String }

/// data/format-rules.json: the rules he confirmed, the pick counts, the questions already asked.
struct FormatMemory: Codable, Equatable {
    var rules: [FormatRule] = []
    var picks: [String: Int] = [:]
    var asked: [String] = []
}

enum FormatLearn {
    static let askAfter = 3
    static func key(_ kind: String, _ dest: FormatDest?, _ form: String) -> String { [kind, dest?.rawValue ?? "*", form].joined(separator: "|") }

    /// The stored form for a kind: the one for this destination, else the one for any destination.
    static func rule(_ kind: String, dest: FormatDest?, in m: FormatMemory) -> FormatRule? {
        if let d = dest, let r = m.rules.first(where: { $0.kind == kind && $0.dest == d.rawValue }) { return r }
        return m.rules.first { $0.kind == kind && $0.dest == nil }
    }
    /// He picked `form` for `kind`: count it. True once, when it is the third same pick, no rule covers it and the
    /// question was never asked: the app may ask "Always?". Nothing is stored here but the count.
    static func picked(_ kind: String, dest: FormatDest?, form: String, in m: inout FormatMemory) -> Bool {
        let k = key(kind, dest, form)
        m.picks[k, default: 0] += 1
        if m.picks.count > 500 { m.picks = m.picks.filter { $0.value >= 2 } }
        guard m.picks[k]! >= askAfter, !m.asked.contains(k), rule(kind, dest: dest, in: m)?.form != form else { return false }
        return true
    }
    /// He answered the question: asked once either way; on yes the rule is stored (replacing one for the same kind and
    /// destination). Returns the rule it replaced, for Undo.
    @discardableResult
    static func answer(_ kind: String, dest: FormatDest?, form: String, yes: Bool, in m: inout FormatMemory) -> FormatRule?? {
        let k = key(kind, dest, form)
        if !m.asked.contains(k) { m.asked.append(k) }
        guard yes else { return nil }
        let old = m.rules.first { $0.kind == kind && $0.dest == dest?.rawValue }
        m.rules.removeAll { $0.kind == kind && $0.dest == dest?.rawValue }
        m.rules.append(FormatRule(kind: kind, dest: dest?.rawValue, form: form))
        return .some(old)
    }
    /// Undo a stored rule: back to what was there before (or none).
    static func undo(_ kind: String, dest: FormatDest?, previous: FormatRule?, in m: inout FormatMemory) {
        m.rules.removeAll { $0.kind == kind && $0.dest == dest?.rawValue }
        if let p = previous { m.rules.append(p) }
    }

    static func load(_ url: URL) -> FormatMemory {
        guard let d = try? Data(contentsOf: url), let m = try? JSONDecoder().decode(FormatMemory.self, from: d) else { return FormatMemory() }
        return m
    }
    static func save(_ m: FormatMemory, to url: URL) {
        let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let d = try? e.encode(m) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? d.write(to: url, options: .atomic)
    }
}

// MARK: - what the copy chip does (app/Clip.swift runs it)

enum CopyPlan: Equatable {
    case nothing
    case note(String)                              // a quiet line: "IBAN: check digit does not match"
    case apply(kind: String, FormatVariant)        // a rule he confirmed: applied at once, with Undo
    case offer(kind: String, [FormatVariant])      // at most 3 forms; the first is Tab, the second 2, the third 3
}

enum CopyChip {
    static let names: [String: String] = ["date": "date", "number": "number", "money": "amount", "iban": "IBAN", "phone": "phone",
                                          "edrpou": "ЄДРПОУ", "rntrc": "РНОКПП", "link": "link", "path": "path", "color": "colour"]
    /// When the copied text IS one thing: its top forms (only those that change the text); a stored rule applies at
    /// once. A link is offered only when it carries tracking parts (otherwise every copied link would get a chip).
    /// Nothing for sensitive things, nothing for a text that only contains things.
    static func plan(_ text: String, memory: FormatMemory, written: Date = Date(), hints: DetectHints = DetectHints()) -> CopyPlan {
        guard let one = Format.whole(text, written: written, hints: hints), !one.sensitive else { return .nothing }
        if let n = one.note { return .note("\(names[one.kind] ?? one.kind): \(n.prefix(1).lowercased() + n.dropFirst())") }
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var v = one.variants.filter { $0.text != t }
        if one.kind == "link" { guard v.contains(where: { $0.id == "clean" }) else { return .nothing }; v = v.filter { $0.id != "host" } }
        guard !v.isEmpty else { return .nothing }
        if let r = FormatLearn.rule(one.kind, dest: nil, in: memory), let f = v.first(where: { $0.id == r.form }) { return .apply(kind: one.kind, f) }
        return .offer(kind: one.kind, Array(v.prefix(3)))
    }
    /// ⇧Tab on the copy chip (keys round three, 17 November 2026; the digits 2 and 3 went back to the apps): the form
    /// after `i`, round to the first after the last.
    static func step(_ i: Int, forms: Int) -> Int { forms > 0 ? (i + 1) % forms : 0 }
    /// The chip's preview of a form: one line, at most 40 characters.
    static func preview(_ s: String) -> String {
        let one = s.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\u{00A0}", with: " ")
        return one.count <= 40 ? one : String(one.prefix(39)) + "…"
    }
}

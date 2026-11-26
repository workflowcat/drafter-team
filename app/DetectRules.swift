// What is in a text (detect round, 15 November 2026; the user: "we should actually parse the text for links and dates
// and such too"). Links, e-mail addresses, phone numbers, dates and ranges, addresses, money, paths, shell commands and
// code, IBANs, tracking codes, issue references, colours, IP addresses, versions, and one-time codes (sensitive: never
// indexed, never a chip, never logged). Apple's NSDataDetector first (links, dates, phones, addresses), then small
// rules for what it misses. On this Mac only: no model, no network. Foundation only, no AppKit, no files.
// A date written relative to "now" is resolved against the time the ITEM was written (see `reanchor`), and the original
// words are kept beside the resolved date. Overlaps resolve by a fixed order (`priority`). Long texts: the first
// `Detect.cap` characters, or the part on screen through `window`.
// Actions on what is found: app/DetectActions.swift. Tests: tests/detect_rules.swift. Notes: docs/rounds/2026-11-15-detect.md.
import Foundation

enum DetectKind: String, CaseIterable, Codable {
    case link, email, phone, date, dateRange, address, money, path, command, code, iban, tracking, issue, color, ip, version
    case oneTimeCode, card      // sensitive: never indexed, never a chip, never logged
}

/// One thing found in a text. `range` is in UTF-16 units of the whole item text (NSString / NSTextView ranges).
struct Found: Hashable, CustomStringConvertible {
    var range: NSRange
    var kind: DetectKind
    var value: String            // normalised: an absolute URL, +380..., ISO date, "1200.50 UAH", an absolute path...
    var display: String          // short text for a chip or a menu
    var words: String            // the words as written
    var sensitive = false        // a one-time code: never indexed, never a chip, never logged
    var date: Date? = nil        // date, dateRange: the start, resolved against the time the item was written
    var end: Date? = nil         // dateRange: the end
    var allDay = false           // no time of day was written
    var amount: Decimal? = nil   // money
    var currency: String? = nil  // money: ISO code
    var bare = false             // a link written without a scheme; a path that is only a file name
    var system = false           // Apple's detector found it (else a rule here)
    /// Logs and debug prints never carry a sensitive value.
    var description: String {
        sensitive ? "\(kind.rawValue)[hidden]" : "\(kind.rawValue)(\(value)) @\(range.location)+\(range.length)"
    }
}

struct DetectHints {
    var timeZone: TimeZone = .current
    var home: String = NSHomeDirectory()
    /// The item's own link (a clip copied from a page): where `owner/repo#12` or `PROJ-12` opens.
    var sourceLink: String? = nil
    init(timeZone: TimeZone = .current, home: String = NSHomeDirectory(), sourceLink: String? = nil) {
        self.timeZone = timeZone; self.home = home; self.sourceLink = sourceLink
    }
}

/// What the search index keeps per item. Sensitive things never reach it.
struct DetectFlags: Equatable {
    var link = false, date = false, money = false, phone = false, code = false, email = false, path = false, iban = false
    /// Days mentioned in the text, "yyyy-MM-dd" in the hints' time zone (ranges: every day, at most 62).
    var days: [String] = []
}

enum Detect {
    /// A text longer than this is scanned only up to here unless a window is given (transcripts).
    static let cap = 20_000

    // MARK: - the adapter

    /// Everything found in `text` (or in `window` of it, widened to line ends), overlaps resolved, in text order.
    static func scan(_ text: String, written: Date, hints: DetectHints = DetectHints(), window: NSRange? = nil) -> [Found] {
        let ns = text as NSString
        guard ns.length > 0 else { return [] }
        let r = span(ns, window)
        guard r.length > 0 else { return [] }
        let sub = (r.location == 0 && r.length == ns.length) ? ns : ns.substring(with: r) as NSString
        var cands: [Cand] = []
        var cal = Calendar(identifier: .gregorian); cal.timeZone = hints.timeZone; cal.firstWeekday = 2
        let ctx = Ctx(s: sub, str: sub as String, written: written, cal: cal, hints: hints)
        systemPass(ctx, &cands)
        datePass(ctx, &cands)
        moneyPass(ctx, &cands)
        codePass(ctx, &cands)
        pathPass(ctx, &cands)
        idPass(ctx, &cands)
        otpPass(ctx, &cands)
        var out = resolve(cands)
        out = mergeDayAndTime(out, ctx)
        if r.location > 0 { for i in out.indices { out[i].range.location += r.location } }
        return out
    }

    /// At most 3 things worth a chip on a card: a date in the future first, then links, then money, then the rest.
    /// Never a sensitive thing, a version or a bare file name; one chip per value.
    static func summary(_ found: [Found], now: Date = Date()) -> [Found] {
        func rank(_ f: Found) -> Int? {
            if f.sensitive || f.kind == .version || f.kind == .oneTimeCode || f.kind == .card || (f.kind == .path && f.bare) { return nil }
            switch f.kind {
            case .date, .dateRange: return ((f.end ?? f.date) ?? .distantPast) >= now ? 0 : 20
            case .link: return 1
            case .money: return 2
            case .email: return 3
            case .phone: return 4
            case .address: return 5
            case .issue: return 6
            case .tracking: return 7
            case .iban: return 8
            case .path: return 9
            case .command: return 10
            case .code: return 11
            case .ip: return 12
            case .color: return 13
            default: return nil
            }
        }
        var seen = Set<String>(); var out: [(Int, Int, Found)] = []
        for (i, f) in found.enumerated() {
            guard let k = rank(f), seen.insert(f.kind.rawValue + "\u{1}" + f.value).inserted else { continue }
            out.append((k, i, f))
        }
        return out.sorted { ($0.0, $0.1) < ($1.0, $1.1) }.prefix(3).map(\.2)
    }

    /// A card's chips straight from the text: scans the first `cap` characters.
    static func summary(_ text: String, written: Date, hints: DetectHints = DetectHints(), now: Date = Date()) -> [Found] {
        summary(scan(text, written: written, hints: hints), now: now)
    }

    /// The search index's flags and day keys. Sensitive things are skipped.
    static func flags(_ found: [Found], timeZone: TimeZone = .current) -> DetectFlags {
        var f = DetectFlags()
        var cal = Calendar(identifier: .gregorian); cal.timeZone = timeZone
        var days = Set<String>()
        for x in found where !x.sensitive {
            switch x.kind {
            case .link: f.link = true
            case .email: f.email = true
            case .phone: f.phone = true
            case .money: f.money = true
            case .code, .command: f.code = true
            case .path: f.path = true
            case .iban: f.iban = true
            case .date, .dateRange:
                f.date = true
                guard let a = x.date else { break }
                var d = cal.startOfDay(for: a); let last = cal.startOfDay(for: x.end ?? a)
                var n = 0
                while d <= last && n < 62 { days.insert(dayKey(d, cal)); d = cal.date(byAdding: .day, value: 1, to: d)!; n += 1 }
            default: break
            }
        }
        f.days = days.sorted()
        return f
    }
    static func flags(_ text: String, written: Date, hints: DetectHints = DetectHints()) -> DetectFlags {
        flags(scan(text, written: written, hints: hints), timeZone: hints.timeZone)
    }

    static func dayKey(_ d: Date, _ cal: Calendar) -> String {
        let c = cal.dateComponents([.year, .month, .day], from: d)
        return String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
    }

    // MARK: - scan window

    /// The part to scan: the window widened to whole lines (at most 400 characters each way), else the first `cap`
    /// characters cut at a space.
    static func span(_ ns: NSString, _ window: NSRange?) -> NSRange {
        let n = ns.length
        if var w = window {
            w.location = max(0, min(w.location, n)); w.length = max(0, min(w.length, n - w.location))
            var a = w.location, b = w.location + w.length
            var k = 0
            while a > 0 && k < 400 && ns.character(at: a - 1) != 10 { a -= 1; k += 1 }
            if a > 0 && ns.character(at: a - 1) != 10 { while a < w.location && !isSpace(ns.character(at: a)) { a += 1 } }
            k = 0
            while b < n && k < 400 && ns.character(at: b) != 10 { b += 1; k += 1 }
            if b < n && ns.character(at: b) != 10 { while b > w.location + w.length && !isSpace(ns.character(at: b - 1)) { b -= 1 } }
            return NSRange(location: a, length: b - a)
        }
        if n <= cap { return NSRange(location: 0, length: n) }
        var b = cap
        while b > cap - 400 && !isSpace(ns.character(at: b - 1)) { b -= 1 }
        if b == cap - 400 { b = cap }
        if b > 0, UTF16.isLeadSurrogate(ns.character(at: b - 1)) { b -= 1 }
        return NSRange(location: 0, length: b)
    }
    static func isSpace(_ c: unichar) -> Bool { c == 32 || c == 10 || c == 9 || c == 13 || c == 0xA0 }

    // MARK: - candidates and the fixed order

    struct Cand { var f: Found; var prio: Int; var timeOnly = false }

    /// Lower wins an overlap: a one-time code hides whatever else it looks like; a fenced block and a command line
    /// keep their whole span; a link wins over a domain-looking word or a file name inside it; a date range over its
    /// two dates.
    static func priority(_ k: DetectKind, fenced: Bool = false) -> Int {
        switch k {
        case .oneTimeCode, .card: return 0
        case .code: return fenced ? 1 : 5
        case .command: return 2
        case .email: return 3
        case .link: return 4
        case .iban: return 6
        case .dateRange: return 7
        case .date: return 8
        case .phone: return 9
        case .money: return 10
        case .tracking: return 11
        case .issue: return 12
        case .ip: return 13
        case .path: return 14
        case .color: return 15
        case .version: return 16
        case .address: return 17
        }
    }

    static func resolve(_ cands: [Cand]) -> [Found] {
        let order = cands.indices.sorted {
            let a = cands[$0], b = cands[$1]
            if a.prio != b.prio { return a.prio < b.prio }
            if a.f.range.length != b.f.range.length { return a.f.range.length > b.f.range.length }
            return a.f.range.location < b.f.range.location
        }
        var taken: [NSRange] = []   // kept sorted by location
        var out: [Found] = []
        for i in order {
            let r = cands[i].f.range
            guard r.length > 0 else { continue }
            var lo = 0, hi = taken.count
            while lo < hi { let m = (lo + hi) / 2; if taken[m].location < r.location { lo = m + 1 } else { hi = m } }
            if lo > 0, NSMaxRange(taken[lo - 1]) > r.location { continue }
            if lo < taken.count, taken[lo].location < NSMaxRange(r) { continue }
            taken.insert(r, at: lo)
            out.append(cands[i].f)
        }
        return out.sorted { $0.range.location < $1.range.location }
    }

    struct Ctx {
        let s: NSString
        let str: String
        let written: Date
        let cal: Calendar
        let hints: DetectHints
        var all: NSRange { NSRange(location: 0, length: s.length) }
        func sub(_ r: NSRange) -> String { s.substring(with: r) }
        /// Up to `n` characters before `loc`, lowercased.
        func before(_ loc: Int, _ n: Int) -> String {
            let a = max(0, loc - n); return s.substring(with: NSRange(location: a, length: loc - a)).lowercased()
        }
        func after(_ end: Int, _ n: Int) -> String {
            let b = min(s.length, end + n); return s.substring(with: NSRange(location: end, length: b - end)).lowercased()
        }
    }

    static func rx(_ p: String, _ o: NSRegularExpression.Options = []) -> NSRegularExpression {
        try! NSRegularExpression(pattern: p, options: o)
    }
    static func test(_ re: NSRegularExpression, _ s: String) -> Bool {
        re.firstMatch(in: s, range: NSRange(location: 0, length: (s as NSString).length)) != nil
    }

    // MARK: - Apple's detector

    static let detector: NSDataDetector = try! NSDataDetector(types: NSTextCheckingResult.CheckingType([.link, .date, .phoneNumber, .address]).rawValue)

    static let fileExt: Set<String> = ["md", "txt", "pdf", "png", "jpg", "jpeg", "gif", "heic", "webp", "svg", "swift", "py",
        "js", "ts", "tsx", "jsx", "json", "jsonl", "yaml", "yml", "toml", "sh", "zsh", "rb", "go", "rs", "c", "h", "cpp", "m",
        "mm", "html", "htm", "css", "csv", "xlsx", "xls", "docx", "doc", "pptx", "key", "pages", "numbers", "zip", "tar",
        "gz", "dmg", "pkg", "app", "wav", "mp3", "m4a", "mp4", "mov", "sqlite", "db", "log", "plist", "ics", "vcf", "pl",
        "so", "cs", "java", "kt", "lock", "env", "ini", "cfg", "conf", "bak", "tmp", "dart", "lua", "php", "sql", "xml"]
    static let deepSchemes: Set<String> = ["facetime", "facetime-audio", "sms", "maps", "imessage"]

    static func systemPass(_ c: Ctx, _ out: inout [Cand]) {
        let now = Date()
        var sys = Calendar(identifier: .gregorian); sys.timeZone = .current
        detector.enumerateMatches(in: c.str, options: [], range: c.all) { m, _, _ in
            guard let m = m else { return }
            let words = c.sub(m.range)
            switch m.resultType {
            case .link:
                guard let u = m.url, let f = linkFound(u, words: words, range: m.range, c) else { return }
                out.append(Cand(f: f, prio: priority(f.kind)))
            case .phoneNumber:
                guard let f = phoneFound(words, range: m.range, c) else { return }
                out.append(Cand(f: f, prio: priority(.phone)))
            case .address:
                let v = words.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).joined(separator: " ")
                guard v.count >= 6 else { return }
                var f = Found(range: m.range, kind: .address, value: v, display: short(v, 40), words: words)
                f.system = true
                out.append(Cand(f: f, prio: priority(.address)))
            case .date:
                guard let d = m.date else { return }
                if let cand = systemDate(d, duration: m.duration, range: m.range, words: words, c, now: now, sys: sys) { out.append(cand) }
            default: return
            }
        }
    }

    static func linkFound(_ u: URL, words: String, range: NSRange, _ c: Ctx) -> Found? {
        let scheme = (u.scheme ?? "").lowercased()
        var f = Found(range: range, kind: .link, value: u.absoluteString, display: "", words: words)
        f.system = true
        switch scheme {
        case "mailto":
            let addr = u.absoluteString.dropFirst(7).split(separator: "?").first.map(String.init)?.removingPercentEncoding ?? ""
            guard addr.contains("@") else { return nil }
            f.kind = .email; f.value = addr.lowercased(); f.display = addr; return f
        case "tel":
            return phoneFound(String(u.absoluteString.dropFirst(4)), range: range, c, words: words)
        case "file":
            f.kind = .path; f.value = u.path; f.display = short(tildePath(u.path, c.hints.home), 48); return f
        case "http", "https":
            guard let host = u.host?.lowercased(), host.contains(where: { $0.isLetter }) else { return nil }
            let written = words.lowercased()
            if !written.contains("://") {
                // a bare word: a site only when it clearly is one (not "file.txt", not "e.g")
                let last = host.split(separator: ".").last.map(String.init) ?? ""
                let hasPath = u.path.count > 1 || u.query != nil
                if fileExt.contains(last) && !hasPath && !host.hasPrefix("www.") { return nil }
                if host.split(separator: ".").count < 2 || last.count < 2 { return nil }
                f.bare = true
                if scheme == "http", var comps = URLComponents(url: u, resolvingAgainstBaseURL: false) {
                    comps.scheme = "https"; f.value = comps.string ?? f.value
                }
            }
            let h = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
            let p = u.path.count > 1 ? u.path : ""
            f.display = short(h + p, 40)
            return f
        default:
            guard scheme.count >= 2, words.contains("://") || deepSchemes.contains(scheme) else { return nil }
            f.display = short(words, 40)
            return f
        }
    }

    static let phoneNoise = rx("(№|#|\\bid\\b|order|замовлення|рахун|рах\\.|invoice|ттн|накладн|\\bкод|\\bcode|iban|єдрпоу|edrpou|інн|ipn)[^\\n]{0,12}$", [.caseInsensitive])

    static func phoneFound(_ words: String, range: NSRange, _ c: Ctx, words orig: String? = nil) -> Found? {
        let digits = words.filter { $0.isASCII && $0.isNumber }
        let plus = words.trimmingCharacters(in: .whitespaces).hasPrefix("+")
        guard (7...15).contains(digits.count) else { return nil }
        let separated = words.contains(where: { " -().\u{00A0}".contains($0) })
        var v: String
        if plus { v = "+" + digits }
        else if digits.count == 10 && digits.hasPrefix("0") { v = "+38" + digits }
        else if digits.count == 12 && digits.hasPrefix("380") { v = "+" + digits }
        else if digits.count == 11 && digits.hasPrefix("80") { v = "+3" + digits }
        else { guard separated else { return nil }; v = digits }
        if !plus && !separated && !(digits.count == 10 && digits.hasPrefix("0")) && !(digits.count == 12 && digits.hasPrefix("380")) { return nil }
        if test(phoneNoise, c.before(range.location, 24)) { return nil }
        var f = Found(range: range, kind: .phone, value: v, display: (orig ?? words).trimmingCharacters(in: .whitespaces), words: orig ?? words)
        f.system = true
        return f
    }

    // MARK: - dates

    static let reYear = rx("(\\b(19|20)\\d{2}\\b|\\d{1,2}[./]\\d{1,2}[./]\\d{2,4}|\\d{4}-\\d{2}-\\d{2}|'\\d{2}\\b)")
    static let monthWords = "(?:jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec)[a-z]*\\.?|(?:січ|лют|берез|квіт|трав|черв|лип|серп|верес|жовт|листопад|груд)\\w*"
    static let reMonth = rx("(\\b(" + monthWords + ")|\\b\\d{1,2}[./]\\d{1,2}\\b)", [.caseInsensitive])
    static let reWeekday = rx("\\b(mon|tue|wed|thu|fri|sat|sun)[a-z]*\\b|(понеділ|вівтор|серед|четвер|п['’ʼ]?ятниц|субот|неділ)\\w*", [.caseInsensitive])
    static let reTimeWords = rx("(\\d{1,2}:\\d{2}|\\b(о|об|at)\\s+\\d{1,2}\\.\\d{2}|\\d\\s?(am|pm|a\\.m|p\\.m)\\b|\\b(at|о|об)\\s+\\d|\\d\\s+(ранку|вечора|дня|ночі)|ранку|вранці|ввечері|увечері|вечері|вечора|вдень|опівдні|опівночі|полудн|morning|evening|afternoon|night|noon|midnight|tonight|\\bз\\s+\\d{1,2}\\s+до\\s+\\d|between\\s+\\d)", [.caseInsensitive])
    static let reNextBefore = rx("(наступн\\w*|next)\\s+$", [.caseInsensitive])
    static let reBareHours = rx("^(з|від|between|from)\\s+\\d{1,2}\\s+(до|по|and|to)\\s+\\d{1,2}$", [.caseInsensitive])
    static let hourFollowers: Set<String> = ["години", "год", "годин", "ранку", "вечора", "дня", "ночі", "завтра", "сьогодні", "в", "у",
        "о", "на", "hours", "o'clock", "tomorrow", "today", "on", "at", "in", "and", "і", "та", "й"]
    static func firstWord(_ s: String) -> String? {
        let t = s.drop(while: { $0 == " " || $0 == "\u{00A0}" })
        guard let f = t.first, f.isLetter else { return nil }
        return String(t.prefix(while: { $0.isLetter || $0 == "'" })).lowercased()
    }
    static let reBareSlash = rx("^\\s*(\\d{1,2})/(\\d{1,2})\\s*$")

    /// Apple's detector resolves against the present moment; this re-resolves its date against the time the item
    /// was written. Written year: kept. Day and month without a year: the year nearest the writing. A weekday: the
    /// first such day after the writing day ("next ...": that day of the following week). Anything else (today,
    /// tomorrow, in 3 days, a time alone): the same number of days from the writing day as the detector put from today.
    static func systemDate(_ det: Date, duration: Double, range: NSRange, words: String, _ c: Ctx, now: Date, sys: Calendar) -> Cand? {
        var range = range, words = words
        // "7/10", "24/7": a rating or a phrase, not a date (prefer missing); "14/11" stays
        if let m = reBareSlash.firstMatch(in: words, range: NSRange(location: 0, length: (words as NSString).length)) {
            let a = Int((words as NSString).substring(with: m.range(at: 1))) ?? 0
            if a <= 12 || words.contains("24/7") { return nil }
        }
        let lw = words.lowercased()
        // "з 10 до 12 людей", "between 2 and 4 cars": bare numbers followed by a counted word are not hours
        if test(reBareHours, lw), let w = firstWord(c.after(NSMaxRange(range), 24)), !hourFollowers.contains(w) { return nil }
        var next = lw.contains("next ") || lw.contains("наступн")
        if test(reWeekday, lw), let m = reNextBefore.firstMatch(in: c.before(range.location, 16), range: NSRange(location: 0, length: (c.before(range.location, 16) as NSString).length)) {
            let n = m.range.length
            range = NSRange(location: range.location - n, length: range.length + n)
            words = c.sub(range); next = true
        }
        let timed = test(reTimeWords, lw)
        let t = sys.dateComponents([.year, .month, .day, .hour, .minute, .weekday], from: det)
        let cal = c.cal
        var start: Date
        var timeOnly = false
        if test(reYear, lw) {
            start = cal.date(from: DateComponents(year: t.year, month: t.month, day: t.day, hour: timed ? t.hour : 12, minute: timed ? t.minute : 0))!
        } else if test(reMonth, lw) {
            let y = nearestYear(month: t.month!, day: t.day!, to: c.written, cal: cal)
            start = cal.date(from: DateComponents(year: y, month: t.month, day: t.day, hour: timed ? t.hour : 12, minute: timed ? t.minute : 0))!
        } else if test(reWeekday, lw) {
            let day = weekdayAfter(t.weekday!, from: c.written, next: next, cal: cal)
            start = cal.date(bySettingHour: timed ? t.hour! : 12, minute: timed ? t.minute! : 0, second: 0, of: day)!
        } else {
            let off = sys.dateComponents([.day], from: sys.startOfDay(for: now), to: sys.startOfDay(for: det)).day ?? 0
            let day = cal.date(byAdding: .day, value: off, to: cal.startOfDay(for: c.written))!
            start = cal.date(bySettingHour: timed ? t.hour! : 12, minute: timed ? t.minute! : 0, second: 0, of: day)!
            timeOnly = off == 0 && timed && !lw.contains("сьогодні") && !lw.contains("today") && !lw.contains("tonight")
        }
        var f = dateFound(range: range, words: words, start: start, end: duration > 0 ? start.addingTimeInterval(duration) : nil,
                          allDay: !timed, cal: cal)
        f.system = true
        return Cand(f: f, prio: priority(f.kind), timeOnly: timeOnly)
    }

    /// The year for a day and month written without one, as Apple's text checker picks it (measured on macOS 26 with
    /// reference dates, docs/rounds/2026-11-15-detect.md): the writing year, or the next one when that month is three
    /// or more months before the writing month ("14 травня" written in August is next May).
    static func nearestYear(month: Int, day: Int, to w: Date, cal: Calendar) -> Int {
        let y = cal.component(.year, from: w), m = cal.component(.month, from: w)
        return m - month >= 3 ? y + 1 : y
    }
    /// Calendar weekday (1 = Sunday): the first such day after `w`'s day; `next`: the first one 4 or more days ahead.
    static func weekdayAfter(_ wd: Int, from w: Date, next: Bool, cal: Calendar) -> Date {
        let base = cal.startOfDay(for: w)
        let cur = cal.component(.weekday, from: base)
        var d = (wd - cur + 7) % 7; if d == 0 { d = 7 }
        if next && d < 4 { d += 7 }   // "next Friday": 4 to 10 days ahead, as the system's text checker does
        return cal.date(byAdding: .day, value: d, to: base)!
    }

    static let shortDay: DateFormatter = { let f = DateFormatter(); f.locale = Locale(identifier: "en_GB"); f.dateFormat = "EEE d MMM"; return f }()
    static let shortYear: DateFormatter = { let f = DateFormatter(); f.locale = Locale(identifier: "en_GB"); f.dateFormat = "EEE d MMM yyyy"; return f }()
    static let clock: DateFormatter = { let f = DateFormatter(); f.locale = Locale(identifier: "en_GB"); f.dateFormat = "HH:mm"; return f }()

    static func iso(_ d: Date, allDay: Bool, cal: Calendar) -> String {
        if allDay { return dayKey(d, cal) }
        let f = ISO8601DateFormatter(); f.timeZone = cal.timeZone; f.formatOptions = [.withInternetDateTime]
        return f.string(from: d)
    }

    static func dateFound(range: NSRange, words: String, start: Date, end: Date?, allDay: Bool, cal: Calendar) -> Found {
        let kind: DetectKind = end != nil ? .dateRange : .date
        var v = iso(start, allDay: allDay, cal: cal)
        if let e = end { v += "/" + iso(e, allDay: allDay, cal: cal) }
        func show(_ d: Date, _ withDay: Bool) -> String {
            let df = cal.component(.year, from: d) == cal.component(.year, from: Date()) ? shortDay : shortYear
            df.timeZone = cal.timeZone; clock.timeZone = cal.timeZone
            return allDay ? df.string(from: d) : (withDay ? df.string(from: d) + ", " + clock.string(from: d) : clock.string(from: d))
        }
        var disp = show(start, true)
        if let e = end { disp += "–" + show(e, !cal.isDate(start, inSameDayAs: e)) }
        var f = Found(range: range, kind: kind, value: v, display: disp, words: words)
        f.date = start; f.end = end; f.allDay = allDay
        return f
    }

    // rules for what Apple's detector misses
    static let reDayMonth = rx("(?<![\\d.,/:$€₴£\\w])(\\d{1,2})\\.(\\d{2})(?![\\d]|[.,]\\d|\\s*(?:%|грн|uah|usd|eur|₴|\\$|€|kg|кг|км|km|г\\b|л\\b|m\\b|м\\b|см|cm|мм|mm|°|x\\b|х\\b))", [.caseInsensitive])
    static let reDateCue = rx("(\\bдо|\\bна|\\bз|\\bіз|\\bпо|\\bвід|until|till|\\bby|\\bon|from|дата|date|станом на|deadline|дедлайн)[\\s:]*$", [.caseInsensitive])
    static let reTimeCue = rx("(\\bо|\\bоб|\\bat|версія|version|\\bver|\\bv)\\s*$", [.caseInsensitive])
    static let numWords: [String: Int] = ["a": 1, "an": 1, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "один": 1, "одну": 1, "один.": 1,
                                          "два": 2, "дві": 2, "три": 3, "чотири": 4, "п'ять": 5, "пʼять": 5, "п’ять": 5]
    static let reIn = rx("\\b(через|in)\\s+(?:(\\d{1,3}|a|an|one|two|three|four|five|один|одну|два|дві|три|чотири|п['’ʼ]ять)\\s+)?(день|дні|днів|тиждень|тижні|тижнів|місяць|місяці|місяців|рік|роки|років|weeks?|months?|years?)\\b", [.caseInsensitive])
    static let reWeek = rx("(наступного тижня|на наступному тижні|наступний тиждень|next week|наступних вихідних|next weekend|на вихідних|цих вихідних|на цих вихідних|this weekend|on the weekend|at the weekend)(?!\\w)", [.caseInsensitive])
    static let reDayRange = rx("(?<![\\d\\w])(?:з\\s+)?(\\d{1,2})\\s*(?:[-–—]|\\s(?:по|до)\\s)\\s*(\\d{1,2})\\s+(" + monthWords + ")(?!\\w)", [.caseInsensitive])
    static let reHourRange = rx("\\bfrom\\s+(\\d{1,2})(?::(\\d{2}))?\\s*(am|pm)?\\s+(?:to|till|until)\\s+(\\d{1,2})(?::(\\d{2}))?\\s*(am|pm)?(?!\\w)", [.caseInsensitive])

    static func monthNumber(_ w: String) -> Int? {
        let s = w.lowercased()
        let en = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"]
        for (i, p) in en.enumerated() where s.hasPrefix(p) { return i + 1 }
        let uk = ["січ", "лют", "берез", "квіт", "трав", "черв", "лип", "серп", "верес", "жовт", "листопад", "груд"]
        for (i, p) in uk.enumerated() where s.hasPrefix(p) { return i + 1 }
        return nil
    }

    static func datePass(_ c: Ctx, _ out: inout [Cand]) {
        let cal = c.cal
        func noon(_ d: Date) -> Date { cal.date(bySettingHour: 12, minute: 0, second: 0, of: d)! }
        // 14.11 (no year): two-digit day, or a cue word before; never after "о", "at", "version"
        reDayMonth.enumerateMatches(in: c.str, range: c.all) { m, _, _ in
            guard let m = m else { return }
            let ds = c.sub(m.range(at: 1)), d = Int(ds) ?? 0, mo = Int(c.sub(m.range(at: 2))) ?? 0
            guard (1...12).contains(mo), (1...31).contains(d) else { return }
            let pre = c.before(m.range.location, 16)
            if test(reTimeCue, pre) { return }
            guard ds.count == 2 || test(reDateCue, pre) else { return }
            let y = nearestYear(month: mo, day: d, to: c.written, cal: cal)
            guard let s = cal.date(from: DateComponents(year: y, month: mo, day: d, hour: 12)), cal.component(.day, from: s) == d else { return }
            out.append(Cand(f: dateFound(range: m.range, words: c.sub(m.range), start: s, end: nil, allDay: true, cal: cal), prio: priority(.date)))
        }
        // через 2 дні, in 2 weeks
        reIn.enumerateMatches(in: c.str, range: c.all) { m, _, _ in
            guard let m = m else { return }
            let nRaw = m.range(at: 2).location == NSNotFound ? "1" : c.sub(m.range(at: 2)).lowercased()
            guard let n = Int(nRaw) ?? numWords[nRaw.replacingOccurrences(of: "’", with: "'")] ?? (nRaw.hasSuffix("ять") ? 5 : nil), n > 0, n < 400 else { return }
            let unit = c.sub(m.range(at: 3)).lowercased()
            let comp: Calendar.Component = unit.hasPrefix("д") ? .day : (unit.hasPrefix("тиж") || unit.hasPrefix("week")) ? .weekOfYear
                : (unit.hasPrefix("міс") || unit.hasPrefix("month")) ? .month : .year
            if comp == .day && c.sub(m.range(at: 1)).lowercased() == "in" { return }   // Apple's detector has "in 3 days"
            let s = noon(cal.date(byAdding: comp, value: n, to: c.written)!)
            out.append(Cand(f: dateFound(range: m.range, words: c.sub(m.range), start: s, end: nil, allDay: true, cal: cal), prio: priority(.date)))
        }
        // next week, на вихідних
        reWeek.enumerateMatches(in: c.str, range: c.all) { m, _, _ in
            guard let m = m else { return }
            let w = c.sub(m.range).lowercased()
            let base = cal.startOfDay(for: c.written)
            let cur = cal.component(.weekday, from: base)   // 1 Sunday ... 7 Saturday
            let toMonday = { () -> Int in let d = (2 - cur + 7) % 7; return d == 0 ? 7 : d }()
            var s: Date, e: Date
            if w.contains("вихідн") || w.contains("weekend") {
                let nextWeekend = w.contains("наступн") || w.contains("next")
                if nextWeekend { s = cal.date(byAdding: .day, value: toMonday + 5, to: base)! }
                else if cur == 7 || cur == 1 { s = cur == 7 ? base : cal.date(byAdding: .day, value: -1, to: base)! }
                else { s = cal.date(byAdding: .day, value: 7 - cur, to: base)! }
                e = cal.date(byAdding: .day, value: 1, to: s)!
                if cur == 1 && !nextWeekend { s = base }
            } else {
                s = cal.date(byAdding: .day, value: toMonday, to: base)!
                e = cal.date(byAdding: .day, value: 6, to: s)!
            }
            out.append(Cand(f: dateFound(range: m.range, words: c.sub(m.range), start: noon(s), end: noon(e), allDay: true, cal: cal), prio: priority(.dateRange)))
        }
        // 14-16 листопада, з 14 по 16 листопада
        reDayRange.enumerateMatches(in: c.str, range: c.all) { m, _, _ in
            guard let m = m, let mo = monthNumber(c.sub(m.range(at: 3))) else { return }
            let a = Int(c.sub(m.range(at: 1))) ?? 0, b = Int(c.sub(m.range(at: 2))) ?? 0
            guard a >= 1, b <= 31, a < b else { return }
            let y = nearestYear(month: mo, day: a, to: c.written, cal: cal)
            guard let s = cal.date(from: DateComponents(year: y, month: mo, day: a, hour: 12)),
                  let e = cal.date(from: DateComponents(year: y, month: mo, day: b, hour: 12)), cal.component(.month, from: e) == mo else { return }
            out.append(Cand(f: dateFound(range: m.range, words: c.sub(m.range), start: s, end: e, allDay: true, cal: cal), prio: priority(.dateRange)))
        }
        // from 10:00 to 12:00, from 2 to 4pm (needs minutes or am/pm: "from 10 to 12 people" stays a number)
        reHourRange.enumerateMatches(in: c.str, range: c.all) { m, _, _ in
            guard let m = m else { return }
            func g(_ i: Int) -> String? { m.range(at: i).location == NSNotFound ? nil : c.sub(m.range(at: i)).lowercased() }
            guard g(2) != nil || g(3) != nil || g(5) != nil || g(6) != nil else { return }
            var h1 = Int(g(1)!) ?? 0, h2 = Int(g(4)!) ?? 0
            let ap2 = g(6), ap1 = g(3) ?? ap2
            if ap1 == "pm" && h1 < 12 { h1 += 12 }; if ap2 == "pm" && h2 < 12 { h2 += 12 }
            if ap1 == "am" && h1 == 12 { h1 = 0 }; if ap2 == "am" && h2 == 12 { h2 = 0 }
            guard h1 < 24, h2 < 24, h1 < h2 || (h1 == h2 && (Int(g(2) ?? "0") ?? 0) < (Int(g(5) ?? "0") ?? 0)) else { return }
            let day = cal.startOfDay(for: c.written)
            let s = cal.date(bySettingHour: h1, minute: Int(g(2) ?? "0") ?? 0, second: 0, of: day)!
            let e = cal.date(bySettingHour: h2, minute: Int(g(5) ?? "0") ?? 0, second: 0, of: day)!
            out.append(Cand(f: dateFound(range: m.range, words: c.sub(m.range), start: s, end: e, allDay: false, cal: cal), prio: priority(.dateRange)))
        }
    }

    static let reGlue = rx("^[\\s,]*(о|об|at|в|у|on)?[\\s,]*$", [.caseInsensitive])
    /// "14.11 о 15:00": a day without a time and a time alone right after it become one date.
    static func mergeDayAndTime(_ list: [Found], _ c: Ctx) -> [Found] {
        guard list.count > 1 else { return list }
        var out: [Found] = []
        var i = 0
        while i < list.count {
            let a = list[i]
            if i + 1 < list.count, a.kind == .date, a.allDay, let ad = a.date {
                let b = list[i + 1]
                let gapR = NSRange(location: NSMaxRange(a.range), length: b.range.location - NSMaxRange(a.range))
                if b.kind == .date, !b.allDay, let bd = b.date, gapR.length >= 0, gapR.length <= 6, test(reGlue, c.sub(gapR)),
                   c.cal.isDate(bd, inSameDayAs: c.written) {
                    let hm = c.cal.dateComponents([.hour, .minute], from: bd)
                    let s = c.cal.date(bySettingHour: hm.hour!, minute: hm.minute!, second: 0, of: ad)!
                    let r = NSUnionRange(a.range, b.range)
                    var f = dateFound(range: r, words: c.sub(r), start: s, end: nil, allDay: false, cal: c.cal)
                    f.system = a.system || b.system
                    out.append(f); i += 2; continue
                }
            }
            out.append(a); i += 1
        }
        return out
    }

    // MARK: - money

    static let curWords = "грн\\.?|гривень|гривні|гривня|гривнi|uah|usd|eur|gbp|pln|chf|дол\\.?|доларів|долари|долар|баксів|бакси|бакс|євро|dollars?|euros?|bucks|pounds?|злотих|₴|\\$|€|£"
    static let num = "\\d{1,3}(?:[ \\u00A0\\u202F]\\d{3})+(?:[.,]\\d{1,2})?|\\d+(?:[.,]\\d+)*"
    static let mult = "(?:\\s?(k|к|тис\\.?|тисяч[аі]?|млн\\.?|m|mln|million|thousand))?"
    static let reMoneyAfter = rx("(?<![\\w.,])(" + num + ")" + mult + "\\s?(" + curWords + ")(?![\\w])", [.caseInsensitive])
    static let reMoneyBefore = rx("(?<![\\w])(₴|\\$|€|£|uah|usd|eur|gbp|pln)\\s?(" + num + ")" + mult + "(?![\\w.,]\\d|[\\w])", [.caseInsensitive])

    static func currencyCode(_ s: String) -> String? {
        let w = s.lowercased()
        if w == "₴" || w.hasPrefix("грн") || w.hasPrefix("грив") || w == "uah" { return "UAH" }
        if w == "$" || w == "usd" || w.hasPrefix("дол") || w.hasPrefix("бакс") || w.hasPrefix("dollar") || w == "bucks" { return "USD" }
        if w == "€" || w == "eur" || w == "євро" || w.hasPrefix("euro") { return "EUR" }
        if w == "£" || w == "gbp" || w.hasPrefix("pound") { return "GBP" }
        if w == "pln" || w.hasPrefix("злот") { return "PLN" }
        if w == "chf" { return "CHF" }
        return nil
    }
    /// "1 200,50" → 1200.50; "1,200.50" → 1200.50; "1.200" → 1200; "12,5" → 12.5.
    static func amount(_ raw: String) -> Decimal? {
        var s = raw.filter { !" \u{00A0}\u{202F}".contains($0) }
        let lastDot = s.lastIndex(of: "."), lastComma = s.lastIndex(of: ",")
        if let d = lastDot, let c = lastComma {
            let dec = max(d, c)
            let intPart = s[..<dec].filter(\.isNumber), frac = s[s.index(after: dec)...]
            s = intPart + "." + frac
        } else if let sep = lastDot ?? lastComma {
            let parts = s.split(separator: s[sep])
            if parts.count > 2 || (parts.count == 2 && parts[1].count == 3 && parts[0].first != "0") { s = parts.joined() }   // thousands
            else { s = s.replacingOccurrences(of: ",", with: ".") }
        }
        guard s.filter({ $0 == "." }).count <= 1 else { return nil }
        return Decimal(string: s, locale: Locale(identifier: "en_US_POSIX"))
    }
    static func multiplier(_ m: String?) -> Decimal {
        guard let m = m?.lowercased() else { return 1 }
        if m.hasPrefix("k") || m.hasPrefix("к") || m.hasPrefix("тис") || m.hasPrefix("thousand") { return 1000 }
        if m.hasPrefix("м") || m.hasPrefix("m") { return 1_000_000 }
        return 1
    }
    static func moneyText(_ a: Decimal) -> String {
        NSDecimalNumber(decimal: a).stringValue   // every digit kept, no rounding
    }

    static func moneyPass(_ c: Ctx, _ out: inout [Cand]) {
        func add(_ r: NSRange, _ numR: NSRange, _ multR: NSRange, _ curR: NSRange) {
            guard let code = currencyCode(c.sub(curR)), var a = amount(c.sub(numR)) else { return }
            a *= multiplier(multR.location == NSNotFound ? nil : c.sub(multR))
            let v = moneyText(a) + " " + code
            var f = Found(range: r, kind: .money, value: v, display: c.sub(r), words: c.sub(r))
            f.amount = a; f.currency = code
            out.append(Cand(f: f, prio: priority(.money)))
        }
        reMoneyAfter.enumerateMatches(in: c.str, range: c.all) { m, _, _ in
            guard let m = m else { return }; add(m.range, m.range(at: 1), m.range(at: 2), m.range(at: 3))
        }
        reMoneyBefore.enumerateMatches(in: c.str, range: c.all) { m, _, _ in
            guard let m = m else { return }; add(m.range, m.range(at: 2), m.range(at: 3), m.range(at: 1))
        }
    }

    // MARK: - code and commands

    static let reFence = rx("```[\\w+-]*[^\\S\\n]*\\n([\\s\\S]{0,20000}?)\\n?```")
    static let reTick = rx("(?<!`)`([^`\\n]{1,300})`(?!`)")
    static let tools: Set<String> = ["git", "npm", "npx", "pnpm", "yarn", "brew", "cd", "ls", "curl", "wget", "ssh", "scp", "rsync",
        "docker", "kubectl", "python", "python3", "pip", "pip3", "swift", "swiftc", "make", "cargo", "go", "node", "sudo", "zsh",
        "bash", "cat", "grep", "rg", "find", "mkdir", "rm", "mv", "cp", "chmod", "chown", "launchctl", "defaults", "open",
        "wrangler", "cf", "gh", "op", "xcodebuild", "xcrun", "tail", "head", "sed", "awk", "echo", "export", "source", "uv",
        "deno", "bun", "kill", "pkill", "pgrep", "ps", "lsof", "du", "df", "tar", "unzip", "ffmpeg", "jq", "sqlite3", "psql",
        "cfgit", "cfmirror", "ship", "transcribe", "beeper", "touch", "ln", "which", "man", "code", "claude", "codex", "vim", "nano"]
    static let subs: Set<String> = ["push", "pull", "commit", "status", "checkout", "clone", "log", "diff", "add", "merge", "rebase",
        "fetch", "branch", "switch", "stash", "worktree", "install", "run", "i", "ci", "build", "test", "start", "dev", "ps",
        "up", "down", "exec", "logs", "update", "upgrade", "deploy", "init", "list", "login", "publish", "uninstall", "tag"]
    static let rePrompt = rx("^[ \\t]*(?:\\$|%|❯)[ \\t]+(\\S[^\\n]*)$", [.anchorsMatchLines])
    static let reLine = rx("^[ \\t]*(\\S[^\\n]{0,298})$", [.anchorsMatchLines])
    static let reCyr = rx("[А-Яа-яІіЇїЄєҐґ]")
    static let reCodeSign = rx("(;\\s*$|\\{\\s*$|^\\s*\\}|=>|===?|!==?|&&|\\|\\||\\bfunc\\s|\\bconst\\s|\\blet\\s+\\w+\\s*=|\\bvar\\s+\\w+\\s*=|\\bdef\\s+\\w+\\(|^\\s*import\\s|\\breturn\\s|#include|console\\.log|print\\(|\\w\\(\\)|\\w+\\.\\w+\\()")

    static func isCommand(_ line: String) -> Bool {
        let toks = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard let first = toks.first, tools.contains(first), toks.count >= 2 else { return false }
        if line.hasSuffix(".") || line.hasSuffix("?") || line.hasSuffix("!") { return false }
        let rest = toks.dropFirst()
        if subs.contains(rest.first!) && ["git", "npm", "pnpm", "yarn", "brew", "docker", "pip", "pip3", "cargo", "go", "gh", "uv", "bun", "deno", "swift", "kubectl", "wrangler", "cf", "op", "npx"].contains(first) {
            return rest.count <= 6 || rest.contains(where: { $0.hasPrefix("-") })
        }
        var shell = 0, plain = 0
        for t in rest {
            if t.hasPrefix("-") || t.contains(where: { "/.=~$:|&><*'\"".contains($0) }) { shell += 1 }
            else if t == "&&" || t == "|" || t == ";" { shell += 1 }
            else if tools.contains(t) || subs.contains(t) { continue }
            else if t.allSatisfy({ $0.isLetter }) && t.count > 1 { plain += 1 }
        }
        return shell >= 1 && plain * 2 <= rest.count && !test(reCyr, line.replacingOccurrences(of: "\"[^\"]*\"", with: "", options: .regularExpression))
    }

    static func codePass(_ c: Ctx, _ out: inout [Cand]) {
        reFence.enumerateMatches(in: c.str, range: c.all) { m, _, _ in
            guard let m = m else { return }
            let inner = c.sub(m.range(at: 1))
            guard !inner.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            let f = Found(range: m.range, kind: .code, value: inner, display: short(firstLine(inner), 40), words: c.sub(m.range))
            out.append(Cand(f: f, prio: priority(.code, fenced: true)))
        }
        reTick.enumerateMatches(in: c.str, range: c.all) { m, _, _ in
            guard let m = m else { return }
            let inner = c.sub(m.range(at: 1))
            guard inner.trimmingCharacters(in: .whitespaces).count >= 2 else { return }
            let kind: DetectKind = isCommand(inner.trimmingCharacters(in: .whitespaces)) ? .command : .code
            let f = Found(range: m.range, kind: kind, value: inner, display: short(inner, 40), words: c.sub(m.range))
            out.append(Cand(f: f, prio: priority(kind == .command ? .code : .code)))
        }
        rePrompt.enumerateMatches(in: c.str, range: c.all) { m, _, _ in
            guard let m = m else { return }
            let cmd = c.sub(m.range(at: 1)).trimmingCharacters(in: .whitespaces)
            guard cmd.count >= 2, cmd.first!.isLetter || cmd.first == "." || cmd.first == "/" || cmd.first == "~" else { return }
            let f = Found(range: m.range, kind: .command, value: cmd, display: short(cmd, 40), words: c.sub(m.range))
            out.append(Cand(f: f, prio: priority(.command)))
        }
        reLine.enumerateMatches(in: c.str, range: c.all) { m, _, _ in
            guard let m = m else { return }
            let r = m.range(at: 1)
            let line = c.sub(r).trimmingCharacters(in: .whitespaces)
            let lr = NSRange(location: r.location, length: (line as NSString).length)
            if isCommand(line) {
                out.append(Cand(f: Found(range: lr, kind: .command, value: line, display: short(line, 40), words: line), prio: priority(.command)))
            } else if !test(reCyr, line), line.count >= 6 {
                var n = 0
                reCodeSign.enumerateMatches(in: line, range: NSRange(location: 0, length: (line as NSString).length)) { _, _, stop in n += 1; if n >= 2 { stop.pointee = true } }
                let words = line.split(separator: " ").filter { $0.allSatisfy(\.isLetter) && $0.count > 2 }.count
                if n >= 2 && words * 3 <= line.split(separator: " ").count * 2 + 1 {
                    out.append(Cand(f: Found(range: lr, kind: .code, value: line, display: short(line, 40), words: line), prio: priority(.code)))
                }
            }
        }
    }

    // MARK: - paths

    static let reQuotedPath = rx("[\"'“«]((?:~|\\.{1,2})?/[^\"'”»\\n]{1,300})[\"'”»]")
    static let rePath = rx("(?<![\\w/~.:@\\]\\)])((?:~|\\.{1,2})?/[\\w.@+%=,\\-/А-Яа-яІіЇїЄєҐґ]+)")
    static let reFileName = rx("(?<![\\w/@.\\-])([\\w\\-]+(?:\\.[\\w\\-]+)*\\.([A-Za-z0-9]{1,8}))(?![\\w/@]|\\.\\w)")
    static let roots: Set<String> = ["Users", "tmp", "Applications", "etc", "var", "opt", "usr", "Library", "System", "Volumes", "private", "dev", "bin", "sbin", "home"]
    static let techNames: Set<String> = ["node", "next", "nuxt", "vue", "react", "three", "chart", "d3", "express", "nest", "ember",
                                         "backbone", "angular", "deno", "bun", "socket", "p5", "moment", "alpine", "solid", "svelte", "asp", "ado"]

    static func pathFound(_ raw: String, range: NSRange, _ c: Ctx) -> Found? {
        var p = raw
        var r = range
        while let last = p.last, ".,;:)!?»\"'".contains(last) { p.removeLast(); r.length -= (String(last) as NSString).length }
        let parts = p.split(separator: "/", omittingEmptySubsequences: true)
        guard !parts.isEmpty else { return nil }
        let home = c.hints.home
        var abs = p
        if p.hasPrefix("~/") { abs = home + p.dropFirst(1) }
        else if p.hasPrefix("/") {
            guard roots.contains(String(parts[0])) ? parts.count >= 2 || p.hasSuffix("/") : parts.count >= 3 else { return nil }
        } else if !(p.hasPrefix("./") || p.hasPrefix("../")) || parts.count < 2 { return nil }
        var f = Found(range: r, kind: .path, value: abs, display: short(p, 48), words: p)
        f.bare = false
        return f
    }

    static func pathPass(_ c: Ctx, _ out: inout [Cand]) {
        reQuotedPath.enumerateMatches(in: c.str, range: c.all) { m, _, _ in
            guard let m = m, let f = pathFound(c.sub(m.range(at: 1)), range: m.range(at: 1), c) else { return }
            out.append(Cand(f: f, prio: priority(.path)))
        }
        rePath.enumerateMatches(in: c.str, range: c.all) { m, _, _ in
            guard let m = m, let f = pathFound(c.sub(m.range(at: 1)), range: m.range(at: 1), c) else { return }
            out.append(Cand(f: f, prio: priority(.path)))
        }
        reFileName.enumerateMatches(in: c.str, range: c.all) { m, _, _ in
            guard let m = m else { return }
            let ext = c.sub(m.range(at: 2)).lowercased()
            guard fileExt.contains(ext), ext != "m" || true else { return }
            let name = c.sub(m.range(at: 1))
            let stem = (name as NSString).deletingPathExtension
            if ext == "js" && techNames.contains(stem.lowercased()) { return }
            if ext == "net" { return }
            guard stem.contains(where: { $0.isLetter || $0.isNumber }), !stem.allSatisfy(\.isNumber) else { return }
            var f = Found(range: m.range(at: 1), kind: .path, value: name, display: short(name, 40), words: name)
            f.bare = true
            out.append(Cand(f: f, prio: priority(.path)))
        }
    }

    // MARK: - identifiers

    static let ibanLen: [String: Int] = {
        var d: [String: Int] = [:]
        for p in "UA29 DE22 GB22 PL28 FR27 ES24 IT27 NL18 LT20 LV21 EE20 CZ24 SK24 AT20 CH21 BE16 IE22 PT25 CY28 GE22 MD24 RO24 BG22 HU28 FI18 SE24 DK18 NO15 LU20 AE23 TR26 IL23 GR27 HR21 SI19".split(separator: " ") {
            d[String(p.prefix(2))] = Int(p.dropFirst(2))
        }
        return d
    }()
    static let reIban = rx("\\b([A-Z]{2})(\\d{2})((?:[ ]?[A-Z0-9]){11,30})")
    static func ibanValid(_ s: String) -> Bool {
        let chars = Array(s.dropFirst(4) + s.prefix(4))
        var rem = 0
        for ch in chars {
            if let d = ch.wholeNumberValue, ch.isASCII { rem = (rem * 10 + d) % 97 }
            else if let a = ch.asciiValue, ch.isUppercase { let v = Int(a) - 55; rem = (rem * 100 + v) % 97 }
            else { return false }
        }
        return rem == 1
    }
    static let reS10 = rx("\\b([A-Z]{2})(\\d{8})(\\d)([A-Z]{2})\\b")
    static let reUPS = rx("\\b1Z[0-9A-Z]{16}\\b")
    static let reNP = rx("(?<![\\d\\w])((?:20|59)\\d{12})(?![\\d\\w])")
    static let reTrackCue = rx("(ттн|накладн|нова пошта|новою поштою|нової пошти|\\bнп\\b|\\bnp\\b|nova poshta|трек|tracking|track|посилк|відправлен|parcel|shipment)", [.caseInsensitive])
    static let reRepoRef = rx("(?<![\\w/.-])([A-Za-z0-9][\\w.-]{0,38})/([A-Za-z0-9][\\w.-]{0,99})#(\\d{1,7})(?!\\w)")
    static let rePRRef = rx("\\b(PR|MR|pull request|issue|issues|пул ?реквест|ПР|тікет|ticket)\\s?#(\\d{1,7})(?!\\w)", [.caseInsensitive])
    static let reJira = rx("(?<![\\w-])([A-Z][A-Z0-9]{1,9})-(\\d{1,6})(?![\\w]|[-.]\\d)")
    static let jiraBlock: Set<String> = ["COVID", "UTF", "ISO", "SHA", "AES", "RFC", "MP", "HTTP", "TLS", "SSL", "IPV", "USB", "MIG",
        "SU", "PS", "GPT", "ES", "CVE", "MD", "RSA", "DDR", "LTE", "WPA", "AK", "AN", "BMP", "SPF", "CO", "PM", "WCAG", "ECMA",
        "EN", "DSTU", "ДСТУ", "GPL", "BSD", "UTC", "GMT", "PDF", "IEC", "IEEE", "AIM", "AGM", "HIMARS", "M", "F", "TU", "T", "BTR",
        "SVG", "H", "X", "IL", "KA", "IP", "TCP", "UDP", "DNS", "API", "ID", "UA", "NATO", "Q", "W", "ABC", "XYZ", "PAGE", "STEP"]
    static let reHex = rx("(?<![\\w&#/])#([0-9A-Fa-f]{8}|[0-9A-Fa-f]{6}|[0-9A-Fa-f]{3,4})(?![\\w-])")
    static let reRGB = rx("\\b(?:rgba?|hsla?)\\(\\s*[\\d.]+%?\\s*,?\\s*[\\d.]+%?\\s*,?\\s*[\\d.]+%?(?:\\s*[,/]\\s*[\\d.]+%?)?\\s*\\)", [.caseInsensitive])
    static let reColorCue = rx("(colou?r|колір|кольор|fill|stroke|background|\\bbg\\b|hex|rgb|css|tint|accent|palette|палітр)", [.caseInsensitive])
    static let reIP = rx("(?<![\\w.])(\\d{1,3})\\.(\\d{1,3})\\.(\\d{1,3})\\.(\\d{1,3})(?::(\\d{1,5}))?(?![\\w]|\\.\\d)")
    static let reLocalhost = rx("\\blocalhost:(\\d{2,5})(/[^\\s)\\]>\"']*)?", [.caseInsensitive])
    static let reVersion = rx("(?<![\\w.])([vV]?\\d+\\.\\d+(?:\\.\\d+){1,2}(?:-[0-9A-Za-z.]+)?|[vV]\\d+(?:\\.\\d+)?(?:-[0-9A-Za-z.]+)?)(?![\\w]|\\.\\d)")
    static let reVersionCue = rx("(version|versions|\\bver\\.?|release|build|версі\\w*|реліз\\w*|оновлен\\w*|update to|macos|ios|ipados|watchos|swift|python|node|xcode|pixelkit|chrome|safari|firefox|ubuntu|debian|android|kernel|java)\\s*$", [.caseInsensitive])
    static let reVersionCuedNum = rx("(?<![\\w.])(\\d+\\.\\d+)(?![\\w]|\\.\\d)")

    static func idPass(_ c: Ctx, _ out: inout [Cand]) {
        // IBAN: the country's length, checked with mod 97
        reIban.enumerateMatches(in: c.str, range: c.all) { m, _, _ in
            guard let m = m else { return }
            let raw = c.sub(m.range)
            let cc = String(raw.prefix(2))
            var compact = ""; var used = 0
            let want = ibanLen[cc]
            for ch in raw {
                if ch == " " { used += 1; continue }
                if let w = want, compact.count == w { break }
                compact.append(ch); used += (String(ch) as NSString).length
            }
            if let w = want, compact.count < w { return }
            guard ibanValid(compact) else { return }
            var len = used; let rs = Array(raw); var k = 0, n = 0
            for ch in rs { if ch != " " { n += 1 }; k += 1; if n == compact.count { break } }
            len = k
            let r = NSRange(location: m.range.location, length: len)
            let grouped = stride(from: 0, to: compact.count, by: 4).map { i -> String in
                let a = compact.index(compact.startIndex, offsetBy: i); let b = compact.index(a, offsetBy: min(4, compact.count - i))
                return String(compact[a..<b]) }.joined(separator: " ")
            out.append(Cand(f: Found(range: r, kind: .iban, value: compact, display: short(grouped, 40), words: c.sub(r)), prio: priority(.iban)))
        }
        // tracking: UPU S10 with its check digit, UPS 1Z, Nova Poshta 14 digits near a cue word
        reS10.enumerateMatches(in: c.str, range: c.all) { m, _, _ in
            guard let m = m else { return }
            let d = c.sub(m.range(at: 2)).compactMap(\.wholeNumberValue), chk = Int(c.sub(m.range(at: 3))) ?? -1
            let w = [8, 6, 4, 2, 3, 5, 9, 7]
            var s = 0; for i in 0..<8 { s += d[i] * w[i] }
            var k = 11 - s % 11; if k == 10 { k = 0 } else if k == 11 { k = 5 }
            guard k == chk else { return }
            let v = c.sub(m.range)
            out.append(Cand(f: Found(range: m.range, kind: .tracking, value: v, display: v, words: v), prio: priority(.tracking)))
        }
        reUPS.enumerateMatches(in: c.str, range: c.all) { m, _, _ in
            guard let m = m else { return }; let v = c.sub(m.range)
            out.append(Cand(f: Found(range: m.range, kind: .tracking, value: v, display: v, words: v), prio: priority(.tracking)))
        }
        reNP.enumerateMatches(in: c.str, range: c.all) { m, _, _ in
            guard let m = m else { return }
            let alone = c.str.trimmingCharacters(in: .whitespacesAndNewlines) == c.sub(m.range)
            guard alone || test(reTrackCue, c.before(m.range.location, 60)) else { return }
            let v = c.sub(m.range)
            out.append(Cand(f: Found(range: m.range, kind: .tracking, value: v, display: v, words: v), prio: priority(.tracking)))
        }
        // issue and pull-request references
        reRepoRef.enumerateMatches(in: c.str, range: c.all) { m, _, _ in
            guard let m = m else { return }; let v = c.sub(m.range)
            out.append(Cand(f: Found(range: m.range, kind: .issue, value: v, display: v, words: v), prio: priority(.issue)))
        }
        rePRRef.enumerateMatches(in: c.str, range: c.all) { m, _, _ in
            guard let m = m else { return }; let v = "#" + c.sub(m.range(at: 2))
            out.append(Cand(f: Found(range: m.range, kind: .issue, value: v, display: c.sub(m.range), words: c.sub(m.range)), prio: priority(.issue)))
        }
        reJira.enumerateMatches(in: c.str, range: c.all) { m, _, _ in
            guard let m = m else { return }
            let key = c.sub(m.range(at: 1))
            guard !jiraBlock.contains(key), key.contains(where: \.isLetter), key.count >= 2 else { return }
            if key.allSatisfy({ $0.isLetter }) == false && key.filter(\.isLetter).count < 2 { return }
            let v = c.sub(m.range)
            out.append(Cand(f: Found(range: m.range, kind: .issue, value: v, display: v, words: v), prio: priority(.issue)))
        }
        // colours
        reHex.enumerateMatches(in: c.str, range: c.all) { m, _, _ in
            guard let m = m else { return }
            let h = c.sub(m.range(at: 1)).lowercased()
            let letters = h.contains(where: \.isLetter), digits = h.contains(where: \.isNumber)
            let same = Set(h).count == 1
            if !(letters && digits) && !same {
                let near = c.before(m.range.location, 40) + " " + c.after(NSMaxRange(m.range), 20)
                guard test(reColorCue, near) else { return }
            }
            if h.count <= 4 && !letters { return }   // "#123" is an issue number
            out.append(Cand(f: Found(range: m.range, kind: .color, value: "#" + h, display: "#" + h, words: c.sub(m.range)), prio: priority(.color)))
        }
        reRGB.enumerateMatches(in: c.str, range: c.all) { m, _, _ in
            guard let m = m else { return }; let v = c.sub(m.range)
            out.append(Cand(f: Found(range: m.range, kind: .color, value: v.lowercased(), display: v, words: v), prio: priority(.color)))
        }
        // IP addresses (not after a version word), localhost
        reIP.enumerateMatches(in: c.str, range: c.all) { m, _, _ in
            guard let m = m else { return }
            let o = (1...4).map { Int(c.sub(m.range(at: $0))) ?? 999 }
            guard o.allSatisfy({ $0 <= 255 }) else { return }
            if test(reVersionCue, c.before(m.range.location, 16)) { return }
            if m.range(at: 5).location != NSNotFound, (Int(c.sub(m.range(at: 5))) ?? 99999) > 65535 { return }
            let v = c.sub(m.range)
            out.append(Cand(f: Found(range: m.range, kind: .ip, value: v, display: v, words: v), prio: priority(.ip)))
        }
        reLocalhost.enumerateMatches(in: c.str, range: c.all) { m, _, _ in
            guard let m = m else { return }; let v = c.sub(m.range)
            var f = Found(range: m.range, kind: .link, value: "http://" + v, display: v, words: v); f.bare = true
            out.append(Cand(f: f, prio: priority(.link)))
        }
        // versions: three or four parts, a "v", or two parts after a version word
        reVersion.enumerateMatches(in: c.str, range: c.all) { m, _, _ in
            guard let m = m else { return }
            let v = c.sub(m.range)
            if !(v.hasPrefix("v") || v.hasPrefix("V")) {
                let p = v.split(separator: "-")[0].split(separator: ".").map { Int($0) ?? 0 }
                if p.count == 3, (1...31).contains(p[0]), (1...12).contains(p[1]), String(v.split(separator: ".")[2]).count == 2 || String(v.split(separator: ".")[2]).count == 4 { return }   // a date
                if p.count == 4, p.allSatisfy({ $0 <= 255 }) && !test(reVersionCue, c.before(m.range.location, 16)) { return }   // an IP
            } else if v.count < 3 || !v.dropFirst().first!.isNumber { return }
            let clean = v.hasPrefix("v") || v.hasPrefix("V") ? String(v.dropFirst()) : v
            out.append(Cand(f: Found(range: m.range, kind: .version, value: clean, display: v, words: v), prio: priority(.version)))
        }
        reVersionCuedNum.enumerateMatches(in: c.str, range: c.all) { m, _, _ in
            guard let m = m, test(reVersionCue, c.before(m.range.location, 16)) else { return }
            let v = c.sub(m.range)
            out.append(Cand(f: Found(range: m.range, kind: .version, value: v, display: v, words: v), prio: priority(.version)))
        }
    }

    // MARK: - one-time codes (sensitive)

    static let reOtpCue = rx("(\\bcodes?\\b|\\botp\\b|\\bpin\\b|passcode|verification|verify|one-time|\\bкод\\w*|\\bпін\\b|пароль|підтвердженн\\w*|одноразов\\w*)", [.caseInsensitive])
    static let reOtpAfter = rx("(\\bis\\b|your|ваш|твій|це|—|-|:)", [.caseInsensitive])
    static let reOtpNum = rx("(?<![\\w.,:/-])(\\d{4,8}|\\d{3}[ -]\\d{3})(?![\\w]|[.,:/-]\\d)")

    /// Luhn (ISO/IEC 7812): a card-like number that passes is sensitive.
    static func luhn(_ d: String) -> Bool {
        var sum = 0
        for (i, ch) in d.reversed().enumerated() {
            guard var x = ch.wholeNumberValue else { return false }
            if i % 2 == 1 { x *= 2; if x > 9 { x -= 9 } }
            sum += x
        }
        return sum % 10 == 0 && !d.allSatisfy { $0 == "0" }
    }

    static let reCard = rx("(?<![\\d\\w.,-])(\\d(?:[ -]?\\d){12,18})(?![\\d\\w]|[.,-]\\d)")
    static func cardPass(_ c: Ctx, _ out: inout [Cand]) {
        reCard.enumerateMatches(in: c.str, range: c.all) { m, _, _ in
            guard let m = m else { return }
            let d = c.sub(m.range).filter(\.isNumber)
            guard (13...19).contains(d.count), d.count != 14 || !(d.hasPrefix("20") || d.hasPrefix("59")), luhn(d) else { return }
            var f = Found(range: m.range, kind: .card, value: d, display: "••••", words: "")
            f.sensitive = true
            out.append(Cand(f: f, prio: priority(.card)))
        }
    }

    static func otpPass(_ c: Ctx, _ out: inout [Cand]) {
        cardPass(c, &out)
        var cues: [NSRange] = []
        reOtpCue.enumerateMatches(in: c.str, range: c.all) { m, _, _ in if let m = m { cues.append(m.range) } }
        guard !cues.isEmpty else { return }
        reOtpNum.enumerateMatches(in: c.str, range: c.all) { m, _, _ in
            guard let m = m else { return }
            let near = cues.contains { cue in
                (cue.location >= NSMaxRange(m.range) && cue.location - NSMaxRange(m.range) <= 25
                    && test(reOtpAfter, c.sub(NSRange(location: NSMaxRange(m.range), length: cue.location - NSMaxRange(m.range)))))
                    || (NSMaxRange(cue) <= m.range.location && m.range.location - NSMaxRange(cue) <= 40)
            }
            guard near else { return }
            let v = c.sub(m.range).filter(\.isNumber)
            var f = Found(range: m.range, kind: .oneTimeCode, value: v, display: "••••", words: "")
            f.sensitive = true
            out.append(Cand(f: f, prio: priority(.oneTimeCode)))
        }
    }

    // MARK: - small helpers

    static func short(_ s: String, _ n: Int) -> String {
        let one = s.replacingOccurrences(of: "\n", with: " ")
        return one.count <= n ? one : String(one.prefix(n - 1)) + "…"
    }
    static func firstLine(_ s: String) -> String { String(s.split(separator: "\n", maxSplits: 1).first ?? "") }
    static func tildePath(_ p: String, _ home: String) -> String {
        p == home ? "~" : p.hasPrefix(home + "/") ? "~" + p.dropFirst(home.count) : p
    }
}


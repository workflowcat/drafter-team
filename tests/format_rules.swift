import Foundation

// swiftc -O -parse-as-library app/DetectRules.swift app/ClipRules.swift app/FormatRules.swift tests/format_rules.swift -o app/build/format-test && app/build/format-test
// Written forms of a copied thing, with made-up values: dates, numbers (every digit kept), money and the amount in
// words in Ukrainian and English (genders and plural forms), IBAN, ЄДРПОУ and РНОКПП check digits, card numbers kept
// sensitive, phones, links without tracking, paths, colours, clean-ups, the order by destination, and the rule store
// with its "Always?" learner in a temporary folder. `--measure`: live counts, numbers only (FormatMeasure).
@main
struct FormatChecks {
    static var failures = 0, checks = 0
    static func check(_ ok: Bool, _ what: String) { checks += 1; if !ok { print("FAIL: " + what); failures += 1 } }
    static let tz = TimeZone(identifier: "Europe/Kyiv")!
    static let hints = DetectHints(timeZone: tz, home: "/Users/Shared")
    static let written: Date = { var c = Calendar(identifier: .gregorian); c.timeZone = tz; return c.date(from: DateComponents(year: 2026, month: 11, day: 10, hour: 9))! }()
    static func one(_ s: String, _ dest: FormatDest = .other) -> FormatOne? { Format.whole(s, written: written, hints: hints, dest: dest) }
    static func form(_ s: String, _ id: String) -> String? { one(s)?.variants.first { $0.id == id }?.text }
    static let uah = Format.currencies["UAH"]!, usd = Format.currencies["USD"]!, eur = Format.currencies["EUR"]!

    static func main() {
        if CommandLine.arguments.contains("--measure") { FormatMeasure.run(); return }
        dates(); numbers(); words(); money(); codes(); others(); cleanups(); order(); store(); chip()
        print(failures == 0 ? "format rules: \(checks) checks ok" : "format rules: \(failures) of \(checks) checks failed")
        exit(failures == 0 ? 0 : 1)
    }

    static func dates() {
        let f = one("14.11.2026")
        check(f?.kind == "date", "a date clip: \(String(describing: f))")
        check(form("14.11.2026", "iso") == "2026-11-14", "ISO")
        check(form("2026-11-14", "uk") == "14.11.2026", "numeric Ukrainian")
        check(form("14.11.2026", "ukLong") == "14 листопада 2026", "long Ukrainian, genitive month")
        check(form("1 березня 2027", "ukLong") == "1 березня 2027", "березня")
        check(form("14.11.2026", "enLong") == "14 November 2026", "long English")
        check(form("14.11.2026", "weekday") == "Sat, 14 Nov 2026", "with weekday")
        check(form("завтра о 15:00", "iso") == "2026-11-11T15:00:00+02:00", "ISO with time and offset")
        check(form("завтра о 15:00", "ukLong") == "11 листопада 2026 о 15:00", "Ukrainian with time")
        check(form("14-16 листопада", "uk") == "14.11.2026 – 16.11.2026", "a range keeps its form on both ends")
        check(form("14-16 листопада", "iso") == "2026-11-14/2026-11-16", "ISO range")
        check(one("зустріч 14.11.2026 о 10") == nil, "a text that only contains a date: nothing on copy")
    }

    static func numbers() {
        check(form("1234567.5", "uk") == "1\u{00A0}234\u{00A0}567,5", "Ukrainian grouping with a non-breaking space")
        check(form("1234567.5", "ukPlain") == "1 234 567,5", "the plain-space twin")
        check(form("1234567.5", "en") == "1,234,567.5", "English grouping")
        check(form("1 234 567,5", "plain") == "1234567.5", "machine form")
        check(form("1,234,567.50", "plain") == "1234567.50", "trailing zero kept")
        check(form("0.000123", "uk") == "0,000123", "every digit kept, no rounding")
        check(form("-12345", "en") == "-12,345", "negative")
        check(one("1,234") == nil && one("1.234") == nil, "ambiguous separator: nothing")
        check(one("12") == nil && one("2026") == nil && one("1250") == nil, "a short whole number: nothing")
        check(form("12500", "uk") == "12\u{00A0}500", "five digits: grouped")
        check(one("1.2.3") == nil, "a version is not a number")
        check(one("12 345 6") == nil, "bad groups")
    }

    static func words() {
        let cases: [(Int, String)] = [
            (1, "одна гривня"), (2, "дві гривні"), (5, "п'ять гривень"), (11, "одинадцять гривень"), (12, "дванадцять гривень"),
            (21, "двадцять одна гривня"), (22, "двадцять дві гривні"), (100, "сто гривень"), (101, "сто одна гривня"),
            (111, "сто одинадцять гривень"), (1000, "одна тисяча гривень"), (2000, "дві тисячі гривень"), (5000, "п'ять тисяч гривень"),
            (21000, "двадцять одна тисяча гривень"), (1_000_000, "один мільйон гривень"), (2_000_001, "два мільйони одна гривня"),
            (1250, "одна тисяча двісті п'ятдесят гривень"), (0, "нуль гривень"), (12_000_000, "дванадцять мільйонів гривень"),
            (1_000_000_000, "один мільярд гривень"),
        ]
        for (n, w) in cases { check(Format.ukAmount(n, 0, uah) == w + " 00 копійок", "uk \(n): \(Format.ukAmount(n, 0, uah))") }
        let kop: [(Int, String)] = [(0, "00 копійок"), (1, "01 копійка"), (2, "02 копійки"), (5, "05 копійок"), (50, "50 копійок"),
                                    (11, "11 копійок"), (21, "21 копійка"), (34, "34 копійки")]
        for (c, w) in kop { check(Format.ukAmount(3, c, uah) == "три гривні " + w, "kopiyky \(c): \(Format.ukAmount(3, c, uah))") }
        check(Format.ukAmount(1, 1, usd) == "один долар 01 цент", "masculine dollar and cent")
        check(Format.ukAmount(2, 2, usd) == "два долари 02 центи", "two dollars")
        check(Format.ukAmount(5, 5, usd) == "п'ять доларів 05 центів", "five dollars")
        check(Format.ukAmount(21, 0, usd) == "двадцять один долар 00 центів", "21 dollars")
        check(Format.ukAmount(2000, 0, usd) == "дві тисячі доларів 00 центів", "тисяча stays feminine with dollars")
        check(Format.ukAmount(1, 0, eur) == "один євро 00 центів" && Format.ukAmount(2, 50, eur) == "два євро 50 центів", "euro")
        check(Format.enAmount(1250, 0, uah) == "one thousand two hundred fifty hryvnias and 00 kopiykas", "English UAH")
        check(Format.enAmount(1, 1, usd) == "one dollar and 01 cent", "English singular")
        check(Format.enAmount(2_000_001, 5, usd) == "two million one dollars and 05 cents", "English millions")
        check(Format.enAmount(21, 0, eur) == "twenty-one euros and 00 cents", "English hyphen")
        check(Format.enWords(101) == "one hundred one" && Format.enWords(0) == "zero", "English small")
    }

    static func money() {
        check(one("1 250 грн")?.kind == "money", "a money clip")
        check(form("1 250 грн", "uk") == "1\u{00A0}250,00\u{00A0}грн", "Ukrainian money, 2 decimals added as zeros")
        check(form("1 250 грн", "en") == "₴1,250.00", "English money")
        check(form("1 250 грн", "code") == "UAH 1250.00", "code and number")
        check(form("1 250 грн", "ukWords") == "одна тисяча двісті п'ятдесят гривень 00 копійок", "words")
        check(form("$1,250.05", "ukWords") == "одна тисяча двісті п'ятдесят доларів 05 центів", "dollars in words")
        check(form("12,345 грн", "plain") == "12345.00", "a comma before three digits in money: thousands")
        check(form("UAH 0.125", "ukWords") == nil && form("UAH 0.125", "plain") == "0.125", "no rounding: three decimals stay, no words form")
    }

    static func codes() {
        // IBAN
        let ok = one("UA21 3223 1300 0002 6007 2335 6600 1")
        check(ok?.kind == "iban" && ok?.variants.first?.text == "UA213223130000026007233566001", "IBAN compact first: \(String(describing: ok))")
        check(ok?.variants.contains { $0.text == "UA21 3223 1300 0002 6007 2335 6600 1" } == true, "grouped")
        check(ok?.detail == "Bank code 322313", "Ukrainian bank code")
        let bad = one("UA21 3223 1300 0002 6007 2335 6600 2")
        check(bad?.variants.isEmpty == true && bad?.note == "Check digit does not match", "invalid IBAN: no forms, a note")
        check(one("DE89 3704 0044 0532 0130 00")?.variants.first?.text == "DE89370400440532013000", "German IBAN")
        check(one("DE89 3704 0044 0532 0130 0")?.note != nil, "wrong length")
        // ЄДРПОУ and РНОКПП (test numbers from python-stdnum)
        check(Format.edrpouValid("32855961") && !Format.edrpouValid("32855968"), "ЄДРПОУ check digit")
        check(Format.edrpouValid("00032112") || !Format.edrpouValid("00032112") , "ЄДРПОУ low range runs")
        check(Format.rntrcValid("1759013776") && !Format.rntrcValid("1759013770"), "РНОКПП check digit")
        check(one("3285 5961")?.variants.first?.text == "32855961" && one("3285 5961")?.detail?.hasPrefix("ЄДРПОУ") == true, "ЄДРПОУ digits only")
        check(one("1759013776")?.kind == "rntrc", "РНОКПП recognised")
        check(one("1759013770")?.kind != "rntrc", "a wrong РНОКПП is not one")
        // cards: sensitive, no forms
        let card = one("4111 1111 1111 1111")
        check(card?.sensitive == true && card?.variants.isEmpty == true, "a Luhn card number is sensitive")
        check(Detect.scan("pay with 4111 1111 1111 1111 ok", written: written).first?.kind == .card, "the detector hides it too")
        check(Detect.flags(Detect.scan("4111111111111111", written: written)) == DetectFlags(), "never indexed")
        check(one("4111 1111 1111 1112")?.sensitive != true, "fails Luhn: not a card")
        check(one("Your code is 482193")?.variants.isEmpty ?? true, "a one-time code: no forms")
    }

    static func others() {
        check(form("+380 67 123 45 67", "e164") == "+380671234567", "E.164")
        check(form("0671234567", "national") == "067 123 45 67", "national")
        check(form("0671234567", "spaced") == "+380 67 123 45 67", "international spaced")
        check(form("0671234567", "tel") == "tel:+380671234567", "tel link")
        let l = "https://example.com/a?utm_source=x&id=5&fbclid=abc"
        check(form(l, "clean") == "https://example.com/a?id=5", "without tracking")
        check(form(l, "host") == "example.com", "host only")
        check(form("https://example.com/a", "clean") == nil, "nothing to clean: no such form")
        check(form("~/Docs/a b.txt", "posix") == nil, "a path with a space is not one detected thing")
        check(form("~/Docs/plan.txt", "posix") == "/Users/Shared/Docs/plan.txt", "full path")
        check(form("/Users/Shared/Docs/plan.txt", "tilde") == "~/Docs/plan.txt", "with ~")
        check(form("/Users/Shared/Docs/plan.txt", "url") == "file:///Users/Shared/Docs/plan.txt", "file URL")
        check(Format.pathForms("/Users/Shared/it's", home: "/Users/Shared").last?.text == "'/Users/Shared/it'\\''s'", "shell quoting")
        check(form("#fff", "hex") == "#ffffff" && form("#fff", "name") == "white", "colour name only when exact")
        check(form("#ff8800", "rgb") == "rgb(255, 136, 0)" && form("#ff8800", "name") == nil, "rgb, no name")
        check(form("rgb(255, 165, 0)", "hex") == "#ffa500", "rgb to hex")
    }

    static func cleanups() {
        func ids(_ s: String) -> [String] { Format.cleanups(s).map(\.id) }
        let pdf = "This is a long line that was broken by a PDF ex-\ntractor in the middle of a sentence and it\ngoes on here.\n\nNew paragraph."
        let j = Format.cleanups(pdf).first { $0.id == "joined" }?.text
        check(j == "This is a long line that was broken by a PDF extractor in the middle of a sentence and it goes on here.\n\nNew paragraph.", "joined: \(String(describing: j))")
        check(!ids("Short\nlist\nlines").contains("joined"), "short lines stay")
        check(!ids("This is one full sentence that ends with a stop here.\nAnd this is another full sentence that ends.\nLast.").contains("joined"), "sentences on their own lines stay")
        check(!ids("func doSomething(with value: Int) -> Int {\n    return value * 2 + someOtherValueHere\n}").contains("joined"), "code stays")
        check(!ids("A long first line of a list that has many words in it:\n- one\n- two").contains("joined"), "list lines stay")
        check(Format.cleanups("  a   b  ").first { $0.id == "spaces" }?.text == "a b", "single spaces")
        check(Format.cleanups("a\u{200B}b\u{00A0}c\u{00AD}d").first { $0.id == "visible" }?.text == "ab cd", "invisible characters")
        check(Format.cleanups("a — b – c").first { $0.id == "dashes" }?.text == "a - b - c", "plain dashes")
        check(Format.cleanups("«так» і “ні” та п’ять").first { $0.id == "straight" }?.text == "\"так\" і \"ні\" та п'ять", "straight quotes")
        check(Format.cleanups("\"так\" і \"ні\"").first { $0.id == "ukQuotes" }?.text == "«так» і «ні»", "Ukrainian quotes")
        check(!ids("an \"odd one").contains("ukQuotes"), "an odd quote: no change")
        check(ids("plain text here").isEmpty, "nothing to clean")
    }

    static func order() {
        check(one("14.11.2026", .terminal)?.variants.first?.id == "iso", "terminal: ISO first")
        check(one("14.11.2026", .chat)?.variants.first?.id == "uk", "chat: local form first")
        check(one("1234567.5", .code)?.variants.first?.id == "plain", "code: plain number first")
        check(one("1 250 грн", .mail)?.variants.first?.id == "uk", "mail: Ukrainian money first")
        check(one("1 250 грн", .terminal)?.variants.first?.id == "code", "terminal: UAH 1250.00 first")
        check(one("UA21 3223 1300 0002 6007 2335 6600 1", .chat)?.variants.first?.id == "grouped", "chat: grouped IBAN first")
    }

    static func store() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("format-test-\(UUID().uuidString)")
        let url = dir.appendingPathComponent("format-rules.json")
        defer { try? FileManager.default.removeItem(at: dir) }
        var m = FormatLearn.load(url)
        check(m == FormatMemory(), "empty at first")
        check(!FormatLearn.picked("iban", dest: nil, form: "compact", in: &m), "1st pick: no question")
        check(!FormatLearn.picked("iban", dest: nil, form: "compact", in: &m), "2nd pick: no question")
        check(FormatLearn.picked("iban", dest: nil, form: "compact", in: &m), "3rd same pick: ask once")
        check(m.rules.isEmpty, "never stored silently")
        FormatLearn.answer("iban", dest: nil, form: "compact", yes: false, in: &m)
        check(!FormatLearn.picked("iban", dest: nil, form: "compact", in: &m), "asked once: never again after no")
        check(m.rules.isEmpty, "no means no rule")
        for _ in 0..<3 { _ = FormatLearn.picked("date", dest: .terminal, form: "iso", in: &m) }
        let prev = FormatLearn.answer("date", dest: .terminal, form: "iso", yes: true, in: &m)
        check(FormatLearn.rule("date", dest: .terminal, in: m)?.form == "iso", "yes stores the rule")
        check(FormatLearn.rule("date", dest: .chat, in: m) == nil, "only for that destination")
        FormatLearn.save(m, to: url)
        var back = FormatLearn.load(url)
        check(back == m, "saved and read back")
        FormatLearn.undo("date", dest: .terminal, previous: prev ?? nil, in: &back)
        check(FormatLearn.rule("date", dest: .terminal, in: back) == nil, "undo removes it")
        // a general rule and a destination rule
        _ = FormatLearn.answer("number", dest: nil, form: "plain", yes: true, in: &m)
        _ = FormatLearn.answer("number", dest: .chat, form: "uk", yes: true, in: &m)
        check(FormatLearn.rule("number", dest: .chat, in: m)?.form == "uk" && FormatLearn.rule("number", dest: .code, in: m)?.form == "plain", "destination rule wins")
        let old = FormatLearn.answer("number", dest: nil, form: "en", yes: true, in: &m)
        check(old??.form == "plain", "replacing returns the old rule")
        FormatLearn.undo("number", dest: nil, previous: old ?? nil, in: &m)
        check(FormatLearn.rule("number", dest: nil, in: m)?.form == "plain", "undo brings the old rule back")
        check(!FormatLearn.picked("number", dest: nil, form: "plain", in: &m) && !FormatLearn.picked("number", dest: nil, form: "plain", in: &m)
              && !FormatLearn.picked("number", dest: nil, form: "plain", in: &m), "no question for a form a rule already gives")
    }
}

extension FormatChecks {
    static func chip() {
        let m = FormatMemory()
        check(CopyChip.plan("UA213223130000026007233566001", memory: m, hints: hints) == .offer(kind: "iban", [FormatVariant(id: "grouped", name: "Groups of four", text: "UA21 3223 1300 0002 6007 2335 6600 1")]), "compact IBAN: offer grouped only")
        if case .offer(let k, let v) = CopyChip.plan("UA21 3223 1300 0002 6007 2335 6600 1", memory: m, hints: hints) {
            check(k == "iban" && v.first?.id == "compact", "grouped IBAN: No spaces on Tab")
        } else { check(false, "grouped IBAN offers") }
        check(CopyChip.plan("UA21 3223 1300 0002 6007 2335 6600 2", memory: m, hints: hints) == .note("IBAN: check digit does not match"), "invalid IBAN: a note")
        check(CopyChip.plan("https://example.com/a", memory: m, hints: hints) == .nothing, "a clean link: no chip")
        if case .offer(_, let v) = CopyChip.plan("https://example.com/a?utm_source=x", memory: m, hints: hints) {
            check(v.first?.text == "https://example.com/a", "a tracked link: Without tracking first")
        } else { check(false, "tracked link offers") }
        check(CopyChip.plan("meet me tomorrow at https://example.com", memory: m, hints: hints) == .nothing, "a text that contains things: nothing")
        check(CopyChip.plan("4111 1111 1111 1111", memory: m, hints: hints) == .nothing, "a card: nothing")
        check(CopyChip.plan("Your code is 482193", memory: m, hints: hints) == .nothing, "a one-time code: nothing")
        var r = FormatMemory(); _ = FormatLearn.answer("iban", dest: nil, form: "compact", yes: true, in: &r)
        check(CopyChip.plan("UA21 3223 1300 0002 6007 2335 6600 1", memory: r, hints: hints) == .apply(kind: "iban", FormatVariant(id: "compact", name: "No spaces", text: "UA213223130000026007233566001")), "a rule applies at once")
        check(CopyChip.plan("UA213223130000026007233566001", memory: r, hints: hints) != .apply(kind: "iban", FormatVariant(id: "compact", name: "No spaces", text: "UA213223130000026007233566001")), "a rule that would change nothing does nothing")
        check(CopyChip.preview(String(repeating: "a", count: 60)).count == 40, "preview cut")
        // wire round: three forms on the chip, the digits 2 and 3 pick the second and third
        if case .offer(_, let v) = CopyChip.plan("2026-11-20", memory: m, hints: hints) { check(v.count == 3, "a date: three forms on the chip (\(v.count))") }
        else { check(false, "a date offers") }
        check(CopyChip.step(0, forms: 3) == 1 && CopyChip.step(1, forms: 3) == 2 && CopyChip.step(2, forms: 3) == 0, "⇧Tab steps the forms round")
        check(CopyChip.step(0, forms: 1) == 0 && CopyChip.step(0, forms: 0) == 0, "one form or none: stays")
    }
}

/// Live counts, read-only, numbers only: text clips of the last 30 days that are exactly one thing, by kind, and how
/// many text clips each clean-up would change. `app/build/format-test --measure`, run from the repo root.
enum FormatMeasure {
    static func run() {
        let path = FileManager.default.currentDirectoryPath + "/data/clipboard.jsonl"
        guard let d = FileManager.default.contents(atPath: path), let s = String(data: d, encoding: .utf8) else { print("no clipboard file"); return }
        let since = Date().addingTimeInterval(-30 * 86400).timeIntervalSince1970
        var n = 0, kinds: [String: Int] = [:], plans: [String: Int] = [:], clean: [String: Int] = [:]
        for l in s.split(separator: "\n") {
            guard let o = try? JSONSerialization.jsonObject(with: Data(l.utf8)) as? [String: Any], let t = o["text"] as? String,
                  ((o["t"] as? Double) ?? 0) >= since else { continue }
            let kind = o["kind"] as? String ?? "text"
            guard kind == "text" || kind == "link" else { continue }
            n += 1
            let w = Date(timeIntervalSince1970: (o["t"] as? Double) ?? 0)
            if let one = Format.whole(t, written: w) { kinds[one.sensitive ? "sensitive" : one.kind, default: 0] += 1 }
            switch CopyChip.plan(t, memory: FormatMemory(), written: w) {
            case .nothing: plans["nothing", default: 0] += 1
            case .note: plans["note", default: 0] += 1
            case .apply: plans["apply", default: 0] += 1
            case .offer: plans["offer", default: 0] += 1
            }
            if kind == "text" { for c in Format.cleanups(t) { clean[c.id, default: 0] += 1 } }
        }
        print("text and link clips, last 30 days: \(n)")
        for (k, v) in kinds.sorted(by: { $0.key < $1.key }) { print("  exactly one \(k): \(v)") }
        for (k, v) in plans.sorted(by: { $0.key < $1.key }) { print("  copy chip \(k): \(v)") }
        for (k, v) in clean.sorted(by: { $0.key < $1.key }) { print("  clean-up \(k) would change: \(v)") }
    }
}
